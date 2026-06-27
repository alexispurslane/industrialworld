--- Scrollable multi-line text panel widget archetype.

local Widget = require("widget")
local ScreenRect = require("mixins.ui.screen_rect")
local TextPanelMixin = require("mixins.ui.text_panel")
local palette = require("palette")

local TextPanelWidget, super = class("TextPanel", Widget):mixin(ScreenRect, TextPanelMixin)

function TextPanelWidget:init(con, x, y, w, h, event_name, max_lines)
    self.con = con
    super.init(self)
    ScreenRect.init(self, x, y, w, h)
    TextPanelMixin.init(self, event_name, max_lines)
    self.panel_bg = self.panel_bg or palette.soot
end

return TextPanelWidget
