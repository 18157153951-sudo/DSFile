//
//  DSKernel.m — 内核逃逸的实际调用方
//
//  内核层：FilzaJailedDS 原版实现（上游 tag 2.2 / commit 49c3a90，逐字节零修改，见 FilzaTweak/NOTICE.md）
//     漏洞  kexploit_opa334()
//     逃逸  DSCredEscapeSandbox()          ← 我们自己的 cred 路线
//     提权  DSCredEscapeElevateToRoot()
//
//  **为什么不用上游的 sandbox_escape() / proc_self()**：
//  上游 proc_self() 走 rw_pcb → inp_socket → socket + off_socket_so_background_thread → thread + thread_t_tro；
//  本机（iPhone13,4 / iOS 18.5）实测 so_background_thread **恒为 0**，于是它把 0x378 当内核地址去读，
//  撞进上游 FAILURE() 宏（sleep(2); exit(c)）→ App 直接退到桌面（真机日志已确认：漏洞跑通、逃逸入口即崩）。
//  所以逃逸/提权改用另一条本机已验证 4/4 命中的路线（两个 socket 的 so_cred 一致 + cr_uid 校验），
//  实现见 Sources/Core/DSCredEscape.m。上游 FilzaTweak/** 依旧零修改。
//
//  三条硬规则：
//   1. 内核漏洞只在用户主动点「激活」时执行一次，同一进程内绝不重跑；
//   2. 上游在 KRW 未就绪时会「故意崩进程 / exit()」——这是它的保真行为，我们不改它的源码，
//      但调用前后都会往 Documents/Logs/kernel-breadcrumb.log 写一行并 fsync，
//      即使它把进程带走，也能事后看到跑到哪一步；
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
#import <stdarg.h>
#import <dlfcn.h>

// ===== 上游内核层（头文件路径由 project.yml 的 HEADER_SEARCH_PATHS 提供）=====
#import "kexploit/kexploit_opa334.h"   // kexploit_opa334 / early_kread64 / SYSTEM_VERSION_* 宏
#import "kexploit/krw.h"               // kread32 / is_kaddr_valid
#import "kexploit/offsets.h"           // off_proc_p_pid 等
#import "DSCredEscape.h"               // cred 路线的逃逸 / 提权（不调用 proc_self / 上游 sandbox_escape）
#import "DS3105Kernel.h"              // 3105 模式：完全独立的第二个内核后端，只在被选中时使用
#import "DSMHAKernel.h"               // MHA 身份（零内核）：MCM 容器租约，只在 bundle id 就是 MHA 时尝试
#import "DSSignatureInfo.h"           // 签名标识 / TeamIdentifier / TrollStore 判定
#import "DSFSAccessProbe.h"           // 逐路径 + 真实 errno 的文件访问探针
#import "DSJailbreakEnv.h"            // 越狱模式：jbroot 解析 + entitlements 诊断（不跑任何漏洞）
#import "patchfinder.h"                // init_xpf（保留上游 XPF 能力，见下）
#import "machine_info.h"               // CPU 家族宏

// 上游在 kexploit_opa334.m 里定义了这几个全局量但没写进头文件，这里补 extern
// 供健康检查与诊断页使用（定义存在，加 extern 声明不影响上游源码）
extern uint64_t g_kernel_base;
extern uint64_t g_kernel_slide;
extern uint64_t rwSocketPcb;
extern uint64_t controlSocketPcb;
extern int controlSocket;
extern int rwSocket;

// XPF 属于上游内核层（kpf/patchfinder.m 用它解析 kernelcache 符号）。
// 当前的漏洞 / 逃逸路径不需要它，但这里保留一个**真实**引用，避免链接器把上游这整块能力丢掉；
// 正常运行时（没有设 DSFILE_XPF 环境变量）这段永远不会执行。
static void ds_maybe_init_xpf(void)
{
    if (getenv("DSFILE_XPF") == NULL) return;
    (void)init_xpf();
}

#pragma mark - 面包屑（同步 fsync：上游可能「故意崩进程」，UI 日志是异步的，不能只靠它）

static int gBreadcrumbFd = -1;

static void ds_breadcrumb_write(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
static void ds_breadcrumb_write(const char *fmt, ...)
{
    if (gBreadcrumbFd < 0) return;
    char buf[2048];
    va_list ap;
    va_start(ap, fmt);
    int n = vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);
    if (n <= 0) return;
    ssize_t ignored = write(gBreadcrumbFd, buf, (size_t)n);
    (void)ignored;
    fsync(gBreadcrumbFd);   // 关键：进程被带走也要留下痕迹
}

