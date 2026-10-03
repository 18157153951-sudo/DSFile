//
//  DS3105Kernel.h — 「3105 模式」内核后端（与现有 FilzaJailedDS 后端完全隔离）
//
//  设计原则（用户明确要求「不要和之前的合并，我怕有bug」）：
//    · 3105 自成一体：自己的入口、自己的就绪标志、自己的错误码区间（1000+）；
//    · 不共用我们的 kread/kwrite 原语，也不把 3105 的原语暴露给现有路径；
//    · 设置里选 3105 时只走 3105 的代码；选 FilzaJailedDS（默认）时行为与 0.4.0 完全一致；
//    · 唯一的分派点在 DSKernel.m 的激活入口（一处 if/else），状态与通知机制复用 EnvironmentProbe。
//
//  3105 源码逐字节原样放在 DSFile/Vendor/ThreeOneOSFive/{exploit,kexploit}，
//  其自有符号通过 DS3105SymbolPrefix.h 统一改名为 t3105_*，所以两份同名的
//  kexploit/krw 实现可以共存于同一个可执行文件。
//  来源与许可证（GPL-3.0）见 Vendor/ThreeOneOSFive/{LICENSE,THIRD_PARTY_NOTICES.md,README.3105.md}。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 内核后端选择。字符串值与 Swift 侧 @AppStorage 共用，改一处要同步改另一处。
///   "filzajailedds" —— 默认，现有后端（FilzaJailedDS 2.2），行为不许变
///   "3105"          —— 3105 后端（本文件）
FOUNDATION_EXPORT NSString * const DSKernelBackendDefaultsKey;      // myfilza.kernelBackend
FOUNDATION_EXPORT NSString * const DSKernelBackendValueFilza;       // filzajailedds
FOUNDATION_EXPORT NSString * const DSKernelBackendValue3105;        // 3105

/// 当前选择是否 3105（默认返回 NO，即走现有后端）
FOUNDATION_EXPORT BOOL DS3105KernelSelected(void);

/// 3105 是否编入本包（始终 YES；保留接口便于以后裁剪）
FOUNDATION_EXPORT BOOL DS3105KernelAvailable(void);

/// 执行 3105 后端：kexploit_opa334 → proc_self → sandbox_escape →（必要时）bad_query
/// 返回 0 = 已取得沙盒外文件访问（探针写盘通过）；非 0 = 3105 自己的错误码（1000+）
/// detail 会带上一句话原因，供界面日志直接展示。
FOUNDATION_EXPORT int DS3105KernelActivate(NSString *_Nullable *_Nullable detail);

/// 本进程内 3105 后端是否已就绪（仅 3105 模式使用；与现有后端的 gEscaped 无关）
FOUNDATION_EXPORT BOOL DS3105KernelIsReady(void);

/// 最近一次执行到哪个阶段（失败时用于定位）
FOUNDATION_EXPORT NSString *DS3105KernelLastStage(void);

/// 把本进程 cred 的 posix_cred 改成 root（cr_uid/cr_ruid/cr_svuid/cr_groups[0]/cr_rgid/cr_svgid 全 0）。
/// 只用 3105 自己的原语（t3105_kread*/t3105_kwrite*），**不共用** FilzaJailedDS 的 kread/kwrite——
/// 两个后端各自建立自己的 socket 原语，混用会野读。
/// 返回 0 = 已确认 cr_uid == 0；1010 = 找不到 cred；1011 = cred 地址未过校验；1012 = 回读 cr_uid 仍非 0。
FOUNDATION_EXPORT int DS3105KernelElevateToRoot(NSString *_Nullable *_Nullable detail);

#pragma mark - 用户态令牌路径（备选分支）

/// 「3105 模式是否使用内核漏洞」开关的 UserDefaults 键。默认 **YES**。
FOUNDATION_EXPORT NSString * const DS3105KernelUseKernelExploitKey;   // myfilza.3105UseKernelExploit

