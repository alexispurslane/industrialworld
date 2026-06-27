--- Text-label rendering mixin for UI widgets.
---
--- Draws `self.text` at (screen_x, screen_y) in the sans-serif UI font.
--- Requires `self.con` to be set by the archetype before `draw()`.

local palette = require("palette")

local Label = {}

function Label:init(text, fg)
    assert(
        self.screen_x ~= nil and self.screen_y ~= nil,
        "Label.init: widget must have screen_x and screen_y"
    )
    assert(type(text) == "string", "Label.init: text must be a string")
    self.text = text
    self.fg = fg or palette.text
    self.screen_w = self.screen_w or #text
    self.screen_h = self.screen_h or 1
end

function Label:draw()
    assert(self.con ~= nil, "Label.draw: widget must have self.con")
    self.con:print_serif(self.screen_x, self.screen_y, self.text, self.fg)
end

return Label
