//
//  DSKernel.m — 内核逃逸的实际调用方
//
//  后端：ClearSword（公开的 DarkSword C 移植，见 Vendor/ClearSword/NOTICE.md）
//  逃逸：DSEscape.m（我们自己写的沙盒改写 + root 凭据改写，带地址合法性与 getpid 自校验）
//
//  三条硬规则：
//   1. 内核漏洞只在用户主动点「激活」时执行一次，同一进程内绝不重跑；
//   2. 任何内核读之前先验地址合法性（上游 krw 在非法地址上会 while(1) 卡死 / 故意崩溃）；
//   3. 所有能力都要自检（探针写盘 + getuid），不做「装作成功」。
//

#import "DSKernel.h"

#import <UIKit/UIKit.h>
#import <sys/sysctl.h>
#import <sys/stat.h>
#import <sys/mount.h>
#import <unistd.h>
#import <fcntl.h>
#import <errno.h>
#import <string.h>
#import <dlfcn.h>

#import "darksword.h"     // lara: ds_run / ds_is_ready / ds_kread* / kernel_base
#import "utils.h"         // lara: ourproc / procbypid / init_offsets
#import "sbx.h"           // lara: sbx_escape 沙盒逃逸
#import "offsets.h"       // lara: offsets_init()（按版本/机型填 off_* 全局量）
#import "DSEscape.h"      // 回退路线：cred 定位 + lara 的 offsets/S() 链路
#import "machine_info.h"  // CPU 家族宏（随 lara 目录带过来的一份常量头）

#pragma mark - 状态

static BOOL gExploitRunning = NO;
static BOOL gExploitAttempted = NO;
static BOOL gExploitDone    = NO;
static BOOL gEscaped        = NO;
static NSError *gLastError  = nil;

#pragma mark - 日志桥

static DSKernelLogBlock gEscapeLogBridge = nil;

/// DSEscape 是 C 层，用函数指针回调；这里转成我们的 block 并切回主线程
static void ds_escape_log_bridge(const char *message)
{
    if (!message) return;
    NSString *line = [NSString stringWithUTF8String:message];
    if (!line) return;
    DSKernelLogBlock sink = gEscapeLogBridge;
    if (!sink) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        sink(line);
    });
}

#pragma mark - stdout / stderr 捕获（内核漏洞只会 printf，必须抓下来才能排错）

static int gPipeRead = -1;
static int gPipeWrite = -1;
static int gSavedStdout = -1;
static int gSavedStderr = -1;
static dispatch_source_t gReadSource = nil;
static NSMutableData *gLineBuffer = nil;
static DSKernelLogBlock gLogSink = nil;

static void ds_emit_line(NSString *line)
{
    if (!line) return;
    DSKernelLogBlock sink = gLogSink;
    if (!sink) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        sink(line);
    });
}

static void ds_capture_start(DSKernelLogBlock log)
{
    if (gReadSource) return;
    gLogSink = [log copy];
    gLineBuffer = [NSMutableData data];

    int fds[2];
    if (pipe(fds) != 0) return;
    gPipeRead = fds[0];
    gPipeWrite = fds[1];

    gSavedStdout = dup(STDOUT_FILENO);
    gSavedStderr = dup(STDERR_FILENO);
    dup2(gPipeWrite, STDOUT_FILENO);
    dup2(gPipeWrite, STDERR_FILENO);
    setvbuf(stdout, NULL, _IOLBF, 0);

    int flags = fcntl(gPipeRead, F_GETFL, 0);
    fcntl(gPipeRead, F_SETFL, flags | O_NONBLOCK);

    dispatch_queue_t q = dispatch_queue_create("com.dsfile.capture", DISPATCH_QUEUE_SERIAL);
    gReadSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, (uintptr_t)gPipeRead, 0, q);
    dispatch_source_set_event_handler(gReadSource, ^{
        uint8_t buf[8192];
        ssize_t n = read(gPipeRead, buf, sizeof(buf));
        if (n <= 0) return;

        @synchronized (gLineBuffer) {
            [gLineBuffer appendBytes:buf length:(NSUInteger)n];
            const uint8_t *bytes = (const uint8_t *)gLineBuffer.bytes;
            NSUInteger total = gLineBuffer.length;
            NSUInteger start = 0;
            for (NSUInteger i = 0; i < total; i++) {
                if (bytes[i] == '\n') {
                    NSData *lineData = [gLineBuffer subdataWithRange:NSMakeRange(start, i - start)];
                    NSString *line = [[NSString alloc] initWithData:lineData encoding:NSUTF8StringEncoding];
                    if (!line) {
                        line = [[NSString alloc] initWithData:lineData encoding:NSISOLatin1StringEncoding];
                    }
                    ds_emit_line(line ?: @"");
                    start = i + 1;
                }
            }
            if (start > 0) {
                [gLineBuffer replaceBytesInRange:NSMakeRange(0, start) withBytes:NULL length:0];
            }
        }
    });
    dispatch_resume(gReadSource);
}

