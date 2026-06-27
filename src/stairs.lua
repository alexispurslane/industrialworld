--- Stairs entity.
---
--- A Collidable + Drawable entity that is NOT solid in the gameplay sense
--- (it doesn't permanently block — it shunts the mover vertically) but its
--- mask is ALL_BITS so it registers a collision with any collidable
--- entity. When a mover slides into it, PhysicsObject's per-axis resolver is
--- blocked (entity-vs-entity collision via the occupancy hash) and fires
--- `collision`; this entity subscribed to the general `collision` event in
--- `init` and reacts (filtering on `blocker === self`, so it works for ANY
--- mover type, not just Player) by TELEPORTING the mover via its own `move`
--- (Collidable's discrete collision-guarded tile step — NOT the integrator):
--- a +2 step in the entry direction lands one cell PAST us at `stairs.z ± 1`,
--- continuing the mover's direction of travel (not resting on the stairs
--- cell). This is deliberate "magic" transit — stairs (and similar
--- teleport-class entities) are the sanctioned exception to the integrator-
--- only motion rule, since a physics arcing of the mover would land
--- sideways/off-target relative to the actual approach. After the shunt the
--- mover's velocity is zeroed so residual momentum doesn't carry it off.
---
--- Direction of travel is set per-instance: `Stairs(x,y,z,"up")` draws "<"
--- and lands at z+1; `Stairs(x,y,z,"down")` draws ">" and lands at z-1. A
--- pair (an up stairs with a matching down stairs one floor above) forms a
--- two-way vertical link.
---
--- The entry direction is inferred from the mover's position relative to
--- the stairs: the resolver snapped the mover back to the adjacent free
--- cell on the entry side, so `dir = sign(stairs.pos - mover.pos)`.

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
    -- handler). Stairs are a deliberate "magic" transit — they TELEPORT
    -- the mover via its own `move` (Collidable:move: a discrete
    -- collision-guarded tile step, NOT the physics integrator). The mover
    -- was blocked trying to enter our cell and PhysicsObject's resolver
    -- snapped it back to the adjacent free cell, so it sits one cell back
    -- on the entry side — a +2 step in the entry direction lands one cell
    -- PAST us at `stairs.z ± 1` (continuing the mover's direction of
    -- travel, not resting on the stairs cell). The landing cell is at a
    -- different z, so it won't re-collide with this stairs. The mover's
    -- own `move` guards solidity/bounds/occupancy at the landing. On
    -- success, zero the mover's velocity so residual slidey momentum
    -- doesn't carry it sideways through the teleport discontinuity.
    -- Motion otherwise stays integrator-driven; only stairs (and similar
    -- magic transit) teleport.
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
        -- Entry direction = from mover toward the stairs (the mover's cell
        -- is the adjacent free cell the resolver snapped it back to).
        local dx = self.x > mover.x and 1 or (self.x < mover.x and -1 or 0)
        local dy = self.y > mover.y and 1 or (self.y < mover.y and -1 or 0)
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
            -- Cancel residual momentum through the teleport so the mover
            -- doesn't drift sideways off the landing next frame.
            mover.vx, mover.vy, mover.vz = 0, 0, 0
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
            -- dumb sink). Only narrate Player climbs — an NPC shunting
            -- would spam the log without meaning to the player.
            if mover.__name == "Player" then
                bus.emit("message", d.dz > 0 and "You climb up." or "You climb down.", d.fg)
            end
        else
            L:debug("[%s] shunt FAILED (landing blocked)", self.__name or "stairs")
        end
    end)
end

return Stairs
