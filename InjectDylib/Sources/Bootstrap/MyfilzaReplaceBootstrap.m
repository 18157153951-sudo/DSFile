//
//  MyfilzaReplaceBootstrap.m — dylib 载入点
//
//  这个 dylib 通过 eSign / Sideloadly 注入到宿主 App（3105）后，由 dyld 在进程启动时载入。
//  这里用 constructor 立刻排队一次「挂悬浮按钮」的动作；真正的挂载交给 Swift 侧
//  （它会轮询等 key window 就绪，超时也不会崩、不会阻塞宿主）。
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

// Xcode 为混编 target 生成的 Swift 接口头（名字 = PRODUCT_MODULE_NAME）
#import "MyfilzaReplace-Swift.h"

__attribute__((constructor)) static void MyfilzaReplaceDylibInit(void)
{
    NSLog(@"[MyfilzaReplace] dylib loaded into %@", NSBundle.mainBundle.bundleIdentifier ?: @"?");

    // constructor 阶段还没有 run loop，切到主队列延后执行
    dispatch_async(dispatch_get_main_queue(), ^{
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [MyfilzaReplaceLauncher start];
        });
    });
}
