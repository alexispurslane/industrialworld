--- industrialworld.blt: high-level BearLibTerminal bindings.
---
--- Replaces the old industrialworld.tcod wrapper. BearLibTerminal is an
--- immediate-mode, layer-based terminal: there is one global scene (not a
--- console buffer you blit), you set the active layer + colors then put
--- glyphs, and `terminal_refresh()` flips the whole scene at once.
---
--- To keep the existing call sites (which were written against libtcod's
--- console-buffer model) readable, this module exposes a Console shim that
--- caches the active fg/bg and forwards put_rgb/print to BLT's global scene
--- on layer 0. The messages panel and any future layered UI draw on higher
--- layers via terminal.layer() directly.
---
--- Fonts: BLT loads TrueType at runtime. We configure TWO tilesets at
--- disjoint Unicode ranges in init():
---   • DejaVuSansMono at the base codepoints  → crisp AA monospace tiles
---   • DejaVuSerif   at 0xE000+ (Private Use) → serif text for messages
--- A put(x,y,code) resolves whichever tileset owns that codepoint.
---
--- Color: BLT color_t is uint32 ARGB (0xAARRGGBB). We pack in Lua.

local ffi = require("ffi")
local bit = require("bit")
local C = require("industrialworld.blt_ffi")

----------------------------------------------------------------------------------------------------
-- Color
----------------------------------------------------------------------------------------------------

--- Pack {r,g,b,a?} → BLT ARGB uint32 (a defaults to 255).
---@param c table|integer {r=,g=,b=,a=} or an already-packed color_t
---@return integer
local function to_color(c)
    if type(c) == "number" then
        return c
    end
    local a = c.a or 255
    return bit.bor(bit.lshift(a, 24), bit.lshift(c.r or 0, 16), bit.lshift(c.g or 0, 8), c.b or 0)
end

--- Named 0xRRGGBB colors (opaque). Pass to any color-taking function.
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

----------------------------------------------------------------------------------------------------
-- Lifecycle + configuration
----------------------------------------------------------------------------------------------------

--- Open the terminal window. Must be called once before any draw call.
---@return boolean ok
local function open()
    return C.terminal_open() ~= 0
end

--- Close the terminal + tear down BLT's global state.
local function close()
    C.terminal_close()
end

--- Apply a BLT configuration string (fonts, window size, etc.).
--- e.g. set("window.title='iw'; window.size=80x50")
---@param cfg string
---@return boolean ok
local function set(cfg)
    return C.terminal_set8(cfg) ~= 0
end

--- Swap the active font/tileset by config string.
---@param name string
local function font(name)
    C.terminal_font8(name)
end

----------------------------------------------------------------------------------------------------
-- Console shim
----------------------------------------------------------------------------------------------------

--- A Console is a thin handle over BLT's global scene, caching the active
--- fg/bg so put_rgb/put_char/print read like the old libtcod buffer API.
--- Drawing targets layer 0 (the background+bglayer) unless layer() is set.
---@class iw.Console
---@field w integer logical width (cells)
---@field h integer logical height (cells)
---@field _fg integer current foreground (packed)
---@field _bg integer current background (packed)
local Console = {}
Console.__index = Console

--- Create a console shim of the given dimensions. In BLT the window size is
--- set via init()'s config string; this just records the logical size so
--- width()/height() keep working for centering math.
---@param w integer
---@param h integer
---@return iw.Console
function Console.new(w, h)
    local self = setmetatable({}, Console)
    self.w = w
    self.h = h
    self._fg = to_color(colors.white)
    self._bg = to_color(colors.black)
    return self
end

--- Console width in cells.
---@return integer
function Console:width()
    return self.w
end

--- Console height in cells.
---@return integer
function Console:height()
    return self.h
end

--- Set the default background color (used by clear + put_rgb bg fill).
---@param col table|integer
function Console:set_default_bg(col)
    self._bg = to_color(col)
end

--- Set the default foreground color (used by put_char/print).
---@param col table|integer
function Console:set_default_fg(col)
    self._fg = to_color(col)
end

--- Clear the whole scene to the default background. Clears layer 0 only;
--- higher layers (messages panel etc.) manage their own clearing.
function Console:clear()
    C.terminal_bkcolor(self._bg)
    C.terminal_clear()
end

--- Put a Unicode codepoint with explicit fg/bg on the given layer.
--- BLT put() sets the cell background via the current bkcolor, so we set
--- it per-call to honor `bg` exactly (BKGND_SET semantics).
--- Layer 0 carries bg+fg; layers >=1 are fg-only (BLT ignores bkcolor
--- there), so an entity drawn on layer 1 with no bg composites
--- transparently over whatever tile bg layer 0 painted.
---@param x integer
---@param y integer
---@param ch integer Unicode codepoint
---@param fg? table|integer packed-ish color, nil = default fg
---@param bg? table|integer packed-ish color, nil = default bg
---@param layer? integer  BLT layer index (default 0 = map/tiles)
function Console:put_rgb(x, y, ch, fg, bg, layer)
    C.terminal_layer(layer or 0)
    if bg then
        C.terminal_bkcolor(to_color(bg))
    else
        C.terminal_bkcolor(self._bg)
    end
    if fg then
        C.terminal_color(to_color(fg))
    else
        C.terminal_color(self._fg)
    end
    C.terminal_put(x, y, ch)
