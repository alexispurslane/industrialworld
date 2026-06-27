--- Dummy archetype (inert pushable body).
--
-- A minimal PhysicsObject entity for testing the physics + knockback model:
-- gravity-bound, Solid (collides with other Solid bodies), no input / no AI /
-- no behavior. It just sits on the floor and gets SHOVED. Included for the
-- same reason a physics sandbox ships with a crate — to see and feel the
-- integrator (gravity, friction, wall slide, knockback impulses) acting on
-- something other than the player.
--
-- It is knockable BY DEFAULT — PhysicsObject.init subscribes it to the
-- "knockback" event, and the collision resolver emits knockback when a
-- mover bumps any is_physics_object blocker. So walking/sprinting into a
-- Dummy transfers the player's velocity to it as an impulse: it slides
-- away along the crossed axis, friction + soft-snap (with the supporting
-- tile's friction) brings it to rest on a cell. No Knockable mixin needed.
--
-- Law 3: an archetype carrying only identity-specific state (a glyph + the
-- "inert" preset of gravity + Solid). The cross-capability orchestration
-- (collision -> knockback impulse -> integrator) lives in PhysicsObject, so
-- every archetype that mixes it in is pushable identically.

local class = require("classes")
local Entity = require("entity")
local PhysicsObject = require("mixins.physics_object")
local Drawable = require("mixins.drawable")
local Collision = require("collision")
local palette = require("palette")

local Dummy, super = class("Dummy", Entity):mixin(PhysicsObject, Drawable)

--- Spawn a dummy resting (after gravity lands it) on the floor at (x, y, z).
--- Spawn z one above the floor and let gravity settle it, matching the player.
--- `mass` (default 2.0) makes it HEAVIER than the player (mass 1.0): a player
--- at cruise shoves it to Δv = (1.0*v_player)/2.0 = half-speed — it slides
--- but doesn't rocket away, reading as a weighty crate. Pass a small mass
--- (e.g. 0.3) for a light box that launches. `glyph` defaults to "#".
---@param x number
---@param y number
---@param z integer  spawn height (gravity lands it on the Solid tile below).
---@param mass? number  entity mass for impulse resolution (default 2.0).
---@param glyph? string  appearance glyph (default "#").
function Dummy:init(x, y, z, mass, glyph)
    super.init(self) -- Entity no-op (law: unconditional super.init)
    -- PhysicsObject BEFORE Drawable so its collision-resolving update wins
    -- first-wins. Solid mask: collides with other Solid bodies (player,
    -- walls) so the player physically cannot walk through it and shoves it.
    -- mass controls how much an impulse budges it (Δv = J/mass).
    PhysicsObject.init(self, x, y, z, Collision.Solid, true, nil, mass or 2.0)
    Drawable.init(self, x, y, z, palette.safety_yellow, nil, glyph or "#")
end

return Dummy
