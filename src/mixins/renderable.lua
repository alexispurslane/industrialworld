--- Renderable mixin (pure leaf).
---
--- Visual appearance: a foreground/background color pair plus one or more
--- glyphs (unicode codepoints). Supports multi-tile entities: each glyph
--- carries a local cell offset `(dx, dy)`, so a 2x2 monster or a wide
--- tree is just four glyphs at (0,0),(1,0),(0,1),(1,1).
---
--- Pure leaf (law 1/2): knows nothing of Position or other mixins.
--- `draw(console, x, y)` takes a world position as a parameter — it does
--- NOT read `self.x`/`self.y`. This is what makes Renderable reusable for
--- non-entity appearance (e.g. tile-type → appearance registry entries,
--- which have no position). For an entity that draws itself in place, use
--- the composed `Drawable` mixin (Position + Renderable).
---
--- Glyph specs accepted by `init`'s `glyphs` arg:
---   * string        -> each codepoint becomes a glyph at (i, 0)
---   * integer       -> single glyph at (0, 0)
---   * list          -> { {dx=,dy=,ch=,fg=,bg=}, ... }
--- A glyph's `ch` may be a string (first codepoint) or an integer
--- codepoint. Per-glyph `fg`/`bg` override the mixin defaults.

local Renderable = {}

--- Decode a UTF-8 string into a list of integer codepoints.
---@param s string
---@return integer[]
local function utf8_decode(s)
    local cps = {}
    local i = 1
    while i <= #s do
        local b = string.byte(s, i)
        local cp, n
        if b < 0x80 then
            cp, n = b, 1
        elseif b < 0xC0 then
            -- stray continuation byte; emit replacement and resync
            cp, n = 0xFFFD, 1
        elseif b < 0xE0 then
            cp = (b - 0xC0) * 64 + (string.byte(s, i + 1) - 0x80)
            n = 2
        elseif b < 0xF0 then
            cp = (b - 0xE0) * 4096
                + (string.byte(s, i + 1) - 0x80) * 64
                + (string.byte(s, i + 2) - 0x80)
            n = 3
        else
            cp = (b - 0xF0) * 262144
                + (string.byte(s, i + 1) - 0x80) * 4096
                + (string.byte(s, i + 2) - 0x80) * 64
                + (string.byte(s, i + 3) - 0x80)
            n = 4
        end
        cps[#cps + 1] = cp
        i = i + n
    end
    return cps
end

--- Coerce a glyph's `ch` (string or integer) to an integer codepoint.
---@param ch string|integer
---@return integer
local function to_codepoint(ch)
    if type(ch) == "number" then
        return ch
    end
    if type(ch) == "string" then
        local cps = utf8_decode(ch)
        return cps[1] or string.byte("?")
    end
    error("Renderable: glyph ch must be a string or integer codepoint", 2)
end

--- Normalize a glyph spec into a list of {dx,dy,ch,fg,bg} tables.
---@param spec string|integer|table
---@return table[]
local function normalize_glyphs(spec)
    if type(spec) == "string" then
        local cps = utf8_decode(spec)
        local out = {}
        for i, cp in ipairs(cps) do
            out[i] = { dx = i - 1, dy = 0, ch = cp }
        end
        return out
    end
    if type(spec) == "number" then
        return { { dx = 0, dy = 0, ch = spec } }
    end
    if type(spec) == "table" then
        local out = {}
        for i, item in ipairs(spec) do
            out[i] = {
                dx = item.dx or 0,
                dy = item.dy or 0,
                ch = to_codepoint(item.ch),
                fg = item.fg,
                bg = item.bg,
            }
        end
        return out
    end
    error("Renderable.init: glyphs must be a string, integer, or list", 2)
end

--- Initialize appearance. Defaults: white-on-black, single "?" glyph.
---@param fg? table  {r=,g=,b=} default foreground.
---@param bg? table  {r=,g=,b=} default background.
---@param glyphs? string|integer|table  Glyph spec (see file header).
function Renderable:init(fg, bg, glyphs)
    self.fg = fg or { r = 255, g = 255, b = 255 }
    self.bg = bg or { r = 0, g = 0, b = 0 }
    self.glyphs = normalize_glyphs(glyphs or "?")
end

--- Render all glyphs onto `console` at world `(x, y)`, rounding to the
--- nearest cell. Each glyph's per-cell fg/bg (if set) overrides the
--- mixin defaults; nil falls back to `console` defaults via put_char.
--- Position is a PARAMETER (pure leaf — does not read self.x/self.y).
---@param console iw.Console
---@param x number  World x (cells).
---@param y number  World y (cells).
function Renderable:draw(console, x, y)
    local x0 = math.floor(x + 0.5)
    local y0 = math.floor(y + 0.5)
    for _, g in ipairs(self.glyphs) do
        console:put_char(x0 + g.dx, y0 + g.dy, g.ch, g.fg or self.fg, g.bg or self.bg)
    end
end

return Renderable
