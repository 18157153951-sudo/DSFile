/*
 * IOSurface/IOSurfaceRef.h shim
 *
 * The macOS/iOS SDK that ships with Xcode does not always expose the IOSurface
 * headers (on device the framework is private). The DarkSword exploit needs
 * exactly four entry points, so we declare them here and resolve them through
 * dlopen() at runtime in Shims/DSIOShim.c — that keeps the build independent of
 * whether IOSurface is linkable from the SDK at all.
 */
#ifndef DS_SHIM_IOSURFACE_REF_H
#define DS_SHIM_IOSURFACE_REF_H

#include <CoreFoundation/CoreFoundation.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct __IOSurface *IOSurfaceRef;

/* kIOSurfaceAllocSize is a CFString constant of exactly this value. */
#ifndef kIOSurfaceAllocSize
#define kIOSurfaceAllocSize ((CFStringRef)CFSTR("IOSurfaceAllocSize"))
#endif

IOSurfaceRef IOSurfaceCreate(CFDictionaryRef properties);
void *IOSurfaceGetBaseAddress(IOSurfaceRef buffer);
void IOSurfacePrefetchPages(IOSurfaceRef surface);

#ifdef __cplusplus
}
#endif

#endif /* DS_SHIM_IOSURFACE_REF_H */
