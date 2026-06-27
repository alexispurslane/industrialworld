# industrialworld — justfile
#
# Fully self-contained, fully-vendored build: vendored LuaJIT + vendored
# BearLibTerminal, with BLT's own deps (FreeType, PicoPNG, NanoJPEG) all
# shipped in BLT's in-tree Dependencies/ and built as STATIC libraries.
# The binary is linked with -force_load + -export_dynamic so LuaJIT's
# ffi.C can dlsym BearLibTerminal symbols (terminal_put, etc.) straight
# out of the executable.
#
# Requires: clang, cmake, make. No system libs beyond macOS
# frameworks (OpenGL + Cocoa).

CC       := "clang"
STYLUA   := "stylua"
LUALS    := "lua-language-server"

SRC_DIR    := "src"
BUILD_DIR  := "build"
VENDOR_DIR := "vendor"
BINARY     := BUILD_DIR / "industrialworld"

# ── Vendored LuaJIT paths ──────────────────────────────────────────
LUAJIT_SRC  := VENDOR_DIR + "/luajit/src"
LUAJIT_INC  := LUAJIT_SRC  # lua.h etc. live directly in luajit/src/
LUAJIT_LIB  := LUAJIT_SRC + "/libluajit.a"
LUAJIT_BIN  := LUAJIT_SRC + "/luajit"

# ── Vendored BearLibTerminal + its dependencies ────────────────────
# BLT ships its own FreeType + PicoPNG + NanoJPEG inside its source tree,
# so no extra git submodules are needed — just a CMake configure/build.
BLT_DIR     := VENDOR_DIR + "/bearlibterminal"
BLT_BUILD   := BUILD_DIR + "/bearlibterminal"
BLT_INC     := BLT_DIR + "/Terminal/Include/C"
BLT_OUTPUT  := BLT_DIR + "/Output/Darwin64"  # where libBearLibTerminal.a lands

# macOS deployment target (needed by LuaJIT build and our own compile).
# Must be consistent across all object files.
MACOSX_DEPLOYMENT_TARGET := `sw_vers -productVersion 2>/dev/null | cut -d. -f1-2 || echo "14.0"`

# List available recipes when invoked with no args.
default:
    @just --list

# ── Clean ──────────────────────────────────────────────────────────

# Remove the build/ directory (bytecode headers, BLT build, binary).
clean:
    rm -rf {{BUILD_DIR}}

# Clean vendored LuaJIT + BearLibTerminal build artifacts (keeps sources).
clean-vendor:
    cd {{VENDOR_DIR}}/luajit && make clean 2>/dev/null || true
    rm -rf {{BLT_BUILD}}



# ── Scaffold & codegen ────────────────────────────────────────────

# Parent/mixins are PascalCase; require paths are derived; existence-checked.
# Convention: one class per module (so module-local `super` is unambiguous).
# Examples:
#   just new-class Entity                                          # base
#   just new-class Enemy --parent=Entity                            # subclass
#   just new-class Enemy --parent=Entity --mixins=Health            # + 1 mixin
#   just new-class Enemy --parent=Entity --mixins=Health,Drawable  # + 2 mixins
# Scaffold a new class module at src/<name>.lua from a parent + mixins.
new-class name *specs:
    #!/usr/bin/env bash
    set -euo pipefail
    scripts/new-class.sh "{{name}}" {{specs}}

# Scaffold a new mixin module at src/mixins/<name>.lua.
# - Leaf (default): `just new-mixin Health`
# - Composed/orchestrating (law 2): `just new-mixin Burning --compose=Flammable,Soakable`
new-mixin name *specs:
    #!/usr/bin/env bash
    set -euo pipefail
    scripts/new-mixin.sh "{{name}}" {{specs}}

# ── Lint & Format ──────────────────────────────────────────────────

# Type-check src/ with lua-language-server (strict .luarc.json config).
lint:
    #!/usr/bin/env bash
    set -euo pipefail
    {{LUALS}} check --configpath .luarc.json --check {{SRC_DIR}}/

# Format every .lua under src/ in place with stylua.
fmt:
    {{STYLUA}} {{SRC_DIR}}

# Check formatting without writing (stylua --check over src/).
_fmt-check:
    {{STYLUA}} --check {{SRC_DIR}}

# ── Build ──────────────────────────────────────────────────────────

# Build the standalone industrialworld binary (vendored LuaJIT + BearLibTerminal).
build mode="release": (_build-luajit) (_compile-bytecode) (_compile-blt mode) (_compile-binary mode)

# Build vendored LuaJIT into libluajit.a + the luajit binary (skips if up to date).
_build-luajit:
    #!/usr/bin/env bash
    set -euo pipefail
    if [ -x {{LUAJIT_BIN}} ] && [ -f {{LUAJIT_LIB}} ]; then
        echo "vendored LuaJIT already built"
        exit 0
    fi
    cd {{VENDOR_DIR}}/luajit
    MACOSX_DEPLOYMENT_TARGET={{MACOSX_DEPLOYMENT_TARGET}} make -j$(sysctl -n hw.ncpu 2>/dev/null || echo 4) clean 2>/dev/null || true
    MACOSX_DEPLOYMENT_TARGET={{MACOSX_DEPLOYMENT_TARGET}} make -j$(sysctl -n hw.ncpu 2>/dev/null || echo 4)

