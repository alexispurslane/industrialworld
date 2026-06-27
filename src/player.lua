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
local tile = require("tile")
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
    -- PhysicsObject.init: Collidable leaf (position + mask) + sets self.z
    -- + gravity flag + settles on spawn (fall). Sets self.z, so the
    -- explicit `self.z = z` below is no longer needed.
    PhysicsObject.init(self, x, y, z, Collision.Solid, true)
    -- Drawable.init sets Position (idempotent reset to the same x,y,z) +
    -- appearance (the "@" glyph).
    Drawable.init(self, x, y, z, { r = 255, g = 255, b = 255 }, nil, "@")

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

--- Draw the player, but with the bg taken from the tile under it (so the
--- "@" sits on the floor's bg, not black). Reads the tile type at the
--- player's cell, looks up its appearance, and uses that appearance's bg
--- as the glyph's bg. Override-and-extend on Drawable:draw (identity-
--- specific to Player — law 3 says identity behavior lives in the
--- subclass), delegating parent positioning to super.draw and the glyph
--- drawing to Renderable.draw with a per-call bg override.
---@param console iw.Console
---@param cam table
function Player:draw(console, cam)
    local cols = console:width()
    local rows = cam.view_rows or console:height()
    local sx = math.floor(self.x) - cam.x + math.floor(cols / 2)
    local sy = math.floor(self.y) - cam.y + math.floor(rows / 2)
    if sx < -1 or sx > cols or sy < -1 or sy > rows then
        return
    end
    -- Look up the tile under the player and borrow its bg.
    local tv = world.map.types:index(math.floor(self.x), math.floor(self.y), self.z)
    local appear = tile.defs[tv]
    local bg = appear and appear.bg or self.bg
    -- Renderable.draw draws each glyph; pass our looked-up bg as the
    -- per-glyph bg override (Renderable honors `g.bg` over `self.bg`).
    -- We can't call super.draw here because it would draw with self.bg;
    -- instead replicate the one-glyph case with the override.
    local g0 = self.glyphs[1]
    console:put_rgb(sx + g0.dx, sy + g0.dy, g0.ch, g0.fg or self.fg, bg)
end

return Player
