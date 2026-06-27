--- Screen objects for the three game modes.
---
--- `main.lua` owns the real-time loop and input routing; these screens own
--- the per-mode draw/update/teardown logic so `main.lua` does not become
--- the "everything file".
---
--- Each screen is a plain table with:
---   * draw()   — render this screen
---   * update(dt) — advance simulation (may be a no-op)
---   * destroy()  — clean up widgets/subscriptions (may be a no-op)

local ui = require("ui")
local palette = require("palette")
local game_state = require("game_state")
local bus = require("event")
local world = require("world")
local messages = require("messages")

local screens = {}

--- Center a string in the console width.
---@param con iw.Console
---@param str string
---@return integer x
local function centered_x(con, str)
    return math.floor((con:width() - #str) / 2)
end

----------------------------------------------------------------------------------------------------
-- Menu screen: title + clickable Start / Quit buttons.
----------------------------------------------------------------------------------------------------

function screens.MenuScreen(con)
    local c, r = con:width(), con:height()
    local title = "INDUSTRIALWORLD"
    local title_y = math.floor(r / 2) - 2
    local start_y = math.floor(r / 2) + 1
    local quit_y = math.floor(r / 2) + 3

    local start_btn, quit_btn

    local function destroy()
        if start_btn then
            start_btn:destroy()
            start_btn = nil
        end
        if quit_btn then
            quit_btn:destroy()
            quit_btn = nil
        end
    end

    start_btn = ui.button(
        con,
        centered_x(con, "[ENTER] Start"),
        start_y,
        "[ENTER] Start",
        function()
            destroy()
            game_state.set(game_state.Mode.Playing)
        end
    )

    quit_btn = ui.button(con, centered_x(con, "[ESC] Quit"), quit_y, "[ESC] Quit", function()
        bus.emit("quit")
    end)

    return {
        update = function(dt) end,

        draw = function()
            con:set_default_bg(palette.soot)
            con:clear()
            con:print_serif(centered_x(con, title), title_y, title, palette.text)
            if start_btn then
                start_btn:draw()
            end
            if quit_btn then
                quit_btn:draw()
            end
        end,

        destroy = destroy,
    }
end

----------------------------------------------------------------------------------------------------
-- Gameplay screen: map, entities, message panel.
----------------------------------------------------------------------------------------------------

function screens.GameScreen(con)
    return {
        update = function(dt)
            world.update(dt)
        end,

        draw = function()
            con:clear()
            -- Recompute each frame so a window resize takes effect
            -- immediately (the console shim's size is updated on resize).
            local view_rows = con:height() - messages.PANEL_H
            world.cam.view_rows = view_rows
            -- Camera follows the player every frame (motion is continuous
            -- via the integrator; there's no discrete "moved" event
            -- anymore). Sync cam x/y/z from world.player BEFORE fov/render
            -- so this frame paints the right viewport + visibility set.
            -- cam coords are INTEGER CELLS (math.floor): the integrator
            -- rests the player at sub-cell precision (e.g. z=1.001 just
            -- above the floor), but cam.z is used as an array index into
            -- the shade cache / FOV voxel grid, which must stay integral.
            local p = world.player
            if p ~= nil then
                world.cam.x = math.floor(p.x)
                world.cam.y = math.floor(p.y)
                world.cam.z = math.floor(p.z)
            end
            -- Recompute the player's FOV (sets TileFlags.Visible; ORs
            -- Explored) BEFORE render so the map paints the visible set
            -- this frame. Cheapest placement: once per draw, right before
            -- render_map / draw_entities read the flags.
            world.update_fov()
            world.render_map(con, view_rows)
            world.draw_entities(con)
            messages.draw(con)
        end,

        destroy = function() end,
    }
end

----------------------------------------------------------------------------------------------------
-- Pause overlay: draws on top of the gameplay screen.
----------------------------------------------------------------------------------------------------

function screens.PauseOverlay(con)
    local c, r = con:width(), con:height()
    local msg = "PAUSED  [P] Resume  [ESC] Quit"
    local y = math.floor(r / 2)

    return {
        draw = function()
            con:print_serif(centered_x(con, msg), y, msg, palette.safety_yellow)
        end,
    }
end

return screens
