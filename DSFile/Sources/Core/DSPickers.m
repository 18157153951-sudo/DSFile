//
//  DSPickers.m
//
//  统一、健壮的「系统选择器 / 分享面板」呈现层。
//
//  为什么不再用「遍历 presentedViewController 取最上层」：
//  那条路可能拿到正在转场 / 正在 dismiss 的控制器，UIKit 会抛
//  NSInvalidArgumentException / NSInternalInconsistencyException；异常沿着 runloop
//  抛出去就是 SIGABRT（实测崩溃报告：objc_exception_rethrow ← CFRunLoopRunSpecific）。
//
//  现在的做法：
//    1) 在 key window 的 rootViewController 上挂一个 1x1、透明、不可交互的**专用宿主控制器**，
//       所有弹层都从它 present —— 它的生命周期稳定，永远不在转场中；
//    2) **一次只呈现一个**：宿主上还有弹层、或上一次还没结束，就排队等它结束（绝不叠加 present）；
//    3) 全程 @try/@catch：异常只写日志 + 弹提示，**绝不 abort**。
//

#import "DSPickers.h"
#import <UIKit/UIKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#pragma mark - 日志

static void (^gDSPickerErrorLog)(NSString *) = nil;

static void DSPickerReportFailure(NSString *label, NSException *exception);

#pragma mark - 呈现器（专用宿主 + 串行队列）

@class DSPickerCoordinator;

@interface DSPickerPresenter : NSObject

+ (instancetype)shared;

/// 排队呈现：一次只跑一个，跑完（弹层消失）再跑下一个
- (void)enqueue:(void (^)(UIViewController *host))block label:(NSString *)label;
/// 当前这次呈现结束（弹层消失 / 呈现失败），继续队列
- (void)finishPresentation;
- (void)retainCoordinator:(DSPickerCoordinator *)coordinator;
- (void)releaseCoordinator:(DSPickerCoordinator *)coordinator;
- (void)presentAlertWithTitle:(NSString *)title message:(NSString *)message;

@end

#pragma mark - delegate 保持器

/// UIKit 的 delegate 是弱引用：必须强持有到回调结束（这里由 DSPickerPresenter 持有）
@interface DSPickerCoordinator : NSObject <UIDocumentPickerDelegate>
@property (nonatomic, copy) DSPickerCompletion onPick;
@property (nonatomic, copy, nullable) DSPickerCancelHandler onCancel;
- (instancetype)initWithPick:(DSPickerCompletion)onPick cancel:(nullable DSPickerCancelHandler)onCancel;
@end

@implementation DSPickerCoordinator

- (instancetype)initWithPick:(DSPickerCompletion)onPick cancel:(DSPickerCancelHandler)onCancel
{
    if ((self = [super init])) {
        _onPick = [onPick copy];
        _onCancel = [onCancel copy];
    }
    return self;
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls
{
    DSPickerCompletion pick = self.onPick;
    [DSPickerPresenter.shared releaseCoordinator:self];
    [DSPickerPresenter.shared finishPresentation];
    if (pick) pick(urls);
}

- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller
{
    DSPickerCancelHandler cancel = self.onCancel;
    [DSPickerPresenter.shared releaseCoordinator:self];
    [DSPickerPresenter.shared finishPresentation];
    if (cancel) cancel();
}

@end

@implementation DSPickerPresenter {
    UIViewController *_host;
    NSMutableArray<NSDictionary *> *_queue;
    NSMutableArray<DSPickerCoordinator *> *_coordinators;
    BOOL _presenting;
    NSUInteger _generation;
}

+ (instancetype)shared
{
    static DSPickerPresenter *shared = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [[DSPickerPresenter alloc] init]; });
    return shared;
}

- (instancetype)init
{
    if ((self = [super init])) {
        _queue = [NSMutableArray array];
        _coordinators = [NSMutableArray array];
    }
    return self;
}

#pragma mark 宿主

/// key window（多场景也稳；都没有就退回第一个窗口）
+ (UIWindow *)keyWindow
{
    UIWindow *fallback = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes.allObjects) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        UIWindowScene *windowScene = (UIWindowScene *)scene;
        for (UIWindow *candidate in windowScene.windows) {
            if (candidate.isKeyWindow) return candidate;
            if (!fallback) fallback = candidate;
        }
    }
    return fallback;
}

