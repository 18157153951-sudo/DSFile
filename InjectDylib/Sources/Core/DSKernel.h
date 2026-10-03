//
//  DSKernel.h — 注入版（dylib）用的轻量替身
//
//  为什么有这份替身：
//  我们把「替换向导」做成 dylib 注入到宿主 App（3105）里运行。宿主进程本身已经具备
//  容器/沙盒外访问能力（这是 3105 的能力，用户在真机验证过），所以我们的代码**不需要**
//  内核漏洞、也不需要沙盒逃逸 —— 只要直接用 POSIX 就能读写目标 App 的数据。
//
//  因此这一份 DSKernel 与 App 内那份**同名同 API**（这样从 DSFile/Sources 复制过来的
//  向导/配方/备份代码一行都不用改），但内部实现全部是用户态：
//    · isEscaped / isExploitDone / probeFilesystemAccess → 真实探测（列容器目录 + 写探针）
//    · setOwner / setMode → 直接走 POSIX chown / chmod
//    · activate / retrySandboxEscape → 直接返回「已可用」（不需要内核）
//    · elevateToRoot → 明确返回失败（注入版拿不到 root）
//    · kernelBase → 恒为 0（本版本没有内核读写）
//
//  **不包含任何内核代码**（不链接 kexploit / krw / DSCredEscape / DS3105Kernel）。
//

#import <Foundation/Foundation.h>
#import <sys/types.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, DSKernelResult) {
    DSKernelResultOK                =  0,
    DSKernelResultAlreadyActive     =  1,
    DSKernelResultUnsupportedSystem = -1,
    DSKernelResultExploitFailed     = -2,
    DSKernelResultEscapeFailed      = -3,
    DSKernelResultBusy              = -4,
    DSKernelResultInternalError     = -5,
};

typedef void (^DSKernelLogBlock)(NSString *line);

@interface DSKernel : NSObject

#pragma mark - 设备 / 系统

+ (NSString *)deviceModelIdentifier NS_SWIFT_NAME(deviceModelIdentifier());
+ (NSString *)systemVersion NS_SWIFT_NAME(systemVersion());
+ (NSString *)cpuFamilyName NS_SWIFT_NAME(cpuFamilyName());
+ (BOOL)isSystemVersionSupported NS_SWIFT_NAME(isSystemVersionSupported());
+ (NSString *)supportSummary NS_SWIFT_NAME(supportSummary());

#pragma mark - 运行时状态

/// 注入版语义：**宿主进程是否已经能访问沙盒外路径**（真实探测，不看标志位）
+ (BOOL)isEscaped NS_SWIFT_NAME(isEscaped());
/// 注入版里「内核读写」这个概念不存在，与 isEscaped 同义（保证向导里那些
/// `guard DSKernel.isExploitDone()` 的前置检查能通过，从而走 POSIX 写入）
+ (BOOL)isExploitDone NS_SWIFT_NAME(isExploitDone());
+ (BOOL)isRunningAsRoot NS_SWIFT_NAME(isRunningAsRoot());
/// 现场做一次探针写盘 + 列目录
+ (BOOL)probeFilesystemAccess NS_SWIFT_NAME(probeFilesystemAccess());
/// 注入版没有内核读写，恒为 0
+ (unsigned long long)kernelBase NS_SWIFT_NAME(kernelBase());
+ (NSString *)diagnosticsText NS_SWIFT_NAME(diagnosticsText());

#pragma mark - 激活（注入版不需要内核）

+ (DSKernelResult)activateWithLog:(nullable DSKernelLogBlock)log NS_SWIFT_NAME(activate(log:));
+ (DSKernelResult)retrySandboxEscapeWithLog:(nullable DSKernelLogBlock)log NS_SWIFT_NAME(retrySandboxEscape(log:));
+ (DSKernelResult)elevateToRootWithLog:(nullable DSKernelLogBlock)log NS_SWIFT_NAME(elevateToRoot(log:));

#pragma mark - 文件属性（注入版直接走 POSIX）

+ (BOOL)setOwnerOfPath:(NSString *)path
                   uid:(uid_t)uid
                   gid:(gid_t)gid
             recursive:(BOOL)recursive NS_SWIFT_NAME(setOwner(path:uid:gid:recursive:));
+ (BOOL)setModeOfPath:(NSString *)path mode:(mode_t)mode NS_SWIFT_NAME(setMode(path:mode:));

@end

NS_ASSUME_NONNULL_END
