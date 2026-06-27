--- Hover-state mixin for UI widgets.
---
--- Subscribes the widget to the targeted `widget:hover` event. When the
--- dispatcher chooses this widget, the mixin updates `self.hovered` and
--- calls a host handler:
---   * `self:on_hover(x, y, state)` -- preferred, knows cursor position.
---   * `self:on_hover_changed(state)` -- fallback for state-only reactions.

local bus = require("event")

local Hoverable = {}

function Hoverable:init()
    assert(
        self.screen_x ~= nil and self.screen_y ~= nil,
        "Hoverable.init: widget must have screen_x and screen_y"
    )
    self.hovered = false
    self._hoverable = true
    bus.subscribe(self, "widget:hover", function(p)
        if p.widget ~= self then
            return
        end
        self:_set_hover(p.state, p.x, p.y)
    end)
end

function Hoverable:_set_hover(state, x, y)
    if self.hovered == state then
        return
    end
    self.hovered = state
    if self.on_hover then
        self:on_hover(x or 0, y or 0, state)
    elseif self.on_hover_changed then
        self:on_hover_changed(state)
    end
end

return Hoverable
