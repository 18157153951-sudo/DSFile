//
//  DS3105Kernel.m — 「3105 模式」内核后端适配层（唯一调用 3105 代码的地方）
//
//  隔离要点：
//    · DS3105SymbolPrefix.h 必须最先包含：它把 3105 自有符号统一改名 t3105_*，
//      这样它那份与现有后端同名的 kexploit/krw 实现不会与 FilzaJailedDS 侧冲突；
//    · 本文件只调用 3105 自己的入口，绝不调用、也绝不暴露我们的 kread/kwrite；
//    · 就绪状态是本文件自己的静态变量，与现有后端的 gEscaped 完全独立。
//
//  3105 的失败行为（未修改上游）：其 kexploit_abort 在漏洞阶段内用 longjmp 回到调用点
//  （上游注释写着 "app stays alive"），只有在漏洞阶段之外才会 exit()。比我们现有后端的
//  故意崩溃温和，但仍属于上游行为，故此处只做日志与错误码上报。
//

// 注意：这里全部用**显式相对路径**包含 3105 的头文件。
// 原因是两个内核后端各有一份同名的 krw.h / kutils.h / offsets.h，如果把 3105 的目录
// 加进 HEADER_SEARCH_PATHS，就可能让现有后端的 `#import "kexploit/krw.h"` 解析到 3105 那份。
// 显式相对路径（相对于本文件所在目录）可以彻底避免这种串台。
#import "../../Vendor/ThreeOneOSFive/DS3105SymbolPrefix.h"   // 必须最先：把 3105 自有符号改名 t3105_*

#import "../../Vendor/ThreeOneOSFive/kexploit/kexploit_opa334.h"
#import "../../Vendor/ThreeOneOSFive/kexploit/kutils.h"
#import "../../Vendor/ThreeOneOSFive/kexploit/sandbox_escape.h"
#import "../../Vendor/ThreeOneOSFive/exploit/bad_query.h"
#import "../../Vendor/ThreeOneOSFive/exploit/mcm_bridge.h"   // 只用 MCMBridgeAvailable 做可用性探测（纯用户态）

#import "DS3105Kernel.h"

#import <unistd.h>
#import <fcntl.h>
#import <errno.h>
#import <string.h>
#import <sys/utsname.h>

NSString * const DSKernelBackendDefaultsKey = @"myfilza.kernelBackend";
NSString * const DSKernelBackendValueFilza  = @"filzajailedds";
NSString * const DSKernelBackendValue3105   = @"3105";

/// 3105 侧状态：与现有后端的 gEscaped 完全独立
static BOOL      g3105Ready      = NO;
static NSString *g3105LastStage  = @"未开始";

BOOL DS3105KernelAvailable(void) { return YES; }
BOOL DS3105KernelIsReady(void)   { return g3105Ready; }
NSString *DS3105KernelLastStage(void) { return g3105LastStage; }

BOOL DS3105KernelSelected(void)
{
    NSString *v = [[NSUserDefaults standardUserDefaults] stringForKey:DSKernelBackendDefaultsKey];
    return [v isEqualToString:DSKernelBackendValue3105];
}

NSString * const DS3105KernelUseKernelExploitKey = @"myfilza.3105UseKernelExploit";

/// 是否使用内核漏洞。**默认 NO**：只走纯用户态的 bad_query 令牌路径。
BOOL DS3105KernelUseKernelExploit(void)
{
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    if ([d objectForKey:DS3105KernelUseKernelExploitKey] == nil) return NO;   // 没设置过 = 关闭
    return [d boolForKey:DS3105KernelUseKernelExploitKey];
}

#pragma mark - 纯用户态令牌路径（bad_query + sandbox_extension_consume，完全不碰内核）

/// 已取过令牌的路径与句柄（进程内保持有效，不主动 release；上限 16 条）
static NSMutableArray<NSString *> *g3105TokenPaths   = nil;
static NSMutableArray<NSNumber *> *g3105TokenHandles = nil;

/// 需要访问的沙盒外根路径。按 3105 本体的用法：容器数据 + App 包体 + /var/mobile 兜底。
static NSArray<NSString *> *ds3105_default_token_roots(void)
{
    return @[
        @"/var/mobile",
        @"/var/mobile/Containers/Data/Application",
        @"/var/containers/Bundle/Application"
    ];
}

