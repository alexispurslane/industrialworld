--- Screen-space bounds mixin for UI widgets.
---
--- Stores screen_x/screen_y/screen_w/screen_h and provides `_contains`
--- for the widget registry's hit-testing.

local ScreenRect = {}

function ScreenRect:init(x, y, w, h)
    assert(type(x) == "number", "ScreenRect.init: x must be a number")
    assert(type(y) == "number", "ScreenRect.init: y must be a number")
    assert(type(w) == "number", "ScreenRect.init: w must be a number")
    assert(type(h) == "number", "ScreenRect.init: h must be a number")
    self.screen_x = x
    self.screen_y = y
    self.screen_w = w
    self.screen_h = h
end

function ScreenRect:_contains(pos)
    return pos.x >= self.screen_x
        and pos.x < self.screen_x + self.screen_w
        and pos.y >= self.screen_y
        and pos.y < self.screen_y + self.screen_h
end

return ScreenRect
