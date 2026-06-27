--- Scrollable multi-line text panel mixin for UI widgets.
---
--- Assumes ScreenRect (screen_x/y/w/h + `_contains`). Stores a list of
--- lines and renders the visible window into it. New lines are added via
--- an event the panel subscribes to in `init`:
---
---     local Panel = require("widgets.text_panel")
---     local p = Panel(con, "log", 0, 40, 80, 7, "message")
---     bus.emit("message", "You climb up.", palette.text)
---
--- When `stick_to_bottom` is true (the default), adding a line scrolls the
--- view to keep the newest line visible. Manual scrolling via
--- `scroll_lines(dy)` pins the view until it returns to the bottom.

local bus = require("event")
local palette = require("palette")

local TextPanel = {}

function TextPanel:init(event_name, max_lines)
    assert(self.screen_x ~= nil and self.screen_y ~= nil,
        "TextPanel.init: widget must have screen_x and screen_y")
    assert(self.screen_w ~= nil and self.screen_h ~= nil,
        "TextPanel.init: widget must have screen_w and screen_h (use ScreenRect)")
    assert(type(event_name) == "string",
        "TextPanel.init: event_name must be a string")
    self.lines = {}
    self.max_lines = max_lines or 256
    self.scroll = 1
    self.stick_to_bottom = true
    self.panel_bg = self.panel_bg or palette.soot
    self.default_fg = self.default_fg or palette.text
    bus.subscribe(self, event_name, function(text, fg)
        self:add_line(text, fg)
    end)
end

--- Append a line. Drops the oldest entry once `max_lines` is exceeded.
--- If `stick_to_bottom`, the view follows the newest line.
---@param text string
---@param fg? table
function TextPanel:add_line(text, fg)
    if text == nil or text == "" then
        return
    end
    local lines = self.lines
    lines[#lines + 1] = { text = text, fg = fg or self.default_fg }
    if #lines > self.max_lines then
        table.remove(lines, 1)
    end
    if self.stick_to_bottom then
        self:scroll_to_bottom()
    end
end

function TextPanel:clear()
    self.lines = {}
    self.scroll = 1
    self.stick_to_bottom = true
end

--- Scroll the view by `dy` lines (negative = up). Pin the view off the
--- bottom until it returns to the newest line.
---@param dy integer
function TextPanel:scroll_lines(dy)
    local lines = self.lines
    local visible = self.screen_h
    local max_top = math.max(1, #lines - visible + 1)
    local new_scroll = self.scroll + dy
    if new_scroll < 1 then
        new_scroll = 1
    elseif new_scroll > max_top then
        new_scroll = max_top
    end
    self.scroll = new_scroll
    self.stick_to_bottom = (new_scroll == max_top)
end

--- Jump the view to the newest line.
function TextPanel:scroll_to_bottom()
    local visible = self.screen_h
    self.scroll = math.max(1, #self.lines - visible + 1)
    self.stick_to_bottom = true
end

--- Draw a single string at (x, y) char by char (per-char color + bg).
--- Truncates to `maxw` cells.
---@param con iw.Console
---@param x integer
---@param y integer
---@param str string
---@param fg table
---@param bg table
---@param maxw integer
local function draw_line(con, x, y, str, fg, bg, maxw)
    local n = #str
    if n > maxw then
        n = maxw
    end
    for i = 1, n do
        con:put_serif(x + i - 1, y, str:byte(i), fg, bg)
    end
end

--- Render the visible window of lines into the panel's ScreenRect.
--- Fills the rect with `panel_bg` first so stale glyphs don't bleed.
---@param con? iw.Console  defaults to self.con
function TextPanel:draw(con)
    con = con or self.con
    assert(con ~= nil, "TextPanel.draw: widget must have self.con")
    local x0, y0 = self.screen_x, self.screen_y
    local w, h = self.screen_w, self.screen_h
    local bg = self.panel_bg

    -- Clear the rect.
    for y = 0, h - 1 do
        for x = 0, w - 1 do
            con:put_rgb(x0 + x, y0 + y, 32, bg, bg, 0)
        end
    end

    -- Paint visible lines top-down from `scroll`. Subclasses can customize
    -- the displayed text and per-row color via the line_text / line_color
    -- hooks (e.g. dedup counters, age-dimming).
    local lines = self.lines
    local scroll = self.scroll
    for row = 0, h - 1 do
        local entry = lines[scroll + row]
        if entry == nil then
            break
        end
        local str = self:line_text(entry, row, h)
        local fg = self:line_color(entry, row, h)
        draw_line(con, x0, y0 + row, str, fg, bg, w)
    end
end

--- Hook: the text to display for `entry` on visible row `row`.
--- Default: the entry's stored text. Override in a subclass for repeat
--- counters, truncation markers, etc.
---@param entry table
---@param row integer
---@param visible_rows integer
---@return string
function TextPanel:line_text(entry, row, visible_rows)
    return entry.text
end

--- Hook: the foreground color for `entry` on visible row `row`.
--- Default: the entry's stored fg. Override for age-dimming etc.
---@param entry table
---@param row integer
---@param visible_rows integer
---@return table
function TextPanel:line_color(entry, row, visible_rows)
    return entry.fg or self.default_fg
end

return TextPanel