/// 为一个路径取一次用户态令牌。返回 YES = 拿到（或已缓存）。
///
/// 这条路径**完全不碰内核**：bad_query 内部是
///   dlopen(libsystem_containermanager) → container_query（class 13 +
///   systemgroup.com.apple.mobilegestaltcache + part_domain "../../../../../../../..<path>" 路径穿越）
///   → container_query_get_single_result → container_copy_sandbox_token
///   → sandbox_extension_consume
static BOOL ds3105_take_token_for_path(NSString *path)
{
    if (path.length == 0) return NO;

    static dispatch_once_t once;
    dispatch_once(&once, ^{
        g3105TokenPaths   = [NSMutableArray array];
        g3105TokenHandles = [NSMutableArray array];
    });

    @synchronized (g3105TokenPaths) {
        if ([g3105TokenPaths containsObject:path]) return YES;
        if (g3105TokenPaths.count >= 16) return NO;
    }

    int64_t handle = bad_query((char *)path.fileSystemRepresentation, false, NULL, false);
    if (handle < 0) {
        NSLog(@"[3105] bad_query(%@) 返回 %lld（未取得令牌）", path, (long long)handle);
        return NO;
    }

    @synchronized (g3105TokenPaths) {
        [g3105TokenPaths addObject:path];
        [g3105TokenHandles addObject:@(handle)];
    }
    NSLog(@"[3105] 已取得沙盒扩展令牌：%@（handle=%lld）", path, (long long)handle);
    return YES;
}

BOOL DS3105KernelEnsureAccessForPath(NSString *path)
{
    if (path.length == 0) return NO;
    if (access(path.fileSystemRepresentation, R_OK) == 0) return YES;   // 已经能读，不必再取
    return ds3105_take_token_for_path(path);
}

/// 纯用户态激活：逐个根路径取令牌 → 读写探针验证。全程不执行任何内核代码。
int DS3105KernelActivateUserspaceOnly(NSString *_Nullable *_Nullable detail)
{
    g3105LastStage = @"用户态令牌：开始取令牌";
    NSLog(@"[3105] 纯用户态路径（不执行任何内核代码）；mcm_bridge 可用=%d", (int)MCMBridgeAvailable());

    NSArray<NSString *> *roots = ds3105_default_token_roots();
    NSMutableArray<NSString *> *got = [NSMutableArray array];

    for (NSString *root in roots) {
        if (![NSFileManager.defaultManager fileExistsAtPath:root]) {
            NSLog(@"[3105] 跳过不存在的路径：%@", root);
            continue;
        }
        if (ds3105_take_token_for_path(root)) [got addObject:root];
    }

    g3105LastStage = [NSString stringWithFormat:@"用户态令牌：取到 %lu/%lu 条",
                      (unsigned long)got.count, (unsigned long)roots.count];

    BOOL writeOK = ds3105_probe_write();
    BOOL readOK  = (access("/var/mobile/Containers/Data/Application", R_OK) == 0)
                || (access("/var/containers/Bundle/Application", R_OK) == 0);

    if (!writeOK && !readOK) {
        if (detail) {
            *detail = [NSString stringWithFormat:
                       @"3105 模式（仅用户态）：bad_query 取得 %lu 条令牌（%@），但沙盒外读写探针都失败"
                        "——这条路径在你这个系统版本上可能已被修补。可在设置里显式开启「使用内核漏洞」再试"
                        "（该路径有崩溃/重启风险）。",
                       (unsigned long)got.count,
                       got.count ? [got componentsJoinedByString:@"、"] : @"无"];
        }
        return 1003;
    }

    g3105Ready = YES;
    g3105LastStage = writeOK ? @"完成：用户态令牌已取得沙盒外读写"
                             : @"完成：用户态令牌已取得沙盒外读权限";
    if (detail) {
        *detail = [NSString stringWithFormat:
                   @"3105 模式（仅用户态，未执行内核漏洞）：bad_query 取得 %lu 条沙盒扩展令牌（%@）；"
                    "沙盒外写=%@、读=%@。",
                   (unsigned long)got.count,
                   got.count ? [got componentsJoinedByString:@"、"] : @"无",
                   writeOK ? @"通过" : @"失败", readOK ? @"通过" : @"失败"];
    }
    return 0;
}

/// 只认「沙盒外路径能不能真的写进去」，不信任任何自报状态
static BOOL ds3105_probe_write(void)
{
    static const char *paths[] = {
        "/var/mobile/.myfilza_3105_probe",
        "/private/var/mobile/.myfilza_3105_probe",
        "/var/tmp/.myfilza_3105_probe",
        "/private/var/tmp/.myfilza_3105_probe"
    };
    for (size_t i = 0; i < sizeof(paths) / sizeof(paths[0]); i++) {
        int fd = open(paths[i], O_WRONLY | O_CREAT | O_TRUNC, 0644);
        if (fd >= 0) {
            close(fd);
            unlink(paths[i]);
            return YES;
        }
    }
    return NO;
}

