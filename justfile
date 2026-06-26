# industrialworld — justfile
#
# Fully self-contained, fully-vendored build: vendored LuaJIT + vendored
# libtcod, with libtcod's own deps (SDL3, zlib, lodepng, utf8proc, stb) all
# cloned into vendor/ and built as STATIC libraries. The binary is linked
# with -force_load + -export_dynamic so LuaJIT's ffi.C can dlsym libtcod
# symbols straight out of the executable.
#
# Requires: clang, cmake, make, git. No homebrew SDL3/zlib — no shared libs
# beyond macOS system frameworks.

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

# ── Vendored libtcod + its dependencies ────────────────────────────
LIBTCOD_DIR   := VENDOR_DIR + "/libtcod"
LIBTCOD_BUILD := BUILD_DIR + "/libtcod"
LIBTCOD_INC   := LIBTCOD_DIR + "/src/libtcod"

# SDL3 is cloned into vendor/ (pinned to release-3.2.30) and built static by
# the libtcod CMake run below. Headers live in vendor/SDL/include, and the
# generated build_config header lands in the SDL3 build subtree.
SDL3_SRC     := VENDOR_DIR + "/SDL"
SDL3_INC     := SDL3_SRC + "/include"
SDL3_BUILDCFG := LIBTCOD_BUILD + "/_deps/sdl3-build/include-config-release/build_config"

# macOS deployment target (needed by LuaJIT build and our own compile).
# Must be consistent across all object files.
MACOSX_DEPLOYMENT_TARGET := `sw_vers -productVersion 2>/dev/null | cut -d. -f1-2 || echo "14.0"`

# List available recipes when invoked with no args.
default:
    @just --list

# ── Clean ──────────────────────────────────────────────────────────

# Remove the build/ directory (bytecode headers, libtcod build, binary).
clean:
    rm -rf {{BUILD_DIR}}

# Clean vendored LuaJIT + libtcod build artifacts (keeps the sources).
clean-vendor:
    cd {{VENDOR_DIR}}/luajit && make clean 2>/dev/null || true
    rm -rf {{LIBTCOD_BUILD}}

# ── One-time vendor preparation ─────────────────────────────────
# Clones SDL3 + zlib into vendor/ at the exact pinned tags libtcod references,
# initializes libtcod's bundled utf8proc submodule, applies the small patches
# needed for a fully static + dlsym-able build, and ships terminal.png next
# to the binary so the demo's fallback tileset resolves at runtime.
# Prepare vendored sources (SDL3/zlib/utf8proc + terminal.png); idempotent, safe to re-run.
prepare-vendor:
    #!/usr/bin/env bash
    set -euo pipefail
    bash scripts/prepare-vendor.sh

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

# Build the standalone industrialworld binary (vendored LuaJIT + libtcod).
build mode="release": (prepare-vendor) (_build-luajit) (_compile-bytecode) (_compile-libtcod mode) (_compile-binary mode)

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