# LUA_PATH must point to the jit/ modules so -b (bcsave.lua) works.
# Compile every .lua under src/ to bytecode C headers + modules.inc/includes.inc.
_compile-bytecode:
    #!/usr/bin/env bash
    set -euo pipefail
    mkdir -p {{BUILD_DIR}}
    src="{{SRC_DIR}}"

    # Compile each .lua → bytecode header (only if missing or stale)
    find "$src" -name '*.lua' -print0 | sort -z | while IFS= read -r -d '' f; do
        rel="${f#$src/}"
        name="${rel%.lua}"
        modname="${name//\//.}"
        ident="${modname//\./_}"
        header="{{BUILD_DIR}}/bytecode_${ident}.h"
        if [ ! -f "$header" ] || [ "$f" -nt "$header" ]; then
            LUA_PATH="{{LUAJIT_SRC}}/?.lua" {{LUAJIT_BIN}} -b -g -n "$modname" "$f" "$header"
        fi
    done

    # Generate includes.inc and modules.inc from whatever .lua files exist
    find "$src" -name '*.lua' -print0 | sort -z | while IFS= read -r -d '' f; do
        rel="${f#$src/}"
        name="${rel%.lua}"
        modname="${name//\//.}"
        ident="${modname//\./_}"
        echo "#include \"bytecode_${ident}.h\""
    done > {{BUILD_DIR}}/includes.inc

    find "$src" -name '*.lua' -print0 | sort -z | while IFS= read -r -d '' f; do
        rel="${f#$src/}"
        name="${rel%.lua}"
        modname="${name//\//.}"
        ident="${modname//\./_}"
        echo "    { \"${modname}\", (const char *)luaJIT_BC_${ident}, sizeof(luaJIT_BC_${ident}) },"
    done > {{BUILD_DIR}}/modules.inc

# BLT's deps (FreeType/PicoPNG/NanoJPEG) are all in BLT's in-tree
# Dependencies/ dir, so this CMake run is fully self-contained — no
# FetchContent, no system FreeType, no SDL. Only macOS frameworks later.
# Configure + build vendored BearLibTerminal as a static lib via CMake.
_compile-blt mode="release":
    #!/usr/bin/env bash
    set -euo pipefail
    mkdir -p {{BUILD_DIR}}
    CMAKE_BUILD_TYPE="{{if mode == "debug" { "Debug" } else { "Release" }}}"
    if [ ! -f {{BLT_OUTPUT}}/libBearLibTerminal.a ] || [ {{BLT_DIR}}/Terminal/CMakeLists.txt -nt {{BUILD_DIR}}/blt-cache.txt ]; then
        echo "vendored BearLibTerminal not built — configuring with CMake"
        rm -rf {{BLT_BUILD}}
        cmake -S {{BLT_DIR}} -B {{BLT_BUILD}} \
            -DBUILD_SHARED_LIBS=OFF \
            -DCMAKE_BUILD_TYPE="$CMAKE_BUILD_TYPE" \
            -DCMAKE_OSX_DEPLOYMENT_TARGET={{MACOSX_DEPLOYMENT_TARGET}}
        touch {{BUILD_DIR}}/blt-cache.txt
    fi
    cmake --build {{BLT_BUILD}} --config "$CMAKE_BUILD_TYPE" -j$(sysctl -n hw.ncpu 2>/dev/null || echo 4)

# Fully static except macOS frameworks. -force_load retains ALL
# BearLibTerminal/FreeType/PicoPNG symbols; -export_dynamic exports them
# so LuaJIT ffi.C / dlsym resolves terminal_put etc. right out of the exe.
# Link src/main.c + LuaJIT + BLT static libs into the industrialworld binary.
_compile-binary mode="release":
    #!/usr/bin/env bash
    set -euo pipefail
    mkdir -p {{BUILD_DIR}}

    # BearLibTerminal + its in-tree deps (FreeType, PicoPNG). NanoJPEG is
    # header-only and compiled straight into libBearLibTerminal.a.
    blt_libs="{{BLT_OUTPUT}}/libBearLibTerminal.a {{BLT_BUILD}}/Terminal/Dependencies/FreeType/libfreetype2.a {{BLT_BUILD}}/Terminal/Dependencies/PicoPNG/libpicopng.a"
    for l in $blt_libs; do
        if [ ! -f "$l" ]; then
            echo "industrialworld: missing BLT static lib $l — run 'just build'"
            exit 1
        fi
    done
    force_load=""
    for l in $blt_libs; do force_load="$force_load -Wl,-force_load,$l"; done

    clang \
        {{if mode == "debug" { "-g -O0 -DDEBUG" } else { "-O2 -DNDEBUG" }}} \
        -std=c11 \
        -Wall -Wextra -Werror \
        -Wno-comment \
        -mmacosx-version-min={{MACOSX_DEPLOYMENT_TARGET}} \
        -I{{LUAJIT_INC}} \
        -I{{BUILD_DIR}} \
        -I{{SRC_DIR}} \
        -I{{BLT_INC}} \
        {{SRC_DIR}}/main.c \
        -Wl,-force_load,{{LUAJIT_LIB}} \
        $force_load \
        -Wl,-export_dynamic \
        -lc++ -lobjc -liconv -lm -ldl -lpthread \
        -framework Cocoa -framework OpenGL -framework IOKit \
        -framework CoreFoundation -framework AppKit -framework Foundation \
        -o {{BINARY}}

# ── Run ────────────────────────────────────────────────────────────

# Build (release) then run the industrialworld binary with any args.
run *ARGS: (build "release")
    {{BINARY}} {{ARGS}}

# Build (debug) then run the industrialworld binary with any args.
run-debug *ARGS: (build "debug")
    {{BINARY}} {{ARGS}}

# ── All checks ─────────────────────────────────────────────────────

# Run formatting check + lint (does not build).
check: _fmt-check lint
