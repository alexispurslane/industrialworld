--- Player archetype.
---
--- A thin subclass of Entity + PhysicsObject + Drawable. PhysicsObject
--- (composed Collidable + gravity) comes BEFORE Drawable so first-wins
--- copying keeps its collision-guarded, gravity-settling `move` over
--- Drawable's plain Position.move. The player OBEYS GRAVITY — it settles
--- onto Solid ground on spawn and after every successful step.
---
--- Identity-specific behavior: in `init` it subscribes to the event bus
--- for the semantic `move` action and emits `moved` after a
--- SUCCESSFUL step, so the camera (subscribed in main.lua) can follow. A
--- blocked step (wall / off-map) is a no-op and emits nothing —
--- `PhysicsObject:move` returns false.
---
--- Subscriptions go through `bus.subscribe(self, name, cb)`, which appends
--- each unsubscribe fn to `self._unsubs`; `Entity:destroy` (via
--- world.destroy) walks that list so a destroyed player stops reacting.
---
--- Movement uses PhysicsObject:move (collision-guarded tile step + gravity
--- settle), NOT the physics integrator (vx/vy/ax/ay stay 0). Z is stored
--- on the entity as `self.z` (Position is 2D); PhysicsObject reads it for
--- the tile lookup + fall, the camera reads it.

local class = require("classes")
local Entity = require("entity")
local PhysicsObject = require("mixins.physics_object")
local Collision = require("collision")
local Drawable = require("mixins.drawable")
local Renderable = require("mixins.renderable")
local palette = require("palette")
local bus = require("event")
local log = require("log")
local L = log.get("player")

local Player, super = class("Player", Entity):mixin(PhysicsObject, Drawable)

--- Initialize the player at (x, y) on z layer `z`. Glyph is "@".
--- Solid mask: collides with solid terrain (walls) so it can't walk through.
--- obeys_gravity = true: the player settles onto Solid ground on spawn
--- and after each step.
---@param x number
---@param y number
---@param z integer
function Player:init(x, y, z)
    super.init(self) -- Entity no-op (law: unconditional super.init)
    -- PhysicsObject.init: Collidable leaf (position + mask) + sets self.z
    -- + gravity flag + settles on spawn (fall). Sets self.z, so the
    -- explicit `self.z = z` below is no longer needed.
    PhysicsObject.init(self, x, y, z, Collision.Solid, true)
    -- Drawable.init sets Position (idempotent reset to the same x,y,z) +
    -- appearance (the "@" glyph).
    Drawable.init(self, x, y, z, palette.text, nil, "@")

    -- Subscribe in init (per the event-bus convention). `bus.subscribe`
    -- tracks the unsubscribe fns on self._unsubs for teardown on destroy.
    -- Only emit `moved` when the step actually happened (PhysicsObject:move
    -- returns false on a blocked / off-map step; the fall inside it has
    -- already adjusted self.z before we emit, so the camera follows to
    -- the settled position).
    bus.subscribe(self, "move", function(dx, dy)
        if self:move(dx, dy) then
            bus.emit("moved", self)
        end
    end)
    L:debug("spawned at (%d,%d,%d) -> settled (%.0f,%.0f,%d)", x, y, z, self.x, self.y, self.z)
end
--- Player overrides draw? No. With BLT layering, entities draw on layer 1
--- (fg-only, transparent) via Renderable.draw, so the floor bg painted by
--- render_map shows through automatically — no tile-bg lookup hack and no
--- per-subclass override needed. Drawable.draw → Renderable.draw handles
--- the player the same as any other entity. (law 3: behavior that isn't
--- identity-specific doesn't belong in the subclass.)

return Player
