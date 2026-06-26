--- Collidable mixin (composed: Position + collision).
---
--- A positionable entity whose `move` is collision-guarded. Composes
--- `Position` (spatial state + the plain `move` it overrides) and carries
--- a collision `mask` (bitflags). `move` checks the destination tile
--- before stepping; if blocked it is a no-op and returns false.
---
--- This is law 2's signature pattern: the "movement blocked by solid
--- terrain" behavior exists ONLY at the intersection of Position +
--- collision, is reusable across archetypes (Player, Goblin, ...), and
--- coordinates two mixins — so it lives as an override on a composed
--- mixin, NOT in the subclass. Drawable stays pure (Position + Renderable,
--- plain step + render) — an archetype mixes `Collidable` BEFORE
--- `Drawable` so first-wins copying keeps this collision-guarded `move`
--- over Drawable's plain one. Collidable has its OWN Position (it pulls
--- Position in directly), so it works standalone too; with Drawable the
--- Position mixin is mixed twice but idempotently (same methods/state).
---
--- Collision lookup reads the cheap SoA cdata tile-type at the
--- destination cell (`map.types:index(x,y,z)`), indexes the fixed
--- per-tile-type collidable registry (`tile.defs[tv]`), and (if
--- present) ANDs the two masks. Tiles absent from the registry (Floor,
--- Open, Stairs, Ramp) are walkable (no lookup hit). Out-of-bounds steps
--- are blocked (no walking off the map edge).
---
--- `move` returns `true` if the step was taken, `false` if blocked, so
--- callers can gate side effects (e.g. only emit "moved" on a successful
--- step).

local mixin = require("classes").mixin
local bit = require("bit")
local Position = require("mixins.position")
local Collision = require("collision")

local Collidable = mixin({}, Position)

--- Initialize position (Position leaf) then the collision mask.
---@param x number
---@param y number
---@param mask integer  OR of Collision.* flags (0 = collides with nothing).
function Collidable:init(x, y, mask)
    Position.init(self, x, y)
    self.mask = mask or 0
end

--- True iff `self` and `other` share any collision category bit.
--- Symmetric on masks; `other` is any table exposing `.mask` (an entity or
--- a fixed tile-type lookup entry). A nil/0 mask on either side -> no
--- collision (so non-collidable entities are skipped cleanly).
---@param other table  Anything with a `.mask` field (or none).
---@return boolean
function Collidable:should_collide(other)
    return bit.band(self.mask or 0, other.mask or 0) ~= 0
end

--- Emit collision events for a collision between `self` (the mover) and
--- `other` (the blocker). Emits TWO events:
---   bus.emit("collision", self, other)
---   bus.emit("collision:<name_self>:<name_other>", self, other)
--- Names come from each collidable's `__name` (entities: the class name via
--- `__index`; tile defs: the field set in tile.lua from the TileType name).
--- `self` (the active/moving party) is always first; `other` second.
--- `bus` is required lazily so this module loads before `bus` is set up.
---@param other table  The collidable `self` collided with.
function Collidable:emit_collision_with(other)
    local bus = require("event")
    bus.emit("collision", self, other)
    bus.emit(
        ("collision:%s:%s"):format(self.__name or "unknown", other.__name or "unknown"),
        self,
        other
    )
end

--- Step by (dx, dy) unless the destination tile is solid. Reads the tile
--- type at the destination cell (cheap cdata lookup via the map), maps it
--- to its fixed collidable through `tile.defs`, and tests masks. A
--- blocked step is a no-op (position unchanged), emits a collision event,
--- and returns false.
---
--- `world` and `tile` are required lazily (inside the function) so this
--- module can load before `world` is constructed (entity subclasses are
--- defined at require time, before main runs).
---@param dx number
---@param dy number
---@return boolean moved  true if the step was taken, false if blocked.
function Collidable:move(dx, dy)
    local world = require("world")
    local tile = require("tile")
    local map = world.map
    local nx = math.floor(self.x) + dx
    local ny = math.floor(self.y) + dy
    local z = self.z or 0
    if not map:in_bounds(nx, ny, z) then
        return false -- off-map: blocked (no tile to name, so no emit)
    end
    local tv = map.types:index(nx, ny, z)
    local cb = tile.defs[tv]
    if cb ~= nil and self:should_collide(cb) then
        self:emit_collision_with(cb)
        return false
    end
    -- Entity-vs-entity: also block if a collidable entity occupies the
    -- destination cell (e.g. a Stairs). `world.entity_at` scans the pool;
    -- scan is O(n) but runs once per step (turn-based, fine).
    local e = world.entity_at(nx, ny, z, self)
    if e ~= nil and self:should_collide(e) then
        self:emit_collision_with(e)
        return false
    end
    Position.move(self, dx, dy)
    return true
end

return Collidable
