//
//  DSPickers.h — 系统「文件」选择器 + 系统分享面板
//
//  为什么不用 SwiftUI 的 .fileImporter / ShareLink：
//  参考包里实测过，在异常容器状态下 .fileImporter 会静默失败（点了没反应），
//  分享面板则需要 iPad 的 popover 锚点。这里统一用 UIKit 实现，两种签名方式都可用。
//

#import <Foundation/Foundation.h>

@class UIViewController;

NS_ASSUME_NONNULL_BEGIN

typedef void (^DSPickerCompletion)(NSArray<NSURL *> *urls);
typedef void (^DSPickerCancelHandler)(void);

@interface DSPickers : NSObject

/// 打开「文件」App 选择器。
/// @param utiIdentifiers 允许的 UTType 标识符，传 nil 表示任意文件
/// @param multiple       是否允许多选
/// @param asCopy         YES = 选完直接拿到临时目录里的拷贝（无需安全作用域处理）
+ (void)presentOpenPickerWithUTIs:(nullable NSArray<NSString *> *)utiIdentifiers
                         multiple:(BOOL)multiple
                           asCopy:(BOOL)asCopy
                       completion:(DSPickerCompletion)completion
                           cancel:(nullable DSPickerCancelHandler)cancel
    NS_SWIFT_NAME(presentOpenPicker(utis:multiple:asCopy:completion:cancel:));

/// 选择文件夹（用于导入「脚本包」目录）。非 asCopy：拿到的 URL 需要安全作用域访问，
/// 调用方应当在回调里立刻递归拷贝到自己的目录。
+ (void)presentFolderPickerWithCompletion:(DSPickerCompletion)completion
                                   cancel:(nullable DSPickerCancelHandler)cancel
    NS_SWIFT_NAME(presentFolderPicker(completion:cancel:));

/// 选择文件夹（asCopy: YES）：选完直接拿到临时目录里的整份拷贝，无需安全作用域处理。
/// 「替换」页的文件夹模式用它导入源文件夹。
+ (void)presentFolderPickerAsCopyWithCompletion:(DSPickerCompletion)completion
                                         cancel:(nullable DSPickerCancelHandler)cancel
    NS_SWIFT_NAME(presentFolderPickerAsCopy(completion:cancel:));

/// 系统分享面板（AirDrop / QQ / 存储到「文件」等）。传文件 URL 数组，可一次多个。
+ (void)presentShareSheetForURLs:(NSArray<NSURL *> *)urls NS_SWIFT_NAME(presentShareSheet(urls:));

/// 当前最顶层的 UIViewController（找不到返回 nil）
+ (nullable UIViewController *)topViewController NS_SWIFT_NAME(topViewController());

/// 出错时的日志回调：Swift 侧接到 DSLog.shared.error，方便在会话日志里看到原因
+ (void)setErrorLogHandler:(nullable void (^)(NSString *message))handler
    NS_SWIFT_NAME(setErrorLogHandler(_:));

/// 双保险：Swift 无法捕获 ObjC 异常，用它把调用包起来。
/// 内部异常会被捕获、写日志并给用户提示，返回 NO（调用方可以据此提示用户）。
+ (BOOL)performSafely:(void (NS_NOESCAPE ^)(void))block label:(NSString *)label
    NS_SWIFT_NAME(performSafely(_:label:));

@end

NS_ASSUME_NONNULL_END