static void ds_capture_stop(void)
{
    if (gReadSource) {
        dispatch_source_cancel(gReadSource);
        gReadSource = nil;
    }
    if (gSavedStdout >= 0) { dup2(gSavedStdout, STDOUT_FILENO); close(gSavedStdout); gSavedStdout = -1; }
    if (gSavedStderr >= 0) { dup2(gSavedStderr, STDERR_FILENO); close(gSavedStderr); gSavedStderr = -1; }
    if (gPipeWrite >= 0) { close(gPipeWrite); gPipeWrite = -1; }
    if (gPipeRead >= 0) { close(gPipeRead); gPipeRead = -1; }
    gLogSink = nil;
}

#pragma mark - 内核地址判据

/// 与上游 is_kaddr_valid / ClearSword 补丁里用的判据一致：高 24 位必须是 0xfffff…
static inline BOOL ds_is_kernel_address(uint64_t address)
{
    return (address & 0xfffff00000000000ULL) == 0xfffff00000000000ULL;
}

/// 漏洞跑完之后，先确认真的拿到了可用的 socket，再碰内核（lara 自己提供了 ready 标志）
static BOOL ds_kernel_rw_healthy(void)
{
    return ds_is_ready();
}

#pragma mark - 探针

static BOOL ds_probe_write_access(void)
{
    const char *paths[] = { "/var/mobile/.dsfile_probe", "/var/tmp/.dsfile_probe" };
    for (int i = 0; i < 2; i++) {
        int fd = open(paths[i], O_WRONLY | O_CREAT | O_TRUNC, 0644);
        if (fd >= 0) {
            close(fd);
            unlink(paths[i]);
            return YES;
        }
    }
    return NO;
}

static NSString *ds_sysctl_string(const char *name)
{
    size_t size = 0;
    if (sysctlbyname(name, NULL, &size, NULL, 0) != 0 || size == 0) return nil;
    char *buf = calloc(1, size + 1);
    if (!buf) return nil;
    NSString *result = nil;
    if (sysctlbyname(name, buf, &size, NULL, 0) == 0) {
        result = [NSString stringWithUTF8String:buf];
    }
    free(buf);
    return result;
}

static uint32_t ds_cpu_family(void)
{
    uint32_t family = 0;
    size_t size = sizeof(family);
    if (sysctlbyname("hw.cpufamily", &family, &size, NULL, 0) != 0) return 0;
    return family;
}

@implementation DSKernel

#pragma mark - 设备 / 系统

+ (NSString *)deviceModelIdentifier
{
    NSString *model = ds_sysctl_string("hw.machine");
    return model ?: @"unknown";
}

+ (NSString *)systemVersion
{
    return [UIDevice currentDevice].systemVersion ?: @"unknown";
}

+ (NSString *)cpuFamilyName
{
    uint32_t family = ds_cpu_family();
    switch (family) {
        case CPUFAMILY_ARM_HURRICANE:            return @"A10";
        case CPUFAMILY_ARM_MONSOON_MISTRAL:      return @"A11";
        case CPUFAMILY_ARM_VORTEX_TEMPEST:       return @"A12";
        case CPUFAMILY_ARM_LIGHTNING_THUNDER:    return @"A13";
        case CPUFAMILY_ARM_FIRESTORM_ICESTORM:   return @"A14 / M1";
        case CPUFAMILY_ARM_BLIZZARD_AVALANCHE:   return @"A15 / M2";
        case CPUFAMILY_ARM_EVEREST_SAWTOOTH:     return @"A16";
        case CPUFAMILY_ARM_COLL:                 return @"A17 Pro";
        case CPUFAMILY_ARM_IBIZA:                return @"M3";
        case CPUFAMILY_ARM_TUPAI:                return @"A18";
        case CPUFAMILY_ARM_TAHITI:               return @"A18 Pro";
        case CPUFAMILY_ARM_DONAN:                return @"M4";
        case CPUFAMILY_ARM_TILOS:                return @"A19";
        case CPUFAMILY_ARM_THERA:                return @"A19 Pro";
        default: break;
    }
    return [NSString stringWithFormat:@"未知 (0x%08x)", family];
}