/// 是否使用内核漏洞（默认 **YES**）。
///
///   YES（默认）—— 走 3105 自己的 kexploit_opa334 拿内核读写，再用**我们当年在 Filza 那条路上
///       验证成功的 cred 路线**做逃逸（无条件 XPACI + cred→label→sandbox→ext_set 三步改写）。
///       这是 18.x 上真正能拿到沙盒外读写的那条路；3105 本体在 iOS < 26 时也保留内核 R/W 继续工作。
///       注意：这条路径**绝不调用** 3105 的 proc_self / sandbox_escape（本机会自旋被 watchdog 杀）。
///
///   NO —— 只走 bad_query + mcm_bridge 纯用户态令牌。仅 iOS 26+ 有意义：18.5 上
///       libsystem_containermanager 缺 container_query_operation_set_part* 符号 → 0 条令牌。
FOUNDATION_EXPORT BOOL DS3105KernelUseKernelExploit(void);

/// 只走用户态令牌（不跑内核漏洞）的激活入口，返回码语义与 DS3105KernelActivate 一致。
FOUNDATION_EXPORT int DS3105KernelActivateUserspaceOnly(NSString *_Nullable *_Nullable detail);

/// 按需为某个沙盒外路径补取一次用户态令牌（纯用户态）。已经取过的路径直接返回 YES。
/// 用于「替换目标在 /var/mobile 之外」时补权限，不需要重跑任何内核代码。
FOUNDATION_EXPORT BOOL DS3105KernelEnsureAccessForPath(NSString *path);

#pragma mark - 访问路径选择（自动 / 仅 MHA / 仅内核）

/// 「访问路径」的 UserDefaults 键，字符串值与 Swift 侧 @AppStorage 共用（改一处要同步改另一处）
FOUNDATION_EXPORT NSString * const DSKernelPathModeDefaultsKey;    // myfilza.pathMode
FOUNDATION_EXPORT NSString * const DSKernelPathModeValueAuto;      // auto
FOUNDATION_EXPORT NSString * const DSKernelPathModeValueMHA;       // mha
FOUNDATION_EXPORT NSString * const DSKernelPathModeValueKernel;    // kernel

/// 用户选择的访问路径。
///   Auto       —— 默认。MHA 可用（签名 identifier 就是 MHA 且探针通过）才用 MHA；否则自动回退内核。
///   MHAOnly    —— 只走 MHA（零内核）。不可用时**明确失败**并说明原因，**绝不静默回退内核**。
///   KernelOnly —— 完全跳过 MHA（连尝试都不做），直接走所选内核后端（默认 FilzaJailedDS，行为与 0.6.2 一致）。
typedef NS_ENUM(NSInteger, DSKernelPathMode) {
    DSKernelPathModeAuto       = 0,
    DSKernelPathModeMHAOnly    = 1,
    DSKernelPathModeKernelOnly = 2,
};

/// 读取用户当前选择（默认 Auto；值非法时也按 Auto 处理）
FOUNDATION_EXPORT DSKernelPathMode DSKernelPathModeCurrent(void);

/// 供日志 / 界面展示的名字
FOUNDATION_EXPORT NSString *DSKernelPathModeDisplayName(DSKernelPathMode mode);

/// 本次进程实际走通的是哪条路（未激活时返回 nil）
FOUNDATION_EXPORT NSString * _Nullable DSKernelActivePathDescription(void);

#pragma mark - 安全模式（稳定性优先）

/// 「安全模式」的 UserDefaults 键。默认 **NO**（保持 FilzaJailedDS 既有行为不变）。
FOUNDATION_EXPORT NSString * const DSSafeModeDefaultsKey;   // myfilza.safeMode

/// 安全模式是否开启。
///
/// 开启后：**任何模式都不执行内核漏洞**——
///   · 3105 模式：强制只走纯用户态令牌（忽略「使用内核漏洞」开关），并在日志里标注；
///   · FilzaJailedDS 模式：它整体依赖内核漏洞，因此在安全模式下会被**阻止执行**并提示改用 3105 令牌模式。
///
/// 目的：给用户一个「绝对不碰内核、绝不重启」的开关，代价是能力受限。
FOUNDATION_EXPORT BOOL DSSafeModeEnabled(void);

NS_ASSUME_NONNULL_END
