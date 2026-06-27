--- Simple immediate-mode UI helpers.
---
--- Built on top of the event bus and the UI-layer sans-serif tileset.
--- Widgets that want hover/click handling register themselves in a global
--- z-ordered table; the centralized mouse handlers dispatch to the topmost
--- clickable widget under the cursor. This means overlapping widgets behave
--- predictably: the one drawn last (highest z) receives hover/click, and a
--- widget below it is not accidentally triggered.
---
--- Buttons must be created once (e.g. during screen setup) and their
--- `draw()` method called each frame as part of that screen's render.
--- Call `destroy()` to unsubscribe from bus events when the screen is torn
--- down.

local bus = require("event")
local palette = require("palette")

local ui = {}

----------------------------------------------------------------------------------------------------
-- Widget registry: z-ordered hover/click dispatch.
----------------------------------------------------------------------------------------------------

-- Active widgets keyed by the widget object itself. Each registered widget
-- exposes at least `_contains(pos)`. Clickable widgets also expose
-- `_on_click(pos)`. Hoverable widgets expose `_set_hover(boolean)`.
ui._widgets = {}

local next_z = 1
local hover_widget = nil

--- Register a widget so it participates in hover/click hit-testing.
--- Z-order is established at registration time: later registrations are
--- considered "on top" of earlier ones, matching typical draw order.
---@param w table
local function register(w)
    if w._z == nil then
        w._z = next_z
        next_z = next_z + 1
    end
    ui._widgets[w] = true
end

--- Remove a widget from the registry. If it was currently hovered, clear
--- hover state so the next hover event retests correctly.
---@param w table
local function unregister(w)
    ui._widgets[w] = nil
    if hover_widget == w then
        if hover_widget._set_hover then
            hover_widget._set_hover(false)
        end
        hover_widget = nil
    end
end

--- Return the topmost registered widget whose bounds contain `pos`.
--- If `clickable` is true, only consider widgets with `_on_click`.
---@param pos table  {x=, y=}
---@param clickable boolean
---@return table|nil
local function topmost(pos, clickable)
    local best, best_z = nil, -1
    for w in pairs(ui._widgets) do
        if w._contains and w._contains(pos) then
            if not clickable or w._on_click then
                if w._z > best_z then
                    best_z = w._z
                    best = w
                end
            end
        end
    end
    return best
end

--- Centralized hover handler: highlight only the topmost hoverable widget.
local function handle_hover(pos)
    local w = topmost(pos, false)
    if w == hover_widget then
        return
    end
    if hover_widget and hover_widget._set_hover then
        hover_widget._set_hover(false)
    end
    hover_widget = w
    if w and w._set_hover then
        w._set_hover(true)
    end
end

--- Centralized click handler: fire only the topmost clickable widget.
local function handle_click(pos)
    local w = topmost(pos, true)
    if w and w._on_click then
        w._on_click(pos)
    end
end

bus.on("mouse_hover", handle_hover)
bus.on("mouse_click", handle_click)

----------------------------------------------------------------------------------------------------
-- Button widget.
----------------------------------------------------------------------------------------------------

--- Create a clickable text button.
---@param con iw.Console  console handle used for drawing.
---@param x integer       screen cell column of the button text start.
---@param y integer       screen cell row of the button.
---@param text string     label text (ASCII; width measured in bytes).
---@param callback fun(pos: table)  invoked on click inside the button bounds.
---@param fg? table       normal foreground color (default palette.text).
---@param fg_hover? table hover foreground color (default palette.safety_yellow).
---@return table button   { draw=function, destroy=function, text=, x=, y=, w= }
function ui.button(con, x, y, text, callback, fg, fg_hover)
    fg = fg or palette.text
    fg_hover = fg_hover or palette.safety_yellow
    local w = #text

    local hovered = false
    local destroyed = false

    --- Is the given cell inside the button's bounding box?
    local function contains(pos)
        return pos.x >= x and pos.x < x + w and pos.y == y
    end

    --- Draw the button using the current hover state.
    local function draw()
        if destroyed then
            return
        end
        local color = hovered and fg_hover or fg
        con:print_serif(x, y, text, color)
    end

    -- `widget` is declared before the table so the `destroy` closure
    -- captures the eventual table, not a nil during initialization.
    local widget
    widget = {
        x = x,
        y = y,
        text = text,
        w = w,
        draw = draw,
        _contains = contains,
        _set_hover = function(state)
            if destroyed then
                return
            end
            if state ~= hovered then
                hovered = state
                draw()
            end
        end,
        _on_click = callback,
        destroy = function()
            if destroyed then
                return
            end
            destroyed = true
            unregister(widget)
        end,
    }

    register(widget)
    draw()
    return widget
end

----------------------------------------------------------------------------------------------------
-- Progress bar widget.
----------------------------------------------------------------------------------------------------

--- Create a progress bar rendered as filled background cells.
---
--- The bar is `width` cells long. The filled portion uses `fill_bg`; the
--- empty portion uses `bg`. Because BLT only applies background colors on
--- layer 0, the bar draws there. This works cleanly on menu screens or
--- other cleared UI areas.
---
--- Progress bars are not interactive: they do not register for hover/click
--- dispatch, so they do not block widgets layered underneath them.
---
--- Control events:
---   * "progress:<id>"         -> set percent (0..100), clamped and redrawn.
---   * "progress:<id>:destroy" -> unsubscribe and stop rendering.
---
---@param con iw.Console
---@param id string|number  identifier used in event names.
---@param x integer         left column of the bar.
---@param y integer         row of the bar.
---@param width integer     total width in cells.
---@param bg? table         empty-bar background (default palette.panel_dim).
---@param fill_bg? table    filled-bar background (default palette.safety_yellow).
---@return table bar        { draw=function, destroy=function, set=function }
function ui.progress_bar(con, id, x, y, width, bg, fill_bg)
    bg = bg or palette.panel_dim
    fill_bg = fill_bg or palette.safety_yellow
    local percent = 0
    local destroyed = false

    local function draw()
        if destroyed then
            return
        end
        local filled = math.floor(percent / 100 * width + 0.5)
        for i = 0, width - 1 do
            local col = x + i
            local color = i < filled and fill_bg or bg
            -- Layer 0: space glyph with the chosen background color.
            con:put_rgb(col, y, 32, bg, color, 0)
        end
    end

    local function set(p)
        if destroyed then
            return
        end
        local new_percent = math.max(0, math.min(100, tonumber(p) or 0))
        if new_percent ~= percent then
            percent = new_percent
            draw()
        end
    end

    local progress_event = ("progress:%s"):format(tostring(id))
    local destroy_event = ("progress:%s:destroy"):format(tostring(id))

    local progress_unsub = bus.on(progress_event, set)

    local destroy_unsub
    destroy_unsub = bus.on(destroy_event, function()
        if destroyed then
            return
        end
        destroyed = true
        progress_unsub()
        destroy_unsub()
    end)

    draw()

    return {
        x = x,
        y = y,
        width = width,
        id = id,
        draw = draw,
        set = set,
        destroy = function()
            if destroyed then
                return
            end
            destroyed = true
            progress_unsub()
            destroy_unsub()
        end,
    }
end

return ui
