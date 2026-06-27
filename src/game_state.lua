--- Centralized game-state machine.
---
--- A single Mode enum plus the current mode value. Anything that needs to
--- know whether the game is on the menu, playing, or paused requires this
--- module (`local game_state = require("game_state")`). Lua's module cache
--- makes it a singleton: every require shares `current`.
---
--- Changes emit a semantic `"state_changed"` event on the bus with the
--- signature `(old_mode, new_mode)`, so systems can react without polling.

local bus = require("event")
local enum = require("enums")

local Mode = enum("Menu", "Playing", "Paused")

-- Start on the menu screen. main.lua will transition to Playing when the
-- player presses Enter/Return.
local current = Mode.Menu

--- Set the current game mode. Validates against the enum and emits
--- `state_changed` on success.
---@param mode integer one of Mode.*
local function set(mode)
    if Mode[mode] == nil then
        error("game_state.set: invalid mode " .. tostring(mode), 2)
    end
    local old = current
    if old ~= mode then
        current = mode
        bus.emit("state_changed", old, current)
    end
end

--- Get the current mode value.
---@return integer
local function get()
    return current
end

--- Is the current mode `mode`?
---@param mode integer one of Mode.*
---@return boolean
local function is(mode)
    return current == mode
end

return {
    Mode = Mode,
    get = get,
    set = set,
    is = is,
}
