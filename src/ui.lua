--- High-level UI widget constructors.
---
--- The low-level machinery lives in src/widget.lua (lifecycle + registry)
--- and src/mixins/ui/*.lua (capabilities). Concrete widget archetypes live
--- in src/widgets/*.lua. This module just exposes the stable factory
--- functions the screens already use.

local Button = require("widgets.button")
local ProgressBar = require("widgets.progress_bar")
local TextPanel = require("widgets.text_panel")

local ui = {}

--- Create a clickable text button.
---@param con iw.Console
---@param x integer
---@param y integer
---@param text string
---@param callback fun(pos: table)
---@param fg? table
---@param fg_hover? table
---@return Button
function ui.button(con, x, y, text, callback, fg, fg_hover)
    return Button(con, x, y, text, callback, fg, fg_hover)
end

--- Create a progress bar.
---@param con iw.Console
---@param id string|number
---@param x integer
---@param y integer
---@param width integer
---@param bg? table
---@param fill_bg? table
---@return ProgressBar
function ui.progress_bar(con, id, x, y, width, bg, fill_bg)
    return ProgressBar(con, id, x, y, width, bg, fill_bg)
end

--- Create a scrollable multi-line text panel that listens for lines on
--- `event_name` (emitted as `bus.emit(event_name, text, fg)`).
---@param con iw.Console
---@param x integer
---@param y integer
---@param w integer
---@param h integer
---@param event_name string
---@param max_lines? integer
---@return TextPanel
function ui.text_panel(con, x, y, w, h, event_name, max_lines)
    return TextPanel(con, x, y, w, h, event_name, max_lines)
end

return ui
