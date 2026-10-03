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

#pragma mark - 用户态令牌路径（默认走这条，不碰内核）

/// 「3105 模式是否使用内核漏洞」开关的 UserDefaults 键。默认 **NO**。
FOUNDATION_EXPORT NSString * const DS3105KernelUseKernelExploitKey;   // myfilza.3105UseKernelExploit

/// 是否使用内核漏洞（默认 NO）。
///
///   NO（默认，安全）—— 只走 bad_query + mcm_bridge 这条**纯用户态**路径：
///       dlopen ContainerManager → container_query 路径穿越
///       → container_copy_sandbox_token → sandbox_extension_consume。
///       完全不执行 kexploit_opa334，不会 panic、不会重启设备。
///
///   YES（用户显式开启）—— 先跑 DarkSword 内核漏洞（kexploit_opa334）→ proc_self →
///       sandbox_escape，失败再回退 bad_query。用户真机反馈：该路径在 iPhone13,4 / iOS 18.5
///       上会崩溃（且可能连崩溃日志都留不下 → 内核 panic 或被 kill），故默认关闭。
FOUNDATION_EXPORT BOOL DS3105KernelUseKernelExploit(void);

/// 只走用户态令牌（不跑内核漏洞）的激活入口，返回码语义与 DS3105KernelActivate 一致。
FOUNDATION_EXPORT int DS3105KernelActivateUserspaceOnly(NSString *_Nullable *_Nullable detail);

/// 按需为某个沙盒外路径补取一次用户态令牌（纯用户态）。已经取过的路径直接返回 YES。
/// 用于「替换目标在 /var/mobile 之外」时补权限，不需要重跑任何内核代码。
FOUNDATION_EXPORT BOOL DS3105KernelEnsureAccessForPath(NSString *path);

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