/// 3105 官方声明的适用范围（与其 ExploitSupportPolicy.swift 一致）。
/// 这里只用于「提前提示」，不阻止执行——用户的目标是尽量适配更多版本，
/// 超出范围时会在日志里明确警告，失败也会给出原因。
static BOOL ds3105_version_in_declared_range(void)
{
    NSOperatingSystemVersion v = NSProcessInfo.processInfo.operatingSystemVersion;
    long major = (long)v.majorVersion, minor = (long)v.minorVersion, patch = (long)v.patchVersion;

    if (major == 17) return minor <= 7;
    if (major == 18) return minor < 7 || (minor == 7 && patch <= 1);
    if (major == 26) return minor < 6 || (minor == 6 && patch <= 1);
    if (major == 27) return minor == 0 && patch == 0;   // 27 beta（按 build 白名单，这里放行 27.0）
    return NO;
}

int DS3105KernelActivate(NSString *_Nullable *_Nullable detail)
{
    g3105Ready = NO;
    g3105LastStage = @"准备";

    // ---- 默认：只走纯用户态令牌（不执行任何内核代码）----
    // 用户真机反馈：3105 的内核阶段（kexploit_opa334 / sandbox_escape）在 iPhone13,4 / iOS 18.5
    // 上会崩溃、而且连崩溃日志都留不下（说明是内核 panic 或被系统 kill），
    // 所以内核路径必须由用户在设置里显式开启，默认一律走不会 panic 的 bad_query 令牌路径。
    if (!DS3105KernelUseKernelExploit()) {
        NSLog(@"[3105] 仅用户态令牌模式（未开启内核漏洞）");
        return DS3105KernelActivateUserspaceOnly(detail);
    }

    NSLog(@"[3105] ⚠️ 用户显式开启了内核漏洞路径：**只执行 kexploit_opa334**（拿内核读写）；"
           "**不会**调用 3105 的 proc_self / sandbox_escape");

    if (!ds3105_version_in_declared_range()) {
        // 不阻止执行，但要说清楚：这是 3105 未声明支持的版本
        g3105LastStage = @"版本提示";
        NSLog(@"[3105] 当前系统不在 3105 声明支持的范围内，仍会尝试执行（失败属预期）");
    }

    // ---- 可选阶段：内核读写（只有用户显式开启才会走到这里）----
    //
    // **绝不调用 t3105_proc_self / t3105_sandbox_escape**。真机实测（iPhone13,4 / iOS 18.5）：
    //   本机 so_background_thread == 0 → proc_self() 拿 0 当 thread 去读 off_thread_t_tro(=0x388)
    //   → 3105 的 early_kread 遇到非法地址是**原地自旋**（不是返回失败）→ 被系统 watchdog 杀掉进程
    //   （设备不重启、也没有崩溃日志，只有 session log 里那行 "kaddr isn't valid, spinning here"）。
    //   sandbox_escape 内部同样要经过 proc/label 链路，所以一并禁用。
    g3105LastStage = @"内核阶段：kexploit_opa334（只取内核读写）";
    int kret = kexploit_opa334();
    if (kret != 0) {
        if (detail) {
            *detail = [NSString stringWithFormat:
                       @"3105 模式：kexploit_opa334 返回 %d（机型/系统版本不在其 offset 表内，或 race 失败）", kret];
        }
        return 1000 + kret;
    }
    NSLog(@"[3105] 内核读写已建立（未调用 3105 的 proc_self / sandbox_escape）");

    // ---- 容器访问：一律走纯用户态令牌路径（与默认路径共用同一套代码）----
    //
    // 依据（源码取证）：exploit/bad_query.c 与 exploit/mcm_bridge.m 里**没有任何内核原语**
    // （无 early_kread/kread/kwrite/kexploit/krw/kaddr/proc_self/offsets），只依赖
    // dlopen(libsystem_containermanager) + dlsym + xpc + sandbox_extension_consume，
    // 因此容器访问**不依赖**刚拿到的内核读写；内核读写在这个模式里目前只是"已具备"。
    g3105LastStage = @"容器访问：bad_query 用户态沙盒扩展令牌";
    NSString *upDetail = nil;
    int upRet = DS3105KernelActivateUserspaceOnly(&upDetail);

    if (upRet != 0 || !ds3105_probe_write()) {
        if (detail) {
            *detail = [NSString stringWithFormat:
                       @"3105 模式：内核读写已建立（kexploit_opa334 成功），但容器访问仍失败——%@",
                       upDetail ?: @"bad_query 未取得有效令牌"];
        }
        return 1002;
    }

    g3105LastStage = @"完成：内核读写已建立 + 用户态令牌已取得容器访问";
    g3105Ready = YES;
    if (detail) {
        *detail = [NSString stringWithFormat:
                   @"3105 模式：kexploit_opa334 成功（内核读写已建立，未调用 proc_self/sandbox_escape）；"
                    "容器访问由 bad_query 取得。%@",
                   upDetail ?: @""];
    }
    return 0;
}
