--- Scrollable multi-line text panel widget archetype.

local Widget = require("widget")
local ScreenRect = require("mixins.ui.screen_rect")
local TextPanelMixin = require("mixins.ui.text_panel")
local palette = require("palette")

---@class TextPanel
---@field lines table[]
---@field max_lines integer
---@field scroll integer
---@field stick_to_bottom boolean
---@field panel_bg table
---@field default_fg table
---@field screen_x integer
---@field screen_y integer
---@field screen_w integer
---@field screen_h integer
---@field con iw.Console
---@field add_line fun(self: TextPanel, text: string, fg?: table)
---@field scroll_to_bottom fun(self: TextPanel)
local TextPanelWidget, super = class("TextPanel", Widget):mixin(ScreenRect, TextPanelMixin)

function TextPanelWidget:init(con, x, y, w, h, event_name, max_lines)
    self.con = con
    super.init(self)
    ScreenRect.init(self, x, y, w, h)
    TextPanelMixin.init(self, event_name, max_lines)
    self.panel_bg = self.panel_bg or palette.soot
end

return TextPanelWidget
