#!/usr/bin/env bash
# prepare-vendor.sh — one-time (idempotent) setup of vendored sources.
#
# Clones SDL3 + zlib into vendor/ at the exact pinned commits libtcod
# references, initializes libtcod's bundled utf8proc submodule, and applies
# the small patches needed for a fully-static, dlsym-able build:
#   * zlib:     alias ZLIB::ZLIB to zlibstatic when the shared target is off
#   * libtcod:  fix the broken `vendored`-mode source paths (src/vendor/...),
#               and use LIBTCOD_EXPORTS (not LIBTCOD_STATIC) in static builds
#               so TCOD_PUBLIC exports the public API for LuaJIT ffi.C/dlsym.
# Also ships libtcod's terminal.png next to the root so the demo's fallback
# tileset resolves at runtime.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

SDL3_SRC="vendor/SDL"
ZLIB_SRC="vendor/zlib"
LIBTCOD_DIR="vendor/libtcod"

# SDL3 pinned to release-3.2.30 (commit libtcod references).
if [ ! -d "$SDL3_SRC/.git" ]; then
    git clone --depth 1 https://github.com/libsdl-org/SDL.git "$SDL3_SRC"
fi
git -C "$SDL3_SRC" fetch --depth 1 origin f5e5f6588921eed3d7d048ce43d9eb1ff0da0ffc 2>/dev/null || true
git -C "$SDL3_SRC" checkout FETCH_HEAD 2>/dev/null || true

# zlib pinned to v1.3.1.2 (commit libtcod references).
if [ ! -d "$ZLIB_SRC/.git" ]; then
    git clone --depth 1 https://github.com/madler/zlib.git "$ZLIB_SRC"
fi
git -C "$ZLIB_SRC" fetch --depth 1 origin 570720b0c24f9686c33f35a1b3165c1f568b96be 2>/dev/null || true
git -C "$ZLIB_SRC" checkout FETCH_HEAD 2>/dev/null || true

# libtcod bundles utf8proc as a submodule (used in `vendored` mode).
git -C "$LIBTCOD_DIR" submodule update --init --depth 1 src/vendor/utf8proc 2>/dev/null || true

# --- Patch zlib ---------------------------------------------------------------
zc="$ZLIB_SRC/CMakeLists.txt"
if ! grep -q 'ZLIB::ZLIB ALIAS zlibstatic' "$zc"; then
    python3 -c '
import sys
p=sys.argv[1]; s=open(p).read()
needle="    add_library(ZLIB::ZLIBSTATIC ALIAS zlibstatic)\n"
ins=(needle
     +"    # Patched for our vendored static build: also alias ZLIB::ZLIB\n"
     +"    # to zlibstatic when the shared target is absent, so consumers\n"
     +"    # linking ZLIB::ZLIB resolve against the static lib.\n"
     +"    if(NOT ZLIB_BUILD_SHARED)\n"
     +"        add_library(ZLIB::ZLIB ALIAS zlibstatic)\n"
     +"    endif()\n")
if needle in s:
    open(p,"w").write(s.replace(needle,ins,1))
' "$zc"
fi

# --- Patch libtcod ------------------------------------------------------------
lc="$LIBTCOD_DIR/CMakeLists.txt"
# (a) fix the broken `vendored`-mode source paths (files live under src/vendor).
sed -i '' \
    -e 's#"vendor/lodepng.c"#"src/vendor/lodepng.c"#' \
    -e 's#"vendor/utf8proc/utf8proc.c"#"src/vendor/utf8proc/utf8proc.c"#' \
    -e 's#"vendor/utf8proc"#"src/vendor/utf8proc"#' \
    -e 's#"vendor/"#"src/vendor/"#g' \
    "$lc"
# (b) LIBTCOD_EXPORTS instead of LIBTCOD_STATIC in static builds (export API).
if grep -q 'target_compile_definitions(${PROJECT_NAME} PUBLIC LIBTCOD_STATIC)' "$lc"; then
    python3 -c '
import sys
p=sys.argv[1]; s=open(p).read()
old="    target_compile_definitions(${PROJECT_NAME} PUBLIC LIBTCOD_STATIC)\n"
new=("    # Patched: keep LIBTCOD_EXPORTS in static builds so TCOD_PUBLIC\n"
     +"    # expands to visibility(\"default\"), exporting the public API\n"
     +"    # for LuaJIT ffi.C / dlsym. Upstream defines LIBTCOD_STATIC here,\n"
     +"    # which empties TCOD_PUBLIC and marks every symbol local.\n"
     +"    target_compile_definitions(${PROJECT_NAME} PUBLIC LIBTCOD_EXPORTS)\n")
open(p,"w").write(s.replace(old,new,1))
' "$lc"
fi

# Ship the font asset next to the binary. We use a square 16×16 DejaVu TCOD-layout
# PNG tileset as the live font; the 32×8 sheet matches tcod.charmap_tcod.
FONT_URL="https://raw.githubusercontent.com/libtcod/python-tcod/develop/fonts/libtcod/dejavu16x16_gs_tc.png"
FONT_LOCAL="vendor/fonts/dejavu16x16_gs_tc.png"

mkdir -p vendor/fonts
if [ ! -f "$FONT_LOCAL" ]; then
    echo "downloading DejaVu 16×16 square tileset..."
    curl -fsSL "$FONT_URL" -o "$FONT_LOCAL"
fi
cp -f "$FONT_LOCAL" terminal.png

echo "vendored sources prepared."
