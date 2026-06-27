--- Filled-bar rendering mixin for UI widgets.
---
--- Draws a percentage bar as filled background cells on layer 0. The
--- filled portion uses `bar_fill`; the empty portion uses `bar_bg`.
--- Update `self.percent` via `set_percent(p)` and call `draw()`.

local palette = require("palette")

local ProgressFill = {}

function ProgressFill:init(width, bg, fill_bg)
    assert(
        self.screen_x ~= nil and self.screen_y ~= nil,
        "ProgressFill.init: widget must have screen_x and screen_y"
    )
    assert(type(width) == "number", "ProgressFill.init: width must be a number")
    self.bar_width = width
    self.percent = 0
    self.bar_bg = bg or palette.panel_dim
    self.bar_fill = fill_bg or palette.safety_yellow
    self.screen_w = self.screen_w or width
    self.screen_h = self.screen_h or 1
end

function ProgressFill:set_percent(p)
    self.percent = math.max(0, math.min(100, tonumber(p) or 0))
end

function ProgressFill:draw()
    assert(self.con ~= nil, "ProgressFill.draw: widget must have self.con")
    local filled = math.floor(self.percent / 100 * self.bar_width + 0.5)
    for i = 0, self.bar_width - 1 do
        local col = self.screen_x + i
        local cell_bg = i < filled and self.bar_fill or self.bar_bg
        -- Space glyph; the bg is the visible bar.
        self.con:put_rgb(col, self.screen_y, 32, self.bar_bg, cell_bg, 0)
    end
end

return ProgressFill
