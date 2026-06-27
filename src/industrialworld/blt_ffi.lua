--- industrialworld.blt_ffi: minimal BearLibTerminal C declarations.
---
--- Mirrors the symbols we touch in src/main.c's vendor.h (which includes the
--- full BearLibTerminal.h). Only the exported (non-inline) functions are
--- declared here, because LuaJIT's ffi.C resolves via dlsym against the
--- executable's dynamic symbol table — `static inline` wrappers like
--- terminal_set / terminal_print / color_from_argb are NOT exportable, so
--- we bind their underlying *8 variants and reimplement the sugar in Lua.
---
--- Color model: BLT uses uint32_t ARGB (0xAARRGGBB). We pack colors in Lua;
--- color_t is just an integer cdata here, no struct.
local ffi = require("ffi")

ffi.cdef([[
    /* ── lifecycle ─────────────────────────────────────────────── */
    int  terminal_open(void);
    void terminal_close(void);

    /* ── configuration ─────────────────────────────────────────── */
    /* UTF-8 form: the *8 variants take/return char-terminated byte
     * strings, which LuaJIT ffi strings map to cleanly. */
    int  terminal_set8(const char *value);
    void terminal_font8(const char *name);
    const char *terminal_get8(const char *key, const char *default_);
    unsigned int color_from_name8(const char *name);

    /* ── drawing state ─────────────────────────────────────────── */
    void terminal_refresh(void);
    void terminal_clear(void);
    void terminal_clear_area(int x, int y, int w, int h);
    void terminal_crop(int x, int y, int w, int h);
    void terminal_layer(int index);
    void terminal_color(unsigned int color);
    void terminal_bkcolor(unsigned int color);
    void terminal_composition(int mode);

    /* ── glyph output ───────────────────────────────────────────── */
    void terminal_put(int x, int y, int code);
    void terminal_put_ext(int x, int y, int dx, int dy, int code, unsigned int *corners);
    int  terminal_pick(int x, int y, int index);
    unsigned int terminal_pick_color(int x, int y, int index);
    unsigned int terminal_pick_bkcolor(int x, int y);

    /* unused but kept for completeness */

    /* ── text output ────────────────────────────────────────────── */
    /* Returns via out_w/out_h; Lua reads them from int[1] arrays. */
    void terminal_print_ext8(int x, int y, int w, int h, int align,
                             const char *s, int *out_w, int *out_h);
    void terminal_measure_ext8(int w, int h, const char *s, int *out_w, int *out_h);

    /* ── input ──────────────────────────────────────────────────── */
    int  terminal_has_input(void);
    int  terminal_state(int code);
    int  terminal_read(void);
    int  terminal_peek(void);
    void terminal_delay(int period);
]])

return require("ffi").C
