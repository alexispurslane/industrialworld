--- Stairs entity.
---
--- A Collidable + Drawable entity (like Player) that is NOT solid in the
--- gameplay sense (it doesn't permanently block — it TELEPORTS the player
--- vertically) but its mask is ALL_BITS so it registers a collision with
--- any collidable entity. When the player steps toward it,
--- `Collidable:move` is blocked (entity-vs-entity collision via
--- `world.entity_at`), firing `collision:Player:Stairs`; this entity
--- subscribed to that event in `init` and reacts by shunting the player:
--- one z level in the stairs's direction (UP for "up" stairs, DOWN for
--- "down" stairs), and one cell PAST the stairs on the opposite side from
--- where it entered (the player passes through, continuing in its
--- direction of travel). The player never rests on the stairs cell.
---
--- Direction of travel is set per-instance: `Stairs(x,y,z,"up")` draws "<"
--- and shunts z+1; `Stairs(x,y,z,"down")` draws ">" and shunts z-1. A pair
--- (an up stairs with a matching down stairs one floor above) forms a
--- two-way vertical link, so players don't have to drop to get back.
---
--- The entry direction is inferred from relative position: at collision
--- time the step was blocked, so the player is still one cell away on the
--- entry side — `dir = sign(stairs.pos - player.pos)`. Exit = stairs.pos
--- + dir.
---
--- The teleport does NOT call fall(): stairs are intentional vertical
--- transit. The shunt happens during the blocked `move` (which returns
--- false → `PhysicsObject:move` skips its `fall()`), so the player stays
--- at the new z. The stairs then emits `moved` so the camera follows.
---
--- Guard: if the landing cell is out of bounds or solid (would embed the
--- player in a wall), the shunt is cancelled (no teleport, player stays
--- blocked at the stairs). This prevents soft-locks on badly-placed stairs.

local class = require("classes")
local Entity = require("entity")
local Collidable = require("mixins.collidable")
local Collision = require("collision")
local Drawable = require("mixins.drawable")
local world = require("world")
local tile = require("tile")
local bus = require("event")

-- ALL_BITS: collide with any entity carrying ANY collision category. The
-- Stairs is "not solid" (no permanent block — it teleports instead) but
-- "collides with everything" (triggers a collision with any masked entity
-- so the stairs reaction fires). Solid is bit 1; ALL_BITS covers future
-- categories too.
local ALL_BITS = 0xFFFFFFFF

-- Per-direction config: (z delta, glyph, color). Up = z+1 ("<", yellow);
-- down = z-1 (">", cyan). Anything else defaults to up.
local DIR = {
    up = { dz = 1, glyph = "<", fg = { r = 230, g = 200, b = 60 } },
    down = { dz = -1, glyph = ">", fg = { r = 80, g = 200, b = 220 } },
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
    Collidable.init(self, x, y, ALL_BITS)
    Drawable.init(self, x, y, d.fg, nil, d.glyph)
    self.z = z

    -- React when the player collides with THIS stairs. The event payload is
    -- (mover, blocker) = (player, this_stairs); filter on identity so only
    -- the actually-struck stairs reacts (every Stairs shares the handler).
    bus.subscribe(self, "collision:Player:Stairs", function(player, stairs_self)
        if stairs_self ~= self then
            return
        end
        -- Entry direction = from player toward the stairs (player is one
        -- cell away on the entry side, since the step was blocked).
        local dx = self.x > player.x and 1 or (self.x < player.x and -1 or 0)
        local dy = self.y > player.y and 1 or (self.y < player.y and -1 or 0)
        local lx = math.floor(self.x) + dx
        local ly = math.floor(self.y) + dy
        local lz = (self.z or 0) + d.dz
        -- Guard: don't shunt into a solid tile, off the map, or into a
        -- pocket with no escape (would embed the player in a wall or
        -- completely trap them). Cancel the teleport in those cases — the
        -- player just stays blocked at the stairs, free to walk away.
        local map = world.map
        if not map:in_bounds(lx, ly, lz) then
            return
        end
        local ldef = tile.defs[map.types:index(lx, ly, lz)]
        if ldef ~= nil and player:should_collide(ldef) then
            return -- landing cell is solid: cancel
        end
        -- Escape check: at least one horizontal neighbor of the landing
        -- cell (at lz) must be non-solid + in-bounds, so the player can
        -- actually take a step after landing. A cell surrounded by solid
        -- on all four sides is a trap pocket — cancel.
        local has_escape = false
        for _, n in ipairs({ { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }) do
            local nx, ny = lx + n[1], ly + n[2]
            if map:in_bounds(nx, ny, lz) then
                local ndef = tile.defs[map.types:index(nx, ny, lz)]
                if ndef == nil or not player:should_collide(ndef) then
                    has_escape = true
                    break
                end
            end
        end
        if not has_escape then
            return -- would be completely stuck: cancel
        end
        player.x = lx
        player.y = ly
        player.z = lz
        bus.emit("moved", player)
    end)
end

return Stairs
