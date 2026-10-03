//
//  DSPickers.h — 系统「文件」选择器 + 系统分享面板
//
//  为什么不用 SwiftUI 的 .fileImporter / ShareLink：
//  参考包里实测过，在异常容器状态下 .fileImporter 会静默失败（点了没反应），
//  分享面板则需要 iPad 的 popover 锚点。这里统一用 UIKit 实现，两种签名方式都可用。
//
//  ⚠️ 关于 asCopy（2026-10 真机踩坑）：
//  Apple **不允许**用 `initForOpeningContentTypes:asCopy:YES` 选文件夹，
//  用户一旦选中文件夹就会抛 `folder import is not supported, use asCopy:false`（NSException → SIGABRT）。
//  所以本文件里**所有**选择器一律 `asCopy:NO`；拿到的 URL 需要安全作用域访问，
//  由本文件的 `...CopyingInto:` 系列负责「安全作用域 + iCloud 协调 + 递归拷贝进沙盒」，
//  调用方只消费沙盒内的目标 URL 与 NSError，不要再自己 copy。
//

#import <Foundation/Foundation.h>

@class UIViewController;

NS_ASSUME_NONNULL_BEGIN

typedef void (^DSPickerCompletion)(NSArray<NSURL *> *urls);
typedef void (^DSPickerCancelHandler)(void);
/// 拷贝进沙盒后的回调：copiedURLs 可能为空数组，error 非空时表示至少有一个没拷成功
typedef void (^DSPickerCopyCompletion)(NSArray<NSURL *> *copiedURLs, NSError * _Nullable error);
typedef void (^DSPickerFolderCopyCompletion)(NSURL * _Nullable copiedURL, NSError * _Nullable error);

@interface DSPickers : NSObject

#pragma mark - 推荐用法（选完直接拷进沙盒，返回沙盒内 URL）

/// 选文件（可多选）→ 逐个拷进 destinationDirectory（重名自动加 -1/-2）→ 回传沙盒内 URL。
/// 内部处理安全作用域与 iCloud 未下载文件（NSFileCoordinator）。
+ (void)presentOpenPickerCopyingInto:(NSURL *)destinationDirectory
                                utis:(nullable NSArray<NSString *> *)utiIdentifiers
                            multiple:(BOOL)multiple
                          completion:(DSPickerCopyCompletion)completion
                              cancel:(nullable DSPickerCancelHandler)cancel
    NS_SWIFT_NAME(presentOpenPickerCopying(into:utis:multiple:completion:cancel:));

/// 选文件夹 → 整棵递归拷进 destinationDirectory（重名自动加 -1/-2）→ 回传沙盒内 URL。
+ (void)presentFolderPickerCopyingInto:(NSURL *)destinationDirectory
                            completion:(DSPickerFolderCopyCompletion)completion
                                cancel:(nullable DSPickerCancelHandler)cancel
    NS_SWIFT_NAME(presentFolderPickerCopying(into:completion:cancel:));

/// 把已经拿到的 URL（可能来自选择器，也可能是别处）拷进沙盒目录，带安全作用域与 iCloud 协调。
/// 返回拷贝后的 URL 数组；partial 成功时也会返回已成功的部分，并把第一个错误写进 error。
+ (nullable NSArray<NSURL *> *)copyItemsAtURLs:(NSArray<NSURL *> *)urls
                                 intoDirectory:(NSURL *)directory
                                         error:(NSError * _Nullable * _Nullable)error
    NS_SWIFT_NAME(copyItems(_:into:));

#pragma mark - 底层用法（调用方必须自己处理安全作用域）

/// 打开「文件」App 选择器。
/// ⚠️ asCopy 参数**已被忽略**（一律按 NO 呈现，见文件头说明）；返回的 URL 需要安全作用域。
/// 新代码请用 presentOpenPickerCopyingInto:。
+ (void)presentOpenPickerWithUTIs:(nullable NSArray<NSString *> *)utiIdentifiers
                         multiple:(BOOL)multiple
                           asCopy:(BOOL)asCopy
                       completion:(DSPickerCompletion)completion
                           cancel:(nullable DSPickerCancelHandler)cancel
    NS_SWIFT_NAME(presentOpenPicker(utis:multiple:asCopy:completion:cancel:));

/// 选择文件夹（asCopy:NO）。返回的 URL 需要安全作用域；新代码请用 presentFolderPickerCopyingInto:。
+ (void)presentFolderPickerWithCompletion:(DSPickerCompletion)completion
                                   cancel:(nullable DSPickerCancelHandler)cancel
    NS_SWIFT_NAME(presentFolderPicker(completion:cancel:));

#pragma mark - 分享与工具

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
