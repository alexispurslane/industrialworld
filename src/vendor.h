// vendor.h -- bundled third-party declarations
//
// BearLibTerminal: the C API lives in the BLT source tree and is compiled
// into libBearLibTerminal.a by the justfile's CMake step. The full set of
// declarations is surfaced to Lua via ffi.cdef in `industrialworld.blt_ffi`;
// only the symbols the C host itself touches are declared here.
//
// The final executable is linked with -Wl,-export_dynamic so every BLT
// symbol is visible to dlsym() -- which is how LuaJIT's ffi.C resolves
// terminal_put / terminal_set / terminal_refresh at runtime. No dlopen
// of a separate .so/.dylib is needed: BLT is baked into the binary.
#ifndef VENDOR_H
#define VENDOR_H

/* BearLibTerminal C header -- included as user code. */
#include "BearLibTerminal.h"

/* `terminal_close()` shuts down BLT's window and frees its global state.
 * Called defensively from main() on exit in case the Lua side didn't. */
static inline void tcow_quit_safe(void)
{
    terminal_close();
}

#endif /* VENDOR_H */