+ (BOOL)isSystemVersionSupported
{
    // ClearSword 的 offsets_init 只覆盖 17.0 ≤ 版本 < 26.1；这里不依赖任何第三方宏
    NSOperatingSystemVersion version = [[NSProcessInfo processInfo] operatingSystemVersion];
    if (version.majorVersion < 17) return NO;
    if (version.majorVersion > 26) return NO;
    if (version.majorVersion == 26 && version.minorVersion >= 1) return NO;
    return YES;
}

+ (NSString *)supportSummary
{
    NSString *version = [self systemVersion];
    NSString *cpu = [self cpuFamilyName];
    if (![self isSystemVersionSupported]) {
        return [NSString stringWithFormat:@"%@ 不在 DarkSword 覆盖范围内（支持 17.0 – 26.0.x）", version];
    }
    if ([cpu isEqualToString:@"A19"] || [cpu isEqualToString:@"A19 Pro"]) {
        return [NSString stringWithFormat:@"%@ / %@：该芯片暂未被漏洞覆盖，激活大概率失败", version, cpu];
    }
    return [NSString stringWithFormat:@"%@ / %@：在 DarkSword 覆盖范围内", version, cpu];
}

#pragma mark - 状态

+ (BOOL)isEscaped { return gEscaped; }
+ (BOOL)isExploitDone { return gExploitDone; }
+ (BOOL)isRunningAsRoot { return getuid() == 0; }
+ (BOOL)probeFilesystemAccess { return ds_probe_write_access(); }
+ (unsigned long long)kernelBase { return (unsigned long long)kernel_base; }

+ (NSString *)diagnosticsText
{
    NSMutableString *text = [NSMutableString string];
    [text appendFormat:@"后端: lara darksword + pe/sbx_escape\n"];
    [text appendFormat:@"机型: %@\n", [self deviceModelIdentifier]];
    [text appendFormat:@"系统: %@\n", [self systemVersion]];
    [text appendFormat:@"芯片: %@\n", [self cpuFamilyName]];
    [text appendFormat:@"支持判定: %@\n", [self supportSummary]];
    [text appendFormat:@"漏洞已执行: %@\n", gExploitAttempted ? @"是" : @"否"];
    [text appendFormat:@"内核读写已拿到: %@\n", gExploitDone ? @"是" : @"否"];
    [text appendFormat:@"沙盒已逃逸: %@\n", gEscaped ? @"是" : @"否"];
    [text appendFormat:@"当前 uid: %d (%@)\n", getuid(), [self isRunningAsRoot] ? @"root" : @"非 root"];
    [text appendFormat:@"内核基址: 0x%llx（slide 0x%llx）\n",
        (unsigned long long)kernel_base, (unsigned long long)kernel_slide];
    [text appendFormat:@"ds_is_ready: %d / rw_socket: %d / control_socket: %d\n",
        (int)ds_is_ready(), rw_socket, control_socket];
    [text appendFormat:@"rw_socket_pcb: 0x%llx\n", (unsigned long long)ds_get_rw_socket_pcb()];
    [text appendFormat:@"本进程 proc: 0x%llx\n", (unsigned long long)ds_get_our_proc()];
    [text appendFormat:@"现场探针写盘: %@\n", ds_probe_write_access() ? @"通过" : @"失败"];
    if (gLastError) [text appendFormat:@"上一次错误: %@\n", gLastError.localizedDescription];
    return text;
}

#pragma mark - 激活

