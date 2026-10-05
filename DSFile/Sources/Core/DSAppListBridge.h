//
//  DSAppListBridge.h — 「无需任何权限」的已安装 App 列表来源
//
//  背景（真机取证）：
//    · 我们的 AppScanner 以前只靠读容器的 metadata.plist 来枚举 App，
//      所以**没逃逸 / 没权限**时永远显示「扫描到 0 个 App」；
//    · 3105 本体在 iOS 18 上的做法（helpers/KernelExploit.swift 注释原文：
//      "File browsing falls back to LSApplicationWorkspace + inode walk"）说明它
//      用私有接口 LSApplicationWorkspace 拿列表，这条路**不需要任何文件系统权限**。
//
//  本文件只做「拿列表」，不读容器内容；容器路径只是字符串，能不能读由调用方探针判定。
//  私有类全部用运行时查找（NSClassFromString / dlopen），**不直接链接**私有框架；
//  每一步都在 @try/@catch 里，取不到就返回 nil 并留下原因，绝不崩。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 返回字典的键（值都是 NSString，可能缺某个键）
FOUNDATION_EXPORT NSString * const DSAppListKeyBundleId;        // 必需
FOUNDATION_EXPORT NSString * const DSAppListKeyName;            // 显示名
FOUNDATION_EXPORT NSString * const DSAppListKeyVersion;         // 短版本号
FOUNDATION_EXPORT NSString * const DSAppListKeyBundlePath;      // .app 路径
FOUNDATION_EXPORT NSString * const DSAppListKeyDataPath;        // 数据容器路径（可能没有）

@interface DSAppListBridge : NSObject

/// 本机能不能用这条路（= LSApplicationWorkspace 类可用）
+ (BOOL)available;

/// 不可用 / 上次失败的原因（一句话，给日志和界面用）
+ (nullable NSString *)lastFailureReason;

/// 上一次调用的逐步诊断（每行一步：dlopen 路径、selector 是否响应、拿到几条…）
+ (NSArray<NSString *> *)lastDiagnostics;

/// 逐步诊断的多行文本（直接写日志 / 导出诊断用）
+ (NSString *)lastDiagnosticsText;

/// 通过 LaunchServices 私有接口取已安装 App 列表。
/// 返回 nil = 这条路不可用（原因见 +lastFailureReason）；返回空数组 = 可用但没有 App。
+ (nullable NSArray<NSDictionary<NSString *, NSString *> *> *)installedAppsFromLaunchServices;

@end

NS_ASSUME_NONNULL_END