/// 专用呈现宿主：rootViewController 的透明子控制器。
/// 注意不能 hidden（隐藏视图会让 present 失效），所以用 1x1 + alpha 0.01 + 关闭交互。
- (UIViewController *)host
{
    if (_host && _host.view.window) return _host;
    _host = nil;

    UIWindow *window = [DSPickerPresenter keyWindow];
    UIViewController *root = window.rootViewController;
    if (!root) return nil;

    UIViewController *host = [[UIViewController alloc] init];
    host.view.backgroundColor = UIColor.clearColor;
    host.view.frame = CGRectMake(0, 0, 1, 1);
    host.view.alpha = 0.01;
    host.view.userInteractionEnabled = NO;

    @try {
        [root addChildViewController:host];
        [root.view addSubview:host.view];
        [host didMoveToParentViewController:root];
    } @catch (NSException *e) {
        NSLog(@"[DSPickers] 挂载呈现宿主失败：%@", e.reason);
        return nil;
    }

    _host = host;
    return host;
}

#pragma mark 队列

- (void)enqueue:(void (^)(UIViewController *))block label:(NSString *)label
{
    if (!block) return;
    [_queue addObject:@{ @"block": [block copy], @"label": [label copy] ?: @"打开选择器" }];
    [self drainIfIdle];
}

- (void)finishPresentation
{
    if (!_presenting && _queue.count == 0) return;
    _presenting = NO;
    _generation += 1;
    // 延到下一次 runloop：让 UIKit 先把 dismiss/转场收干净，避免叠加 present
    dispatch_async(dispatch_get_main_queue(), ^{ [self drainIfIdle]; });
}

- (void)drainIfIdle
{
    if (_presenting) return;
    if (_queue.count == 0) return;

    NSDictionary *item = _queue.firstObject;
    void (^block)(UIViewController *) = item[@"block"];
    NSString *label = item[@"label"];

    UIViewController *host = [self host];
    if (!host) {
        [_queue removeObjectAtIndex:0];
        DSPickerReportFailure(label, nil);
        return;
    }

    // 宿主上还有别的弹层：等它消失，不叠加 present
    if (host.presentedViewController) {
        _presenting = NO;
        __weak DSPickerPresenter *weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ [weakSelf drainIfIdle]; });
        return;
    }

    [_queue removeObjectAtIndex:0];
    _presenting = YES;

    NSUInteger generation = _generation;

    @try {
        block(host);
    } @catch (NSException *e) {
        DSPickerReportFailure(label, e);
        [self finishPresentation];
        return;
    }

    // 兜底：万一 delegate 回调一直不来（例如被手势异常关掉），也别把队列卡死
    __weak DSPickerPresenter *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(180.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        DSPickerPresenter *strongSelf = weakSelf;
        if (!strongSelf) return;
        if (strongSelf->_presenting && strongSelf->_generation == generation) {
            NSLog(@"[DSPickers] 呈现超时兜底，继续队列");
            [strongSelf finishPresentation];
        }
    });
}

#pragma mark 协调器持有

- (void)retainCoordinator:(DSPickerCoordinator *)coordinator
{
    if (coordinator) [_coordinators addObject:coordinator];
}

- (void)releaseCoordinator:(DSPickerCoordinator *)coordinator
{
    if (coordinator) [_coordinators removeObjectIdenticalTo:coordinator];
}

#pragma mark 提示

- (void)presentAlertWithTitle:(NSString *)title message:(NSString *)message
{
    [self enqueue:^(UIViewController *host) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                      message:message
                                                               preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"好"
                                                 style:UIAlertActionStyleDefault
                                               handler:^(UIAlertAction *action) {
            [DSPickerPresenter.shared finishPresentation];
        }]];
        [host presentViewController:alert animated:YES completion:nil];
    } label:@"提示"];
}

@end

#pragma mark - 失败出口

static void DSPickerReportFailure(NSString *label, NSException *exception)
{
    NSString *name = label.length ? label : @"打开选择器";
    NSString *reason = exception.reason.length ? exception.reason : @"没有可用的呈现宿主";
    NSString *message = exception
        ? [NSString stringWithFormat:@"%@ 失败：%@（%@）", name, reason, NSStringFromClass(exception.class)]
        : [NSString stringWithFormat:@"%@ 失败：%@", name, reason];

    if (gDSPickerErrorLog) {
        @try { gDSPickerErrorLog(message); } @catch (__unused NSException *ignored) {}
    }
    NSLog(@"[DSPickers] %@", message);

    // 弹提示本身也走同一条队列，所以它绝不会和选择器叠加
    [DSPickerPresenter.shared presentAlertWithTitle:@"打不开系统选择器" message:message];
}

#pragma mark - DSPickers

@implementation DSPickers

+ (void)setErrorLogHandler:(void (^)(NSString *))handler
{
    gDSPickerErrorLog = [handler copy];
}

+ (BOOL)performSafely:(void (NS_NOESCAPE ^)(void))block label:(NSString *)label
{
    if (!block) return YES;
    @try {
        block();
        return YES;
    } @catch (NSException *e) {
        DSPickerReportFailure(label, e);
        return NO;
    }
}

