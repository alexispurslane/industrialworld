// vendor.h -- bundled third-party declarations
//
// libtcod: the C API lives in the libtcod source tree and is compiled
// into a static library by the justfile's CMake step. The full set of
// declarations is surfaced to Lua via ffi.cdef in
// `industrialworld.tcod_ffi`; only the handful of symbols the C host
// itself needs to touch are declared here.
//
// The final executable is linked with -Wl,-export_dynamic so every
// libtcod symbol is visible to dlsym() -- which is how LuaJIT's ffi.C
// resolves names at runtime. No dlopen of a separate .so/.dylib is
// needed: libtcod is baked into the binary.
#ifndef VENDOR_H
#define VENDOR_H

/* libtcod C headers -- included as user code. */
#include <libtcod.h>

/* `TCOD_quit()` shuts down SDL and frees libtcod's global state.
 * Called defensively from main() on exit in case the Lua side didn't. */
static inline void tcow_quit_safe(void)
{
    TCOD_quit();
}

#endif /* VENDOR_H */
