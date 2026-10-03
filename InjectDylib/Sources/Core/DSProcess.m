//
//  DSProcess.m
//

#import "DSProcess.h"

#import <sys/sysctl.h>
#import <sys/types.h>
#import <signal.h>
#import <string.h>
#import <unistd.h>
#import <errno.h>
#import <stdlib.h>

/// p_comm 在 kinfo_proc 里最多 16 字节，超长会截断；这里做「精确 或 合法截断前缀」判定
static BOOL ds_comm_matches(const char *comm, const char *target)
{
    if (!comm || !target) return NO;
    size_t clen = strlen(comm);
    size_t tlen = strlen(target);
    if (clen == 0 || tlen == 0) return NO;
    if (clen > tlen) return NO;
    if (clen == tlen) return strcmp(comm, target) == 0;
    // comm 比 target 短 → 只接受「被截断」的情况（原名字长度至少到 15）
    if (clen < 15) return NO;
    return strncmp(comm, target, clen) == 0;
}

static NSArray<NSNumber *> *ds_collect_pids(NSString *name)
{
    NSMutableArray<NSNumber *> *result = [NSMutableArray array];
    if (name.length == 0) return result;

    int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0 };
    size_t size = 0;
    if (sysctl(mib, 4, NULL, &size, NULL, 0) != 0 || size == 0) return result;

    struct kinfo_proc *procs = malloc(size);
    if (!procs) return result;

    if (sysctl(mib, 4, procs, &size, NULL, 0) == 0) {
        int count = (int)(size / sizeof(struct kinfo_proc));
        const char *target = name.UTF8String;
        for (int i = 0; i < count; i++) {
            pid_t pid = procs[i].kp_proc.p_pid;
            if (pid <= 1) continue;
            if (pid == getpid()) continue;
            if (ds_comm_matches(procs[i].kp_proc.p_comm, target)) {
                [result addObject:@(pid)];
            }
        }
    }

    free(procs);
    return result;
}

@implementation DSProcess

+ (NSArray<NSNumber *> *)pidsMatchingExecutableName:(NSString *)name
{
    return ds_collect_pids(name);
}

+ (NSInteger)killProcessesMatchingExecutableName:(NSString *)name
{
    NSArray<NSNumber *> *pids = ds_collect_pids(name);
    NSInteger killed = 0;
    for (NSNumber *number in pids) {
        pid_t pid = (pid_t)number.intValue;
        if (kill(pid, SIGKILL) == 0) {
            killed++;
        } else {
            NSLog(@"[DSProcess] kill(%d) 失败: %s", pid, strerror(errno));
        }
    }
    return killed;
}

+ (BOOL)isProcessRunningWithExecutableName:(NSString *)name
{
    return ds_collect_pids(name).count > 0;
}

@end
