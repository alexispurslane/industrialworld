--- Message log UI — owns a MessageLog widget (a TextPanel subclass).
---
--- Systems emit `bus.emit("message", text, fg)`; the widget subscribes and
--- renders. This module is a thin singleton wrapper so main.lua/screens can
--- keep using `messages.PANEL_H`, `messages.init(con)`, and
--- `messages.draw(con)` without holding the widget themselves.
---
--- Dedup (xN), age-dimming, and the top rule line are identity-specific
--- to the message log and live in src/widgets/message_log.lua.

local MessageLog = require("widgets.message_log")

local PANEL_H = 7
local MAX = 128

local messages = {
    PANEL_H = PANEL_H,
}

local panel = nil

--- Create the singleton MessageLog widget (subscribed to "message").
--- Idempotent: safe to call more than once.
---@param con iw.Console
function messages.init(con)
    if panel ~= nil then
        return
    end
    panel = MessageLog(con, PANEL_H - 1, "message", MAX)
end

--- Render the message log (rule line + visible lines).
---@param con iw.Console
function messages.draw(con)
    if panel ~= nil then
        panel:draw(con)
    end
end

--- Notify the panel of a new console width (window resized). The
--- Anchor mixin repositions it; this just keeps the width in sync so it
--- still spans the screen.
---@param w integer  new console width in cells.
function messages.on_resize(w)
    if panel ~= nil then
        panel.screen_w = w
    end
end

return messages