+ (DSKernelResult)activateWithLog:(DSKernelLogBlock)log
{
    @synchronized (self) {
        if (gExploitRunning) {
            if (log) log(@"[DSFile] 激活正在进行中，忽略重复请求");
            return DSKernelResultBusy;
        }
        gExploitRunning = YES;
    }

    DSKernelResult result = DSKernelResultInternalError;
    @try {
        if (log) ds_capture_start(log);

        if (gEscaped) {
            if (log) log(@"[DSFile] 本进程沙盒已经是逃逸状态");
            result = DSKernelResultAlreadyActive;
        } else if (![self isSystemVersionSupported]) {
            if (log) log([NSString stringWithFormat:@"[DSFile] %@", [self supportSummary]]);
            gLastError = [NSError errorWithDomain:@"DSFile" code:DSKernelResultUnsupportedSystem
                                         userInfo:@{ NSLocalizedDescriptionKey: [self supportSummary] }];
            result = DSKernelResultUnsupportedSystem;
        } else if (gExploitDone) {
            if (log) log(@"[DSFile] 内核读写已在本次进程内取得，跳过漏洞，只重试沙盒改写");
            result = [self ds_escapeStepWithLog:log];
        } else if (gExploitAttempted) {
            if (log) log(@"[DSFile] 本次运行已经执行过一次内核漏洞且没有成功。同一个进程里重跑风险极高，"
                          "请从后台完全退出 App 再重新打开后重试。");
            gLastError = [NSError errorWithDomain:@"DSFile" code:DSKernelResultExploitFailed
                                         userInfo:@{ NSLocalizedDescriptionKey: @"本次运行已尝试过内核漏洞，请重启 App 后再试" }];
            result = DSKernelResultExploitFailed;
        } else {
            gExploitAttempted = YES;
            if (log) log([NSString stringWithFormat:@"[DSFile] 目标: %@ / iOS %@ / %@",
                          [self deviceModelIdentifier], [self systemVersion], [self cpuFamilyName]]);
            if (log) log(@"[DSFile] 开始执行内核漏洞（lara darksword 后端，可能耗时数秒，界面短暂无响应属正常）…");

            int kret = 1;
            @try {
                // lara 的 off_* / PROC_PID_OFFSET 等全局量必须先由 init_offsets() / offsets_init() 填好，
                // 否则 darksword 的漏洞代码会拿着 0 偏移去读写内核。
                init_offsets();
                offsets_init();
                kret = ds_run();
            } @catch (NSException *e) {
                if (log) log([NSString stringWithFormat:@"[DSFile] 漏洞抛出异常: %@", e.reason]);
                kret = -1;
            }

            if (log) log([NSString stringWithFormat:
                          @"[DSFile] 漏洞返回 %d；kernel_base=0x%llx（slide 0x%llx）；ds_is_ready=%d；rw_socket=%d",
                          kret, (unsigned long long)kernel_base, (unsigned long long)kernel_slide,
                          (int)ds_is_ready(), rw_socket]);

            if (kret != 0) {
                if (log) log(@"[DSFile] 内核漏洞没有成功（race 失败是最常见原因）。"
                              "设备没有重启就说明没伤到内核，完全退出 App 重开后再试即可。");
                gLastError = [NSError errorWithDomain:@"DSFile" code:DSKernelResultExploitFailed
                                             userInfo:@{ NSLocalizedDescriptionKey: @"内核漏洞 race 失败，请退出 App 重开后重试" }];
                result = DSKernelResultExploitFailed;
            } else {
                gExploitDone = YES;
                if (log) log([NSString stringWithFormat:@"[DSFile] 内核读写已获得，kernel base = 0x%llx",
                              (unsigned long long)kernel_base]);
                result = [self ds_escapeStepWithLog:log];
            }
        }
    } @finally {
        ds_capture_stop();
        @synchronized (self) { gExploitRunning = NO; }
    }

    return result;
}

+ (DSKernelResult)retrySandboxEscapeWithLog:(DSKernelLogBlock)log
{
    @synchronized (self) {
        if (gExploitRunning) return DSKernelResultBusy;
        gExploitRunning = YES;
    }
    DSKernelResult result = DSKernelResultInternalError;
    @try {
        if (log) ds_capture_start(log);
        if (!gExploitDone) {
            if (log) log(@"[DSFile] 内核读写还没拿到，必须先跑完整激活");
            result = DSKernelResultExploitFailed;
        } else {
            result = [self ds_escapeStepWithLog:log];
        }
    } @finally {
        ds_capture_stop();
        @synchronized (self) { gExploitRunning = NO; }
    }
    return result;
}

