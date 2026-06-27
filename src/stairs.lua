--- Stairs entity.
---
--- A Collidable + Drawable entity that is NOT solid in the gameplay sense
--- (it doesn't permanently block — it shunts the mover vertically) but its
--- mask is ALL_BITS so it registers a collision with any collidable
--- entity. When a mover steps toward it, `Collidable:move` is blocked
--- (entity-vs-entity collision via the occupancy hash), firing `collision`;
--- this entity subscribed to the general `collision` event in `init` and
--- reacts (filtering on `blocker === self`, so it works for ANY mover
--- type, not just Player) by calling the MOVER's own `move` with a 3D
--- step: one cell in the entry direction (continuing past the stairs) and
--- one z level in the stairs's direction (UP for "up", DOWN for "down").
--- The mover:move guards solidity/bounds/occupancy at the landing cell;
--- on success we emit `moved` so the camera follows. The mover never
--- rests on the stairs cell.
---
--- Direction of travel is set per-instance: `Stairs(x,y,z,"up")` draws "<"
--- and shunts z+1; `Stairs(x,y,z,"down")` draws ">" and shunts z-1. A pair
--- (an up stairs with a matching down stairs one floor above) forms a
--- two-way vertical link.
---
--- The entry direction is inferred from relative position: at collision
--- time the step was blocked, so the mover is still one cell away on the
--- entry side — `dir = sign(stairs.pos - mover.pos)`. The landing is
--- `stairs.pos + dir` at `stairs.z ± 1`.
---
--- Note: mover:move (PhysicsObject) re-runs gravity after the step, so a
--- stairs landing must be grounded (solid below) or the mover will
--- re-fall — possibly right back down. Stairs are intentional vertical
--- transit, so place them with grounded landings.

local class = require("classes")
local Entity = require("entity")
local Collidable = require("mixins.collidable")
local Collision = require("collision")
local Drawable = require("mixins.drawable")
local palette = require("palette")
local bus = require("event")
local log = require("log")
local L = log.get("stairs")

-- ALL_BITS: collide with any entity carrying ANY collision category. The
-- Stairs is "not solid" (no permanent block — it shunts instead) but
-- "collides with everything" (triggers a collision with any masked entity
-- so the shunt reaction fires). Solid is bit 1; ALL_BITS covers future
-- categories too.
local ALL_BITS = 0xFFFFFFFF

-- Per-direction config: (z delta, glyph, color). Up = z+1 ("<", safety
-- yellow); down = z-1 (">", cyan). Anything else defaults to up.
local DIR = {
    up = { dz = 1, glyph = "<", fg = palette.safety_yellow },
    down = { dz = -1, glyph = ">", fg = palette.cyan },
}

local Stairs, super = class("Stairs", Entity):mixin(Collidable, Drawable)

--- Place the stairs at (x, y, z). `direction` is "up" (shunt z+1, "<") or
--- "down" (shunt z-1, ">"). Defaults to "up".
---@param x number
---@param y number
---@param z integer
---@param direction? string  "up" (default) or "down".
function Stairs:init(x, y, z, direction)
    super.init(self) -- Entity no-op
    local d = DIR[direction] or DIR.up
    self.direction = direction or "up"
    Collidable.init(self, x, y, z, ALL_BITS)
    Drawable.init(self, x, y, z, d.fg, nil, d.glyph)
    L:debug("placed %s-stairs at (%d,%d,%d)", self.direction, x, y, z)

    -- React when ANY mover collides with THIS stairs. The general
    -- `collision` event payload is (mover, blocker); filter on identity so
    -- only the actually-struck stairs reacts (every Stairs shares the
    -- handler). Then call the mover's own move with a 3D step that PASSES
    -- THROUGH the stairs: the mover is one cell back from us on the entry
    -- side (its forward step was blocked), so a +2 step in the entry
    -- direction lands one cell PAST us (stairs.x+dx) at stairs.z+dz —
    -- continuing the mover's direction of travel, not resting on the
    -- stairs cell. The landing cell is at a different z than us, so the
    -- move won't re-collide with this stairs. The mover's own move guards
    -- solidity/bounds/occupancy at the landing. On success, emit `moved`
    -- so the camera (and anything else) follows.
    bus.subscribe(self, "collision", function(mover, blocker)
        if blocker ~= self then
            L:trace(
                "[%s] ignore collision %s<->%s (blocker is not this stairs)",
                self.__name or "stairs",
                mover.__name or "?",
                blocker and blocker.__name or "?"
            )
            return
        end
        -- Entry direction = from mover toward the stairs (mover is one
        -- cell away on the entry side, since the step was blocked).
        local dx = self.x > mover.x and 1 or (self.x < mover.x and -1 or 0)
        local dy = self.y > mover.y and 1 or (self.y < mover.y and -1 or 0)
        -- +2 in the entry direction: skip over our cell to land past us.
        L:debug(
            "[%s] shunt %s from (%.0f,%.0f,%d) dir %+d,%+d -> step %+d,%+d,%+d",
            self.__name or "stairs",
            mover.__name or "?",
            mover.x or 0,
            mover.y or 0,
            mover.z or 0,
            dx,
            dy,
            2 * dx,
            2 * dy,
            d.dz
        )
        if mover:move(2 * dx, 2 * dy, d.dz) then
            L:debug(
                "[%s] shunt OK -> %s now at (%.0f,%.0f,%d)",
                self.__name or "stairs",
                mover.__name or "?",
                mover.x or 0,
                mover.y or 0,
                mover.z or 0
            )
            -- Narrate the climb for the message log. Stairs knows its own
            -- direction, so the prose lives here (the message module is a
            -- dumb sink). Only narrate Player climbs for now — an NPC
            -- shunting would spam the log without meaning to the player.
            if mover.__name == "Player" then
                bus.emit("message", d.dz > 0 and "You climb up." or "You climb down.", d.fg)
            end
            bus.emit("moved", mover)
        else
            L:debug("[%s] shunt FAILED (landing blocked)", self.__name or "stairs")
        end
    end)
end

return Stairs
