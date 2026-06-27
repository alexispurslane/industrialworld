--- Message-log widget: a TextPanel subclass with dedup, age-dimming, and a
--- top rule line. Identity-specific behavior (collapsing repeats, tinting
--- older lines by age, drawing the divider) lives here, not in the generic
--- TextPanel mixin.

local TextPanelWidget = require("widgets.text_panel")
local Anchor = require("mixins.ui.anchor")
local palette = require("palette")

-- Per-age dimming. Row 0 (top of panel) is the oldest visible line; the
-- bottom row is the newest. `age` is distance from the bottom.
local DIM_PER_ROW = 0.14
local MIN_BRIGHT = 0.42

local RULE_FG = palette.graphite
local PANEL_BG = palette.soot
local DEFAULT_FG = palette.text
local DIM_TARGET = palette.panel_dim

local function lerp_color(c, target, t)
    return {
        r = math.floor(c.r + (target.r - c.r) * t),
        g = math.floor(c.g + (target.g - c.g) * t),
        b = math.floor(c.b + (target.b - c.b) * t),
    }
end

local MessageLog, super = class("MessageLog", TextPanelWidget):mixin(Anchor)

function MessageLog:init(con, visible_rows, event_name, max_lines)
    -- Position (0,0) is a placeholder; the Anchor mixin repositions to the
    -- screen bottom on every update. Width spans the screen.
    super.init(self, con, 0, 0, con:width(), visible_rows, event_name, max_lines)
    Anchor.init(self, "screen", "bottom", "start")
    self.panel_bg = PANEL_BG
    self.default_fg = DEFAULT_FG
end

--- Collapse consecutive identical messages into one entry with a repeat
--- counter instead of appending a duplicate line.
---@param text string
---@param fg? table
function MessageLog:add_line(text, fg)
    if text == nil or text == "" then
        return
    end
    local lines = self.lines
    local last = lines[#lines]
    if last ~= nil and last.text == text then
        last.count = last.count + 1
        if self.stick_to_bottom then
            self:scroll_to_bottom()
        end
        return
    end
    -- Append via the generic TextPanel add, then stamp a count on the new
    -- entry so line_text can render the "xN" suffix.
    super.add_line(self, text, fg)
    lines[#lines].count = 1
end

function MessageLog:line_text(entry, row, visible_rows)
    if entry.count and entry.count > 1 then
        return entry.text .. (" x%d"):format(entry.count)
    end
    return entry.text
end

function MessageLog:line_color(entry, row, visible_rows)
    local age = (visible_rows - 1) - row
    local dim = math.max(MIN_BRIGHT, 1.0 - age * DIM_PER_ROW)
    return lerp_color(entry.fg or self.default_fg, DIM_TARGET, 1.0 - dim)
end

--- Draw the rule line across the row above the panel, then render the
--- panel itself.
---@param con? iw.Console
function MessageLog:draw(con)
    con = con or self.con
    local rule_y = self.screen_y - 1
    if rule_y >= 0 then
        for x = 0, self.screen_w - 1 do
            con:put_rgb(self.screen_x + x, rule_y, 0x2500, RULE_FG, PANEL_BG, 0)
        end
    end
    super.draw(self, con)
end

return MessageLog
