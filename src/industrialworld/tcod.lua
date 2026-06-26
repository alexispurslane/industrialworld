--- High-level libtcod bindings with RAII memory management via ffi.gc.
---
--- Usage:
---   local tcod = require("industrialworld.tcod")
---
---   local ctx, err = tcod.Context.new({ columns = 80, rows = 50, title = "iw" })
---   if not ctx then error(err) end
---
---   local con = tcod.Console.new(80, 50)
---   con:clear()
---   con:put_char(0, 0, 64, tcod.colors.white, tcod.colors.black)
---   ctx:present(con)          -- flip the console to the screen
---
---   -- GC calls TCOD_console_delete / TCOD_context_delete / TCOD_quit
---   -- automatically when objects are collected. Call :shutdown() to
---   -- free deterministically before GC runs.
---
--- Every C function that returns a TCOD_Error is checked; on failure the
--- Lua wrapper returns nil + an error message fetched from TCOD_get_error.

local ffi = require("ffi")
local C = require("industrialworld.tcod_ffi")
local gc = require("industrialworld.gc")

--- Coerce an ffi integer cdata to a Lua integer.
--- `tonumber` returns `number?`; for C int fields that always hold a value,
--- this floors to a proper `integer` for the type checker (and guards nil
--- defensively as 0, which can't happen for valid pointers).
---@param x any ffi integer cdata
---@return integer
local function toint(x)
    return math.floor(tonumber(x) or 0)
end

----------------------------------------------------------------------------------------------------
-- Color constants
----------------------------------------------------------------------------------------------------

--- Named 0xRRGGBB colors. Pass to any function taking a TCOD_color_t.
local colors = {
    black = { r = 0, g = 0, b = 0 },
    white = { r = 255, g = 255, b = 255 },
    red = { r = 255, g = 0, b = 0 },
    green = { r = 0, g = 255, b = 0 },
    blue = { r = 0, g = 0, b = 255 },
    yellow = { r = 255, g = 255, b = 0 },
    magenta = { r = 255, g = 0, b = 255 },
    cyan = { r = 0, g = 255, b = 255 },
    orange = { r = 255, g = 165, b = 0 },
    gray = { r = 128, g = 128, b = 128 },
}

--- Build a TCOD_color_t struct value from an {r,g,b} table (or pass through a cdata).
---@param c table|any {r=,g=,b=} table or an existing TCOD_color_t cdata
---@return any cdata TCOD_color_t
local function to_color(c)
    if type(c) == "table" then
        return ffi.new("TCOD_color_t", c.r or 0, c.g or 0, c.b or 0)
    end
    return c
end

--- Build a TCOD_ColorRGBA from an {r,g,b,a?} table (a defaults to 255).
---@param c table|any
---@return any cdata TCOD_ColorRGBA
local function to_rgba(c)
    if type(c) == "table" then
        return ffi.new("TCOD_ColorRGBA", c.r or 0, c.g or 0, c.b or 0, c.a or 255)
    end
    return c
end

----------------------------------------------------------------------------------------------------
-- Error checking
----------------------------------------------------------------------------------------------------

--- Turn a TCOD_Error return value into (true, nil) on OK / WARN or (nil, msg) otherwise.
---@param rv integer TCOD_Error
---@return boolean|nil ok
---@return string|nil errmsg
local function check(rv)
    local v = tonumber(rv)
    if v == nil then
        return nil, "industrialworld.tcod: nil return value"
    end
    if v >= 0 then
        return true, nil
    end
    local msg = C.TCOD_get_error()
    return nil, ffi.string(msg)
end

-- ── CP437 → Unicode charmap (mirrors libtcod's TCOD_CHARMAP_CP437).
-- libtcod defines this as a `static const int[256]` in a header, so it is
-- inlined into the .a and not dlsym-able. We replicate it here so Lua-side
-- font loading can build the int[] libtcod wants.
local charmap_cp437 = {
    0x0000,
    0x263A,
    0x263B,
    0x2665,
    0x2666,
    0x2663,
    0x2660,
    0x2022,
    0x25D8,
    0x25CB,
    0x25D9,
    0x2642,
    0x2640,
    0x266A,
    0x266B,
    0x263C,
    0x25BA,
    0x25C4,
    0x2195,
    0x203C,
    0x00B6,
    0x00A7,
    0x25AC,
    0x21A8,
    0x2191,
    0x2193,
    0x2192,
    0x2190,
    0x221F,
    0x2194,
    0x25B2,
    0x25BC,
    0x0020,
    0x0021,
    0x0022,
    0x0023,
    0x0024,
    0x0025,
    0x0026,
    0x0027,
    0x0028,
    0x0029,
    0x002A,
    0x002B,
    0x002C,
    0x002D,
    0x002E,
    0x002F,
    0x0030,
    0x0031,
    0x0032,
    0x0033,
    0x0034,
    0x0035,
    0x0036,
    0x0037,
    0x0038,
    0x0039,
    0x003A,
    0x003B,
    0x003C,
    0x003D,
    0x003E,
    0x003F,
    0x0040,
    0x0041,
    0x0042,
    0x0043,
    0x0044,
    0x0045,
    0x0046,
    0x0047,
    0x0048,
    0x0049,
    0x004A,
    0x004B,
    0x004C,
    0x004D,
    0x004E,
    0x004F,
    0x0050,
    0x0051,
    0x0052,
    0x0053,
    0x0054,
    0x0055,
    0x0056,
    0x0057,
    0x0058,
    0x0059,
    0x005A,
    0x005B,
    0x005C,
    0x005D,
    0x005E,
    0x005F,
    0x0060,
    0x0061,
    0x0062,
    0x0063,
    0x0064,
    0x0065,
    0x0066,
    0x0067,
    0x0068,
    0x0069,
    0x006A,
    0x006B,
    0x006C,
    0x006D,
    0x006E,
    0x006F,
    0x0070,
    0x0071,
    0x0072,
    0x0073,
    0x0074,
    0x0075,
    0x0076,
    0x0077,
    0x0078,
    0x0079,
    0x007A,
    0x007B,
    0x007C,
    0x007D,
    0x007E,
    0x2302,
    0x00C7,
    0x00FC,
    0x00E9,
    0x00E2,
    0x00E4,
    0x00E0,
    0x00E5,
    0x00E7,
    0x00EA,
    0x00EB,
    0x00E8,
    0x00EF,
    0x00EE,
    0x00EC,
    0x00C4,
    0x00C5,
    0x00C9,
    0x00E6,
    0x00C6,
    0x00F4,
    0x00F6,
    0x00F2,
    0x00FB,
    0x00F9,
    0x00FF,
    0x00D6,
    0x00DC,
    0x00A2,
    0x00A3,
    0x00A5,
    0x20A7,
    0x0192,
    0x00E1,
    0x00ED,
    0x00F3,
    0x00FA,
    0x00F1,
    0x00D1,
    0x00AA,
    0x00BA,
    0x00BF,
    0x2310,
    0x00AC,
    0x00BD,
    0x00BC,
    0x00A1,
    0x00AB,
    0x00BB,
    0x2591,
    0x2592,
    0x2593,
    0x2502,
    0x2524,
    0x2561,
    0x2562,
    0x2556,
    0x2555,
    0x2563,
    0x2551,
    0x2557,
    0x255D,
    0x255C,
    0x255B,
    0x2510,
    0x2514,
    0x2534,
    0x252C,
    0x251C,
    0x2500,
    0x253C,
    0x255E,
    0x255F,
    0x255A,
    0x2554,
    0x2569,
    0x2566,
    0x2560,
    0x2550,
    0x256C,
    0x2567,
    0x2568,
    0x2564,
    0x2565,
    0x2559,
    0x2558,
    0x2552,
    0x2553,
    0x256B,
    0x256A,
    0x2518,
    0x250C,
    0x2588,
    0x2584,
    0x258C,
    0x2590,
    0x2580,
    0x03B1,
    0x00DF,
    0x0393,
    0x03C0,
    0x03A3,
    0x03C3,
    0x00B5,
    0x03C4,
    0x03A6,
    0x0398,
    0x03A9,
    0x03B4,
    0x221E,
    0x03C6,
    0x03B5,
    0x2229,
    0x2261,
    0x00B1,
    0x2265,
    0x2264,
    0x2320,
    0x2321,
    0x00F7,
    0x2248,
    0x00B0,
    0x2219,
    0x00B7,
    0x221A,
    0x207F,
    0x00B2,
    0x25A0,
    0x00A0,
}

-- TCOD charmap: mirrors libtcod's TCOD_CHARMAP_TCOD[256] (a `static const`
-- in the header, so not dlsym-able). Maps each tile slot of terminal.png
-- (which uses TCOD layout) to its Unicode codepoint, so rendering a
-- codepoint resolves to the right glyph. Generated from the header's
-- TCOD_CHARMAP_TCOD_ table.
local charmap_tcod = {
    0x0020,
    0x0021,
    0x0022,
    0x0023,
    0x0024,
    0x0025,
    0x0026,
    0x0027,
    0x0028,
    0x0029,
    0x002A,
    0x002B,
    0x002C,
    0x002D,
    0x002E,
    0x002F,
    0x0030,
    0x0031,
    0x0032,
    0x0033,
    0x0034,
    0x0035,
    0x0036,
    0x0037,
    0x0038,
    0x0039,
    0x003A,
    0x003B,
    0x003C,
    0x003D,
    0x003E,
    0x003F,
    0x0040,
    0x005B,
    0x005C,
    0x005D,
    0x005E,
    0x005F,
    0x0060,
    0x007B,
    0x007C,
    0x007D,
    0x007E,
    0x2591,
    0x2592,
    0x2593,
    0x2502,
    0x2500,
    0x253C,
    0x2524,
    0x2534,
    0x251C,
    0x252C,
    0x2514,
    0x250C,
    0x2510,
    0x2518,
    0x2598,
    0x259D,
    0x2580,
    0x2596,
    0x259A,
    0x2590,
    0x2597,
    0x2191,
    0x2193,
    0x2190,
    0x2192,
    0x25B2,
    0x25BC,
    0x25C4,
    0x25BA,
    0x2195,
    0x2194,
    0x2610,
    0x2611,
    0x25CB,
    0x25C9,
    0x2551,
    0x2550,
    0x256C,
    0x2563,
    0x2569,
    0x2560,
    0x2566,
    0x255A,
    0x2554,
    0x2557,
    0x255D,
    0x0000,
    0x0000,
    0x0000,
    0x0000,
    0x0000,
    0x0000,
    0x0000,
    0x0041,
    0x0042,
    0x0043,
    0x0044,
    0x0045,
    0x0046,
    0x0047,
    0x0048,
    0x0049,
    0x004A,
    0x004B,
    0x004C,
    0x004D,
    0x004E,
    0x004F,
    0x0050,
    0x0051,
    0x0052,
    0x0053,
    0x0054,
    0x0055,
    0x0056,
    0x0057,
    0x0058,
    0x0059,
    0x005A,
    0x0000,
    0x0000,
    0x0000,
    0x0000,
    0x0000,
    0x0000,
    0x0061,
    0x0062,
    0x0063,
    0x0064,
    0x0065,
    0x0066,
    0x0067,
    0x0068,
    0x0069,
    0x006A,
    0x006B,
    0x006C,
    0x006D,
    0x006E,
    0x006F,
    0x0070,
    0x0071,
    0x0072,
    0x0073,
    0x0074,
    0x0075,
    0x0076,
    0x0077,
    0x0078,
    0x0079,
    0x007A,
    0x0000,
    0x0000,
    0x0000,
    0x0000,
    0x0000,
    0x0000,
    0x0000,
    0x0000,
    0x0000,
    0x0000,
    0x0000,
    0x0000,
    0x0000,
    0x0000,
    0x0000,
    0x0000,
    0x0000,
    0x0000,
    0x0000,
    0x0000,
    0x0000,
    0x0000,
    0x0000,
    0x0000,
    0x0000,
    0x0000,
    0x0000,
    0x0000,
    0x0000,
    0x0000,
    0x0000,
    0x0000,
    0x0000,
    0x0000,
    0x0000,
    0x0000,
    0x0000,
    0x0000,
    0x0000,
    0x0000,
    0x0000,
    0x0000,
    0x0000,
    0x0000,
    0x0000,
    0x0000,
    0x0000,
    0x0000,
    0x0000,
    0x0000,
    0x0000,
    0x0000,
    0x0000,
    0x0000,
    0x0000,
    0x0000,
    0x0000,
    0x0000,
    0x0000,
    0x0000,
    0x0000,
    0x0000,
    0x0000,
    0x0000,
    0x0000,
    0x0000,
    0x0000,
    0x0000,
    0x0000,
    0x0000,
    0x0000,
    0x0000,
    0x0000,
    0x0000,
    0x0000,
    0x0000,
    0x0000,
    0x0000,
    0x0000,
    0x0000,
    0x0000,
    0x0000,
    0x0000,
    0x0000,
    0x0000,
    0x0000,
    0x0000,
    0x0000,
    0x0000,
    0x0000,
    0x0000,
    0x0000,
    0x0000,
    0x0000,
    0x0000,
    0x0000,
    0x0000,
    0x0000,
    0x0000,
    0x0000,
    0x0000,
    0x0000,
}

----------------------------------------------------------------------------------------------------
-- Console
----------------------------------------------------------------------------------------------------

---@class iw.Console
---@field ptr any TCOD_Console* (ffi.gc-managed)
local Console = {}
Console.__index = Console

--- Finalizer — TCOD_console_delete is idempotent enough for our use.
local function console_finalizer(self)
    if self.ptr ~= nil then
        C.TCOD_console_delete(self.ptr)
        self.ptr = nil
    end
end

--- Create a new console of the given dimensions.
---@param w integer
---@param h integer
---@return iw.Console|nil
---@return string|nil errmsg
function Console.new(w, h)
    local ptr = C.TCOD_console_new(w, h)
    if ptr == nil then
        return nil, "industrialworld.tcod: TCOD_console_new returned NULL"
    end
    local self = setmetatable({}, Console)
    self.ptr = gc.wrap_gc(ptr, function()
        console_finalizer(self)
    end)
    return self, nil
end

--- Console width in cells.
---@return integer
function Console:width()
    return toint(C.TCOD_console_get_width(self.ptr))
end

--- Console height in cells.
---@return integer
function Console:height()
    return toint(C.TCOD_console_get_height(self.ptr))
end

--- Clear the console to its default colors.
function Console:clear()
    C.TCOD_console_clear(self.ptr)
end

--- Set the default background color used by clear()/put_char().
---@param col table|any
function Console:set_default_bg(col)
    C.TCOD_console_set_default_background(self.ptr, to_color(col))
end

--- Set the default foreground color used by clear()/put_char().
---@param col table|any
function Console:set_default_fg(col)
    C.TCOD_console_set_default_foreground(self.ptr, to_color(col))
end

--- Put a Unicode codepoint with explicit fg/bg colors (the modern, non-deprecated path).
---@param x integer
---@param y integer
---@param ch integer Unicode codepoint
---@param fg? table|any TCOD_ColorRGBA-ish, nil = default fg
---@param bg? table|any TCOD_ColorRGBA-ish, nil = default bg
function Console:put_rgb(x, y, ch, fg, bg)
    local fg_c = fg and to_rgba(fg) or nil
    local bg_c = bg and to_rgba(bg) or nil
    -- TCOD_BKGND_SET (1): the bg color replaces the cell's background
    -- outright (solid fill). The C fn's `flag` param was missing from the
    -- cdef before, which left it garbage on the stack and occasionally read
    -- as BKGND_NONE -> backgrounds silently dropped (only the fg glyph drew).
    C.TCOD_console_put_rgb(self.ptr, x, y, ch, fg_c, bg_c, C.TCOD_BKGND_SET)
end

--- Put a codepoint at (x,y) using TCOD_console_put_char_ex with a color pair.
---@param x integer
---@param y integer
---@param ch integer Unicode codepoint
---@param fg? table|any TCOD_color_t-ish
---@param bg? table|any TCOD_color_t-ish
function Console:put_char(x, y, ch, fg, bg)
    C.TCOD_console_put_char_ex(
        self.ptr,
        x,
        y,
        ch,
        to_color(fg or colors.white),
        to_color(bg or colors.black)
    )
end

--- Print a string at (x,y) using the console defaults.
---@param x integer
---@param y integer
---@param str string
function Console:print(x, y, str)
    -- TCOD_console_print is variadic (printf-style); call the n form to
    -- avoid va_list issues from LuaJIT. We have the format string but no
    -- args, so a direct call is fine as long as `str` has no '%'.
    C.TCOD_console_print(self.ptr, x, y, str)
end

--- Blit a sub-rectangle of this console onto another.
---@param x integer source x
---@param y integer source y
---@param w integer source w
---@param h integer source h
---@param dst iw.Console destination console
---@param dst_x integer
---@param dst_y integer
---@param fg_alpha? number default 1.0
---@param bg_alpha? number default 1.0
function Console:blit(x, y, w, h, dst, dst_x, dst_y, fg_alpha, bg_alpha)
    C.TCOD_console_blit(
        self.ptr,
        x,
        y,
        w,
        h,
        dst.ptr,
        dst_x,
        dst_y,
        fg_alpha or 1.0,
        bg_alpha or 1.0
    )
end

--- Free the console immediately, bypassing the GC.
function Console:shutdown()
    console_finalizer(self)
end

----------------------------------------------------------------------------------------------------
-- Tileset
----------------------------------------------------------------------------------------------------

---@class iw.Tileset
---@field ptr any TCOD_Tileset*
local Tileset = {}
Tileset.__index = Tileset

local function tileset_finalizer(self)
    if self.ptr ~= nil then
        C.TCOD_tileset_delete(self.ptr)
        self.ptr = nil
    end
end

--- Load a PNG font as a tileset, passing a charmap table.
--- `charmap` is a 1-based Lua array of codepoints (use `tcod.charmap_cp437`
--- or `tcod.charmap_tcod`). Pass nil to leave tiles unassigned.
---@param filename string
---@param columns integer
---@param rows integer
---@param charmap? integer[] 1-based codepoint array
---@return iw.Tileset|nil
---@return string|nil errmsg
function Tileset.load_font(filename, columns, rows, charmap)
    local n = 0
    local arr = nil
    if charmap then
        n = #charmap
        arr = ffi.new("int[?]", n)
        for i = 1, n do
            arr[i - 1] = charmap[i]
        end
    end
    local ptr = C.TCOD_tileset_load(filename, columns, rows, n, arr)
    if ptr == nil then
        return nil, ffi.string(C.TCOD_get_error())
    end
    local self = setmetatable({}, Tileset)
    self.ptr = gc.wrap_gc(ptr, function()
        tileset_finalizer(self)
    end)
    return self, nil
end

--- Create an empty tileset of the given tile dimensions.
---@param tile_w integer
---@param tile_h integer
---@return iw.Tileset|nil
---@return string|nil errmsg
function Tileset.new(tile_w, tile_h)
    local ptr = C.TCOD_tileset_new(tile_w, tile_h)
    if ptr == nil then
        return nil, "industrialworld.tcod: TCOD_tileset_new returned NULL"
    end
    local self = setmetatable({}, Tileset)
    self.ptr = gc.wrap_gc(ptr, function()
        tileset_finalizer(self)
    end)
    return self, nil
end

-- Tileset.load_font is the canonical loader above. (The older Tileset.load
-- wrapper is intentionally removed in favor of load_font, which mirrors the
-- 1-based Lua charmap convention used by charmap_cp437 / charmap_tcod.)

--- Load a BDF bitmap font directly into a tileset.
--- This is useful for crisp monospace fonts like Terminus that are
--- distributed in BDF form.
---@param path string
---@return iw.Tileset|nil
---@return string|nil errmsg
function Tileset.load_bdf(path)
    local ptr = C.TCOD_load_bdf(path)
    if ptr == nil then
        return nil, ffi.string(C.TCOD_get_error())
    end
    local self = setmetatable({}, Tileset)
    self.ptr = gc.wrap_gc(ptr, function()
        tileset_finalizer(self)
    end)
    return self, nil
end

--- Free the tileset immediately.
function Tileset:shutdown()
    tileset_finalizer(self)
end

----------------------------------------------------------------------------------------------------
-- Context
----------------------------------------------------------------------------------------------------

---@class iw.Context
---@field ptr any TCOD_Context*
local Context = {}
Context.__index = Context

local function context_finalizer(self)
    if self.ptr ~= nil then
        C.TCOD_context_delete(self.ptr)
        self.ptr = nil
    end
end

--- Create a rendering context.
---
--- Options (all optional unless noted):
---   columns / rows       console size in cells
---   pixel_width/height   window size in pixels (alt. to columns/rows)
---   window_title          string
---   vsync                  bool (default true)
---   sdl_window_flags      int (SDL_WindowFlags bitfield)
---   renderer               TCOD_renderer_t value (default TCOD_RENDERER_SDL2)
---   tileset               iw.Tileset (optional)
---@param opts table
---@return iw.Context|nil
---@return string|nil errmsg
function Context.new(opts)
    opts = opts or {}
    local p = ffi.new("TCOD_ContextParams")
    ffi.fill(p, ffi.sizeof("TCOD_ContextParams"), 0)
    p.tcod_version = 0
    p.window_x = 0
    p.window_y = 0
    p.window_xy_defined = false
    p.columns = opts.columns or 0
    p.rows = opts.rows or 0
    p.pixel_width = opts.pixel_width or 0
    p.pixel_height = opts.pixel_height or 0
    p.renderer_type = opts.renderer or 3 -- TCOD_RENDERER_SDL2
    p.tileset = opts.tileset and opts.tileset.ptr or nil
    p.vsync = opts.vsync == nil and 1 or (opts.vsync and 1 or 0)
    p.sdl_window_flags = opts.sdl_window_flags or 0
    p.window_title = opts.window_title or nil
    p.argc = 0
    p.argv = nil
    p.cli_output = nil
    p.cli_userdata = nil
    p.console = nil

    local out = ffi.new("TCOD_Context*[1]")
    local ok, err = check(C.TCOD_context_new(p, out))
    if not ok then
        return nil, err
    end
    local ptr = out[0]
    if ptr == nil then
        return nil, "industrialworld.tcod: TCOD_context_new returned NULL context"
    end
    local self = setmetatable({}, Context)
    self.ptr = gc.wrap_gc(ptr, function()
        context_finalizer(self)
    end)
    return self, nil
end

--- Present a console to the screen.
---@param console iw.Console
---@return boolean|nil ok
---@return string|nil errmsg
function Context:present(console)
    return check(C.TCOD_context_present(self.ptr, console.ptr, nil))
end

--- Save a screenshot.
---@param filename? string
---@return boolean|nil ok
---@return string|nil errmsg
function Context:screenshot(filename)
    return check(C.TCOD_context_save_screenshot(self.ptr, filename))
end

--- Swap the active tileset.
---@param tileset iw.Tileset
---@return boolean|nil ok
---@return string|nil errmsg
function Context:set_tileset(tileset)
    return check(C.TCOD_context_change_tileset(self.ptr, tileset.ptr))
end

--- Get the recommended console size for this context.
---@param magnification? number default 1.0
---@return integer columns, integer rows
function Context:recommended_console_size(magnification)
    local cols = ffi.new("int[1]")
    local rows = ffi.new("int[1]")
    C.TCOD_context_recommended_console_size(self.ptr, magnification or 1.0, cols, rows)
    return toint(cols[0]), toint(rows[0])
end

--- Free the context immediately. Also tears down SDL as a side effect.
function Context:shutdown()
    context_finalizer(self)
end

----------------------------------------------------------------------------------------------------
-- Events
----------------------------------------------------------------------------------------------------

--- Wait for an event matching the mask. Returns the event_t value plus the
--- populated key/mouse structs (both are fresh cdata each call).
--- Pass flush=true to discard the pending input queue first.
---@param mask integer TCOD_EVENT_* bitfield
---@param flush? boolean
---@return integer event_t
---@return any key TCOD_key_t cdata
---@return any mouse TCOD_mouse_t cdata
local function wait_for_event(mask, flush)
    local key = ffi.new("TCOD_key_t")
    local mouse = ffi.new("TCOD_mouse_t")
    local ev = toint(C.TCOD_sys_wait_for_event(mask, key, mouse, flush and true or false))
    return ev, key, mouse
end

--- Non-blocking check for an event matching the mask.
---@param mask integer TCOD_EVENT_* bitfield
---@return integer event_t
---@return any key TCOD_key_t cdata
---@return any mouse TCOD_mouse_t cdata
local function check_for_event(mask)
    local key = ffi.new("TCOD_key_t")
    local mouse = ffi.new("TCOD_mouse_t")
    local ev = toint(C.TCOD_sys_check_for_event(mask, key, mouse))
    return ev, key, mouse
end

----------------------------------------------------------------------------------------------------
-- Module export
----------------------------------------------------------------------------------------------------

return {
    -- RAII classes
    Console = Console,
    Tileset = Tileset,
    Context = Context,

    -- Color helpers / palette
    colors = colors,
    to_color = to_color,
    to_rgba = to_rgba,

    -- Enum mirrors (for ergonomics in Lua)
    bkgnd_none = 0,
    bkgnd_set = 1,
    bkgnd_default = 13,
    alignment_left = 0,
    alignment_right = 1,
    alignment_center = 2,

    -- Renderer enum values
    renderer_gls = 0,
    renderer_opengl = 1,
    renderer_sdl = 2,
    renderer_sdl2 = 3,
    renderer_opengl2 = 4,

    -- Error enum
    e_ok = 0,
    e_error = -1,

    -- Event masks
    event_none = 0,
    event_key_press = 1,
    event_key_release = 2,
    event_key = 3,
    event_mouse_move = 4,
    event_mouse = 28,
    event_any = 255,

    -- Key codes (TCOD_keycode_t). Use as `tcod.key.up`, etc.
    key = {
        none = 0,
        escape = 1,
        backspace = 2,
        tab = 3,
        enter = 4,
        shift = 5,
        control = 6,
        alt = 7,
        pause = 8,
        capslock = 9,
        pageup = 10,
        pagedown = 11,
        end_ = 12,
        home = 13,
        up = 14,
        left = 15,
        right = 16,
        down = 17,
    },

    -- Event loop
    wait_for_event = wait_for_event,
    check_for_event = check_for_event,

    -- Character maps (for Tileset.load_font)
    charmap_cp437 = charmap_cp437,
    charmap_tcod = charmap_tcod,
}
