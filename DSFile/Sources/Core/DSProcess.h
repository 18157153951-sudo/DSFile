//
//  DSProcess.h — 进程查询 / 结束目标 App
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface DSProcess : NSObject

/// 按可执行文件名找 pid（p_comm 会被内核截断到 16 字节，这里做了前缀匹配处理）
+ (NSArray<NSNumber *> *)pidsMatchingExecutableName:(NSString *)name
    NS_SWIFT_NAME(pids(matchingExecutableName:));

/// 结束所有匹配的可执行文件对应的进程（跳过自己和 pid 1），返回处理个数
+ (NSInteger)killProcessesMatchingExecutableName:(NSString *)name
    NS_SWIFT_NAME(killProcesses(matchingExecutableName:));

/// 是否还有该可执行文件的进程在跑
+ (BOOL)isProcessRunningWithExecutableName:(NSString *)name
    NS_SWIFT_NAME(isProcessRunning(executableName:));

@end

NS_ASSUME_NONNULL_END