end

--- Put an ASCII byte drawn with the sans-serif message font (DejaVuSans
--- loaded at offset 0xE000, full cellsize). We remap the ASCII codepoint
--- into the Private Use Area so BLT's global codespace resolves the glyph
--- to the message font instead of the base mono tileset. Non-ASCII
--- codepoints (< 0x20 or >= 0x7F) fall through unchanged.
---@param x integer
---@param y integer
---@param ch integer ASCII codepoint (0x20–0x7E)
---@param fg? table|integer
---@param bg? table|integer
function Console:put_serif(x, y, ch, fg, bg)
    if ch >= 0x20 and ch < 0x7F then
        ch = 0xE000 + ch
    end
    self:put_rgb(x, y, ch, fg, bg)
end

--- Put a codepoint at (x,y) with an fg/bg color pair (put_char shape).
---@param x integer
---@param y integer
---@param ch integer Unicode codepoint
---@param fg? table|integer
---@param bg? table|integer
---@param layer? integer  BLT layer index (default 0)
function Console:put_char(x, y, ch, fg, bg, layer)
    self:put_rgb(x, y, ch, fg, bg, layer)
end

--- Print a UTF-8 string at (x,y) with the current defaults.
---@param x integer
---@param y integer
---@param str string
function Console:print(x, y, str)
    C.terminal_color(self._fg)
    C.terminal_bkcolor(self._bg)
    C.terminal_layer(0)
    local out_w = ffi.new("int[1]")
    local out_h = ffi.new("int[1]")
    C.terminal_print_ext8(x, y, 0, 0, 0, str, out_w, out_h) -- 0 = TK_ALIGN_DEFAULT
end

--- Flip the scene to the screen.
function Console:refresh()
    C.terminal_refresh()
end

-- No-op: BLT owns the scene; shutdown is handled by close() at process exit.
function Console:shutdown() end

----------------------------------------------------------------------------------------------------
-- Input
------------------------------------------------------------------------------------------------------

--- Non-blocking: is there a pending input event?
---@return boolean
local function has_input()
    return C.terminal_has_input() ~= 0
end

--- Non-blocking: peek the next input code without removing it.
---@return integer code  (0 if none)
local function peek()
    return C.terminal_peek()
end

--- Blocking: read + dequeue the next input code.
---@return integer code
local function read()
    return C.terminal_read()
end

--- Query a terminal state (e.g. TK_WIDTH, TK_MOUSE_X).
---@param code integer
---@return integer
local function state(code)
    return C.terminal_state(code)
end

--- Sleep for `ms` milliseconds (BLT's portable delay).
---@param ms integer
local function delay(ms)
    C.terminal_delay(ms)
end

----------------------------------------------------------------------------------------------------
-- Module export
------------------------------------------------------------------------------------------------------

return {
    -- lifecycle
    open = open,
    close = close,
    set = set,
    font = font,
    refresh = function()
        C.terminal_refresh()
    end,
    clear = function()
        C.terminal_clear()
    end,
    layer = function(i)
        C.terminal_layer(i)
    end,
    composition = function(on)
        C.terminal_composition(on and 1 or 0)
    end,

    -- BLT layer conventions: 0 = map tiles (bg+fg, opaque), 1 = entities
    -- (fg-only, transparent — the tile bg on layer 0 shows through).
    LAYER_MAP = 0,
    LAYER_ENTITY = 1,

    -- color
    colors = colors,
    to_color = to_color,

    -- Console shim
    Console = Console,

    -- input
    has_input = has_input,
    peek = peek,
    read = read,
    state = state,
    delay = delay,

    -- layout constants (TK_* mirrors of BearLibTerminal.h)
    align_left = 1,
    align_right = 2,
    align_center = 3,
    align_top = 4,
    align_bottom = 8,
    align_middle = 12,

    -- composition modes
    off = 0,
    on = 1,

    -- state codes
    tk_width = 0xC0,
    tk_height = 0xC1,
    tk_cell_width = 0xC2,
    tk_cell_height = 0xC3,
    tk_char = 0xC8,
    tk_wchar = 0xC9,

    -- input codes (the ones main.lua maps)
    tk_escape = 0x29,
    tk_return = 0x28,
    tk_enter = 0x28,
    tk_backspace = 0x2A,
    tk_tab = 0x2B,
    tk_space = 0x2C,
    tk_up = 0x52,
    tk_down = 0x51,
    tk_left = 0x50,
    tk_right = 0x4F,
    tk_pageup = 0x4B,
    tk_pagedown = 0x4E,
    tk_home = 0x4A,
    tk_end = 0x4D,
    tk_close = 0xE0,
    tk_key_released = 0x100,
}
