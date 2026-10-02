//
//  DSShell.m
//

#import "DSShell.h"

#import <spawn.h>
#import <poll.h>
#import <signal.h>
#import <sys/wait.h>
#import <unistd.h>
#import <fcntl.h>
#import <errno.h>
#import <string.h>
#import <stdlib.h>

extern char **environ;

static NSError *ds_error(int code, NSString *message)
{
    return [NSError errorWithDomain:@"DSFile.Shell" code:code
                           userInfo:@{ NSLocalizedDescriptionKey: message ?: @"未知错误" }];
}

static char **ds_build_argv(NSArray<NSString *> *args)
{
    NSUInteger count = args.count;
    char **array = calloc(count + 1, sizeof(char *));
    if (!array) return NULL;
    for (NSUInteger i = 0; i < count; i++) {
        array[i] = strdup(args[i].UTF8String ?: "");
    }
    array[count] = NULL;
    return array;
}

static void ds_free_argv(char **array, NSUInteger count)
{
    if (!array) return;
    for (NSUInteger i = 0; i < count; i++) {
        free(array[i]);
    }
    free(array);
}

static char **ds_build_envp(NSDictionary<NSString *, NSString *> *environment)
{
    NSMutableDictionary<NSString *, NSString *> *merged = [NSMutableDictionary dictionary];
    if (environment) [merged addEntriesFromDictionary:environment];
    if (!merged[@"PATH"]) merged[@"PATH"] = @"/usr/bin:/bin:/usr/sbin:/sbin";
    if (!merged[@"HOME"]) merged[@"HOME"] = NSHomeDirectory();

    char **array = calloc(merged.count + 1, sizeof(char *));
    if (!array) return NULL;
    NSUInteger index = 0;
    for (NSString *key in merged) {
        NSString *pair = [NSString stringWithFormat:@"%@=%@", key, merged[key]];
        array[index++] = strdup(pair.UTF8String ?: "");
    }
    array[index] = NULL;
    return array;
}

@implementation DSShell

+ (BOOL)isShellAvailable
{
    return access("/bin/sh", X_OK) == 0;
}

+ (int)runScriptAtPath:(NSString *)scriptPath
             arguments:(NSArray<NSString *> *)arguments
             directory:(NSString *)workingDirectory
           environment:(NSDictionary<NSString *, NSString *> *)environment
               timeout:(NSTimeInterval)timeout
                output:(DSShellOutputBlock)output
                 error:(NSError **)error
{
    if (scriptPath.length == 0) {
        if (error) *error = ds_error(-1, @"脚本路径为空");
        return -1;
    }
    if (![self isShellAvailable]) {
        if (error) *error = ds_error(-1, @"/bin/sh 不存在或不可执行");
        return -1;
    }

    NSMutableArray<NSString *> *argv = [NSMutableArray arrayWithObjects:@"/bin/sh", scriptPath, nil];
    if (arguments.count > 0) [argv addObjectsFromArray:arguments];

    return [self ds_spawn:argv
                directory:workingDirectory
              environment:environment
                  timeout:timeout
                   output:output
                    error:error];
}

+ (int)runCommand:(NSString *)command
        directory:(NSString *)workingDirectory
      environment:(NSDictionary<NSString *, NSString *> *)environment
          timeout:(NSTimeInterval)timeout
           output:(DSShellOutputBlock)output
            error:(NSError **)error
{
    if (command.length == 0) {
        if (error) *error = ds_error(-1, @"命令为空");
        return -1;
    }
    if (![self isShellAvailable]) {
        if (error) *error = ds_error(-1, @"/bin/sh 不存在或不可执行");
        return -1;
    }

    return [self ds_spawn:@[ @"/bin/sh", @"-c", command ]
                directory:workingDirectory
              environment:environment
                  timeout:timeout
                   output:output
                    error:error];
}

#pragma mark - 实际 spawn

