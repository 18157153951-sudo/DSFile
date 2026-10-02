//
//  DSCrash.h — 崩溃现场记录（信号 + 未捕获异常）
//
//  为什么需要它：内核漏洞跑挂的时候，App 是直接 SIGSEGV / SIGBUS 死的，
//  系统 .ips 报告要用户去「设置 → 隐私 → 分析」翻，很多人找不到；
//  这里让 App 自己把信号、回溯写进 Documents/Logs/crash-*.log，
//  下次进「设置 → 诊断」就能一键分享出来。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface DSCrash : NSObject

/// 装上信号处理器与未捕获异常处理器（建议在 App init 里调用一次）
+ (void)install NS_SWIFT_NAME(install());

/// 最新一份崩溃报告的路径；没有则返回 nil
+ (nullable NSString *)latestCrashReportPath NS_SWIFT_NAME(latestCrashReportPath());

/// 崩溃报告目录（Documents/Logs）
+ (nullable NSString *)crashReportDirectory NS_SWIFT_NAME(crashReportDirectory());

@end

NS_ASSUME_NONNULL_END
