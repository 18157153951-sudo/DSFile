//
//  xpf.h — XPF 的**打桩**版本（本仓库专用，不是 lara 原文件）
//
//  为什么需要它：
//    lara 把 XPF 编译成预编译库 libxpf.dylib 随 App 一起分发；我们出的是**未签名 IPA**，
//    靠证书重签，没法带上这个 dylib，链接会失败。offsets.m / utils.m 只用到 XPF 的很小一部分
//    接口，而且都写在「拿不到 XPF 就退回去用自带的版本表」的容错分支里，所以这里给出
//    能编译的最小声明，实现在 xpf_stub.m 里 —— 全部返回失败/0，运行时会走那些容错分支。
//
//  另外这里还给出了 ChOma（PatchFinder）里 offsets.m 用到的几个类型与函数声明，
//  它们的实现同样在 xpf_stub.m 里打桩（本构建不做 patchfinder 解析）。
//

#ifndef xpf_h
#define xpf_h

#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>
#include <xpc/xpc.h>

#pragma mark - ChOma（PatchFinder）最小面

typedef struct s_PFMetric PFMetric;
typedef PFMetric PFStringMetric;
typedef PFMetric PFXrefMetric;
typedef struct s_PFSection PFSection;

// 只用到 REFERENCE 这一个；值本身不影响打桩实现，但保持与 XPF 一致
#define XREF_TYPE_MASK_REFERENCE    (1u << 0)
#define XREF_TYPE_MASK_CALL         (1u << 1)
#define XREF_TYPE_MASK_JUMP         (1u << 2)
#define XREF_TYPE_MASK_PAC          (1u << 3)

PFStringMetric *pfmetric_string_init(const char *string);
PFXrefMetric *pfmetric_xref_init(uint64_t target, uint32_t xrefType);
void pfmetric_run(PFSection *section, PFMetric *metric, bool (^callback)(uint64_t vmaddr, bool *stop));
void pfmetric_free(PFMetric *metric);
bool pfsec_contains_vmaddr(PFSection *section, uint64_t vmaddr);
uint64_t pfsec_arm64_resolve_adrp_ldr_str_add_reference_auto(PFSection *section, uint64_t adrpAddr);

#pragma mark - XPF

typedef struct s_XPFItem {
    struct s_XPFItem *nextItem;
    const char *name;
    uint64_t (*finder)(void *);
    void *ctx;
    bool cached;
    uint64_t cache;
} XPFItem;

typedef struct s_XPFSet {
    const char *name;
    bool (*supported)(void);
    const char *metrics[];
} XPFSet;

typedef struct s_XPF {
    int kernelFd;
    void *mappedKernel;
    size_t kernelSize;
    void *decompressedKernel;
    size_t decompressedKernelSize;

    // lara 原头里这两个是 ChOma 的 Fat * / MachO *，这里不需要它们的定义
    void *kernelContainer;
    void *kernel;
    bool kernelIsFileset;
    bool kernelIsArm64e;

    char *kernelVersionString;
    char *kernelInfoPlist;
    char *darwinVersion;
    char *xnuBuild;
    char *xnuPlatform;
    char *osVersion;

    uint64_t kernelBase;
    uint64_t kernelEntry;

    PFSection *kernelTextSection;
    PFSection *kernelPinstSection;
    PFSection *kernelPPLTextSection;
    PFSection *kernelStringSection;
    PFSection *kernelConstSection;
    PFSection *kernelDataConstSection;
    PFSection *kernelDataSection;
    PFSection *kernelOSLogSection;
    PFSection *kernelPrelinkTextSection;
    PFSection *kernelPLKTextSection;
    PFSection *kernelKmodInfoSection;
    PFSection *kernelPrelinkInfoSection;
    PFSection *kernelBootdataInit;
    PFSection *kernelAMFITextSection;
    PFSection *kernelAMFIStringSection;
    PFSection *kernelSandboxTextSection;
    PFSection *kernelSandboxStringSection;
    PFSection *kernelInfoPlistSection;

    XPFItem *firstItem;
} XPF;

extern XPF gXPF;

#define XPF_ASSERT(assert) if (!(assert)) { if (!xpf_get_error()) { xpf_set_error("[%s:%d] Failed assert in %s: %s", __FILE__, __LINE__, __FUNCTION__, #assert); } return 0; }

int xpf_start_with_kernel_path(const char *kernelPath);
void xpf_item_register(const char *name, void *finder, void *ctx);
uint64_t xpf_item_resolve(const char *name);
uint64_t xpfsec_decode_pointer(PFSection *section, uint64_t vmaddr, uint64_t value);
bool xpf_set_is_supported(const char *name);
int xpf_offset_dictionary_add_set(xpc_object_t xdict, XPFSet *set);
xpc_object_t xpf_construct_offset_dictionary(const char *sets[]);
void xpf_set_error(const char *error, ...);
const char *xpf_get_error(void);
void xpf_print_all_items(void);
void xpf_stop(void);

/// 打桩：恒为 0。lara 原来的实现是从 kernelConstant.pointer_mask 数位数，
/// 拿不到 XPF 时本来也会得到 0，调用方会走「没有 XPF」的容错分支。
static inline uint64_t xpf_gett1szboot(void) {
    return 0;
}

#endif /* xpf_h */
