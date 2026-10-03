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

/// 执行 MHA 路径（全程不跑内核）。
/// 返回 0    = 已取得沙盒外读写；
///     1020 = 自身 bundle id 不是 MHA（这条路径不适用，不是失败）；
///     1021 = MCM 桥不可用（缺私有符号）；
///     1022 = 一个容器租约都没激活成功；
///     1023 = 租约拿到了但读写探针仍失败。
FOUNDATION_EXPORT int DSMHAKernelActivate(NSString *_Nullable *_Nullable detail);

/// 确保某个沙盒外路径可读：已可读直接 YES；否则重跑一次激活（懒加载）再判定。
FOUNDATION_EXPORT BOOL DSMHAKernelEnsureAccessForPath(NSString *path);

NS_ASSUME_NONNULL_END
