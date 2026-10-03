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
static int64_t   g3105TokenHandle = -1;

BOOL DS3105KernelAvailable(void) { return YES; }
BOOL DS3105KernelIsReady(void)   { return g3105Ready; }
NSString *DS3105KernelLastStage(void) { return g3105LastStage; }

BOOL DS3105KernelSelected(void)
{
    NSString *v = [[NSUserDefaults standardUserDefaults] stringForKey:DSKernelBackendDefaultsKey];
    return [v isEqualToString:DSKernelBackendValue3105];
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

    if (!ds3105_version_in_declared_range()) {
        // 不阻止执行，但要说清楚：这是 3105 未声明支持的版本
        g3105LastStage = @"版本提示";
        NSLog(@"[3105] 当前系统不在 3105 声明支持的范围内，仍会尝试执行（失败属预期）");
    }

    // ---- 阶段 1/3：内核读写（3105 自带 kexploit_opa334，内部自行调用 offsets_init）----
    g3105LastStage = @"阶段 1/3：kexploit_opa334（内核读写）";
    int kret = kexploit_opa334();
    if (kret != 0) {
        if (detail) {
            *detail = [NSString stringWithFormat:
                       @"3105 模式：kexploit_opa334 返回 %d（机型/系统版本不在其 offset 表内，或 race 失败）", kret];
        }
        return 1000 + kret;
    }

    // ---- 阶段 2/3：定位本进程 proc ----
    g3105LastStage = @"阶段 2/3：proc_self（定位本进程）";
    uint64_t selfProc = proc_self();
    if (selfProc == 0) {
        if (detail) *detail = @"3105 模式：proc_self() 返回 0（该机型 so_background_thread 为 0 时会这样）";
        return 1001;
    }

    // ---- 阶段 3/3：沙盒逃逸（3105 自带 sandbox_escape）----
    g3105LastStage = @"阶段 3/3：sandbox_escape（沙盒逃逸）";
    int sret = sandbox_escape(selfProc);
    BOOL active = (sandbox_access_is_active() == 1) || ds3105_probe_write();

    if (!active) {
        // 3105 在 iOS 26+ 走的另一条路：用 ContainerManager 查询越权换取沙盒扩展令牌
        g3105LastStage = @"阶段 3/3 回退：bad_query（MCM 沙盒扩展令牌）";
        int64_t handle = bad_query("/var/mobile", false, NULL, false);
        if (handle >= 0) {
            g3105TokenHandle = handle;   // 进程内保持有效，不主动 release
        } else {
            NSLog(@"[3105] bad_query(/var/mobile) 返回 %lld", (long long)handle);
        }
        active = ds3105_probe_write();
    }

    if (!active) {
        if (detail) {
            *detail = [NSString stringWithFormat:
                       @"3105 模式：sandbox_escape 返回 %d，bad_query 也未能取得沙盒外写权限（探针仍失败）", sret];
        }
        return 1002;
    }

    g3105LastStage = @"完成：已取得沙盒外文件访问";
    g3105Ready = YES;
    if (detail) {
        *detail = [NSString stringWithFormat:
                   @"3105 模式：kexploit_opa334 成功，self_proc=0x%llx，sandbox_escape 返回 %d，沙盒外写探针通过",
                   (unsigned long long)selfProc, sret];
    }
    return 0;
}
