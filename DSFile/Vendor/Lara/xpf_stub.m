//
//  xpf_stub.m — xpf.h / libgrabkernel2.h / persistence.h 的打桩实现
//
//  目的只有两个：
//    1) 让 lara 的 offsets.m / utils.m 能编译并链接（我们不带 libxpf.dylib）；
//    2) 运行时一律返回「失败」，让调用方走它自己的容错分支 —— offsets 用 lara 自带的版本表。
//
//  这里绝不做任何实际解析，也不会被调用到关键路径上：
//     * offsets.m 的 verifykernoffsets / resolvekernoffsets / getmacprocenforceoff 都会在
//       xpf_start_with_kernel_path() 返回非 0 时立刻返回；
//     * utils.m 只打印一句错误后继续；
//     * transfer_krw_to_launchd / recover_krw_primitives 只在 NSUserDefaults 的 stashKRW
//       为真时才会被调用，我们从不设置它（打桩返回 false 也不会改变流程）。
//

#import <Foundation/Foundation.h>
#import <stdarg.h>
#import <stdio.h>

#import "xpf.h"
#import "libgrabkernel2.h"
#import "darksword.h"

#pragma mark - XPF 全局对象与错误串

XPF gXPF;   // 缺省全 0：所有 section 指针都是 NULL

static char gXPFStubErrorBuffer[512];
static const char *const kXPFStubError = "xpf stub: 本构建不含 XPF（libxpf.dylib 无法随未签名 IPA 分发）";

int xpf_start_with_kernel_path(const char *kernelPath)
{
    (void)kernelPath;
    return -1;      // 非 0 = 失败，调用方据此走容错分支
}

void xpf_item_register(const char *name, void *finder, void *ctx)
{
    (void)name; (void)finder; (void)ctx;
}

uint64_t xpf_item_resolve(const char *name)
{
    (void)name;
    return 0;
}

uint64_t xpfsec_decode_pointer(PFSection *section, uint64_t vmaddr, uint64_t value)
{
    (void)section; (void)vmaddr; (void)value;
    return 0;
}

bool xpf_set_is_supported(const char *name)
{
    (void)name;
    return false;
}

int xpf_offset_dictionary_add_set(xpc_object_t xdict, XPFSet *set)
{
    (void)xdict; (void)set;
    return 0;
}

xpc_object_t xpf_construct_offset_dictionary(const char *sets[])
{
    (void)sets;
    return NULL;
}

void xpf_set_error(const char *error, ...)
{
    if (!error) {
        gXPFStubErrorBuffer[0] = '\0';
        return;
    }
    va_list args;
    va_start(args, error);
    vsnprintf(gXPFStubErrorBuffer, sizeof(gXPFStubErrorBuffer), error, args);
    va_end(args);
}

const char *xpf_get_error(void)
{
    return gXPFStubErrorBuffer[0] ? gXPFStubErrorBuffer : kXPFStubError;
}

void xpf_print_all_items(void) {}

void xpf_stop(void) {}

#pragma mark - ChOma（PatchFinder）打桩

PFStringMetric *pfmetric_string_init(const char *string)
{
    (void)string;
    return NULL;
}

PFXrefMetric *pfmetric_xref_init(uint64_t target, uint32_t xrefType)
{
    (void)target; (void)xrefType;
    return NULL;
}

void pfmetric_run(PFSection *section, PFMetric *metric, void (^callback)(uint64_t vmaddr, bool *stop))
{
    (void)section; (void)metric; (void)callback;
}

void pfmetric_free(PFMetric *metric)
{
    (void)metric;
}

bool pfsec_contains_vmaddr(PFSection *section, uint64_t vmaddr)
{
    (void)section; (void)vmaddr;
    return false;
}

uint64_t pfsec_arm64_resolve_adrp_ldr_str_add_reference_auto(PFSection *section, uint64_t adrpAddr)
{
    (void)section; (void)adrpAddr;
    return 0;
}

#pragma mark - libgrabkernel2 打桩（offsets.m 只用到 grab_kernelcache）

bool download_kernelcache_for(NSString *boardconfig, NSString *zipURL, bool isOTA, NSString *outPath)
{
    (void)boardconfig; (void)zipURL; (void)isOTA; (void)outPath;
    return false;
}

bool grab_kernelcache_for(NSString *osStr, NSString *build, NSString *modelIdentifier, NSString *boardconfig, NSString *outPath)
{
    (void)osStr; (void)build; (void)modelIdentifier; (void)boardconfig; (void)outPath;
    return false;
}

bool download_kernelcache(NSString *zipURL, bool isOTA, NSString *outPath)
{
    (void)zipURL; (void)isOTA; (void)outPath;
    return false;
}

bool grab_kernelcache(NSString *outPath)
{
    (void)outPath;
    return false;
}

bool grab_kernelcache_for_build_number(NSString *build, NSString *outPath)
{
    (void)build; (void)outPath;
    return false;
}

int grabkernel(char *downloadPath, int isResearchKernel)
{
    (void)downloadPath; (void)isResearchKernel;
    return -1;
}

#pragma mark - persistence.m 打桩（未搬入；正常路径不会走到）

bool transfer_krw_to_launchd(void)
{
    return false;
}

bool recover_krw_primitives(void)
{
    return false;
}
