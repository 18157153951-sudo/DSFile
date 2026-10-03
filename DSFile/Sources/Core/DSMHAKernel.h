//
//  DSMHAKernel.h — 「MHA 身份（零内核）」路径
//
//  机制（由上游 PoC 原文证实，见 DSMCMBridge.h 顶部来源）：
//    ① 身份：CodeDirectory identifier = com.apple.mobile.MobileHouseArrest
//       → iOS 据此下发特权沙盒 profile；
//    ② 租约：用 MCM 查询目标**容器标识**，拿到可读可写的沙盒扩展并激活。
//  两步都**不执行任何内核代码**。
//
//  本文件负责第 ② 步的编排：枚举标识 → 逐个取租约并激活 → 真实探针验证。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// MHA 身份的 bundle id
FOUNDATION_EXPORT NSString * const DSMHABundleIdentifier;

/// 本进程的 bundle id 是否为 MHA 身份（第一步）
FOUNDATION_EXPORT BOOL DSMHAIsHost(void);

/// 最近一次执行到哪个阶段（失败定位用）
FOUNDATION_EXPORT NSString *DSMHALastStage(void);

/// 已成功激活并**持有**的容器租约数量（持有着才不会失效）
FOUNDATION_EXPORT NSUInteger DSMHAActivatedLeaseCount(void);

/// 已成功激活并持有的 **App 数据容器（class 2）** 租约数量。
/// 判据用：只能拿到 1 个（=自己）说明签名 identifier 不是 MHA，MCM 没给别人的容器。
FOUNDATION_EXPORT NSUInteger DSMHAAppDataLeaseCount(void);

/// 签名 identifier 是否就是 MHA（1 = 是；0 = 明确不是；-1 = 无法判断）
FOUNDATION_EXPORT NSInteger DSMHASignatureIsMHA(void);

/// 真实权限探针：**在已持有的租约容器根目录里**写一个临时文件再删掉。
/// 只有租约真的生效（扩展可用）才返回 YES；不依赖"持有租约数"，避免自报成功。
FOUNDATION_EXPORT BOOL DSMHAAccessProbePasses(void);

/// 执行 MHA 路径（全程不跑内核）。
/// 返回 0    = 已取得沙盒外读写；
///     1020 = 自身 bundle id 不是 MHA（这条路径不适用，不是失败）；
///     1021 = MCM 桥不可用（缺私有符号）；
///     1022 = 一个容器租约都没激活成功；
///     1023 = 租约拿到了但权限探针仍失败；
///     1024 = **签名 identifier 不是 MHA**（MCM 的授权键不匹配，此时绝不会拿到别人的容器，
///            因此连 MCM 都不必尝试）。
FOUNDATION_EXPORT int DSMHAKernelActivate(NSString *_Nullable *_Nullable detail);

/// 确保某个沙盒外路径可读：已可读直接 YES；否则重跑一次激活（懒加载）再判定。
FOUNDATION_EXPORT BOOL DSMHAKernelEnsureAccessForPath(NSString *path);

NS_ASSUME_NONNULL_END