+ (int)ds_spawn:(NSArray<NSString *> *)argv
      directory:(NSString *)workingDirectory
    environment:(NSDictionary<NSString *, NSString *> *)environment
        timeout:(NSTimeInterval)timeout
         output:(DSShellOutputBlock)output
          error:(NSError **)error
{
    int fds[2];
    if (pipe(fds) != 0) {
        if (error) *error = ds_error(errno, [NSString stringWithFormat:@"pipe 失败: %s", strerror(errno)]);
        return -1;
    }

    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_adddup2(&actions, fds[1], STDOUT_FILENO);
    posix_spawn_file_actions_adddup2(&actions, fds[1], STDERR_FILENO);
    posix_spawn_file_actions_addclose(&actions, fds[0]);
    posix_spawn_file_actions_addclose(&actions, fds[1]);
    if (workingDirectory.length > 0) {
        posix_spawn_file_actions_addchdir_np(&actions, workingDirectory.fileSystemRepresentation);
    }

    char **cargv = ds_build_argv(argv);
    char **cenvp = ds_build_envp(environment);

    pid_t pid = 0;
    int rc = posix_spawn(&pid, "/bin/sh", &actions, NULL, cargv, cenvp);

    posix_spawn_file_actions_destroy(&actions);
    ds_free_argv(cargv, argv.count);
    if (cenvp) {
        NSUInteger envCount = 0;
        while (cenvp[envCount]) envCount++;
        ds_free_argv(cenvp, envCount);
    }
    close(fds[1]);

    if (rc != 0) {
        close(fds[0]);
        NSString *reason = [NSString stringWithFormat:@"posix_spawn 失败 (%d: %s)", rc, strerror(rc)];
        if (rc == EPERM || rc == EACCES) {
            reason = [reason stringByAppendingString:
                @"\n沙盒拒绝了 process-exec。免越狱 + DarkSword 环境下这是预期行为：shell 脚本需要越狱 / TrollStore 环境，或改用配方脚本。"];
        }
        if (error) *error = ds_error(rc, reason);
        NSLog(@"[DSShell] %@", reason);
        return -1;
    }

    // 读输出：poll + 超时
    NSMutableData *lineBuffer = [NSMutableData data];
    char buffer[4096];
    NSDate *deadline = (timeout > 0) ? [NSDate dateWithTimeIntervalSinceNow:timeout] : nil;
    BOOL timedOut = NO;
    BOOL finished = NO;

    while (!finished) {
        struct pollfd pfd;
        pfd.fd = fds[0];
        pfd.events = POLLIN;
        pfd.revents = 0;

        int waitMs = -1;
        if (deadline) {
            NSTimeInterval remaining = [deadline timeIntervalSinceNow];
            if (remaining <= 0) { timedOut = YES; break; }
            waitMs = (int)(remaining * 1000);
            if (waitMs < 1) waitMs = 1;
        }

        int pollResult = poll(&pfd, 1, waitMs);
        if (pollResult < 0) {
            if (errno == EINTR) continue;
            break;
        }
        if (pollResult == 0) {
            timedOut = YES;
            break;
        }

        ssize_t bytes = read(fds[0], buffer, sizeof(buffer));
        if (bytes > 0) {
            [lineBuffer appendBytes:buffer length:(NSUInteger)bytes];
            const uint8_t *raw = (const uint8_t *)lineBuffer.bytes;
            NSUInteger total = lineBuffer.length;
            NSUInteger start = 0;
            for (NSUInteger i = 0; i < total; i++) {
                if (raw[i] == '\n') {
                    NSData *chunk = [lineBuffer subdataWithRange:NSMakeRange(start, i - start)];
                    NSString *line = [[NSString alloc] initWithData:chunk encoding:NSUTF8StringEncoding];
                    if (!line) line = [[NSString alloc] initWithData:chunk encoding:NSISOLatin1StringEncoding];
                    if (output && line) output(line);
                    start = i + 1;
                }
            }
            if (start > 0) {
                [lineBuffer replaceBytesInRange:NSMakeRange(0, start) withBytes:NULL length:0];
            }
        } else if (bytes == 0) {
            finished = YES;
        } else {
            if (errno == EINTR || errno == EAGAIN) continue;
            break;
        }
    }

    if (timedOut) {
        NSLog(@"[DSShell] 超时 %.0fs，结束进程 %d", timeout, pid);
        kill(pid, SIGKILL);
    }

    int status = 0;
    while (waitpid(pid, &status, 0) < 0 && errno == EINTR) {
        // 重试
    }

    // 收尾输出
    if (lineBuffer.length > 0 && output) {
        NSString *line = [[NSString alloc] initWithData:lineBuffer encoding:NSUTF8StringEncoding];
        if (!line) line = [[NSString alloc] initWithData:lineBuffer encoding:NSISOLatin1StringEncoding];
        if (line.length > 0) output(line);
    }

    close(fds[0]);

    if (timedOut) {
        if (error) *error = ds_error(-2, [NSString stringWithFormat:@"脚本执行超时（%.0f 秒），已强制结束", timeout]);
        return -2;
    }
    if (WIFEXITED(status)) {
        return WEXITSTATUS(status);
    }
    if (WIFSIGNALED(status)) {
        if (error) *error = ds_error(-3, [NSString stringWithFormat:@"脚本被信号 %d 结束", WTERMSIG(status)]);
        return -3;
    }
    return 0;
}

@end
