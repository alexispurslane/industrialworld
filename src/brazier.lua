--- Brazier archetype (stationary light source).
--
-- A minimal Entity + Drawable + LightSource: a fixed, in-world torch that
-- emits an omnidirectional (sphere) light. It has no physics, no collision,
-- no behavior — it just SITS at its cell, draws a glyph, and registers a
-- LightSource with the world so `world.update_lights` floods light around it
-- each frame (when the map `is_dark`). Law 3: an archetype carrying only
-- identity-specific state — a glyph + a "lit brazier" preset of radius /
-- intensity. The cross-capability orchestration (flood → light array →
-- dark render lerp) lives in the lighting system, so every archetype that
-- mixes LightSource in is lit identically.
--
-- Demo use: drop one near the player so you can SEE the lit pool, the soft
-- falloff at the radius edge, dark unlit visible space beyond (proving the
-- unlimited player FOV), and light stopping at Opaque walls.

local class = require("classes")
local Entity = require("entity")
local Drawable = require("mixins.drawable")
local LightSource = require("mixins.light_source")
local SoundEmitter = require("mixins.sound_emitter")
local palette = require("palette")

local Brazier, super = class("Brazier", Entity):mixin(Drawable, LightSource, SoundEmitter)

--- Spawn a lit brazier at (x, y, z). Draws a "≈" in ember orange; emits a
--- sphere light of `radius` (default 7) at peak intensity (default 255).
---@param x number
---@param y number
---@param z integer
---@param radius? integer  light flood radius in cells (default 7).
---@param intensity? number  0-255 peak at source (default 255).
function Brazier:init(x, y, z, radius, intensity)
    super.init(self) -- Entity no-op (law: unconditional super.init)
    -- Drawable BEFORE LightSource: Drawable.init sets Position state
    -- (x/y/z) which LightSource reads as the light origin. LightSource.init
    -- registers the light with the world (teardown-tracked via _unsubs).
    Drawable.init(self, { x = x, y = y, z = z, fg = palette.safety_yellow, glyphs = "≈" })
    LightSource.init(self, { radius = radius or 7, shape = "sphere", intensity = intensity or 255 })
    -- Fire crackle: soft, intermittent, spatialized relative to the player.
    SoundEmitter.init(self, {
        sound_id = "crackle",
        volume = 0.7,
        emit_interval = { min = 0.4, max = 1.2 },
    })
    -- One immediate crackle so new players can verify audio without
    -- waiting for the first timer roll.
    self:emit_sound()
    -- Fire the first periodic crackle very soon after entering Playing.
    self.sound_emit_timer = 0.2
end

function Brazier:update(dt)
    super.update(self, dt)
    SoundEmitter.step(self, dt)
end

return Brazier
