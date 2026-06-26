# industrialworld

A standalone LuaJIT binary that statically links [libtcod](https://github.com/libtcod/libtcod) and exposes it to Lua through safe, RAII-style FFI wrappers. Built as a single self-contained executable: vendored LuaJIT, vendored libtcod (which fetches its own SDL3/zlib/etc. via CMake), and ahead-of-time compiled LuaJIT bytecode embedded as C headers.

## Layout

```
industrialworld/
  vendor/
    luajit/              # vendored LuaJIT (built once, reused)
    libtcod/             # vendored libtcod (CMake fetches SDL3, zlib, …)
  src/
    main.c              # C host: preload bytecode, run `main` module
    main.lua            # Lua entry point (demo)
    vendor.h            # libtcod C declarations used from C
    industrialworld/
      gc.lua            # shared ffi.gc RAII helper
      tcod_ffi.lua      # low-level ffi.cdef of the libtcod C API
      tcod.lua          # safe RAII wrappers (Console / Tileset / Context)
  build/                # generated: bytecode headers, static libs, binary
  justfile              # build commands
```

## Build

Requires `clang`, `cmake`, `make`, and `just`.

```
just            # release build → build/industrialworld
just run        # build + run
just clean      # wipe build/
```

The build:

1. **LuaJIT** — compiles the vendored LuaJIT into `libluajit.a` + the `luajit` bcsave tool.
2. **Bytecode** — each `src/**/*.lua` is compiled to a `bytecode_*.h` C header via `luajit -b`; `includes.inc` and `modules.inc` are generated so `main.c` can preload them into `package.preload`.
3. **libtcod** — CMake configures + builds libtcod as a static library (`BUILD_SHARED_LIBS=OFF`), fetching SDL3, zlib, lodepng, utf8proc, and stb as static deps.
4. **Binary** — links `main.c` + LuaJIT + every produced `.a` with `-Wl,-export_dynamic`, so libtcod symbols are visible to `dlsym()` and thus resolvable through LuaJIT's `ffi.C`.

## The FFI wrapper pattern

- `industrialworld/tcod_ffi.lua` — declares all libtcod types/enums/functions via `ffi.cdef`, returns `ffi.C`.
- `industrialworld/tcod.lua` — wraps the raw C calls in RAII objects: `Console`, `Tileset`, `Context` each attach a finalizer via `gc.wrap_gc` so the corresponding `TCOD_*_delete` runs on collection; `:shutdown()` frees deterministically. Functions returning `TCOD_Error` are checked and surfaced as `(nil, errmsg)` Lua tuples, with the message pulled from `TCOD_get_error()`.
- `industrialworld/gc.lua` — the shared `wrap_gc` helper that every typed wrapper routes through, keeping the GC protocol consistent.

## License

MIT.
