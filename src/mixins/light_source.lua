--- LightSource mixin (pure leaf).
--
-- The "emits light" capability: an in-world light source the per-frame
-- lighting pass (`world.update_lights`) floods into the map's `light`
-- array. A carried torch is a LightSource whose Position tracks the
-- player each frame (the flood reads `self.x/y/z` live); a stationary
-- brazier is a LightSource on a fixed entity. Either way the mixin
-- itself does NO work per frame — it is plain data the lighting pass
-- consumes (`radius`, `shape`, `dir`, `half_angle`, `intensity`), plus a
-- registry slot.
--
-- MODEL: when a LightSource is initialized (`Light.init`), it registers
-- itself with the world light registry (`world.add_light(self)`); on
-- teardown (`Light.destroy`), it unregisters (`world.remove_light(self)`).
-- The registry is walked each frame by `world.update_lights`, which reads
-- each light's Position + its shape params and floods the `light` SoA
-- array accordingly (sphere = unfiltered flood; cone = flood gated by an
-- angular test). Falloff is by accumulated path distance (Option A: the
-- `pf.distance_field` budget-capped Dijkstra) — distance from the source
-- along the connected non-opaque air volume → linear intensity fade, so
-- light bends around corners and leaks through doorways.
--
-- `is_dark` gate: lights only matter when the map has no sun
-- (`map.is_dark == true`); in daylight the per-frame pass early-outs and a
-- torch is invisible, exactly as it should be.
--
-- Pure leaf (law 1/2): knows nothing of the world's render or update loop.
-- It carries state + a register/unregister pair; the lighting system reads
-- that state. It does NOT pull in Position at the mixin level — the host
-- archetype already has Position (a torch is a Player/Item + LightSource;
-- a brazier is an Entity + Drawable + LightSource), so the host's `x/y/z`
-- ARE the light's origin. `world.update_lights` reads them directly.
--
-- SHAPE PARAMS:
--   shape      = "sphere" (default) | "cone"
--   radius     = integer flood radius (cells). Distance-field budget.
--   intensity  = 0..255 peak light value at the source cell (default 255).
--                 Falls off linearly to 0 at `radius` path-distance.
--   dir        = {x,y,z} unit vector (cone only). The cone's axis.
--   half_angle = radians (cone only). Half the cone's aperture; a cell is
--                 lit only if normalize(offset)·dir >= cos(half_angle).
--
-- 256-LEVEL LIGHTING: the map's `light` array is uint8 (0-255). Multiple
-- lights add (clamp 255). Render lerps each cell's shaded appearance
-- between a dark color and its sunlit look by `light/255` when `is_dark`.

local world = require("world")

local LightSource = {}

--- Register this light source with the world light registry. Called from
--- `Light.init` (the host archetype's init chain must call
--- `LightSource.init(self, opts)`). The teardown is tracked via
--- `world.add_light` returning an unregister fn appended to
--- `self._unsubs` (the SAME convention as `bus.subscribe`), so an entity
--- destroyed via `Entity:destroy` (→ `world.destroy` walks `_unsubs`
--- newest-first) automatically removes itself from the light registry —
--- a destroyed light stops being flooded the same frame.
---
--- `opts` (a single named-field table, per the >4-arg/init-table
--- convention — light sources have many tunable params):
---   radius     = integer flood radius in cells (REQUIRED).
---   shape      = "sphere" | "cone" (default "sphere").
---   intensity  = 0..255 peak at source (default 255).
---   dir        = {x,y,z} cone axis (cone only; need not be unit — normalized
---                 at flood time).
---   half_angle = radians, cone half-aperture (cone only).
---@param self table  the host entity (must have Position state: x/y/z).
---@param opts table  `{ radius, shape?, intensity?, dir?, half_angle? }`.
function LightSource.init(self, opts)
    opts = opts or {}
    local radius = opts.radius
    assert(type(radius) == "number" and radius > 0, "LightSource.init: opts.radius (>0) required")
    local shape = opts.shape or "sphere"
    assert(shape == "sphere" or shape == "cone", "LightSource.init: shape = 'sphere'|'cone'")
    if shape == "cone" then
        assert(type(opts.dir) == "table", "LightSource.init: cone requires opts.dir = {x,y,z}")
        assert(
            type(opts.half_angle) == "number" and opts.half_angle > 0,
            "LightSource.init: cone requires opts.half_angle (>0 radians)"
        )
    end
    local intensity = opts.intensity or 255
    assert(
        type(intensity) == "number" and intensity >= 0 and intensity <= 255,
        "LightSource.init: intensity 0..255"
    )
    self.light_radius = math.floor(radius)
    self.light_shape = shape
    self.light_intensity = intensity
    self.light_dir = opts.dir -- {x,y,z}; nil for sphere. Normalized at flood time.
    self.light_half_angle = opts.half_angle -- radians; nil for sphere.

    -- Register + track teardown, mirroring `bus.subscribe` exactly: the
    -- unregister fn `world.add_light` returns is appended to `self._unsubs`,
    -- so `Entity:destroy` (→ `world.destroy` walks `_unsubs` newest-first)
    -- removes this light from the registry the same frame it dies.
    local unsubs = rawget(self, "_unsubs")
    if unsubs == nil then
        unsubs = {}
        self._unsubs = unsubs
    end
    unsubs[#unsubs + 1] = world.add_light(self)
end

return LightSource
