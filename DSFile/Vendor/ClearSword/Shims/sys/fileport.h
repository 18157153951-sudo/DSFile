/*
 * fileport.h shim
 *
 * XNU's bsd/sys/fileport.h is not shipped in the public iOS SDK, but the two
 * functions it declares are exported by libsystem on every iOS version we
 * support. This shim declares exactly what the DarkSword escape needs, and is
 * placed first on the header search path so it is used instead of a system
 * header when one happens to exist.
 */
#ifndef DS_SHIM_SYS_FILEPORT_H
#define DS_SHIM_SYS_FILEPORT_H

#include <stdint.h>
#include <sys/cdefs.h>

__BEGIN_DECLS

typedef uint32_t fileport_t;
#define FILEPORT_NULL ((fileport_t)0)

/* Turn a file descriptor into a fileport send right. */
extern int fileport_makeport(int fd, fileport_t *portnamep);
/* Turn a fileport back into a file descriptor. */
extern int fileport_makefd(fileport_t portname);

__END_DECLS

#endif /* DS_SHIM_SYS_FILEPORT_H */
