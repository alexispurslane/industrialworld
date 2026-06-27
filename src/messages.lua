--- Message log UI — a thin consumer of the event bus.
---
--- A singleton module holding a ring buffer of recent human-readable
--- game messages and a `draw(console)` that paints them into a reserved
--- bottom panel of the root console. Systems that *know* the narrative
--- context (e.g. Stairs knows its climb direction; future combat knows
--- the damage dealt) emit a `message` event:
---
---     bus.emit("message", "You climb up.", {r=230,g=200,b=60})
---
--- This module subscribes to `message` and renders. It knows nothing
--- about Stairs, combat, or any other system — it is purely a message
--- sink + renderer, which keeps narration localized to the system that
--- has the context (per the mixin/capability philosophy: cross-cutting
--- prose doesn't belong in a generic mixin).
---
--- Layout: the bottom PANEL_H rows of the console are reserved. The
--- topmost reserved row is a box-drawing rule (─); the remaining rows
--- show messages bottom-aligned (newest at the bottom), with older
--- messages dimmed toward the panel background so the freshest entry
--- reads brightest. Consecutive IDENTICAL messages (same text) collapse
--- into one entry with a " xN" repeat counter, so a spammy source never
--- floods the panel.
---
--- To keep the map centered in the VISIBLE map region (above this
--- panel), `main.lua` sets `cam.view_rows = con:height() - PANEL_H`
--- each frame; render_map and the entity draws read `cam.view_rows`
--- (falling back to the full console height) for their centering + cull.
--- This module only owns the panel; it does NOT touch the map viewport
--- math itself.

local bus = require("event")
local log = require("log")
local L = log.get("messages")

-- Panel geometry. PANEL_H rows reserved at the bottom; the topmost is
-- the rule line, the rest are message rows. Together: 1 rule + (PANEL_H-1)
-- visible messages.
local PANEL_H = 7

-- Ring-buffer cap. We keep far more than we show so a burst of messages
-- isn't lost before the player can read them (older ones scroll off the
-- top of the panel but stay in the buffer for a future scrollback).
local MAX = 128

-- Per-age dimming. The newest entry is full brightness; each row up the
-- panel the previous message fades by DIM_PER_ROW, floored at MIN_BRIGHT
-- so the oldest visible entry still reads as a faint echo rather than
-- dropping into the panel bg.
local DIM_PER_ROW = 0.14
local MIN_BRIGHT = 0.42

-- Panel + rule colors.
local PANEL_BG = { r = 12, g = 14, b = 20 }
local RULE_FG = { r = 70, g = 75, b = 90 }
local DEFAULT_FG = { r = 220, g = 220, b = 225 }
-- Color dimmed entries lerp toward (matches the panel bg-ish dark).
local DIM_TARGET = { r = 24, g = 26, b = 34 }

local messages = {
    PANEL_H = PANEL_H,
}

-- The ring buffer: array of {text=, fg=, count=}. Newest is at the end.
local buf = {}

--- Add (or stack) a message. If the new text equals the current newest
--- entry's text, its repeat count is bumped instead of appending a dup,
--- so a spammy source reads as a single line "msg xN". Thread-safe
--- enough for our single-threaded sim.
---@param text string
---@param fg? table  {r=,g=,b=} default light gray.
function messages.add(text, fg)
    if text == nil or text == "" then
        return
    end
    local last = buf[#buf]
    if last ~= nil and last.text == text then
        last.count = last.count + 1
    else
        buf[#buf + 1] = { text = text, fg = fg or DEFAULT_FG, count = 1 }
        if #buf > MAX then
            table.remove(buf, 1)
        end
    end
    L:debug("add: %q", text)
end

--- Lerp `c` toward `target` by factor `t` (0 = c, 1 = target).
---@param c table
---@param target table
---@param t number
---@return table
local function lerp_color(c, target, t)
    return {
        r = math.floor(c.r + (target.r - c.r) * t),
        g = math.floor(c.g + (target.g - c.g) * t),
        b = math.floor(c.b + (target.b - c.b) * t),
    }
end

--- Draw a single string at (x, y) with the given fg + panel bg, char by
--- char via put_serif (so we control per-message color + the message
--- font). Full cellsize (one line per cell row), matching the tiles.
--- Truncates to `maxw` cells. Byte-length truncation is fine here — all
--- current messages are ASCII.
---@param con iw.Console
---@param x integer
---@param y integer
---@param str string
---@param fg table
---@param maxw integer
local function draw_line(con, x, y, str, fg, maxw)
    local n = #str
    if n > maxw then
        n = maxw
    end
    for i = 1, n do
        local ch = str:byte(i)
        con:put_serif(x + i - 1, y, ch, fg, PANEL_BG)
    end
end

--- Paint the panel: a rule line across the top reserved row, then the
--- last (PANEL_H-1) buffered messages bottom-aligned (newest at the
--- bottom) drawn in the sans-serif message font at full cellsize.
--- Older visible messages are dimmed toward DIM_TARGET by age. Any cells
--- in the panel not covered by a message row are filled with the panel bg
--- so stray map/entity glyphs from the map pass don't bleed through (the
--- panel is drawn LAST in the frame, over the map).
---@param con iw.Console
function messages.draw(con)
    local W = con:width()
    local H = con:height()
    local top = H - PANEL_H -- index of the rule row
    local msg_rows = PANEL_H - 1 -- rows below the rule

    -- Rule line across the top of the panel (─ = U+2500 = 0x2500).
    for x = 0, W - 1 do
        con:put_rgb(x, top, 0x2500, RULE_FG, PANEL_BG)
    end

    -- Fill message rows with the panel bg first (clears any bleed-through).
    for y = top + 1, H - 1 do
        for x = 0, W - 1 do
            con:put_rgb(x, y, 32, RULE_FG, PANEL_BG) -- space, bg fill
        end
    end

    -- Paint messages bottom-up: newest at y = H-1, older above.
    local n = #buf
    if n == 0 then
        return
    end
    local start = n - msg_rows + 1
    if start < 1 then
        start = 1
    end
    local row = H - 1
    local age = 0 -- 0 = newest shown
    for i = n, start, -1 do
        local m = buf[i]
        local line = m.text
        if m.count > 1 then
            line = line .. (" x%d"):format(m.count)
        end
        local dim = math.max(MIN_BRIGHT, 1.0 - age * DIM_PER_ROW)
        local fg = lerp_color(m.fg, DIM_TARGET, 1.0 - dim)
        draw_line(con, 1, row, line, fg, W - 2)
        row = row - 1
        age = age + 1
        if row <= top then
            break
        end
    end
end

--- Subscribe to the `message` event on the bus. Systems emit
--- `bus.emit("message", text, fg)` and this routes it into the buffer.
--- Called once at startup from main.lua (after the bus exists).
function messages.init()
    bus.on("message", function(text, fg)
        messages.add(text, fg)
    end)
    L:debug("init: subscribed to 'message' (panel_h=%d)", PANEL_H)
end

return messages
