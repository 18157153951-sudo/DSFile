//
//  DSPickers.m
//

#import "DSPickers.h"
#import <UIKit/UIKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#pragma mark - delegate 保持器

/// UIKit 的 delegate 是弱引用，需要静态持有到回调结束
@interface DSPickerCoordinator : NSObject <UIDocumentPickerDelegate>
+ (void)setCurrentCoordinator:(nullable DSPickerCoordinator *)coordinator;
@property (nonatomic, copy) DSPickerCompletion onPick;
@property (nonatomic, copy, nullable) DSPickerCancelHandler onCancel;
- (instancetype)initWithPick:(DSPickerCompletion)onPick cancel:(nullable DSPickerCancelHandler)onCancel;
@end

@implementation DSPickerCoordinator

static DSPickerCoordinator *gCurrent = nil;

+ (void)setCurrentCoordinator:(DSPickerCoordinator *)coordinator { gCurrent = coordinator; }

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
    [DSPickerCoordinator setCurrentCoordinator:nil];
    if (pick) pick(urls);
}

- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller
{
    DSPickerCancelHandler cancel = self.onCancel;
    [DSPickerCoordinator setCurrentCoordinator:nil];
    if (cancel) cancel();
}

@end

#pragma mark - DSPickers

@implementation DSPickers

+ (UIViewController *)topViewController
{
    NSArray<UIScene *> *scenes = UIApplication.sharedApplication.connectedScenes.allObjects;
    UIWindow *window = nil;

    for (UIScene *scene in scenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        UIWindowScene *windowScene = (UIWindowScene *)scene;
        for (UIWindow *candidate in windowScene.windows) {
            if (candidate.isKeyWindow) { window = candidate; break; }
        }
        if (window) break;
        if (!window && windowScene.windows.count > 0) window = windowScene.windows.firstObject;
    }

    UIViewController *top = window.rootViewController;
    while (top.presentedViewController) {
        top = top.presentedViewController;
    }
    return top;
}

+ (void)presentOpenPickerWithUTIs:(NSArray<NSString *> *)utiIdentifiers
                         multiple:(BOOL)multiple
                           asCopy:(BOOL)asCopy
                       completion:(DSPickerCompletion)completion
                           cancel:(DSPickerCancelHandler)cancel
{
    UIViewController *top = [self topViewController];
    if (!top) { if (cancel) cancel(); return; }

    NSMutableArray<UTType *> *types = [NSMutableArray array];
    if (utiIdentifiers.count == 0) {
        [types addObject:UTTypeItem];
    } else {
        for (NSString *identifier in utiIdentifiers) {
            UTType *type = [UTType typeWithIdentifier:identifier];
            if (type) [types addObject:type];
        }
        if (types.count == 0) [types addObject:UTTypeItem];
    }

    UIDocumentPickerViewController *picker =
        [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:types asCopy:asCopy];
    picker.allowsMultipleSelection = multiple;

    DSPickerCoordinator *coordinator = [[DSPickerCoordinator alloc] initWithPick:completion cancel:cancel];
    [DSPickerCoordinator setCurrentCoordinator:coordinator];
    picker.delegate = coordinator;
    picker.modalPresentationStyle = UIModalPresentationFormSheet;

    [top presentViewController:picker animated:YES completion:nil];
}

+ (void)presentFolderPickerWithCompletion:(DSPickerCompletion)completion cancel:(DSPickerCancelHandler)cancel
{
    UIViewController *top = [self topViewController];
    if (!top) { if (cancel) cancel(); return; }

    UIDocumentPickerViewController *picker =
        [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[ UTTypeFolder ] asCopy:NO];
    picker.allowsMultipleSelection = NO;

    DSPickerCoordinator *coordinator = [[DSPickerCoordinator alloc] initWithPick:completion cancel:cancel];
    [DSPickerCoordinator setCurrentCoordinator:coordinator];
    picker.delegate = coordinator;
    picker.modalPresentationStyle = UIModalPresentationFormSheet;

    [top presentViewController:picker animated:YES completion:nil];
}

+ (void)presentShareSheetForURLs:(NSArray<NSURL *> *)urls
{
    if (urls.count == 0) return;
    UIViewController *top = [self topViewController];
    if (!top) return;

    UIActivityViewController *sheet = [[UIActivityViewController alloc] initWithActivityItems:urls
                                                                      applicationActivities:nil];
    // iPad 上分享面板走 popover，必须给锚点：锚定屏幕中央、不带箭头
    UIPopoverPresentationController *popover = sheet.popoverPresentationController;
    if (popover) {
        popover.sourceView = top.view;
        popover.sourceRect = CGRectMake(CGRectGetMidX(top.view.bounds), CGRectGetMidY(top.view.bounds), 1, 1);
        popover.permittedArrowDirections = 0;
    }
    [top presentViewController:sheet animated:YES completion:nil];
}

@end
