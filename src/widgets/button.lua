--- Clickable text-button widget archetype.

local Widget = require("widget")
local ScreenRect = require("mixins.ui.screen_rect")
local Hoverable = require("mixins.ui.hoverable")
local Clickable = require("mixins.ui.clickable")
local Label = require("mixins.ui.label")
local palette = require("palette")

local Button, super = class("Button", Widget):mixin(ScreenRect, Hoverable, Clickable, Label)

function Button:init(con, x, y, text, callback, fg, fg_hover)
    self.con = con
    super.init(self)
    ScreenRect.init(self, x, y, #text, 1)
    Label.init(self, text, fg or palette.text)
    Hoverable.init(self)
    Clickable.init(self)
    self._click_handler = callback
    self.fg_normal = self.fg
    self.fg_hover = fg_hover or palette.safety_yellow
end

function Button:on_hover_changed(state)
    self.fg = state and self.fg_hover or self.fg_normal
end

function Button:on_click(x, y, button)
    if self._click_handler then
        self._click_handler(x, y, button)
    end
end

function Button:draw()
    Label.draw(self)
end

return Button