static void ds_breadcrumb_open(void)
{
    if (gBreadcrumbFd >= 0) return;
    NSString *dir = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/Logs"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:NULL];
    NSString *path = [dir stringByAppendingPathComponent:@"kernel-breadcrumb.log"];
    gBreadcrumbFd = open(path.fileSystemRepresentation, O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (gBreadcrumbFd >= 0) {
        ds_breadcrumb_write("=== 会话 %s ===\n", [[[NSDate date] description] UTF8String]);
    }
}

#pragma mark - 状态

static BOOL gExploitRunning = NO;
static BOOL gExploitAttempted = NO;
static BOOL gExploitDone    = NO;
static BOOL gEscaped        = NO;
/// 本次进程实际走通的是哪条路（供界面/日志展示）；nil = 还没成功
static NSString *gActivePath = nil;
/// 最近一次 MHA 路径失败的原因（供「仅 MHA」模式如实报错，不静默回退）
static NSString *gLastMHAFailureReason = nil;
/// 最近一次越狱模式失败的原因（供「仅越狱」模式如实报错，不静默回退）
static NSString *gLastJailbreakFailureReason = nil;

NSString * _Nullable DSKernelActivePathDescription(void) { return gActivePath; }
static NSError *gLastError  = nil;
// 逃逸/提权不再需要 self proc：旧版缓存的上游 proc_self() 结果已弃用（本机必然野读 0x378 → exit）。

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
    // 同步落盘一份（上游可能故意崩进程，UI 侧是异步的）
    ds_breadcrumb_write("[kernel] %s\n", line.UTF8String ?: "");
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
    ds_breadcrumb_open();

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

/// 与上游 is_kaddr_valid 同一判据：高 24 位必须是 0xfffff…
static inline BOOL ds_is_kernel_address(uint64_t address)
{
    return (address & 0xfffff00000000000ULL) == 0xfffff00000000000ULL;
}

/// 漏洞跑完之后，先确认真的拿到了可用的 socket，再碰内核（上游把结果放在 rwSocketPcb / controlSocketPcb）
static BOOL ds_kernel_rw_healthy(void)
{
    return ds_is_kernel_address(rwSocketPcb) || ds_is_kernel_address(controlSocketPcb);
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
    // 上游 offsets_init 只覆盖 17.0 ≤ 版本 < 26.1（超出范围它会直接 exit，所以这里先挡住）
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
/// 能不能读写沙盒外：
///   · 现场写探针成功（内核逃逸 / 越狱环境下可直接写）；
///   · 或 MHA 容器租约已生效（零内核）；
///   · 或 **TrollStore 环境下沙盒外可读**（真机：TrollStore 装的 App 带 platform-application，
///     可能只给读权限；这种"只读可达"也算已有文件系统访问，界面会标注"只读可达"）。
+ (BOOL)probeFilesystemAccess
{
    if (ds_probe_write_access()) return YES;
    if (DSMHAAccessProbePasses()) return YES;
    if (DSSignatureIsTrollStoreInstalled() && DSFilesystemProbeReadable()) return YES;
    // 越狱模式：越狱 App（装进 <jbroot>/Applications/）本来就没有沙盒，沙盒外只读可达也算有访问
    if (DSJailbreakLooksJailbroken() && DSFilesystemProbeReadable()) return YES;
    return NO;
}

/// 统一入口（0.9.5）：**语义 = 现在能不能操作沙盒外文件**，与 isEscaped（内核逃逸标志）区分开。
/// 实现就是上面那个"现场探针 + 各条零内核路径"的判定，这里只是给它一个不会再被误用的名字。
+ (BOOL)hasFileSystemAccess { return [self probeFilesystemAccess]; }

/// 人话版诊断：把"为什么没有访问"需要的全部事实压成一行（越狱类型 / 生效路径 / 内核逃逸 / 探针 + errno）。
/// 失败提示直接带上它，用户回传一行就够定位。
+ (NSString *)fileSystemAccessDiagnosis
{
    NSMutableString *text = [NSMutableString string];

    NSString *jb;
    if (DSJailbreakLooksJailbroken()) {
        NSString *root = DSJailbreakRootPath();
        jb = root.length > 0 ? [NSString stringWithFormat:@"有（jbroot=%@）", root] : @"有（未解析到 jbroot）";
    } else {
        jb = @"未检测到越狱特征";
    }
    [text appendFormat:@"越狱=%@", jb];
    [text appendFormat:@"、生效路径=%@", gActivePath.length > 0 ? gActivePath : @"无"];
    [text appendFormat:@"、内核逃逸=%@", gEscaped ? @"是" : @"否"];
    [text appendFormat:@"、沙盒外探针：可读=%@ 可写=%@",
        DSFilesystemProbeReadable() ? @"是" : @"否",
        DSFilesystemProbeWritable() ? @"是" : @"否"];

    // 附上 /var/mobile 那一行的真实 errno（最直观的一条：EPERM=沙盒拒绝 / ENOENT=不存在 / EACCES=权限不足）
    for (NSString *line in [DSFilesystemAccessReport() componentsSeparatedByString:@"\n"]) {
        if ([line containsString:@"/var/mobile →"] || [line hasSuffix:@"/var/mobile"]) {
            [text appendFormat:@"、%@", [line stringByTrimmingCharactersInSet:
                [NSCharacterSet whitespaceAndNewlineCharacterSet]]];
            break;
        }
    }
    return text;
}
+ (unsigned long long)kernelBase { return (unsigned long long)g_kernel_base; }

/// 本次进程实际走通的是哪条路（供设置页/日志标注「MHA · 零内核」或「内核 + cred 逃逸」）
+ (nullable NSString *)activePathDescription { return gActivePath; }

+ (NSString *)diagnosticsText
{
    NSMutableString *text = [NSMutableString string];
    [text appendFormat:@"后端: FilzaJailedDS 原版漏洞（kexploit_opa334）+ 自研 cred 路线逃逸\n"];
    [text appendFormat:@"机型: %@\n", [self deviceModelIdentifier]];
    [text appendFormat:@"系统: %@\n", [self systemVersion]];
    [text appendFormat:@"芯片: %@\n", [self cpuFamilyName]];
    [text appendFormat:@"支持判定: %@\n", [self supportSummary]];
    [text appendFormat:@"漏洞已执行: %@\n", gExploitAttempted ? @"是" : @"否"];
    [text appendFormat:@"内核读写已拿到: %@\n", gExploitDone ? @"是" : @"否"];
    [text appendFormat:@"沙盒已逃逸: %@\n", gEscaped ? @"是" : @"否"];
    [text appendFormat:@"当前 uid: %d (%@)\n", getuid(), [self isRunningAsRoot] ? @"root" : @"非 root"];
    [text appendFormat:@"内核基址: 0x%llx（slide 0x%llx）\n",
        (unsigned long long)g_kernel_base, (unsigned long long)g_kernel_slide];
    [text appendFormat:@"rw_socket_pcb: 0x%llx / control_socket_pcb: 0x%llx\n",
        (unsigned long long)rwSocketPcb, (unsigned long long)controlSocketPcb];
    [text appendFormat:@"socket fd: rw=%d control=%d\n", rwSocket, controlSocket];
    [text appendFormat:@"cred: 0x%llx / label: 0x%llx\n",
        DSCredEscapeLastCred(), DSCredEscapeLastLabel()];
    [text appendFormat:@"sandbox: 0x%llx / ext_set: 0x%llx\n",
        DSCredEscapeLastSandbox(), DSCredEscapeLastExtSet()];
    [text appendFormat:@"现场探针写盘: %@\n", ds_probe_write_access() ? @"通过" : @"失败"];
    [text appendFormat:@"TrollStore 安装: %@\n",
        DSSignatureIsTrollStoreInstalled()
            ? [NSString stringWithFormat:@"是（%@）", DSSignatureTrollStoreEvidence()]
            : @"否"];
    [text appendFormat:@"签名标识: %@\n", DSSignatureIdentifier() ?: @"(读取不到)"];
    // 越狱模式相关：jbroot 解析 + 本 App entitlements（判断"权限没给"还是"沙盒在拦"的决定性依据）
    [text appendFormat:@"越狱特征: %@\n", DSJailbreakLooksJailbroken() ? @"有" : @"无"];
    [text appendFormat:@"jbroot: %@\n", DSJailbreakRootPath() ?: @"(未解析到)"];
    [text appendString:DSJailbreakEntitlementReport()];
    // 逐路径 + 真实 errno：越狱/TrollStore 环境下"没能获取权限"时，这一节就是定位依据
    [text appendString:DSFilesystemAccessReport()];
    ds_maybe_init_xpf();   // 仅在设了 DSFILE_XPF 时才真的初始化 XPF；同时保证上游 XPF 不被链接器丢掉
    if (gLastError) [text appendFormat:@"上一次错误: %@\n", gLastError.localizedDescription];
    return text;
}

#pragma mark - 激活

/// 3105 后端激活。与下面 FilzaJailedDS 的路径**完全独立**：
/// 不共用 kread/kwrite 原语、不共享就绪标志，只复用「沙盒外写探针」与统一的状态通知。
+ (DSKernelResult)ds_activate3105WithLog:(DSKernelLogBlock)log
{
    if (gEscaped || DS3105KernelIsReady()) {
        if (log) log(@"[myfilza] 3105 后端已就绪，无需重复执行");
        return DSKernelResultAlreadyActive;
    }
    if (gExploitAttempted) {
        if (log) log(@"[myfilza] 本次运行已经尝试过一次内核漏洞（3105 模式）。同一个进程里重跑风险极高，"
                      "请从后台完全退出 App 再重新打开后重试。");
        gLastError = [NSError errorWithDomain:@"myfilza" code:DSKernelResultExploitFailed
                                     userInfo:@{ NSLocalizedDescriptionKey: @"本次运行已尝试过内核漏洞，请重启 App 后再试" }];
        return DSKernelResultExploitFailed;
    }
    BOOL useKernel3105 = DS3105KernelUseKernelExploit();

    if (log) log([NSString stringWithFormat:@"[myfilza] 目标: %@ / iOS %@ / %@",
                  [self deviceModelIdentifier], [self systemVersion], [self cpuFamilyName]]);

    // 按系统版本说明这次的机制顺序（依据 3105 自己的 README 与 helpers/KernelExploit.swift）：
    //   README：`iOS 18 | 18.0–18.7.1 (kernel exploit)`；26/27 两行没有 kernel exploit。
    //   KernelExploit.swift：requiresSandboxEscape = majorVersion >= 26。
    BOOL modern3105 = (NSProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26);
    if (log) {
        log([NSString stringWithFormat:
             @"[myfilza] 系统版本分流（3105 模式）：iOS %@ → 机制顺序 = %@",
             modern3105
                 ? [NSString stringWithFormat:@"%@（≥26）", [self systemVersion]]
                 : [NSString stringWithFormat:@"%@（<26）", [self systemVersion]],
             modern3105
                 ? @"① MHA/MCM（零内核，已在上面先试） ② bad_query 用户态令牌 ③ 内核 R/W + cred 逃逸（兜底）"
                 : @"① 内核 R/W + cred 路线逃逸 ② bad_query 用户态令牌（兜底）"]);
        log(@"[myfilza] 依据：3105 README 写明 `iOS 18 | 18.0–18.7.1 (kernel exploit)`；"
              "26/27 两行没有 kernel exploit；其 KernelExploit.swift 里 requiresSandboxEscape = majorVersion >= 26");
    }

    if (useKernel3105) {
        // 只有真正要跑内核漏洞时才计入「本进程已尝试过」——纯用户态令牌模式可以反复重试。
        gExploitAttempted = YES;
        // 先把警告写进 breadcrumb 与会话日志（两者都 fsync 过）：即使随后是内核 panic 或 exit()，
        // 也能从落盘日志看到它死在哪个阶段。
        ds_breadcrumb_write("[myfilza] 即将执行 3105 内核漏洞（用户显式开启）：只跑 kexploit_opa334 取内核读写，不调用 proc_self/sandbox_escape\n");
        if (log) log(@"[myfilza] ⚠️ 即将执行 3105 内核漏洞（你在设置里显式开启了它）：该路径使用 DarkSword 内核漏洞，"
                      "在你的设备上可能导致崩溃或重启。");
        if (log) log(@"[myfilza] 内核后端 = 3105 · 内核读写（只跑 kexploit_opa334，不调用 3105 的 proc_self/sandbox_escape）+ 用户态令牌");
    } else {
        if (log) log(@"[myfilza] 内核后端 = 3105 · 仅用户态令牌（不执行内核漏洞：bad_query + ContainerManager 令牌，不会 panic）");
    }
    if (log) log(@"[myfilza] 开始执行 3105 链路（仅用户态通常很快；完整路径可能耗时数秒到数十秒，界面短暂无响应属正常）…");

    NSString *detail = nil;
    int ret = 1009;
    @try {
        ret = DS3105KernelActivate(&detail);
    } @catch (NSException *e) {
        if (log) log([NSString stringWithFormat:@"[myfilza] 3105 后端抛出异常: %@", e.reason]);
        detail = [NSString stringWithFormat:@"3105 模式：抛出异常 %@", e.reason];
        ret = 1009;
    }

    ds_breadcrumb_write("[myfilza] 3105 后端返回 %d（阶段：%s）\n", ret, DS3105KernelLastStage().UTF8String);

    if (ret == 0) {
        gExploitDone = YES;
        gEscaped = ds_probe_write_access();
        if (log) log([NSString stringWithFormat:@"[myfilza] %@", detail ?: @"3105 后端完成"]);
        if (gEscaped) {
            gActivePath = @"内核 + cred 逃逸（3105 后端）";
            if (log) log(@"[myfilza] *** 沙盒逃逸成功（3105 模式）：现在可以读写沙盒外的路径 ***");
            [[NSNotificationCenter defaultCenter] postNotificationName:@"myfilza.fileSystemAccessChanged" object:nil];
            return DSKernelResultOK;
        }
        if (log) log([NSString stringWithFormat:@"[myfilza] 3105 自检认为成功，但沙盒外写探针失败 (errno=%d: %s)",
                      errno, strerror(errno)]);
        gLastError = [NSError errorWithDomain:@"myfilza" code:DSKernelResultEscapeFailed
                                     userInfo:@{ NSLocalizedDescriptionKey: @"3105 后端执行完成，但沙盒外写探针仍失败" }];
        return DSKernelResultEscapeFailed;
    }

    if (log) log([NSString stringWithFormat:@"[myfilza] 3105 后端失败（阶段：%@）：%@",
                  DS3105KernelLastStage(), detail ?: @"未提供原因"]);
    gLastError = [NSError errorWithDomain:@"myfilza" code:DSKernelResultExploitFailed
                                 userInfo:@{ NSLocalizedDescriptionKey: (detail ?: @"3105 后端失败") }];
    return DSKernelResultExploitFailed;
}

/// 越狱模式（roothide / rootless / 经典越狱）：**完全不执行任何漏洞**。
///
/// 越狱 App（装进 <jbroot>/Applications/，带 platform-application 沙盒例外）本来就能
/// 直接用 POSIX 读写系统路径，根本不需要内核漏洞；而 roothide 下 TrollStore 安装的
/// App **仍然受沙盒限制**，这时本路径会如实失败并说明"是权限没给，不是我们没做对"。
///
/// 只做三件事：解析 jbroot（逐条记结果）→ 打印本 App entitlements → 逐路径 errno 探针。
+ (DSKernelResult)ds_activateJailbreakWithLog:(DSKernelLogBlock)log
{
    if (gEscaped) {
        if (log) log(@"[myfilza] 本进程已具备沙盒外访问，跳过越狱模式");
        return DSKernelResultAlreadyActive;
    }

    if (log) {
        log(@"[myfilza] 越狱模式：**不执行任何漏洞**，直接用越狱环境给的 POSIX 权限");
        log([NSString stringWithFormat:@"[myfilza] %@", DSJailbreakEnvironmentSummaryLine()]);
    }

    // 决定性诊断 1：jbroot 到底解析到哪儿了（逐条尝试 + 结果）
    for (NSString *line in [DSJailbreakRootResolutionReport() componentsSeparatedByString:@"\n"]) {
        if (line.length && log) log([NSString stringWithFormat:@"[越狱诊断] %@", line]);
    }
    // 决定性诊断 2：本 App 自己的 entitlements —— 一眼看出「权限没给」还是「沙盒在拦」
    for (NSString *line in [DSJailbreakEntitlementReport() componentsSeparatedByString:@"\n"]) {
        if (line.length && log) log([NSString stringWithFormat:@"[越狱诊断] %@", line]);
    }

    NSString *detail = nil;
    int ret = 1031;
    @try {
        ret = DSJailbreakActivate(&detail);
    } @catch (NSException *e) {
        detail = [NSString stringWithFormat:@"越狱模式抛出异常：%@", e.reason];
        ret = 1031;
    }
    ds_breadcrumb_write("[myfilza] 越狱模式返回 %d（阶段：%s）\n", ret, DSJailbreakLastStage().UTF8String);

    if (ret == 0) {
        BOOL writable = ds_probe_write_access();
        BOOL readable = DSFilesystemProbeReadable();
        gEscaped = writable || readable;
        if (log) log([NSString stringWithFormat:@"[myfilza] %@", detail ?: @"越狱模式完成"]);
        if (gEscaped) {
            gActivePath = writable ? @"越狱 · 直接 POSIX（可读写）" : @"越狱 · 直接 POSIX（只读可达）";
            if (log) log([NSString stringWithFormat:
                          @"[myfilza] *** 已具备沙盒外访问（越狱模式 · 零漏洞）：%@ ***",
                          writable ? @"可直接读写系统路径" : @"沙盒外只读可达（能浏览/导出，写入仍受限）"]);
            [[NSNotificationCenter defaultCenter] postNotificationName:@"myfilza.fileSystemAccessChanged" object:nil];
            return DSKernelResultOK;
        }
        // 理论上到不了这里（DSJailbreakActivate 只有在 readable/writable 时才返回 0）
        gLastJailbreakFailureReason = @"越狱模式报告成功，但探针没通过";
        if (log) log(@"[myfilza] 越狱模式自检与探针不一致：按失败处理（不做美化）");
        return DSKernelResultEscapeFailed;
    }

    gLastJailbreakFailureReason = detail ?: @"未提供原因";
    if (log) log([NSString stringWithFormat:@"[myfilza] 越狱模式未成功（阶段：%@）：%@",
                  DSJailbreakLastStage(), detail ?: @"未提供原因"]);
    return DSKernelResultEscapeFailed;
}

/// MHA 身份路径（零内核）：只有本 App 的 bundle id 就是
/// `com.apple.mobile.MobileHouseArrest` 时才尝试。它走 MCM 容器租约
/// （枚举容器标识 → 逐个取租约并激活 → 真实探针），**完全不执行内核代码**。
///
/// 与 3105 / FilzaJailedDS 两条路径**完全独立**：不共用原语、不共享就绪标志，
/// 只复用「沙盒外写探针」和统一的状态通知。失败由调用方继续按用户选择的模式走（不阻断）。
+ (DSKernelResult)ds_activateMHAWithLog:(DSKernelLogBlock)log
{
    if (gEscaped) {
        if (log) log(@"[myfilza] 本进程已具备沙盒外访问，跳过 MHA 路径");
        return DSKernelResultAlreadyActive;
    }

    if (log) {
        log(@"[myfilza] 检测到 MHA 身份：bundle id = com.apple.mobile.MobileHouseArrest");
        log(@"[myfilza] 尝试 MCM 容器租约（零内核：不执行任何内核代码、不调用 proc_self/sandbox_escape）…");
    }

    NSString *detail = nil;
    int ret = 1021;
    @try {
        ret = DSMHAKernelActivate(&detail);
    } @catch (NSException *e) {
        detail = [NSString stringWithFormat:@"MHA 路径抛出异常：%@", e.reason];
        ret = 1021;
    }
    ds_breadcrumb_write("[myfilza] MHA 路径返回 %d（阶段：%s）\n", ret, DSMHALastStage().UTF8String);

    if (ret == 0) {
        gExploitDone = YES;
        // 成功判据与 DSMHAKernelActivate 内部保持一致：**真的**能写沙盒外，或**真的**拿到了别人的容器。
        // 注意：不能只看"持有租约数 > 0"——那正是 0.7.3 自报成功的 bug。
        gEscaped = ds_probe_write_access() || DSMHAAccessProbePasses();
        if (log) log([NSString stringWithFormat:@"[myfilza] %@", detail ?: @"MHA 路径完成"]);
        if (gEscaped) {
            gActivePath = @"MHA · 零内核";
            if (log) log(@"[myfilza] *** 沙盒逃逸成功（MHA 身份 · 零内核）：沙盒扩展已生效，"
                          @"现在可以读写其它 App 的容器 ***");
            [[NSNotificationCenter defaultCenter] postNotificationName:@"myfilza.fileSystemAccessChanged" object:nil];
            return DSKernelResultOK;
        }
        gLastMHAFailureReason = detail ?: @"MHA 探针未通过（没拿到别人的容器）";
        if (log) log(@"[myfilza] MHA 激活完成但**未真正生效**（没拿到别人的容器 / 沙盒外写仍失败）"
                      @"——是否回退内核由「访问路径」选择决定");
        return DSKernelResultEscapeFailed;
    }

    gLastMHAFailureReason = detail ?: @"未提供原因";
    if (log) log([NSString stringWithFormat:@"[myfilza] MHA 路径未成功（阶段：%@）：%@",
                  DSMHALastStage(), detail ?: @"未提供原因"]);
    return DSKernelResultExploitFailed;
}

+ (DSKernelResult)activateWithLog:(DSKernelLogBlock)log
{
    @synchronized (self) {
        if (gExploitRunning) {
            if (log) log(@"[myfilza] 激活正在进行中，忽略重复请求");
            return DSKernelResultBusy;
        }
        gExploitRunning = YES;
    }

    DSKernelResult result = DSKernelResultInternalError;
    @try {
        if (log) ds_capture_start(log);

        // === 分派点 1：访问路径（用户可选：自动 / 仅 MHA / 仅内核 / 仅越狱）===
        //   Auto          —— 检测到越狱/TrollStore 特征先试越狱模式；否则 MHA 可用才用 MHA；都不行回退所选内核后端；
        //   MHAOnly       —— 只走 MHA，不可用就**明确失败**，绝不静默回退内核；
        //   KernelOnly    —— 完全跳过越狱模式与 MHA（连检测/尝试都不做），直接走内核后端；
        //   JailbreakOnly —— 只走越狱模式（**零漏洞**），失败也**明确失败**，不回退内核。
        DSKernelPathMode pathMode = DSKernelPathModeCurrent();
        if (log) log([NSString stringWithFormat:@"[myfilza] 访问路径选择：%@",
                      DSKernelPathModeDisplayName(pathMode)]);

        // === 分派点 0：越狱模式（**完全不执行任何漏洞**，直接用越狱环境给的 POSIX 权限）===
        //   JailbreakOnly —— 只走越狱路径；失败就**明确失败**（说明是"权限没给"还是"没有越狱特征"），不回退内核；
        //   Auto          —— 检测到越狱/TrollStore 特征时先试越狱路径（成功即采用；失败不阻断，继续原有分派）。
        if (pathMode == DSKernelPathModeJailbreakOnly) {
            DSKernelResult jb = [self ds_activateJailbreakWithLog:log];
            if (jb == DSKernelResultOK || jb == DSKernelResultAlreadyActive) {
                result = jb;
            } else {
                if (log) {
                    log([NSString stringWithFormat:@"[myfilza] 「仅越狱（直接 POSIX）」失败（阶段：%@）：%@",
                         DSJailbreakLastStage(), gLastJailbreakFailureReason ?: @"未提供原因"]);
                    log(@"[myfilza] 按你的选择**不回退内核**。要让越狱模式生效：① 用 Sileo / Zebra 安装"
                          "越狱版 deb（myfilza_<版本>_iphoneos-arm64e.deb，装进 <jbroot>/Applications/，"
                          "带越狱 entitlements，装完会自动刷新桌面）；② deb 装不上时用手动安装包 myfilza-jb-manual.zip"
                          "（解压后只需一条命令 sh install.sh，全自动）；或者把访问路径改成「自动（推荐）」/「仅内核」。");
                }
                gLastError = [NSError errorWithDomain:@"myfilza"
                                                 code:DSKernelResultEscapeFailed
                                             userInfo:@{ NSLocalizedDescriptionKey:
                                                         (gLastJailbreakFailureReason ?: @"仅越狱模式失败：越狱环境没有给出文件访问权限") }];
                result = DSKernelResultEscapeFailed;
            }
        } else {
        if (pathMode == DSKernelPathModeAuto && DSJailbreakLooksJailbroken()) {
            if (log) log(@"[myfilza] 「自动」：检测到越狱 / TrollStore 特征 → 先试越狱模式（不跑任何漏洞）");
            DSKernelResult jb = [self ds_activateJailbreakWithLog:log];
            if (jb == DSKernelResultOK || jb == DSKernelResultAlreadyActive) {
                result = jb;
            } else if (log) {
                log([NSString stringWithFormat:@"[myfilza] 越狱模式不可用（阶段：%@）：%@ → 继续按「自动」走 MHA / 内核",
                     DSJailbreakLastStage(), gLastJailbreakFailureReason ?: @"未提供原因"]);
            }
        }

        DSKernelResult mhaResult = DSKernelResultInternalError;
        BOOL mhaAttempted = NO;

        if (result == DSKernelResultOK || result == DSKernelResultAlreadyActive) {
            // 越狱模式已经拿到访问，不再往下走
        } else if (pathMode == DSKernelPathModeKernelOnly) {
            if (log) log(@"[myfilza] 「仅内核」：完全跳过越狱模式与 MHA 路径（不检测、不尝试），直接走所选内核后端");
        } else if (!DSMHAIsHost()) {
            if (log) log([NSString stringWithFormat:
                          @"[myfilza] MHA 路径不适用：本 App bundle id 是 %@，不是 com.apple.mobile.MobileHouseArrest%@",
                          NSBundle.mainBundle.bundleIdentifier ?: @"(nil)",
                          (pathMode == DSKernelPathModeMHAOnly)
                              ? @"（你选的是「仅 MHA」，按选择将明确失败，不回退内核）"
                              : @" → 自动回退内核模式"]);
        } else {
            mhaAttempted = YES;
            mhaResult = [self ds_activateMHAWithLog:log];
        }

        if (mhaAttempted && (mhaResult == DSKernelResultOK || mhaResult == DSKernelResultAlreadyActive)) {
            result = mhaResult;
        } else if (pathMode == DSKernelPathModeMHAOnly) {
            // 用户明确要求：只在 MHA 上运行 —— 不可用时明确失败，**不回退内核**。
            if (log) {
                log([NSString stringWithFormat:@"[myfilza] 「仅 MHA（零内核）」失败（阶段：%@）：%@",
                     DSMHALastStage(), gLastMHAFailureReason ?: @"未提供原因"]);
                log(@"[myfilza] 按你的选择**不回退内核**。要让 MHA 生效：请用签名 identifier 为 "
                      "com.apple.mobile.MobileHouseArrest 的证书重签（且不要用「自动生成 Bundle ID」）；"
                      "或者把访问路径改成「自动（推荐）」/「仅内核（FilzaJailedDS）」。");
            }
            gLastError = [NSError errorWithDomain:@"myfilza"
                                             code:DSKernelResultEscapeFailed
                                         userInfo:@{ NSLocalizedDescriptionKey:
                                                     (gLastMHAFailureReason ?: @"仅 MHA 模式失败：MHA 路径不可用") }];
            result = DSKernelResultEscapeFailed;
        // === 分派点 2：选了 3105 就整条走 3105 的独立路径，绝不进入下面的 FilzaJailedDS 逻辑 ===
        // （未选中时这个 if 恒为假，下面的代码与 0.4.0 逐字一致）
        } else if (DS3105KernelSelected()) {
            result = [self ds_activate3105WithLog:log];
        } else if (DSSafeModeEnabled()) {
            // 安全模式：FilzaJailedDS 整体依赖内核漏洞，按用户设置阻止执行。
            // 默认关闭，所以不影响既有行为；开启时只提示、不硬跑。
            if (log) log(@"[myfilza] 安全模式已开启：FilzaJailedDS 模式必须使用内核漏洞，已阻止执行。"
                          "要拿容器访问请切换到「3105」（默认仅用户态令牌），或到设置里关闭安全模式。");
            gLastError = [NSError errorWithDomain:@"myfilza" code:DSKernelResultExploitFailed
                                         userInfo:@{ NSLocalizedDescriptionKey: @"安全模式已开启：FilzaJailedDS 需要内核漏洞，已被阻止；请改用 3105 模式或关闭安全模式" }];
            result = DSKernelResultExploitFailed;
        } else if (gEscaped) {
            if (log) log(@"[myfilza] 本进程沙盒已经是逃逸状态");
            result = DSKernelResultAlreadyActive;
        } else if (![self isSystemVersionSupported]) {
            if (log) log([NSString stringWithFormat:@"[myfilza] %@", [self supportSummary]]);
            gLastError = [NSError errorWithDomain:@"myfilza" code:DSKernelResultUnsupportedSystem
                                         userInfo:@{ NSLocalizedDescriptionKey: [self supportSummary] }];
            result = DSKernelResultUnsupportedSystem;
        } else if (gExploitDone) {
            if (log) log(@"[myfilza] 内核读写已在本次进程内取得，跳过漏洞，只重试沙盒改写");
            result = [self ds_escapeStepWithLog:log];
        } else if (gExploitAttempted) {
            if (log) log(@"[myfilza] 本次运行已经执行过一次内核漏洞且没有成功。同一个进程里重跑风险极高，"
                          "请从后台完全退出 App 再重新打开后重试。");
            gLastError = [NSError errorWithDomain:@"myfilza" code:DSKernelResultExploitFailed
                                         userInfo:@{ NSLocalizedDescriptionKey: @"本次运行已尝试过内核漏洞，请重启 App 后再试" }];
            result = DSKernelResultExploitFailed;
        } else {
            gExploitAttempted = YES;
            if (log) log([NSString stringWithFormat:@"[myfilza] 目标: %@ / iOS %@ / %@",
                          [self deviceModelIdentifier], [self systemVersion], [self cpuFamilyName]]);
            if (log) log(@"[myfilza] 开始执行内核漏洞（FilzaJailedDS 原版 kexploit_opa334，可能耗时数秒，界面短暂无响应属正常）…");
            ds_breadcrumb_write("[myfilza] → kexploit_opa334() 开始\n");

            int kret = 1;
            @try {
                kret = kexploit_opa334();
            } @catch (NSException *e) {
                if (log) log([NSString stringWithFormat:@"[myfilza] 漏洞抛出异常: %@", e.reason]);
                ds_breadcrumb_write("[myfilza] kexploit 抛异常: %s\n", e.reason.UTF8String ?: "?");
                kret = -1;
            }

            ds_breadcrumb_write("[myfilza] ← kexploit_opa334() 返回 %d；kernel_base=0x%llx slide=0x%llx rwSocketPcb=0x%llx\n",
                                kret, (unsigned long long)g_kernel_base, (unsigned long long)g_kernel_slide,
                                (unsigned long long)rwSocketPcb);
            if (log) log([NSString stringWithFormat:
                          @"[myfilza] 漏洞返回 %d；kernel_base=0x%llx（slide 0x%llx）；rw_socket_pcb=0x%llx",
                          kret, (unsigned long long)g_kernel_base, (unsigned long long)g_kernel_slide,
                          (unsigned long long)rwSocketPcb]);

            if (kret != 0) {
                if (log) log(@"[myfilza] 内核漏洞没有成功（race 失败是最常见原因）。"
                              "设备没有重启就说明没伤到内核，完全退出 App 重开后再试即可。");
                gLastError = [NSError errorWithDomain:@"myfilza" code:DSKernelResultExploitFailed
                                             userInfo:@{ NSLocalizedDescriptionKey: @"内核漏洞 race 失败，请退出 App 重开后重试" }];
                result = DSKernelResultExploitFailed;
            } else {
                gExploitDone = YES;
                if (log) log([NSString stringWithFormat:@"[myfilza] 内核读写已获得，kernel base = 0x%llx",
                              (unsigned long long)g_kernel_base]);
                result = [self ds_escapeStepWithLog:log];
            }
        }
        }   // 关闭「非 JailbreakOnly」分支（越狱模式已在上面单独处理）
    } @finally {
        ds_capture_stop();
        @synchronized (self) { gExploitRunning = NO; }
    }

    // 收尾：如实写明"这次实际走的是哪条路"，界面与日志都以它为准（不猜、不美化）
    if (result == DSKernelResultOK || result == DSKernelResultAlreadyActive) {
        NSString *path = gActivePath ?: (gEscaped ? @"已具备沙盒外访问（进程内先前已取得）" : @"未知");
        if (log) log([NSString stringWithFormat:@"[myfilza] ✅ 本次实际路径 = %@", path]);
    } else if (log) {
        log([NSString stringWithFormat:@"[myfilza] ❌ 激活未成功（结果码 %ld）；访问路径选择 = %@",
             (long)result, DSKernelPathModeDisplayName(DSKernelPathModeCurrent())]);
        if (gLastMHAFailureReason.length > 0) {
            log([NSString stringWithFormat:@"[myfilza] MHA 路径失败原因：%@", gLastMHAFailureReason]);
        }
        if (gLastJailbreakFailureReason.length > 0) {
            log([NSString stringWithFormat:@"[myfilza] 越狱模式失败原因：%@", gLastJailbreakFailureReason]);
        }
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
            if (log) log(@"[myfilza] 内核读写还没拿到，必须先跑完整激活");
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

/// 只做「沙盒改写 + 自检」这一步。
/// 逃逸走 DSCredEscapeSandbox()（cred 路线）：不碰 proc_self()，也不调用上游 sandbox_escape()。
+ (DSKernelResult)ds_escapeStepWithLog:(DSKernelLogBlock)log
{
    if (!ds_kernel_rw_healthy()) {
        if (log) log([NSString stringWithFormat:
                      @"[myfilza] 内核读写不可用：rw_socket_pcb=0x%llx control_socket_pcb=0x%llx 都不是合法内核地址。"
                       "请完全退出 App 重开后再点一次「激活内核访问」。",
                      (unsigned long long)rwSocketPcb, (unsigned long long)controlSocketPcb]);
        gLastError = [NSError errorWithDomain:@"myfilza" code:DSKernelResultExploitFailed
                                     userInfo:@{ NSLocalizedDescriptionKey: @"内核读写不可用，请退出 App 重开后重试" }];
        return DSKernelResultExploitFailed;
    }

    if (log) log(@"[myfilza] 开始改写本进程沙盒数据（cred 路线：两个 socket 的 so_cred 一致 + cr_uid 校验）…");
    ds_breadcrumb_write("[myfilza] 逃逸开始（cred 路线）\n");

    DSCredEscapeSetLogCallback(ds_escape_log_bridge);

    int sret = 1;
    @try {
        sret = DSCredEscapeSandbox();
    } @catch (NSException *e) {
        if (log) log([NSString stringWithFormat:@"[myfilza] 沙盒改写异常: %@", e.reason]);
        sret = -9;
    }
    ds_breadcrumb_write("[myfilza] DSCredEscapeSandbox() 返回 %d（cred=0x%llx label=0x%llx ext_set=0x%llx）\n",
                        sret, DSCredEscapeLastCred(), DSCredEscapeLastLabel(), DSCredEscapeLastExtSet());
    if (log) log([NSString stringWithFormat:@"[myfilza] 沙盒改写返回 %d（cred=0x%llx → ext_set=0x%llx）",
                  sret, DSCredEscapeLastCred(), DSCredEscapeLastExtSet()]);

    if (ds_probe_write_access()) {
        gEscaped = YES;
        gActivePath = DS3105KernelSelected() ? @"内核 + cred 逃逸（3105 后端）"
                                             : @"内核 + cred 逃逸（FilzaJailedDS）";
        if (log) log([NSString stringWithFormat:@"[myfilza] *** 沙盒逃逸成功（%@）：现在可以读写沙盒外的路径 ***",
                      gActivePath]);
        return DSKernelResultOK;
    }

    if (log) log([NSString stringWithFormat:@"[myfilza] 探针写盘失败 (errno=%d: %s)", errno, strerror(errno)]);
    gLastError = [NSError errorWithDomain:@"myfilza" code:DSKernelResultEscapeFailed
                                 userInfo:@{ NSLocalizedDescriptionKey: @"沙盒改写后探针写盘仍失败" }];
    return DSKernelResultEscapeFailed;
}

+ (DSKernelResult)elevateToRootWithLog:(DSKernelLogBlock)log
{
    if (getuid() == 0) return DSKernelResultAlreadyActive;
    if (!gExploitDone) {
        if (log) log(@"[myfilza] 提权需要先有内核读写：请先点「激活内核访问」，激活成功后再点这一项");
        return DSKernelResultExploitFailed;
    }

    if (log) log(@"[myfilza] 尝试把本进程凭据改成 root（改写 ucred 里的 posix_cred）…");

    // 3105 模式必须用 3105 自己的原语提权：两个后端各自建立自己的 socket 原语，
    // 在 3105 模式下调用 DSCredEscape*（FilzaJailedDS 原语）会拿着未初始化的原语野读内核。
    if (DS3105KernelSelected()) {
        ds_breadcrumb_write("[myfilza] 提权开始（3105 后端：t3105 原语）\n");
        if (!DS3105KernelIsReady()) {
            if (log) log(@"[myfilza] 提权未执行：3105 后端不在就绪状态（请先点「激活内核访问」并等它成功）");
            ds_breadcrumb_write("[myfilza] 提权未执行：DS3105KernelIsReady() = false\n");
            return DSKernelResultExploitFailed;
        }
        int ret3105 = 1010;
        NSString *d3105 = nil;
        @try {
            ret3105 = DS3105KernelElevateToRoot(&d3105);
        } @catch (NSException *e) {
            if (log) log([NSString stringWithFormat:@"[myfilza] 3105 提权异常: %@", e.reason]);
        }
        if (log) log([NSString stringWithFormat:@"[myfilza] DS3105KernelElevateToRoot() 返回 %d；%@；当前 uid=%d",
                      ret3105, d3105 ?: @"（无详情）", (int)getuid()]);
        ds_breadcrumb_write("[myfilza] DS3105KernelElevateToRoot() 返回 %d；uid=%d\n", ret3105, (int)getuid());
        if (getuid() == 0) {
            if (log) log(@"[myfilza] 提权成功（3105 后端），当前 uid=0");
            return DSKernelResultOK;
        }
        if (log) log([NSString stringWithFormat:
                      @"[myfilza] 3105 提权失败（返回码 %d）：失败不影响已获得的文件系统访问", ret3105]);
        return DSKernelResultExploitFailed;
    }

    ds_breadcrumb_write("[myfilza] 提权开始（cred 路线）\n");

    DSCredEscapeSetLogCallback(ds_escape_log_bridge);

    // 前置就绪校验在 DSCredEscape 内部还会再查一遍（rwSocketPcb / controlSocketPcb / g_kernel_base），
    // 这里先查一次是为了在界面上给出更直白的提示，避免用户以为是别的问题。
    if (!DSCredEscapeIsKernelReady()) {
        if (log) log(@"[myfilza] 提权未执行：内核读写不在就绪状态（本次运行还没成功跑过漏洞）");
        ds_breadcrumb_write("[myfilza] 提权未执行：DSCredEscapeIsKernelReady() = false\n");
        return DSKernelResultExploitFailed;
    }

    int ret = -1;
    @try {
        ret = DSCredEscapeElevateToRoot();
    } @catch (NSException *e) {
        if (log) log([NSString stringWithFormat:@"[myfilza] 提权异常: %@", e.reason]);
        ret = -1;
    }

    if (log) log([NSString stringWithFormat:@"[myfilza] DSCredEscapeElevateToRoot() 返回 %d；当前 uid=%d",
                  ret, (int)getuid()]);
    ds_breadcrumb_write("[myfilza] DSCredEscapeElevateToRoot() 返回 %d；uid=%d\n", ret, (int)getuid());

    if (getuid() == 0) {
        if (log) log(@"[myfilza] 提权成功，当前 uid=0（posix_cred 已被改写，日志里有改写前后回读）");
        return DSKernelResultOK;
    }
    if (log) log([NSString stringWithFormat:@"[myfilza] 提权失败（返回码 %d, uid=%d）：失败不影响已获得的沙盒逃逸",
                  ret, (int)getuid()]);
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
