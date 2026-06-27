--- Player archetype.
---
--- A thin subclass of Entity + PhysicsObject + Drawable. PhysicsObject
--- (composed Collidable + gravity + the Euler integrator) comes BEFORE
--- Drawable so first-wins copying keeps its collision-resolving,
--- gravity-driven `update` over Drawable's plain Position.update. The
--- player OBEYS GRAVITY — it falls onto Solid ground and slides along
--- walls, fully via the integrator (no teleporting).
---
--- Identity-specific behavior: in `init` it subscribes to the event bus
--- for the semantic `move` action and translates it into an ACCELERATION
--- IMPULSE (`self:accelerate(STEP_ACCEL*dx, dy, 0)`) — the integrator +
--- friction turn that into slidey momentum. Motion is continuous, so the
--- camera follows every frame (synced from `world.player` in the screen
--- draw), not on a discrete "moved" event.
---
--- Subscriptions go through `bus.subscribe(self, name, cb)`, which appends
--- each unsubscribe fn to `self._unsubs`; `Entity:destroy` (via
--- world.destroy) walks that list so a destroyed player stops reacting.
---
--- Z is stored on the entity as `self.z` (Position is 3D); PhysicsObject
--- reads it for the collision cell + landing, the camera reads it.

local class = require("classes")
local Entity = require("entity")
local PhysicsObject = require("mixins.physics_object")
local Collision = require("collision")
local Drawable = require("mixins.drawable")
local Renderable = require("mixins.renderable")
local palette = require("palette")
local world = require("world")
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
    -- PhysicsObject.init: Collidable leaf (position + mask) + gravity flag
    -- (no friction override -> world.FRICTION default; the Player uses the
    -- engine-wide slideyness). NO pre-settle: gravity lands it on the first
    -- update. Sets self.z, so the explicit `self.z = z` below is unused.
    PhysicsObject.init(self, x, y, z, Collision.Solid, true)
    -- Drawable.init sets Position (idempotent reset to the same x,y,z) +
    -- appearance (the "@" glyph).
    Drawable.init(self, x, y, z, palette.text, nil, "@")

    -- Subscribe in init (per the event-bus convention). `bus.subscribe`
    -- tracks the unsubscribe fns on self._unsubs for teardown on destroy.
    --
    -- Movement is a single channel: "move" (key PRESS, dx/dy in {-1,0,1})
    -- → an ACCELERATION IMPULSE. Holding a key re-fires via BLT's OS-repeat,
    -- so a hold applies repeated impulses → continuous accel (a run), and a
    -- tap applies one → a step. The integrator advances position, friction
    -- decays velocity, PhysicsObject's per-axis resolver handles walls
    -- (slide) + landing (gravity).
    --
    -- "Feels tile-by-tile" comes from the SOFT-SNAP baked into
    -- PhysicsObject.update: when an axis's velocity decays below a low
    -- threshold (nearly stopped), the integrator re-grids it to the cell
    -- boundary in the direction of last motion. So a tap's tail completes
    -- cleanly to the next cell, and a run coasts to a graceful slide-to-stop
    -- that finally re-grids — no per-input snap logic, no origin capture, no
    -- key-release event. The soft-snap is universal: it applies to every
    -- entity running the integrator (NPCs, projectiles, knockback all
    -- benefit), not just the player.
    --
    -- No "moved" emit — motion is continuous, the camera follows every
    -- frame (GameScreen.draw syncs cam to world.player).
    local accel = world.STEP_ACCEL
    bus.subscribe(self, "move", function(dx, dy)
        self:accelerate(accel * dx, accel * dy, 0)
    end)
    L:debug("spawned at (%d,%d,%d)", x, y, z)
end
--- Player overrides draw? No. With BLT layering, entities draw on layer 1
--- (fg-only, transparent) via Renderable.draw, so the floor bg painted by
--- render_map shows through automatically — no tile-bg lookup hack and no
--- per-subclass override needed. Drawable.draw → Renderable.draw handles
--- the player the same as any other entity. (law 3: behavior that isn't
--- identity-specific doesn't belong in the subclass.)

return Player
