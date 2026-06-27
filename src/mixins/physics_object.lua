--- PhysicsObject mixin (composed: Collidable + gravity).
---
--- A collidable entity that also obeys gravity: it FALLS — drops z levels
--- straight down — until the cell directly below it (same x,y, z-1) is a
--- tile it collides with (per `should_collide`, the Solid mask). On the
--- current map only Walls are Solid, so an entity falls through Floor/Open
--- until a Wall is below (or it hits z=0, the floor of the world).
---
--- This is law 2: "movement + gravity" exists at the intersection of
--- Collidable + a gravity flag, is reusable across archetypes, and
--- orchestrates one mixin (Collidable) — so it's a composed mixin, not
--- subclass code. It overrides `move` (Collidable's) to re-settle after a
--- horizontal step. It overrides `update` (the real-time frame tick) to
--- run the Position euler integrator THEN re-settle via `fall`, so a
--- gravity-bound entity re-grounded every frame whether it moved via
--- discrete steps (move), velocity (euler), or got teleported. Mix it
--- BEFORE Drawable so its `move`/`update` win first-wins over Drawable's.
---
--- `obeys_gravity` is an optional init flag (default false): pass true for
--- an entity that should fall. fall() early-returns when it's false, so
--- the same mixin serves gravity-less collidables too.
---
--- Fall does NOT emit "moved" itself: an init-time fall happens before the
--- archetype's bus subscriptions are wired, and a move-time fall is
--- followed by the caller emitting "moved" (Player's move handler does
--- this), so the camera sees the post-fall z.

local mixin = require("classes").mixin
local Position = require("mixins.position")
local Collidable = require("mixins.collidable")
local world = require("world")
local tile = require("tile")
local log = require("log")
local L = log.get("physics")

local PhysicsObject = mixin({}, Collidable)

--- Initialize 3D position + collision mask (Collidable leaf) and the
--- gravity flag, then settle onto the ground ("on start").
---@param x number
---@param y number
---@param z integer
---@param mask integer  OR of Collision.* flags.
---@param obeys_gravity? boolean  default false; pass true to make it fall.
function PhysicsObject:init(x, y, z, mask, obeys_gravity)
    Collidable.init(self, x, y, z, mask)
    self.obeys_gravity = obeys_gravity or false
    L:debug("[%s] init gravity=%s at (%d,%d,%d)", self.__name or "?", self.obeys_gravity, x, y, z)
    self:fall()
end

--- Fall straight down until a Solid tile is below (or z=0). A no-op if
--- this entity doesn't obey gravity. Reads the cell at (x, y, z-1) via the
--- map's SoA cdata lookup, indexes the fixed tile-type registry
--- (`tile.defs[tv]`), and rests when `should_collide` says the tile below
--- blocks it. Otherwise decrements z and re-checks. After settling, the
--- occupancy hash is re-synced (the entity's cell may have changed z).
function PhysicsObject:fall()
    if not self.obeys_gravity then
        return
    end
    local map = world.map
    local x, y = math.floor(self.x), math.floor(self.y)
    local start_z = self.z
    local landed_on -- the tile def we came to rest on (for the landing emit)
    -- Drop while the cell below is NOT solid. z>0 guards against reading
    -- the OOB z-1 = -1 layer (and against falling past the world floor).
    while self.z > 0 do
        local below = map.types:index(x, y, self.z - 1)
        local cb = tile.defs[below]
        if cb ~= nil and self:should_collide(cb) then
            landed_on = cb
            break -- solid below: rest here
        end
        self.z = self.z - 1
    end
    -- Re-sync the spatial hash: z may have changed (or the entity was just
    -- spawned and isn't tracked yet — occ_rehash handles both safely).
    world.occ_rehash(self)
    -- Emit a landing collision ONLY if we actually fell (z changed).
    -- Resting-in-place after a horizontal step has start_z == self.z, so
    -- it won't spam a "collision:Player:Floor" every step.
    if self.z ~= start_z and landed_on ~= nil then
        L:debug(
            "[%s] fell %d -> %d (landed on %s)",
            self.__name or "?",
            start_z,
            self.z,
            landed_on.__name or "?"
        )
        self:emit_collision_with(landed_on)
    end
end

--- Collision-guarded step PLUS re-settle. Delegates the (3D) step to
--- Collidable (which already checks the destination tile's mask and
--- bounds, the destination entity cell, and returns false if blocked). On
--- a successful step, re-run gravity: the new x,y column may have open
--- space below. Only emits a move-effect (via the caller's "moved") when
--- the step actually happened.
---@param dx number
---@param dy number
---@param dz? number  default 0.
---@return boolean moved  true if the step was taken, false if blocked.
function PhysicsObject:move(dx, dy, dz)
    if not Collidable.move(self, dx, dy, dz) then
        return false
    end
    self:fall()
    return true
end

--- Per-frame real-time tick: run the Position euler integrator (advances
--- x/y/z by velocity/acceleration; a no-op for entities with zero
--- velocity, like the tile-based Player), THEN re-settle gravity so a
--- moving entity re-grounds when its column opens up. The occupancy hash
--- is re-synced by both euler (via Position.update) repositioning and by
--- fall (it rehashes itself). Overrides Position.update (first-wins:
--- this method is on the composed mixin, copied into the class table).
---@param dt number  Seconds elapsed since the last update.
function PhysicsObject:update(dt)
    Position.update(self, dt)
    self:fall()
end

return PhysicsObject
