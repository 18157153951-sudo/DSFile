//
//  DSSignatureInfo.h — 读取「本 App 的签名标识」，用来判断 MHA 身份是否真的生效
//
//  为什么需要它：
//    上游 MobileHouseArrest-PoC 原文写明 —— MCM 把调用方的
//    **CodeDirectory identifier** 当作授权键。所以只把 Info.plist 里的
//    CFBundleIdentifier 改成 com.apple.mobile.MobileHouseArrest 是**不够**的：
//    签名时那个 identifier 也必须是它，否则 MCM 只会给你自己的容器、
//    特权沙盒 profile 也不会下发（这与真机现象完全一致）。
//
//  设计原则（与全项目一致）：
//    · 只读、只诊断，**绝不影响激活流程**，拿不到就如实说"拿不到"；
//    · 只用签名确定的 API：csops(2) 与 Security.framework 里签名稳定的两个函数
//      （SecTaskCreateFromSelf / SecTaskCopyValueForEntitlement）；
//      其它私有接口一律不碰，避免"猜签名导致崩溃"。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// MHA 期望的签名标识
FOUNDATION_EXPORT NSString * const DSSignatureExpectedIdentifier;

/// 最佳努力地取签名标识（CodeDirectory identifier）；取不到返回 nil
FOUNDATION_EXPORT NSString * _Nullable DSSignatureIdentifier(void);

/// 三态判断：1 = 与 MHA 一致；0 = 明确不一致；-1 = 无法判断
FOUNDATION_EXPORT NSInteger DSSignatureIdentifierMatchesMHA(void);

/// 签名里的 TeamIdentifier（取不到返回 nil）
FOUNDATION_EXPORT NSString * _Nullable DSSignatureTeamIdentifier(void);

/// 签名里的 application-identifier（形如 TEAMID.bundle.id；取不到返回 nil）
FOUNDATION_EXPORT NSString * _Nullable DSSignatureApplicationIdentifier(void);

/// 是不是 TrollStore 安装的：
///   · TeamIdentifier == "TROLLTROLL"，或
///   · application-identifier 以 "TROLLTROLL." 开头
/// 这是**不需要任何权限**就能拿到的可靠信号（真机日志里 TrollStore 安装的包就是 TROLLTROLL）。
FOUNDATION_EXPORT BOOL DSSignatureIsTrollStoreInstalled(void);

/// TrollStore 判定的依据（一句话，给日志/界面用；不是 TrollStore 时返回 nil）
FOUNDATION_EXPORT NSString * _Nullable DSSignatureTrollStoreEvidence(void);

/// 多行诊断报告（用于写日志）：签名标识 / TeamIdentifier / application-identifier / 结论
FOUNDATION_EXPORT NSString *DSSignatureDiagnosticReport(void);

/// 单行摘要（用于激活结论里附带一句）
FOUNDATION_EXPORT NSString *DSSignatureSummaryLine(void);

NS_ASSUME_NONNULL_END