# SDL3/zlib are pointed at our vendor/ clones (FETCHCONTENT_SOURCE_DIR_*),
# so NOTHING is fetched from homebrew/system. lodepng/utf8proc/stb are
# compiled straight into libtcod.a (vendored mode). Run `just prepare-vendor`
# once first to clone SDL3/zlib + init the utf8proc submodule + apply patches.
# Configure + build vendored libtcod + SDL3 + zlib as static libs via CMake.
_compile-libtcod mode="release":
    #!/usr/bin/env bash
    set -euo pipefail
    mkdir -p {{LIBTCOD_BUILD}}
    root="$(pwd)"
    CMAKE_BUILD_TYPE="{{if mode == "debug" { "Debug" } else { "Release" }}}"
    if [ ! -f {{LIBTCOD_BUILD}}/libtcod/libtcod.a ] || [ {{LIBTCOD_DIR}}/CMakeLists.txt -nt {{LIBTCOD_BUILD}}/CMakeCache.txt ]; then
        echo "vendored libtcod not built — configuring with CMake (static SDL3/zlib from vendor/)"
        cmake -S {{LIBTCOD_DIR}} -B {{LIBTCOD_BUILD}} \
            -DCMAKE_BUILD_TYPE="$CMAKE_BUILD_TYPE" \
            -DBUILD_SHARED_LIBS=OFF \
            -DLIBTCOD_SAMPLES=OFF \
            -DLIBTCOD_TESTS=OFF \
            -DLIBTCOD_INSTALL=OFF \
            -DLIBTCOD_DOCS=OFF \
            -DCMAKE_DISABLE_FIND_PACKAGE_SDL3=ON \
            -DCMAKE_DISABLE_FIND_PACKAGE_ZLIB=ON \
            -DFETCHCONTENT_SOURCE_DIR_SDL3="$root/{{SDL3_SRC}}" \
            -DFETCHCONTENT_SOURCE_DIR_ZLIB="$root/{{VENDOR_DIR}}/zlib" \
            -DLIBTCOD_LODEPNG=vendored \
            -DLIBTCOD_UTF8PROC=vendored \
            -DLIBTCOD_STB=vendored \
            -DSDL_STATIC=ON -DSDL_SHARED=OFF -DSDL_TEST=OFF -DSDL_INSTALL=OFF \
            -DZLIB_BUILD_SHARED=OFF -DZLIB_BUILD_STATIC=ON \
            -DCMAKE_OSX_DEPLOYMENT_TARGET={{MACOSX_DEPLOYMENT_TARGET}}
    fi
    cmake --build {{LIBTCOD_BUILD}} --config "$CMAKE_BUILD_TYPE" -j$(sysctl -n hw.ncpu 2>/dev/null || echo 4)

# Fully static except macOS frameworks. -force_load retains ALL libtcod/SDL3/zlib
# symbols; -export_dynamic exports them so LuaJIT ffi.C / dlsym resolves them.
# Link src/main.c + LuaJIT + libtcod static libs into the industrialworld binary.
_compile-binary mode="release":
    #!/usr/bin/env bash
    set -euo pipefail
    mkdir -p {{BUILD_DIR}}

    # Gather static archives to force-load. Exclude libSDL_uclibc.a (its
    # math shims duplicate symbols inside libSDL3.a) and libSDL3_test.a.
    tcod_libs=$(find {{LIBTCOD_BUILD}} -name '*.a' \
        ! -name 'libSDL_uclibc.a' ! -name 'libSDL3_test.a' | sort -u)
    if [ -z "$tcod_libs" ]; then
        echo "industrialworld: no libtcod static libs found in {{LIBTCOD_BUILD}} — run 'just build'"
        exit 1
    fi
    force_load=""
    for l in $tcod_libs; do force_load="$force_load -Wl,-force_load,$l"; done

    clang \
        {{if mode == "debug" { "-g -O0 -DDEBUG" } else { "-O2 -DNDEBUG" }}} \
        -std=c11 \
        -Wall -Wextra -Werror \
        -Wno-comment \
        -mmacosx-version-min={{MACOSX_DEPLOYMENT_TARGET}} \
        -I{{LUAJIT_INC}} \
        -I{{BUILD_DIR}} \
        -I{{SRC_DIR}} \
        -I{{LIBTCOD_INC}} \
        -I{{SDL3_INC}} -I{{SDL3_INC}}/SDL3 \
        -I{{SDL3_BUILDCFG}} \
        {{SRC_DIR}}/main.c \
        -Wl,-force_load,{{LUAJIT_LIB}} \
        $force_load \
        -Wl,-export_dynamic \
        -lc++ -lobjc -liconv -lm -ldl -lpthread \
        -framework Cocoa -framework IOKit -framework CoreVideo -framework CoreAudio \
        -framework AudioToolbox -framework ForceFeedback -framework CoreHaptics \
        -framework Metal -framework QuartzCore -framework GameController \
        -framework CoreServices -framework Carbon -framework CoreMedia \
        -framework AVFoundation -framework CoreFoundation \
        -framework UniformTypeIdentifiers -framework AppKit -framework Foundation \
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
