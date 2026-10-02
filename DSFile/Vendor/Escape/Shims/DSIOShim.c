/*
 * DSIOShim.c — runtime binding for the IOSurface entry points used by the
 * DarkSword kernel exploit.
 *
 * Why this exists: IOSurface is a private framework on iOS, so linking
 * "-framework IOSurface" is not portable across SDKs. Instead we dlopen the
 * framework at first use and dispatch through function pointers. If the
 * framework cannot be loaded, the exploit fails cleanly (NULL / no-op) instead
 * of the app crashing at launch.
 */

#include <dlfcn.h>
#include <stddef.h>
#include <stdio.h>

#include <IOSurface/IOSurfaceRef.h>

static void *gIOSurfaceHandle = NULL;
static int gIOSurfaceTried = 0;

static IOSurfaceRef (*p_IOSurfaceCreate)(CFDictionaryRef properties) = NULL;
static void *(*p_IOSurfaceGetBaseAddress)(IOSurfaceRef buffer) = NULL;
static void (*p_IOSurfacePrefetchPages)(IOSurfaceRef surface) = NULL;

static const char *kIOSurfaceCandidates[] = {
	"/System/Library/Frameworks/IOSurface.framework/IOSurface",
	"/System/Library/PrivateFrameworks/IOSurface.framework/IOSurface",
	"/System/Library/Frameworks/IOSurface.framework/IOSurface",
};

static void dsio_resolve(void)
{
	if (gIOSurfaceTried) return;
	gIOSurfaceTried = 1;

	/* Already mapped into the process (e.g. by another framework)? */
	gIOSurfaceHandle = dlopen(NULL, RTLD_NOW);

	for (size_t i = 0; i < sizeof(kIOSurfaceCandidates) / sizeof(kIOSurfaceCandidates[0]); i++) {
		void *h = dlopen(kIOSurfaceCandidates[i], RTLD_NOW | RTLD_LOCAL);
		if (h) {
			gIOSurfaceHandle = h;
			break;
		}
	}

	if (!gIOSurfaceHandle) {
		printf("[DSIO] could not load IOSurface.framework (%s)\n", dlerror() ?: "unknown");
		return;
	}

	p_IOSurfaceCreate = (IOSurfaceRef (*)(CFDictionaryRef))dlsym(gIOSurfaceHandle, "IOSurfaceCreate");
	p_IOSurfaceGetBaseAddress = (void *(*)(IOSurfaceRef))dlsym(gIOSurfaceHandle, "IOSurfaceGetBaseAddress");
	p_IOSurfacePrefetchPages = (void (*)(IOSurfaceRef))dlsym(gIOSurfaceHandle, "IOSurfacePrefetchPages");

	if (!p_IOSurfaceCreate || !p_IOSurfaceGetBaseAddress) {
		printf("[DSIO] IOSurface symbols missing (create=%p base=%p)\n",
		       (void *)p_IOSurfaceCreate, (void *)p_IOSurfaceGetBaseAddress);
	}
}

IOSurfaceRef IOSurfaceCreate(CFDictionaryRef properties)
{
	dsio_resolve();
	if (!p_IOSurfaceCreate) return NULL;
	return p_IOSurfaceCreate(properties);
}

void *IOSurfaceGetBaseAddress(IOSurfaceRef buffer)
{
	dsio_resolve();
	if (!p_IOSurfaceGetBaseAddress) return NULL;
	return p_IOSurfaceGetBaseAddress(buffer);
}

void IOSurfacePrefetchPages(IOSurfaceRef surface)
{
	dsio_resolve();
	if (p_IOSurfacePrefetchPages) p_IOSurfacePrefetchPages(surface);
}