/// 只做「沙盒改写 + 自检」这一步
+ (DSKernelResult)ds_escapeStepWithLog:(DSKernelLogBlock)log
{
    if (!ds_kernel_rw_healthy()) {
        if (log) log([NSString stringWithFormat:
                      @"[DSFile] 内核读写不可用（ds_is_ready=%d，rw_socket=%d）。"
                       "请完全退出 App 重开后再点一次「激活内核访问」。",
                      (int)ds_is_ready(), rw_socket]);
        gLastError = [NSError errorWithDomain:@"DSFile" code:DSKernelResultExploitFailed
                                     userInfo:@{ NSLocalizedDescriptionKey: @"内核读写不可用，请退出 App 重开后重试" }];
        return DSKernelResultExploitFailed;
    }

    if (log) log(@"[DSFile] 开始改写本进程沙盒数据（lara sbx_escape）…");
    gEscapeLogBridge = [log copy];
    sbx_setlogcallback(ds_escape_log_bridge);

    uint64_t selfProc = 0;
    @try {
        selfProc = ds_get_our_proc();
    } @catch (NSException *e) {
        if (log) log([NSString stringWithFormat:@"[DSFile] 取本进程 proc 异常: %@", e.reason]);
    }
    if (log) log([NSString stringWithFormat:@"[DSFile] 本进程 proc = 0x%llx", (unsigned long long)selfProc]);

    int sret = 1;
    @try {
        if (selfProc != 0) {
            sret = sbx_escape(selfProc);
        } else {
            // lara 的 proc 恢复（procbysock*）依赖 so_background_thread，本机（18.5/A14）恒为 0，
            // 大概率拿不到 proc；这时回退到我们自己的 cred 定位 + lara 的 offsets/S() 链路。
            if (log) log(@"[DSFile] lara ds_get_our_proc() 返回 0，回退到内置 cred 定位 + 沙盒链路…");
            gEscapeLogBridge = [log copy];
            sret = DSEscapeSandbox(ds_escape_log_bridge);
        }
    } @catch (NSException *e) {
        if (log) log([NSString stringWithFormat:@"[DSFile] 沙盒改写异常: %@", e.reason]);
        sret = -9;
    }
    sbx_setlogcallback(NULL);
    gEscapeLogBridge = nil;
    if (log) log([NSString stringWithFormat:@"[DSFile] 沙盒改写返回 %d", sret]);

    if (ds_probe_write_access()) {
        gEscaped = YES;
        if (log) log(@"[DSFile] *** 沙盒逃逸成功：现在可以读写沙盒外的路径 ***");
        return DSKernelResultOK;
    }

    if (log) log([NSString stringWithFormat:@"[DSFile] 探针写盘失败 (errno=%d: %s)", errno, strerror(errno)]);
    gLastError = [NSError errorWithDomain:@"DSFile" code:DSKernelResultEscapeFailed
                                 userInfo:@{ NSLocalizedDescriptionKey: @"沙盒改写后探针写盘仍失败" }];
    return DSKernelResultEscapeFailed;
}

+ (DSKernelResult)elevateToRootWithLog:(DSKernelLogBlock)log
{
    if (getuid() == 0) return DSKernelResultAlreadyActive;
    if (!gExploitDone) {
        if (log) log(@"[DSFile] 提权需要先有内核读写");
        return DSKernelResultExploitFailed;
    }

    if (log) log(@"[DSFile] 尝试把本进程凭据改成 root…");
    gEscapeLogBridge = [log copy];

    int ret = -1;
    @try {
        // lara 自己的 sbx_elevate 被它们标注为 broken；这里照用，失败也不影响已获得的沙盒逃逸
        ret = sbx_elevate();
    } @catch (NSException *e) {
        if (log) log([NSString stringWithFormat:@"[DSFile] 提权异常: %@", e.reason]);
        ret = -1;
    }
    gEscapeLogBridge = nil;

    if (getuid() == 0) {
        if (log) log(@"[DSFile] 提权成功，当前 uid=0");
        return DSKernelResultOK;
    }
    if (log) log([NSString stringWithFormat:@"[DSFile] 提权失败（ret=%d, uid=%d）", ret, getuid()]);
    return DSKernelResultEscapeFailed;
}

#pragma mark - 文件属性

+ (BOOL)setOwnerOfPath:(NSString *)path uid:(uid_t)uid gid:(gid_t)gid recursive:(BOOL)recursive
{
    if (path.length == 0) return NO;

    if (recursive) {
        NSFileManager *manager = [NSFileManager defaultManager];
        NSDirectoryEnumerator *enumerator = [manager enumeratorAtPath:path];
        if (chown(path.fileSystemRepresentation, uid, gid) != 0 && getuid() != 0) return NO;
        for (NSString *entry in enumerator) {
            NSString *child = [path stringByAppendingPathComponent:entry];
            chown(child.fileSystemRepresentation, uid, gid);
        }
        return YES;
    }

    if (chown(path.fileSystemRepresentation, uid, gid) == 0) return YES;
    return NO;
}

+ (BOOL)setModeOfPath:(NSString *)path mode:(mode_t)mode
{
    if (path.length == 0) return NO;
    return chmod(path.fileSystemRepresentation, mode) == 0;
}

@end
