--- Click-dispatch mixin for UI widgets.
---
--- Subscribes the widget to the targeted `widget:click` event chosen by
--- the dispatcher. When this widget is chosen, it calls a host handler:
---   * `self:on_click(x, y, button)` -- preferred, defined on archetype.
---   * `self._click_handler(x, y, button)` -- fallback closure stored in init.

local bus = require("event")

local Clickable = {}

function Clickable:init()
    assert(self.screen_x ~= nil and self.screen_y ~= nil,
        "Clickable.init: widget must have screen_x and screen_y")
    assert(self._contains ~= nil,
        "Clickable.init: widget must have a _contains method (use ScreenRect)")
    self._clickable = true
    bus.subscribe(self, "widget:click", function(p)
        if p.widget ~= self then
            return
        end
        if self.on_click then
            self:on_click(p.x, p.y, p.button)
        elseif self._click_handler then
            self._click_handler(p.x, p.y, p.button)
        end
    end)
end

return Clickable
