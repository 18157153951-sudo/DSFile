//
//  DSShell.h — 用 /bin/sh 跑脚本（posix_spawn + 管道，带超时和实时输出）
//
//  注意：免越狱 + DarkSword 环境下，沙盒可能仍然拒绝 process-exec，
//  posix_spawn 会返回 EPERM。这不是 bug，调用方要把这条错误讲清楚。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^DSShellOutputBlock)(NSString *line);

@interface DSShell : NSObject

/// 可用的 sh 路径：越狱环境优先 /var/jb/bin/sh（roothide 走 .jbroot-*），否则 /bin/sh
+ (NSString *)shellPath;

/// 上面那个 sh 是否存在且可执行
+ (BOOL)isShellAvailable NS_SWIFT_NAME(isShellAvailable());

/// 同步执行一个 shell 脚本（调用方自己放到后台队列）
/// Swift 侧名字：execScript(_:arguments:directory:environment:timeout:output:)
/// @return 进程退出码；-1 表示启动失败（此时 error 有值）
+ (int)execScript:(NSString *)scriptPath
        arguments:(nullable NSArray<NSString *> *)arguments
        directory:(nullable NSString *)workingDirectory
      environment:(nullable NSDictionary<NSString *, NSString *> *)environment
          timeout:(NSTimeInterval)timeout
           output:(nullable DSShellOutputBlock)output
            error:(NSError **)error;

/// 执行一段内联命令（/bin/sh -c "..."）
+ (int)runCommand:(NSString *)command
        directory:(nullable NSString *)workingDirectory
      environment:(nullable NSDictionary<NSString *, NSString *> *)environment
          timeout:(NSTimeInterval)timeout
           output:(nullable DSShellOutputBlock)output
            error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