+ (UIViewController *)topViewController
{
    UIWindow *window = [DSPickerPresenter keyWindow];
    UIViewController *top = window.rootViewController;
    while (top.presentedViewController) {
        top = top.presentedViewController;
    }
    return top;
}

/// 统一的 UTType 解析（nil / 空 / 全不认识 → 任意文件）
static NSArray<UTType *> *DSPickerResolveTypes(NSArray<NSString *> *identifiers)
{
    NSMutableArray<UTType *> *types = [NSMutableArray array];
    for (NSString *identifier in identifiers) {
        if (![identifier isKindOfClass:[NSString class]] || identifier.length == 0) continue;
        UTType *type = [UTType typeWithIdentifier:identifier];
        if (type) [types addObject:type];
    }
    if (types.count == 0) [types addObject:UTTypeItem];
    return types;
}

/// 装好 delegate（强持有到回调结束）
+ (void)installCoordinatorOn:(UIDocumentPickerViewController *)picker
                  completion:(DSPickerCompletion)completion
                      cancel:(DSPickerCancelHandler)cancel
{
    DSPickerCoordinator *coordinator = [[DSPickerCoordinator alloc] initWithPick:completion cancel:cancel];
    [DSPickerPresenter.shared retainCoordinator:coordinator];
    picker.delegate = coordinator;
}

+ (void)presentOpenPickerWithUTIs:(NSArray<NSString *> *)utiIdentifiers
                         multiple:(BOOL)multiple
                           asCopy:(BOOL)asCopy
                       completion:(DSPickerCompletion)completion
                           cancel:(DSPickerCancelHandler)cancel
{
    [DSPickerPresenter.shared enqueue:^(UIViewController *host) {
        NSArray<UTType *> *types = DSPickerResolveTypes(utiIdentifiers);
        UIDocumentPickerViewController *picker =
            [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:types asCopy:asCopy];
        picker.allowsMultipleSelection = multiple;
        if ([picker respondsToSelector:@selector(setShouldShowFileExtensions:)]) {
            picker.shouldShowFileExtensions = YES;
        }
        [DSPickers installCoordinatorOn:picker completion:completion cancel:cancel];
        [host presentViewController:picker animated:YES completion:nil];
    } label:@"选择文件"];
}

+ (void)presentFolderPickerWithCompletion:(DSPickerCompletion)completion cancel:(DSPickerCancelHandler)cancel
{
    [DSPickerPresenter.shared enqueue:^(UIViewController *host) {
        UIDocumentPickerViewController *picker =
            [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[ UTTypeFolder ] asCopy:NO];
        picker.allowsMultipleSelection = NO;
        if ([picker respondsToSelector:@selector(setShouldShowFileExtensions:)]) {
            picker.shouldShowFileExtensions = YES;
        }
        [DSPickers installCoordinatorOn:picker completion:completion cancel:cancel];
        [host presentViewController:picker animated:YES completion:nil];
    } label:@"选择文件夹"];
}

+ (void)presentFolderPickerAsCopyWithCompletion:(DSPickerCompletion)completion cancel:(DSPickerCancelHandler)cancel
{
    [DSPickerPresenter.shared enqueue:^(UIViewController *host) {
        UIDocumentPickerViewController *picker =
            [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[ UTTypeFolder ] asCopy:YES];
        picker.allowsMultipleSelection = NO;
        if ([picker respondsToSelector:@selector(setShouldShowFileExtensions:)]) {
            picker.shouldShowFileExtensions = YES;
        }
        [DSPickers installCoordinatorOn:picker completion:completion cancel:cancel];
        [host presentViewController:picker animated:YES completion:nil];
    } label:@"添加源文件夹"];
}

+ (void)presentShareSheetForURLs:(NSArray<NSURL *> *)urls
{
    if (urls.count == 0) return;

    [DSPickerPresenter.shared enqueue:^(UIViewController *host) {
        UIActivityViewController *sheet = [[UIActivityViewController alloc] initWithActivityItems:urls
                                                                           applicationActivities:nil];
        // iPad 上分享面板走 popover：锚在窗口中央、不带箭头
        UIPopoverPresentationController *popover = sheet.popoverPresentationController;
        if (popover) {
            UIView *anchor = host.view.window ?: host.view;
            popover.sourceView = anchor;
            popover.sourceRect = CGRectMake(CGRectGetMidX(anchor.bounds), CGRectGetMidY(anchor.bounds), 1, 1);
            popover.permittedArrowDirections = 0;
        }
        sheet.completionWithItemsHandler = ^(UIActivityType activityType, BOOL completed,
                                             NSArray *returnedItems, NSError *activityError) {
            [DSPickerPresenter.shared finishPresentation];
        };
        [host presentViewController:sheet animated:YES completion:nil];
    } label:@"打开分享面板"];
}

@end
