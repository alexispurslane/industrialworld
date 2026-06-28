--- The game world: a singleton module holding entity pool storage, the
--- Map, and the camera. Required from anywhere (`local world = require("world")`);
--- Lua's module cache makes it a single shared object.
---
--- Entity pool: POOLED Lua tables (not freshly allocated per spawn — 0
--- allocs steady-state). A 1-based Lua array `slots` holds the pooled
--- tables; a dense cffi `uint8_t` `alive` array is the tombstone
--- (0=dead/unused, 1=alive) — the "is-living array corresponding to the
--- entity array", scanned linearly for the first dead slot.
---
--- A cffi array CAN'T safely hold the Lua entity tables themselves (Lua
--- tables aren't a storable ctype; a raw pointer would dangle at GC), so
--- the cffi part is the bit tombstone and the Lua array is the table pool.
---
--- allocation/destroy live here too (Entity.new routes through
--- world.allocate; Entity:destroy routes through world.destroy). Required
--- from anywhere: `local world = require("world")`.

local ffi = require("ffi")
local bit = require("bit")
local Map = require("map")
local tile = require("tile")
local fov = require("fov")
local pf = require("pathfinding")
local blt = require("industrialworld.blt")
local palette = require("palette")
local log = require("log")
local L = log.get("world")

local INITIAL_ENTITY_CAP = 1000

-- Depth-darkening curve. d=0 (the current layer) renders at full brightness;
-- each level deeper fades by FADE_PER_LEVEL, clamped at MIN_BRIGHTNESS so
-- the depths stay faintly visible rather than dropping to pure black.
local DEPTH_FADE_PER_LEVEL = 0.2
local MIN_BRIGHTNESS = 0.25

-- Ceiling-darkening curve (layers ABOVE the camera). Each level above
-- fades by CEIL_FADE_PER_LEVEL, clamped at CEIL_MIN_BRIGHTNESS so the
-- upper floors read as a dimmed "see-through" ceiling rather than full
-- opacity (which would obscure the current layer entirely).
local CEIL_FADE_PER_LEVEL = 0.35
local CEIL_MIN_BRIGHTNESS = 0.3

-- Field-of-view (native 3D; see src/fov.lua). The player's vision is
-- UNLIMITED in range and VIEWPORT-BOUNDED: there is no radius and no
-- spherical falloff — the player sees as far as real eyes do, blocked only
-- by opaque terrain. We bound the COMPUTED set each frame to the rendered
-- viewport (the camera's screen rect × the rendered z-window), so cells
-- outside the painted region don't waste rays. Only the per-frame Visible
-- set is kept — NO MEMORY (no Explored accumulation): a cell renders iff
-- it's Visible this frame. This is the hard render boundary; combined with
-- the darkness/lighting model it removes the class of brightness-inversion
-- bugs where remembered terrain read brighter than visible-but-unlit cells.
--
-- (The old VISION_RANGE/VISION_SHAPE sphere model is removed; `fov` still
-- supports `range`/`shape` for finite-radius vision like NPC sight, but the
-- player no longer uses them — it passes a viewport `box` instead.)

-- Physics tuning (the "basic silly physics engine"). Movement is
-- impulse-driven: a keypress calls `self:accelerate(STEP_ACCEL*dx, ...)`;
-- gravity is a constant downward `az`; friction damps horizontal velocity
-- per second as `FRICTION^dt` (retains FRICTION-fraction/s, so you slide to
-- a stop shortly after releasing input). Stairs give a direct velocity bump
-- (SHUNT_VZ vertical / SHUNT_VH forward) in place of a teleport shunt.
-- Exposed on `world` for callers (player, stairs, PhysicsObject).
local GRAVITY = 20 -- cells/sec^2 downward (obeys_gravity entities)
local STEP_ACCEL = 150 -- cells/sec^2 per arrow-key impulse (horizontal)
-- (high enough that holding crosses cell 1 by ~frame 5 for
-- snappy response; SOFT_SNAP_V in PhysicsObject re-grids short
-- taps to 1 cell so the high accel doesn't overshoot on taps)
local FRICTION = 0.02 -- per-second horizontal velocity retention (0.02 = 2%/s)
local SHUNT_VZ = 7 -- cells/sec upward/downward bump a stairs imparts
local SHUNT_VH = 3 -- cells/sec forward bump a stairs imparts

-- X-ray hole through VISIBLE ceilings. Even with native-3D FOV revealing
-- open-ceiling voxels, the player wants a clear cutout around them through
-- any VISIBLE above-layer cells (a platform above, stairs head) so the
-- player cell reads and nearby above-layer content shows without the
-- ceiling-floor occluding it. Applied ONLY to cells that are BOTH visible
-- (in the FOV) AND on a layer above the camera (z > cam.z) — cells not
-- visible this frame render nothing, so they're untouched by definition.
-- Rings by squared horizontal distance from the player cell:
--   CORE  (r <= XRAY_CORE_R) : alpha 0  → above-layer cell NOT drawn (hole).
--   RING1 (CORE..RING1_R)    : alpha A1 → very transparent (mostly hole).
--   RING2 (RING1..RING2_R)   : alpha A2 → slightly less transparent.
--   outside RING2            : alpha 1  → drawn normally (full ceiling).
-- The composite lerps the above-layer (ceiling) colors toward the below
-- (player-layer) cell's colors by `alpha`, so near the player the ceiling
-- dissolves into what's beneath it; the fg glyph's alpha channel carries
-- the ring opacity for GL blending (BLT only applies a cell bg on layer 0).
local XRAY_CORE_R = 8
local XRAY_RING1_R = 10
local XRAY_RING2_R = 12
local XRAY_CORE_R2 = XRAY_CORE_R * XRAY_CORE_R
local XRAY_RING1_R2 = XRAY_RING1_R * XRAY_RING1_R
local XRAY_RING2_R2 = XRAY_RING2_R * XRAY_RING2_R
local XRAY_ALPHA_RING1 = 0.18
local XRAY_ALPHA_RING2 = 0.40

-- Pure-black stand-in for the below color of a column that is Open air all
-- the way down (nothing was drawn on layer 0 there beyond con:clear's
-- default black bg); used by the x-ray compositing lerp.
local BLACK = palette.black

--- Pick the x-ray hole opacity (0..1) for an above-layer visible cell at
--- squared horizontal distance `r2` from the player cell. 0 = fully
--- removed (core hole), 1 = fully drawn (outside all rings).
---@param r2 number  squared dx*dx+dy*dy (horizontal only).
---@return number alpha
local function xray_alpha(r2)
    if r2 <= XRAY_CORE_R2 then
        return 0
    elseif r2 <= XRAY_RING1_R2 then
        return XRAY_ALPHA_RING1
    elseif r2 <= XRAY_RING2_R2 then
        return XRAY_ALPHA_RING2
    end
    return 1.0
end

--- Lerp two {r,g,b} colors by `t` (0 = `a`, 1 = `b`), floored to ints so
--- the result is safe to feed into bit.lshift in blt.to_color.
---@param a table
---@param b table
---@param t number
---@return table
local function lerp_color(a, b, t)
    if t <= 0 then
        return a
    end
    return {
        r = math.floor(a.r + (b.r - a.r) * t),
        g = math.floor(a.g + (b.g - a.g) * t),
        b = math.floor(a.b + (b.b - a.b) * t),
    }
end

local INITIAL_WIDGET_CAP = 256

local world = {
    capacity = INITIAL_ENTITY_CAP,
    slots = {}, -- slots[1..capacity] = pooled Lua tables, pre-allocated below
    alive = ffi.new("uint8_t[?]", INITIAL_ENTITY_CAP), -- 0=dead, 1=alive (0-based)
    widgets_capacity = INITIAL_WIDGET_CAP,
    widgets_slots = {}, -- UI widget pool (same shape as the entity pool)
    widgets_alive = ffi.new("uint8_t[?]", INITIAL_WIDGET_CAP),
    widgets_next_z = 1,
    map = Map(2000, 2000, 10), -- the game world's Map (schema-driven SoA; zero-filled)
    cam = { x = 1000, y = 1000, z = 9, z_offset = 0 }, -- camera center cell, z layer, + peek offset
    -- Spatial hash: cell_idx -> set of living entities at that cell.
    -- Cell idx mirrors the Map's z-major layout (idx = ((z*H+y)*W+x)).
    -- A cell holds a list (usually 0 or 1 entity); entity_at is O(1)
    -- instead of the O(capacity) pool scan it replaced. Maintained in
    -- allocate (post-init), destroy (pre-teardown), and every move/update
    -- path that changes an entity's cell (Collidable:move,
    -- PhysicsObject.update) via occ_rehash.
    occ = {},
    -- Light registry: the set of living LightSource entities. Walked each
    -- frame by `world.update_lights` (which reads each light's Position +
    -- shape params and floods the map's `light` SoA array). Maintained by
    -- `world.add_light` (called from `LightSource.init`) and pruned by the
    -- unregister fn it returns (tracked on the entity's `_unsubs`, walked on
    -- `world.destroy`) — so a destroyed light is removed the same frame,
    -- exactly like a `bus.subscribe` teardown.
    lights = {},
    _shade = {}, -- depth-shaded appearance cache (rebuilt on cam.z change)
    _shade_max_depth = -1,
    -- (Player vision is unlimited + viewport-bounded now; the old
    -- VISION_RANGE/VISION_SHAPE sphere model is removed. `fov` still
    -- supports range/shape for finite-radius vision like NPC sight.)
    -- Physics tuning (mirrors the module locals above; the hot-loop reads
    -- use the locals, so runtime tweaks need both updated — kept here for
    -- discoverability/tests, same convention as VISION_*).
    GRAVITY = GRAVITY,
    STEP_ACCEL = STEP_ACCEL,
    FRICTION = FRICTION,
    SHUNT_VZ = SHUNT_VZ,
    SHUNT_VH = SHUNT_VH,
}

-- Pre-allocate the pools of empty tables once.
for i = 1, world.capacity do
    world.slots[i] = {}
end
for i = 1, world.widgets_capacity do
    world.widgets_slots[i] = {}
end

--- Wipe a pooled table's own fields so a recycled slot starts clean.
---@param t table
local function wipe(t)
    for k in pairs(t) do
        t[k] = nil
    end
end

--- Find the first dead/unused slot (1-based index) or nil if the pool is full.
---@return integer|nil
local function find_dead_slot()
    local a = world.alive
    for i = 0, world.capacity - 1 do
        if a[i] == 0 then
            return i + 1
        end
    end
    return nil
end

--- Double the pool capacity (slots Lua array + alive cffi array), copying
--- old state; new slots are dead (zero-filled). Called when the pool is full.
local function grow()
    local old_cap = world.capacity
    local new_cap = old_cap * 2
    local new_alive = ffi.new("uint8_t[?]", new_cap)
    ffi.copy(new_alive, world.alive, old_cap) -- old bits copied; tail is 0 (dead)
    world.alive = new_alive
    for i = old_cap + 1, new_cap do
        world.slots[i] = {} -- fresh pooled tables for the new slots
    end
    world.capacity = new_cap
end

--- Allocate a game entity into the first dead slot (growing the pool if
--- full), reusing the pooled table there. Returns the entity (a Lua table
--- dispatching through `cls`). Called by Entity.new; spawn via `Cls(...)`.
--- After init, registers the entity in the spatial hash at its post-init
--- cell (init may have moved it, e.g. PhysicsObject falls on spawn).
---@param cls table   The class (e.g. Goblin).
---@param ... any      Args forwarded to cls.init.
---@return table entity
function world.allocate(cls, ...)
    local i = find_dead_slot()
    if i == nil then
        grow()
        i = find_dead_slot()
    end
    local e = world.slots[i]
    wipe(e) -- clear the previous occupant's state
    setmetatable(e, cls) -- rebind dispatch to this archetype's class
    if cls.init then
        cls.init(e, ...)
    end
    e.__slot = i -- engine infra (not mixin state); O(1) destroy lookup
    world.alive[i - 1] = 1
    world.occ_rehash(e) -- register at post-init cell (init may have moved it)
    L:debug(
        "allocate %s -> slot %d (%.0f,%.0f,%d)",
        cls.__name or "?",
        i,
        e.x or 0,
        e.y or 0,
        e.z or 0
    )
    return e
end

--- Mark `e`'s slot dead so it can be recycled by a later allocate. Calls
--- the entity's mixin teardown chain FIRST (so subscribers unsubscribe
--- before the table is wiped/reused), removes it from the spatial hash,
--- then marks the slot dead. Does NOT free the Lua table (the pool retains
--- it for recycling).
---@param e table  An entity previously returned by allocate.
function world.destroy(e)
    -- Mixin teardown: any mixin that subscribed in its init appended an
    -- unsubscribe fn to `e._unsubs`. Walk them (newest-first is safe; the
    -- bus snapshot makes order not matter, but newest-first avoids
    -- touching indices if a teardown mutated the list).
    local unsubs = rawget(e, "_unsubs")
    if unsubs ~= nil then
        for i = #unsubs, 1, -1 do
            unsubs[i]()
        end
        e._unsubs = nil
    end
    local slot = rawget(e, "__slot")
    L:debug(
        "destroy %s slot %s (%.0f,%.0f,%d)",
        e.__name or "?",
        tostring(slot),
        e.x or 0,
        e.y or 0,
        e.z or 0
    )
    world.occ_remove(e)
    local i = rawget(e, "__slot")
    if i ~= nil then
        world.alive[i - 1] = 0
    end
end

----------------------------------------------------------------------------------------------------
-- Widget pool (mirrors the entity pool; no spatial hash, no map).
----------------------------------------------------------------------------------------------------

local function find_dead_widget_slot()
    local a = world.widgets_alive
    for i = 0, world.widgets_capacity - 1 do
        if a[i] == 0 then
            return i + 1
        end
    end
    return nil
end

local function grow_widgets()
    local old_cap = world.widgets_capacity
    local new_cap = old_cap * 2
    local new_alive = ffi.new("uint8_t[?]", new_cap)
    ffi.copy(new_alive, world.widgets_alive, old_cap)
    world.widgets_alive = new_alive
    for i = old_cap + 1, new_cap do
        world.widgets_slots[i] = {}
    end
    world.widgets_capacity = new_cap
end

--- Allocate a UI widget into the first dead slot (growing if needed),
--- reusing the pooled table there. Called by Widget.new; create via
--- `Cls(...)`.
---@param cls table
---@return table widget
function world.allocate_widget(cls, ...)
    local i = find_dead_widget_slot()
    if i == nil then
        grow_widgets()
        i = find_dead_widget_slot()
    end
    local w = world.widgets_slots[i]
    wipe(w)
    setmetatable(w, cls)
    if cls.init then
        cls.init(w, ...)
    end
    w.__widget_slot = i
    w._z = world.widgets_next_z
    world.widgets_next_z = world.widgets_next_z + 1
    world.widgets_alive[i - 1] = 1
    L:debug("allocate widget %s -> slot %d", cls.__name or "?", i)
    return w
end

--- Mark a widget's slot dead so it can be recycled. Runs mixin teardown
--- (unsubscribes bus listeners) first, then clears the alive bit.
---@param w table
function world.destroy_widget(w)
    local unsubs = rawget(w, "_unsubs")
    if unsubs ~= nil then
        for i = #unsubs, 1, -1 do
            unsubs[i]()
        end
        w._unsubs = nil
    end
    local i = rawget(w, "__widget_slot")
    L:debug("destroy widget %s slot %s", w.__name or "?", tostring(i))
    if i ~= nil then
        world.widgets_alive[i - 1] = 0
    end
end

--- Find the topmost living widget under `pos` with the given capability
--- flag (`_hoverable` or `_clickable`). Later allocations sit higher in
--- z-order, matching draw order.
---@param pos table   {x=, y=}
---@param flag string "_hoverable" | "_clickable"
---@return table|nil
function world.widget_topmost(pos, flag)
    local best, best_z = nil, -1
    local n = world.widgets_capacity
    local alive = world.widgets_alive
    local slots = world.widgets_slots
    for i = 1, n do
        if alive[i - 1] == 1 then
            local w = slots[i]
            if w[flag] and w._contains and w:_contains(pos) then
                if w._z > best_z then
                    best_z = w._z
                    best = w
                end
            end
        end
    end
    return best
end

----------------------------------------------------------------------------------------------------
-- Rendering: map + entity overlay
----------------------------------------------------------------------------------------------------

--- Brightness factor (0..1) for a layer `d` levels below the camera z.
---@param d integer  depth offset (0 = current layer).
---@return number
local function depth_brightness(d)
    if d <= 0 then
        return 1.0
    end
    return math.max(MIN_BRIGHTNESS, 1.0 - d * DEPTH_FADE_PER_LEVEL)
end

--- Brightness factor (0..1) for a layer `h` levels ABOVE the camera z.
--- Dimmer than the current layer so the ceiling reads as see-through.
---@param h integer  height offset (1 = layer just above).
---@return number
local function height_brightness(h)
    return math.max(CEIL_MIN_BRIGHTNESS, 1.0 - h * CEIL_FADE_PER_LEVEL)
end

--- Lerp a color toward black by a brightness factor (1 = full, 0 = black).
---@param c table  {r=,g=,b=}
---@param f number  brightness factor.
---@return table
local function shade_color(c, f)
    return {
        r = math.floor(c.r * f),
        g = math.floor(c.g * f),
        b = math.floor(c.b * f),
    }
end

--- Rebuild the depth-shaded appearance cache. shade[d] maps each tile
--- type value -> {fg={r,g,b}, bg={r,g,b}, glyph=int}, colors pre-lerped
--- toward black for depth offset d, lerped from each tile-type def's
--- Renderable state (first glyph's colors). The render loop is then a
--- pure table read + put_rgb, no per-tile color math. Rebuild only when
--- cam.z changes. Also builds the ABOVE cache `_shade_above[h]` for layers
--- above the camera (dimmed), used by the ceiling pass of render_map.
---@param max_depth integer  number of depth levels to precompute (cam.z+1).
---@param above_count integer  number of above-ceiling levels (map.d-1 - cam.z).
local function rebuild_shade(max_depth, above_count)
    local defs = tile.defs
    local Open = tile.TileType.Open
    local shade = {}
    for d = 0, max_depth do
        local f = depth_brightness(d)
        local entry = {}
        for type_val, def in pairs(defs) do
            -- Open air is clear: omit it so the renderer skips it
            -- (entry[Open] == nil) and lower layers show through. Every
            -- other type caches its first glyph, lerped by depth. The
            -- `connect` spec (neighbor-aware glyph resolution) is carried
            -- as a shared pointer — the renderer resolves the per-cell
            -- glyph from it; nil = fixed glyph (the cached `glyph`).
            if type_val ~= Open then
                local g0 = def.glyphs[1]
                entry[type_val] = {
                    fg = shade_color(g0.fg or def.fg, f),
                    bg = shade_color(g0.bg or def.bg, f),
                    glyph = g0.ch,
                    connect = def.connect,
                }
            end
        end
        shade[d] = entry
    end
    world._shade = shade
    world._shade_max_depth = max_depth

    -- Above layers (ceiling): keyed by height h = z - cam.z (1..above_count).
    -- Same per-type glyph cache, lerped by height_brightness (dimmer).
    local above = {}
    for h = 1, above_count do
        local f = height_brightness(h)
        local entry = {}
        for type_val, def in pairs(defs) do
            if type_val ~= Open then
                local g0 = def.glyphs[1]
                entry[type_val] = {
                    fg = shade_color(g0.fg or def.fg, f),
                    bg = shade_color(g0.bg or def.bg, f),
                    glyph = g0.ch,
                    connect = def.connect,
                }
            end
        end
        above[h] = entry
    end
    world._shade_above = above
    world._shade_above_count = above_count
end

--- Adjust the camera's peek height: how many z levels above the player's
--- layer the ceiling render reaches. PgUp increases, PgDn decreases to 0
--- (no peek — only the player's layer + below show). Clamped to the
--- world's layer count. Does NOT move the player; only the camera's view.
---@param dz integer  +1 to peek higher, -1 to peek lower.
function world.peek(dz)
    local off = world.cam.z_offset + dz
    if off < 0 then
        off = 0
    end
    local max_off = world.map.d - 1 - world.cam.z
    if off > max_off then
        off = max_off
    end
    world.cam.z_offset = off
    L:debug("peek %+d -> z_offset=%d (ceil_top=%d)", dz, off, world.cam.z + off)
end

--- Recompute the player's field of view from the camera cell (which tracks
--- the player via the per-frame sync in GameScreen.draw). NATIVE 3D FOV
--- (src/fov.lua): one 3D supercover ray per candidate voxel, blocked by any
--- `Opaque` voxel — so walls block in-plane and a solid ceiling cuts off
--- upper layers except where it's Open (a skylight lets rays climb).
---
--- UNLIMITED-RANGE, VIEWPORT-BOUNDED: there is NO vision radius and NO
--- spherical falloff — the player sees as far as real eyes do, blocked only
--- by opaque terrain. We bound the COMPUTED set to the rendered viewport (the
--- camera's screen rect × the rendered z-window 0..cam.z+z_offset): cells
--- outside the viewport never paint, so casting rays to them would be wasted
--- work. The box is passed to fov via `opts.box`; fov.visible_tiles
--- iterates exactly that extent instead of a vision sphere.
---
--- NO MEMORY: only the per-frame Visible set is kept — what the player can
--- see right now. There is no Explored/memory flag: a cell renders iff it's
--- Visible this frame, so moving away from a lit area drops it to black
--- immediately (a torch in a pitch cave; you see only what's currently lit).
--- This removes the whole class of brightness-inversion bugs where remembered
--- terrain read brighter than visible-but-unlit cells.
---
--- Each frame:
---   1. Clear `TileFlags.Visible` on EVERY cell (per-frame; no accumulation).
---   2. Compute the visible set from the player's cell over the viewport box.
---   3. Mark `Visible` on the visible cells (the box already bounds them to
---      the rendered z-window; the per-cell z clamp is a defensive no-op).
---
--- Opaque predicate reads `band(flags, Opaque)` straight from the map's
--- flags field cdata. Expensive part (the field build) is `fov.visible_tiles`,
--- which is zero-alloc steady-state (uint8 cdata buffer).
function world.update_fov()
    local map = world.map
    local W, H, D = map.w, map.h, map.d
    local flags = map.flags.cdata
    local TF = tile.TileFlags
    local VisibleBit = TF.Visible
    local OpaqueBit = TF.Opaque
    local OpaqueBit = TF.Opaque
    -- 1. Clear this frame's Visible everywhere (no accumulation).
    for i = 0, map.count - 1 do
        flags[i] = bit.band(flags[i], bit.bnot(VisibleBit))
    end
    -- 2. Compute the visible set from the camera cell (the player) over the
    --    RENDERED VIEWPORT BOX (unlimited range, viewport-bounded). Derive
    --    the same ox/oy/z-window render_map paints so FOV + render match the
    --    painted region exactly. view_cols/view_rows come from GameScreen each
    --    frame (set right before this call); fall back to map extent if unset.
    local cam = world.cam
    local cols = cam.view_cols or W
    local vrows = cam.view_rows or H
    local z_max = cam.z + (cam.z_offset or 0)
    if z_max < 0 then
        z_max = 0
    end
    if z_max > D - 1 then
        z_max = D - 1
    end
    local ox = cam.x - math.floor(cols / 2)
    local oy = cam.y - math.floor(vrows / 2)
    -- Clamp the box to the grid (fov also clamps, but clamping here keeps the
    -- candidate count minimal for an off-edge camera).
    local minx = math.max(0, ox)
    local miny = math.max(0, oy)
    local minz = 0
    local maxx = math.min(W - 1, ox + cols - 1)
    local maxy = math.min(H - 1, oy + vrows - 1)
    local maxz = z_max
    local vis_tiles = fov.visible_tiles({ cam.x, cam.y, cam.z }, {
        dims = { W, H, D },
        opaque = function(x, y, z)
            return bit.band(flags[((z * H) + y) * W + x], OpaqueBit) ~= 0
        end,
        box = { minx, miny, minz, maxx, maxy, maxz },
    })
    -- 3. Mark Visible ONLY. No memory/Explored: the Visible set is purely
    --    per-frame (what the player can see right now). Memory is gone — it
    --    was the source of brightness-inversion bugs (remembered terrain
    --    reading brighter than visible-but-unlit cells). Now FOV is the hard
    --    render boundary: a cell renders iff it's Visible this frame.
    for _, c in ipairs(vis_tiles) do
        local cz = c[3]
        if cz >= 0 and cz <= z_max then
            local i = ((cz * H) + c[2]) * W + c[1]
            flags[i] = bit.bor(flags[i], VisibleBit)
        end
    end
end

----------------------------------------------------------------------------------------------------
-- Lighting
----------------------------------------------------------------------------------------------------

--- Clear the per-frame light array. When `is_dark` (no sun), every cell is
--- reset to 0 (unlit) so LightSource floods fill it this frame; when not
--- `is_dark` (the sun exists), every cell is reset to 255 (fully lit) and
--- `world.update_lights` early-outs, so a torch in daylight does nothing.
---
--- `world.update_lights` calls this first, then each active LightSource adds
--- into the array. Returns the value the array was filled with (0 or 255) so
--- callers can early-out the light flood when the sun is up.
---@return integer fill  the value the light array was reset to (0 or 255).
function world.clear_lights()
    local map = world.map
    if not map.is_dark then
        -- Sun exists: daylight render path. Fill 255 so any straggling
        -- light from a previous dark frame is wiped; the flood is skipped
        -- by the caller, and render uses the depth-shade path unchanged.
        ffi.fill(map.light, map.count, 255)
        return 255
    end
    ffi.fill(map.light, map.count, 0)
    return 0
end

--- Register a LightSource entity with the world light registry (called from
--- `LightSource.init`). Returns an UNREGISTER fn the caller appends to the
--- entity's `_unsubs` (the SAME convention as `bus.subscribe`), so
--- `world.destroy` walking `_unsubs` newest-first removes a destroyed light
--- the same frame. Idempotent: re-registering an already-registered light is
--- a no-op; the returned unregister fn removes it from the set (not a count).
---@param light table  a LightSource-bearing entity (has light_* fields + Position).
---@return function unregister  call to remove `light` from the registry.
function world.add_light(light)
    world.lights[light] = true
    return function()
        world.lights[light] = nil
    end
end

--- Remove a light from the registry. Idempotent. Convenience form for ad-hoc
--- removal; the preferred path is the `_unsubs` fn `add_light` returns
--- (auto-run by `world.destroy`).
---@param light table
function world.remove_light(light)
    world.lights[light] = nil
end

----------------------------------------------------------------------------------------------------
-- Light propagation (per-frame flood)
----------------------------------------------------------------------------------------------------

-- Module-level upvalues for the light flood hot path: the opaque flag, the
-- light array, and dims. Set at the top of `world.update_lights` so the
-- `passable` / `transition` / cone-filter closures capture locals, not
-- `world.*` table lookups per cell (the flood calls them once per visited
-- neighbor — table lookups there would dominate).
local _opaque_bit
local _light_cdata
local _light_flags
local _light_dims_w, _light_dims_h, _light_dims_d

-- Wall-surface flood scratch (see the WALL-SURFACE PASS in update_lights):
-- `wdist` maps cell-index -> accumulated path distance for opaque cells
-- reached by THIS light's wall pass (a Lua table keyed only by reached walls —
-- typically a tiny set, the thin walls near the light, so a table beats a
-- full-count uint32 array). Each wave builds a fresh frontier list (`local` in
-- the loop) — the wall set near a light is tiny, so per-wave allocation is
-- negligible and the logic stays simple (no double-buffer swap bugs).
-- `WALL_OFFSETS` is the 26-connected neighbor offsets (x,y,z triples, flat)
-- so the wall pass matches the air flood's 26-connected spread.
local wdist = {}
local WALL_OFFSETS = (function()
    local t = {}
    for dz = -1, 1 do
        for dy = -1, 1 do
            for dx = -1, 1 do
                if not (dx == 0 and dy == 0 and dz == 0) then
                    t[#t + 1] = dx
                    t[#t + 1] = dy
                    t[#t + 1] = dz
                end
            end
        end
    end
    return t
end)()

--- Light-specific vertical transition: light climbs or descends a z-layer
--- through ANY non-opaque voxel (the cell we're in AND the cell above/below
--- are both non-opaque). This models light passing through Open air / an
--- Open ceiling "skylight" hole, exactly as the native-3D FOV rays do — NOT
--- restricted to stairs/ramps the way the walking `default_transition` is
--- (light doesn't need a staircase). Returns an iterator of reachable
--- (nx, ny, nz) vertical neighbors.
local function light_transition(x, y, z, opts)
    -- We must consult opacity at the CURRENT cell too: a light inside an
    -- opaque wall shouldn't leak vertically. (Non-opaque cells: Open air,
    -- Floor — light passes; Wall/closed ceiling blocks.)
    local flags = _light_flags
    local W, H = _light_dims_w, _light_dims_h
    if bit.band(flags[((z * H) + y) * W + x], _opaque_bit) ~= 0 then
        return function() end
    end
    local D = _light_dims_d
    local dirs = {}
    if z + 1 < D then
        if bit.band(flags[(((z + 1) * H) + y) * W + x], _opaque_bit) == 0 then
            dirs[#dirs + 1] = 1
        end
    end
    if z - 1 >= 0 then
        if bit.band(flags[(((z - 1) * H) + y) * W + x], _opaque_bit) == 0 then
            dirs[#dirs + 1] = -1
        end
    end
    if #dirs == 0 then
        return function() end
    end
    local i = 0
    return function()
        i = i + 1
        if i > #dirs then
            return nil
        end
        return x, y, z + dirs[i]
    end
end

--- Per-frame lighting pass. When the map is NOT dark (`is_dark == false`),
--- the sun exists and lights are invisible — `clear_lights` fills 255 and we
--- early-out (render uses the depth-shade path unchanged).
---
--- When dark: `clear_lights(0)` first, then for EACH registered LightSource
--- run a `pf.distance_field` Dijkstra flood from its cell over the connected
--- non-opaque air volume: `passable = not opaque`, a light-specific
--- `transition` (climbs/descends through ANY non-opaque voxel, not just
--- stairs), euclidean `cost` (1 cardinal / sqrt2 diagonal, so the flood is
--- a true 3D sphere), and `budget = radius` (cost cap = the light's reach).
--- Walk the reached cells; each contributes `floor(peak * (1 - g/radius))`
--- (linear falloff to 0 at `radius`), ADDED into the map `light` array and
--- clamped at 255 (overlapping lights sum). gscore is an INTEGER (euclidean
--- cost scaled here by 1000 so sqrt2 ≈ 1414 fits an int32), so we scale back.
---
--- Falloff by PATH distance (Dijkstra), not euclidean bird's-eye — this is
--- Option A: light bends around corners and leaks through doorways, the
--- soft roguelike look. Opaque voxels are light-opaque (no passable), so
--- light fills a room's connected air and stops at walls.
function world.update_lights()
    local map = world.map
    if not map.is_dark then
        world.clear_lights() -- fills 255 + early-out (daylight path)
        return
    end
    local W, H, D = map.w, map.h, map.d
    local count = map.count
    local flags = map.flags.cdata
    local light = map.light
    local OpaqueBit = tile.TileFlags.Opaque
    -- Reset upvalues for the closures captured below (set ONCE per frame,
    -- not per light).
    _opaque_bit = OpaqueBit
    _light_cdata = light
    _light_flags = flags
    _light_dims_w, _light_dims_h, _light_dims_d = W, H, D
    -- Clear to 0 ONLY the rendered viewport: render_map reads `light[idx]`
    -- solely for cells in the cam view box (cols × view_rows × z-window),
    -- so stale light values outside it are never read and need not be cleared.
    -- On the 2000×2000×10 map this turns a full-map 40 MB memset/frame into
    -- a ~few-KB box clear. Cells scrolled into view next frame are re-cleared
    -- + re-flooded then, so partial clearing stays correct.
    local cam = world.cam
    local vcols = cam.view_cols or W
    local vrows = cam.view_rows or H
    local z_max = cam.z + (cam.z_offset or 0)
    if z_max < 0 then
        z_max = 0
    end
    if z_max > D - 1 then
        z_max = D - 1
    end
    local ox = cam.x - math.floor(vcols / 2)
    local oy = cam.y - math.floor(vrows / 2)
    local cx0 = ox < 0 and 0 or ox
    local cx1 = ox + vcols - 1
    if cx1 > W - 1 then
        cx1 = W - 1
    end
    local cy0 = oy < 0 and 0 or oy
    local cy1 = oy + vrows - 1
    if cy1 > H - 1 then
        cy1 = H - 1
    end
    local span = cx1 - cx0 + 1
    if span > 0 and cy0 <= cy1 then
        for z = 0, z_max do
            local zbase = (z * H) * W
            for y = cy0, cy1 do
                ffi.fill(light + zbase + y * W + cx0, span, 0)
            end
        end
    end

    if next(world.lights) == nil then
        return -- no lights: the world stays fully dark this frame
    end

    -- Euclidean cost scaled by 1000 (integer Dijkstra; sqrt2 = 1414, so a
    -- radius of e.g. 8 becomes a budget of 8000). Cardinal step = 1000,
    -- diagonal = 1414. We scale back by /1000 when computing intensity.
    local COST_SCALE = 1000
    local sqrt2 = math.floor(math.sqrt(2) * COST_SCALE + 0.5)
    local function euclid_cost(ax, ay, az, bx, by, bz)
        local dx = bx - ax
        local dy = by - ay
        local dz = bz - az
        if dx ~= 0 and dy ~= 0 and dz ~= 0 then
            return 1732 -- 3D diagonal (sqrt3) scaled
        elseif dx ~= 0 and dy ~= 0 then
            return sqrt2
        elseif dx ~= 0 and dz ~= 0 then
            return sqrt2
        elseif dy ~= 0 and dz ~= 0 then
            return sqrt2
        else
            return COST_SCALE -- single-axis step
        end
    end

    local function not_opaque(x, y, z)
        return bit.band(flags[((z * H) + y) * W + x], OpaqueBit) == 0
    end

    for light_entity in pairs(world.lights) do
        if light_entity.alive ~= false then
            local sx = math.floor(light_entity.x)
            local sy = math.floor(light_entity.y)
            local sz = math.floor(light_entity.z)
            if sx >= 0 and sx < W and sy >= 0 and sy < H and sz >= 0 and sz < D then
                local radius = light_entity.light_radius
                local peak = light_entity.light_intensity
                local budget = radius * COST_SCALE
                --- Cone params (precomputed once per light; nil for spheres).
                --- A cell receives light only if its offset from the source
                --- lies within the cone's solid angle: normalize(offset)·dir
                --- >= cos(half_angle). We precompute cos(half_angle) and a
                --- normalized dir and a squared-vs-dotted-threshold form that
                --- avoids per-cell sqrt: the test `dot(o,dir) >= cos(ang) * |o|`
                --- squares to `dot^2 >= cos2*|o|^2` (only when cos>=0, i.e.
                --- half_angle <= 90°, which is always true for real cones).
                local cone = nil
                if light_entity.light_shape == "cone" then
                    local d = light_entity.light_dir
                    local dl = d[1] * d[1] + d[2] * d[2] + d[3] * d[3]
                    if dl > 0 then
                        local inv = 1.0 / math.sqrt(dl)
                        local cos_a = math.cos(light_entity.light_half_angle)
                        cone = {
                            dx = d[1] * inv,
                            dy = d[2] * inv,
                            dz = d[3] * inv,
                            cos2 = cos_a * cos_a, -- squared threshold
                            -- The actual test: `dot(o,dir) >= cos(ang) * |o|`.
                            -- Since half_angle <= pi/2 ⇒ cos(ang) >= 0, both
                            -- sides are nonneg when |o|>=0, so squaring is safe:
                            -- dot^2 >= cos2 * (ox²+oy²+oz²). The source cell
                            -- (offset 0) is always lit (torch lights itself).
                        }
                    end
                end
                local field = pf.distance_field({
                    dims = { W, H, D },
                    source = { sx, sy, sz },
                    passable = not_opaque,
                    cost = euclid_cost,
                    transition = light_transition,
                    diagonal = true,
                    budget = budget,
                    -- Box-scoped: confine the arena memset + the reached-cell
                    -- log to a box around the source. The flood can't reach
                    -- past `budget` (= radius), so a box of source ± (radius+2)
                    -- covers every air cell it opens AND the one-step-into-wall
                    -- cells of the wall pass below. On the 2000×2000×10 map
                    -- this turns a per-light 40 MB memset + 40 M-cell scan into
                    -- a tiny box memset + a few-thousand-cell iteration.
                    box = {
                        math.max(0, sx - radius - 2),
                        math.max(0, sy - radius - 2),
                        math.max(0, sz - radius - 2),
                        math.min(W - 1, sx + radius + 2),
                        math.min(H - 1, sy + radius + 2),
                        math.min(D - 1, sz + radius + 2),
                    },
                })
                local gscore = field.gscore
                local visited = field.visited
                if visited == nil then
                    goto continue -- box disabled / search failure: skip this light
                end
                local inv_r = 1.0 / budget -- inverse scaled budget (so 1 = at source)
                -- The source cell is gscore 0. Walk every cell the flood REACHED
                -- (the `visited` list of global indices, not a 0..count-1 scan):
                -- gscore is valid for exactly these (unseen cells carry stale
                -- gscore from the pooled scratch buffer, so we MUST not read them).
                --
                -- Falloff: a GENTLE curve (1 - (g/radius)²) so the lit pool
                -- holds near-full brightness through most of the radius and
                -- only softens at the edge — feels like a bright torch with a
                -- soft penumbra, rather than a linear ramp that dims immediately.
                for _, i in ipairs(visited) do
                    local g = gscore[i]
                    if g <= budget then
                        local frac = g * inv_r -- 0 at source, 1 at radius
                        local t = 1.0 - frac * frac -- bright core, soft edge
                        if t > 0 then
                            --- Cone angular filter (sphere lights skip this). The
                            --- source cell (offset 0) is always in-cone and lit.
                            local in_cone = true
                            if cone ~= nil then
                                local cz = math.floor(i / (W * H))
                                local rem2 = i - cz * W * H
                                local cy = math.floor(rem2 / W)
                                local cx = rem2 - cy * W
                                local ox = cx - sx
                                local oy = cy - sy
                                local oz = cz - sz
                                if ox ~= 0 or oy ~= 0 or oz ~= 0 then
                                    local dot = ox * cone.dx + oy * cone.dy + oz * cone.dz
                                    local len2 = ox * ox + oy * oy + oz * oz
                                    if dot * dot < cone.cos2 * len2 then
                                        in_cone = false
                                    elseif dot < 0 then
                                        -- Behind the source (cone points away):
                                        -- dot may be positive but the squared
                                        -- test passes only for forward hemisphere
                                        -- when cos(ang) >= 0; guard dot < 0 out.
                                        in_cone = false
                                    end
                                end
                            end
                            if in_cone then
                                local add = math.floor(peak * t)
                                if add > 0 then
                                    local cur = light[i]
                                    local nv = cur + add
                                    if nv > 255 then
                                        nv = 255
                                    end
                                    light[i] = nv
                                end
                            end
                        end
                    end
                end

                --- WALL-SURFACE PASS (this light): opaque cells (walls,
                --- pillars, ceilings) the player can SEE render black otherwise,
                --- because the air flood above never enters them (they're
                --- light-opaque for PROPAGATION — light doesn't pass through).
                --- But a wall BLOCKS light and is itself illuminated up to its
                --- far edge: light enters the wall face from the lit air touching
                --- it, penetrates the wall's thickness (diminishing), and does
                --- NOT bleed out the far side into air (so walls still cast
                --- shadows). Implemented as a small BFS over opaque cells seeded
                --- by reached air cells (distance d_air + one step), propagating
                --- wall→wall only, bounded by the same radius budget. 1-cell
                --- walls/pillars light fully (their air-facing surface IS the
                --- whole cell); thicker walls dim through to the far edge.
                ---
                --- Per-light so the falloff is continuous (the wall's distance
                --- continues the air path distance). The wall uses the SAME
                --- quadratic falloff as air; a wall cell at distance d gets
                --- intensity peak*(1-(d/budget)^2), added into light[] (clamp).
                local WALL_STEP = COST_SCALE -- one cell into the wall / wall→wall
                local frontier = {} -- current wave's wall cell indices
                -- Seed: every opaque cell adjacent to a reached AIR cell. Its
                -- distance = (the air cell's path distance) + one step into
                -- the wall face. We iterate the air flood's `visited` cells
                -- (not 0..count-1) and look at their opaque neighbors. Air
                -- neighbors were already handled by the flood; we only ENTER
                -- walls here, so no light bleeds out the far side (walls still
                -- cast shadows).
                for _, ai in ipairs(visited) do
                    local ag = gscore[ai]
                    if ag <= budget and ag + WALL_STEP <= budget then
                        local az = math.floor(ai / (W * H))
                        local arem = ai - az * W * H
                        local ay = math.floor(arem / W)
                        local ax = arem - ay * W
                        for k = 1, #WALL_OFFSETS, 3 do
                            local nx = ax + WALL_OFFSETS[k]
                            local ny = ay + WALL_OFFSETS[k + 1]
                            local nz = az + WALL_OFFSETS[k + 2]
                            if nx >= 0 and nx < W and ny >= 0 and ny < H and nz >= 0 and nz < D then
                                local ni = ((nz * H) + ny) * W + nx
                                if bit.band(flags[ni], OpaqueBit) ~= 0 then
                                    local nd = ag + WALL_STEP
                                    if wdist[ni] == nil or nd < wdist[ni] then
                                        wdist[ni] = nd
                                        frontier[#frontier + 1] = ni
                                    end
                                end
                            end
                        end
                    end
                end

                -- Propagate wall→wall (diminishing) until the budget runs out
                -- or no more wall cells reach. Each wave builds a fresh next
                -- frontier (the wall set near a light is tiny — thin walls —
                -- so per-wave allocation is negligible). A wall cell reached
                -- by a shorter path is re-enqueued; reprocessing is idempotent
                -- (same light value recomputed) and the budget bounds it.
                while #frontier > 0 do
                    local next_frontier = {}
                    for idx = 1, #frontier do
                        local ci = frontier[idx]
                        local cd = wdist[ci]
                        if cd <= budget then
                            -- accumulate this wall cell's light contribution
                            local frac = cd * inv_r
                            local tw = 1.0 - frac * frac
                            if tw > 0 then
                                local add = math.floor(peak * tw)
                                if add > 0 then
                                    local c = light[ci]
                                    local nv = c + add
                                    if nv > 255 then
                                        nv = 255
                                    end
                                    light[ci] = nv
                                end
                            end
                            -- expand to wall neighbors (wall→wall only — no
                            -- bleed into far-side air, so walls cast shadows)
                            if cd + WALL_STEP <= budget then
                                local cz = math.floor(ci / (W * H))
                                local crem = ci - cz * W * H
                                local cy = math.floor(crem / W)
                                local cx = crem - cy * W
                                for k = 1, #WALL_OFFSETS, 3 do
                                    local nx = cx + WALL_OFFSETS[k]
                                    local ny = cy + WALL_OFFSETS[k + 1]
                                    local nz = cz + WALL_OFFSETS[k + 2]
                                    if
                                        nx >= 0
                                        and nx < W
                                        and ny >= 0
                                        and ny < H
                                        and nz >= 0
                                        and nz < D
                                    then
                                        local ni = ((nz * H) + ny) * W + nx
                                        if bit.band(flags[ni], OpaqueBit) ~= 0 then
                                            local nd = cd + WALL_STEP
                                            if wdist[ni] == nil or nd < wdist[ni] then
                                                wdist[ni] = nd
                                                next_frontier[#next_frontier + 1] = ni
                                            end
                                        end
                                    end
                                end
                            end
                        end
                    end
                    frontier = next_frontier
                end
                -- reset the per-light wdist scratch for the next light.
                for k in pairs(wdist) do
                    wdist[k] = nil
                end
            end
        end
        ::continue::
    end
end

--- Resolve the glyph for cell (wx,wy,z) of tile-type `tv` using shade entry
--- `s`. Two paths:
---   * Fast (no z): if `s.connect` is nil → fixed `s.glyph`; if present but
---     `s.connect.z` is falsy → 4-bit N/E/S/W mask (today's box-drawing
---     walls). No vertical neighbor reads.
---   * Slow (z-aware): if `s.connect.z` is true → 6-bit mask: the 4 cardinals
---     (low bits, same as above) PLUS bit 16 = cell-above (z+1) linked,
---     bit 32 = cell-below (z-1) linked. Looks up `glyphs[mask]` with the
---     same default fallback. Used by future vertical-spanning tiles
---     (columns/pillars); current tiles never set `z`, so they stay fast.
--- Bounds: cardinal single-side guards; the z reads are guarded by 0<=z<D.
--- The z-branch is the only hot-path cost of opting into 6-bit; 4-bit tiles
--- never touch it.
local function resolve_glyph(types, W, H, D, wx, wy, z, tv, s)
    local connect = s.connect
    if connect == nil then
        return s.glyph -- fast path: fixed glyph
    end
    local link = connect.link
    local b = 0
    -- N (0,-1)
    if wy - 1 >= 0 and link[types[((z * H) + wy - 1) * W + wx]] then
        b = b + 1
    end
    -- E (+1,0)
    if wx + 1 < W and link[types[((z * H) + wy) * W + wx + 1]] then
        b = b + 2
    end
    -- S (0,+1)
    if wy + 1 < H and link[types[((z * H) + wy + 1) * W + wx]] then
        b = b + 4
    end
    -- W (-1,0)
    if wx - 1 >= 0 and link[types[((z * H) + wy) * W + wx - 1]] then
        b = b + 8
    end
    -- 6-bit path: only for tiles whose connect spec opts in with `z = true`.
    if connect.z then
        if z + 1 < D and link[types[((z + 1) * H + wy) * W + wx]] then
            b = b + 16 -- up: cell above links
        end
        if z - 1 >= 0 and link[types[((z - 1) * H + wy) * W + wx]] then
            b = b + 32 -- down: cell below links
        end
    end
    local cp = connect.glyphs[b]
    if cp ~= nil then
        return cp
    end
    return connect.default
end

--- Render the map to `con`, centered on the camera. DEFAULT-DARK: cells
--- that are NOT `TileFlags.Visible` this frame render nothing (the world
--- opens black and is revealed as the player moves — no memory). `world.update_fov`
--- recomputes the per-frame Visible set each frame from the camera (player) cell;
--- FOV is the hard render boundary.
---
--- Per cell, one z loop 0..ceil_top (ceil_top = cam.z + z_offset):
---   • Visible at/below cam.z → the shaded appearance (depth-below/height-
---     above falloff from the shade cache). In a DARK world (`is_dark`), this
---     is lerped between BLACK and the shaded color by the cell's light value
---     (L/255): unlit visible cells render near-black, lit cells full shade.
---     In daylight the shade IS the ambient sun, applied directly.
---   • Visible above cam.z → the same, composed with the x-ray hole ring.
---   • NOT Visible → no `put` at all (the cell stays at con:clear's bg).
---
--- The X-ray concentric-ring ceiling pass is GONE: native-3D FOV reveals
--- open-ceiling voxels directly (rays climb through Open air above the
--- player and stop at opaque ones), so there's no "peel the roof back"
--- composite to run — visible ceiling cells just render like any other.
--- Tiles with a `connect` spec resolve their glyph per-cell (box-drawing
--- walls etc.); other tiles use their cached fixed glyph.
---
--- The map renders into rows 0..view_rows-1 (the VISIBLE map region,
--- above the message panel). `view_rows` defaults to `cam.view_rows` if
--- set by the caller (main.lua reserves PANEL_H rows at the bottom),
--- else the full console height. The camera centers in this region so
--- the player sits mid-screen of the VISIBLE area, not the full console.
---@param con table  iw.Console (blt shim)
---@param view_rows? integer  usable map rows (default cam.view_rows or con:height()).
function world.render_map(con, view_rows)
    local cam = world.cam
    local map = world.map
    local W, H = map.w, map.h
    local D = map.d
    local cols, rows = con:width(), con:height()
    local vrows = view_rows or cam.view_rows or rows
    local ox = cam.x - math.floor(cols / 2)
    local oy = cam.y - math.floor(vrows / 2)
    local ceil_top = cam.z + (cam.z_offset or 0)
    -- Shade cache covers depth-below (0..cam.z) and height-above
    -- (1..above_count). rebuild_shade keys the above cache by height, so
    -- it works for any ceil_top up to map.d-1; rebuild only when the
    -- camera's depth or the rendered above-count changes.
    local above_count = (D - 1) - cam.z
    if
        world._shade == nil
        or world._shade_max_depth ~= cam.z
        or world._shade_above_count ~= above_count
    then
        L:debug("rebuild shade (depth=%d above=%d)", cam.z, above_count)
        rebuild_shade(cam.z, above_count)
    end
    local shade = world._shade -- [depth_below] = per-type appearance
    local above = world._shade_above -- [height_above] = per-type appearance
    local types = map.types.cdata
    local flags = map.flags.cdata
    local light_arr = map.light -- per-cell 0-255 light value (dark mode driver)
    local is_dark = map.is_dark -- "does the sun exist?" — false = today's path
    local TF = tile.TileFlags
    local VisibleBit = TF.Visible
    local Open = tile.TileType.Open
    local camz = cam.z
    local cpx, cpy = cam.x, cam.y
    --- Resolve the (fg, bg) the below pass left at column (wx,wy): the
    --- shaded appearance of the topmost non-Open tile at z <= cam.z, or
    --- BLACK if the whole column is Open air (nothing was painted). Used
    --- by the x-ray ring lerp so a carved-out ceiling dissolves into the
    --- actual cell beneath it rather than a fixed color.
    local function below_color(wx, wy)
        for bz = camz, 0, -1 do
            local i_b = ((bz * H) + wy) * W + wx
            local tv = types[i_b]
            if tv ~= Open then
                local s = shade[camz - bz][tv]
                if s ~= nil then
                    local bfg, bbg = s.fg, s.bg
                    -- Dark mode: the below cell is ALSO visible (lit by the
                    -- light array), so its color must be dark-lerped by its
                    -- own light value before the x-ray ring composes with it.
                    if is_dark then
                        local L = light_arr[i_b]
                        if L < 255 then
                            local t = L / 255.0
                            bfg = lerp_color(BLACK, bfg, t)
                            bbg = lerp_color(BLACK, bbg, t)
                        end
                    end
                    return bfg, bbg
                end
            end
        end
        return BLACK, BLACK
    end
    -- composition is toggled lazily across the ring pass: track the mode so
    -- terminal_composition is called only on transitions (core/outside=OFF,
    -- rings=ON), not per cell. Reset at the start of each frame.
    local comp_on = false
    -- Walk z bottom-to-top; upper layers overwrite lower (a visible ceiling
    -- cell paints over the open air below it, exactly as before).
    for z = 0, ceil_top do
        local d = cam.z - z -- depth-below (<=0 means at/above the camera)
        local entry
        if d >= 0 then
            entry = shade[d]
        else
            entry = above[-d] -- height above the camera (1..)
        end
        if entry ~= nil then
            for cy = 0, vrows - 1 do
                local wy = oy + cy
                if wy >= 0 and wy < H then
                    for cx = 0, cols - 1 do
                        local wx = ox + cx
                        if wx >= 0 and wx < W then
                            local i = ((z * H) + wy) * W + wx
                            local fl = flags[i]
                            local is_visible = bit.band(fl, VisibleBit) ~= 0
                            if is_visible then
                                local tv = types[i]
                                local s = entry[tv]
                                if s ~= nil then
                                    local ch = resolve_glyph(types, W, H, D, wx, wy, z, tv, s)
                                    local fg, bg = s.fg, s.bg
                                    -- DARK MODE: when is_dark, the `light` array
                                    -- drives brightness instead of sunlight —
                                    -- lerp THIS visible cell's shaded appearance
                                    -- between BLACK (unlit, L=0) and its full
                                    -- sunlit shade (L=255), BEFORE the x-ray/full
                                    -- branches use it (so the x-ray composes two
                                    -- already-lit colors). FOV is the hard render
                                    -- boundary: no memory, so only the per-frame
                                    -- Visible set ever reaches here.
                                    if is_dark then
                                        local L = light_arr[i]
                                        if L < 255 then
                                            local t = L / 255.0
                                            fg = lerp_color(BLACK, fg, t)
                                            bg = lerp_color(BLACK, bg, t)
                                        end
                                    end
                                    if z > camz then
                                        -- VISIBLE above-layer cell: carve
                                        -- the x-ray hole. CORE = skip (the
                                        -- hole); rings = lerp ceiling→below
                                        -- by alpha (bg manual, fg glyph
                                        -- alpha-blended via composition ON).
                                        local ddx = wx - cpx
                                        local ddy = wy - cpy
                                        local alpha = xray_alpha(ddx * ddx + ddy * ddy)
                                        if alpha == 0 then
                                            -- CORE hole: draw nothing; the
                                            -- below pass shows through.
                                        elseif alpha == 1.0 then
                                            if comp_on then
                                                con:composition(false)
                                                comp_on = false
                                            end
                                            con:put_rgb(cx, cy, ch, fg, bg)
                                        else
                                            if not comp_on then
                                                con:composition(true)
                                                comp_on = true
                                            end
                                            local bfg, bbg = below_color(wx, wy)
                                            local blended_bg = lerp_color(bbg, bg, alpha)
                                            local lfg = lerp_color(bfg, fg, alpha)
                                            local blended_fg = {
                                                r = lfg.r,
                                                g = lfg.g,
                                                b = lfg.b,
                                                a = math.floor(alpha * 255),
                                            }
                                            con:put_rgb(cx, cy, ch, blended_fg, blended_bg)
                                        end
                                    else
                                        -- Visible cell at/below cam.z: full.
                                        con:put_rgb(cx, cy, ch, fg, bg)
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    -- Always restore composition OFF (draw_entities + next frame's below
    -- pass expect the default overwrite mode).
    if comp_on then
        con:composition(false)
    end
end

--- Draw every living entity that exposes a `draw(console, cam)` method,
--- ONLY on cells currently in the player's FOV (`TileFlags.Visible`).
--- There is no memory, so off-screen entities are simply skipped — entities
--- are drawn on the camera's z layer and above, up to the peek height
--- (`z_offset`), the same z-window render_map paints. Scans the pooled
--- slots [1..capacity], skipping dead ones via the `world.alive` tombstone.
--- Entities without a `draw` method are skipped.
---@param con table  iw.Console (blt shim)
function world.draw_entities(con)
    local cam = world.cam
    local cz = cam.z
    local ceil_top = cz + (cam.z_offset or 0)
    local map = world.map
    local W, H = map.w, map.h
    local flags = map.flags.cdata
    local TF = tile.TileFlags
    local VisibleBit = TF.Visible
    local n = world.capacity
    local alive = world.alive
    local slots = world.slots
    for i = 1, n do
        if alive[i - 1] == 1 then
            local e = slots[i]
            local ez = e.z
            -- Only draw entities in the rendered z-window AND on a cell
            --- currently in the player's FOV. Memory cells' entities stay
            --- hidden by design. A MULTI-TILE entity draws if ANY of its
            --- footprint cells is visible (so a 2×2 body doesn't pop based
            --- on its origin cell); Drawable.draw then clips its glyphs to
            --- the viewport as before.
            if math.floor(ez) >= cz and math.floor(ez) <= ceil_top then
                local w = e.w or 1
                local h = e.h or 1
                local ex0, ey0 = math.floor(e.x), math.floor(e.y)
                local z0 = math.floor(ez)
                local any_visible = false
                for fx = ex0, ex0 + w - 1 do
                    if fx >= 0 and fx < W then
                        for fy = ey0, ey0 + h - 1 do
                            if fy >= 0 and fy < H then
                                local fi = ((z0 * H) + fy) * W + fx
                                if bit.band(flags[fi], VisibleBit) ~= 0 then
                                    any_visible = true
                                    break
                                end
                            end
                        end
                        if any_visible then
                            break
                        end
                    end
                end
                if any_visible then
                    local d = e.draw
                    if d ~= nil then
                        d(e, con, cam)
                    end
                end
            end
        end
    end
end

--- Find the first living entity (other than `ignore`) occupying cell
--- (x,y,z), or nil. An O(1) spatial-hash lookup (was an O(capacity)\n--- pool scan). Used by entity-vs-entity collision (Collidable:move) to\n--- detect e.g. a Stairs at the destination.
---@param x integer
---@param y integer
---@param z integer
---@param ignore? table  Skip this entity (the mover itself).
---@return table|nil
function world.entity_at(x, y, z, ignore)
    local map = world.map
    if x < 0 or x >= map.w or y < 0 or y >= map.h or z < 0 or z >= map.d then
        return nil
    end
    local i = ((z * map.h) + y) * map.w + x
    local bucket = world.occ[i]
    if bucket == nil then
        return nil
    end
    for _, e in ipairs(bucket) do
        if e ~= ignore then
            return e
        end
    end
    return nil
end

--- Cell indices for an entity's CURRENT footprint. Mirrors the Map's
--- z-major layout so a cell's bucket lives at the same index the map uses
--- for that (x,y,z). Returns the list of cells the entity's w×h footprint
--- covers at its floored origin. Local helper for occ_*. A 1×1 entity
--- (the default) returns a single-cell list — the historical case.
---@param e table
---@return integer[] cells
local function footprint_cells(e)
    local map = world.map
    local fx = math.floor(e.x or 0)
    local fy = math.floor(e.y or 0)
    local fz = math.floor(e.z)
    local w = e.w or 1
    local h = e.h or 1
    local cells = {}
    for cx = fx, fx + w - 1 do
        for cy = fy, fy + h - 1 do
            cells[#cells + 1] = ((fz * map.h) + cy) * map.w + cx
        end
    end
    return cells
end

--- Compute a set `{[cell_index]=true}` (fast membership test) over an
--- entity's CURRENT footprint. Local helper for occ_rehash: the diff
--- (old cells not in the new set) is what to remove.
---@param e table
---@return table set  {[cell_index]=true}.
local function footprint_set(e)
    local set = {}
    for _, i in ipairs(footprint_cells(e)) do
        set[i] = true
    end
    return set
end

--- Remove `e` from EVERY occupancy bucket its footprint covered (if any).
--- Idempotent: a no-op if `e.__cells` is unset (never added, or already
--- removed). Does NOT bounds-check the old cells — a teleport past the map
--- edge still cleans up the old buckets by index. Scans each (usually
--- 1-element) bucket list for `e` and removes it; emptied buckets are
--- pruned. Generalizes the old single-`__cell` path to a multi-cell body.
---@param e table
function world.occ_remove(e)
    local olds = rawget(e, "__cells")
    if olds == nil then
        return
    end
    for _, old in ipairs(olds) do
        local bucket = world.occ[old]
        if bucket ~= nil then
            for i = #bucket, 1, -1 do
                if bucket[i] == e then
                    table.remove(bucket, i)
                    break
                end
            end
            if #bucket == 0 then
                world.occ[old] = nil
            end
        end
    end
    e.__cells = nil
end

--- Re-sync `e`'s occupancy entries to its CURRENT footprint. Removes it
--- from old buckets whose cells it no longer covers, then adds it to any
--- new buckets it now covers (idempotent: a body that didn't move covers
--- the same set and the diff is empty). Safe to call before an entity is
--- tracked (allocate calls it post-init, before __cells is set; occ_remove
--- no-ops). Stale cells (entity partially off-map) are still tracked by
--- index so a later occ_remove finds the buckets. Call from every
--- position-changing path (allocate/destroy, Collidable:move,
--- PhysicsObject.update). A multi-tile entity lists itself in EVERY
--- footprint cell's bucket, so `world.entity_at` (one-cell lookup) finds
--- it when ANY of its covered cells is queried — still O(1).
---@param e table
function world.occ_rehash(e)
    local news = footprint_set(e)
    local olds = rawget(e, "__cells")
    if olds ~= nil then
        -- Remove from cells no longer covered, keep cells still covered.
        local still_covered = {}
        for _, old in ipairs(olds) do
            if news[old] then
                still_covered[#still_covered + 1] = old
            else
                local bucket = world.occ[old]
                if bucket ~= nil then
                    for i = #bucket, 1, -1 do
                        if bucket[i] == e then
                            table.remove(bucket, i)
                            break
                        end
                    end
                    if #bucket == 0 then
                        world.occ[old] = nil
                    end
                end
            end
        end
        -- New cells = footprint minus what was already there.
        local cells_to_add = {}
        for old in pairs(news) do
            local already = false
            for _, c in ipairs(olds) do
                if c == old then
                    already = true
                    break
                end
            end
            if not already then
                cells_to_add[#cells_to_add + 1] = old
            end
        end
        -- Build the new tracked list: still-covered + newly-added.
        local out = {}
        for _, c in ipairs(still_covered) do
            out[#out + 1] = c
        end
        for _, c in ipairs(cells_to_add) do
            local bucket = world.occ[c]
            if bucket == nil then
                bucket = {}
                world.occ[c] = bucket
            end
            bucket[#bucket + 1] = e
            out[#out + 1] = c
        end
        e.__cells = out
    else
        -- First registration: add to every footprint bucket.
        local out = {}
        for c in pairs(news) do
            local bucket = world.occ[c]
            if bucket == nil then
                bucket = {}
                world.occ[c] = bucket
            end
            bucket[#bucket + 1] = e
            out[#out + 1] = c
        end
        e.__cells = out
    end
    L:trace(
        "occ_rehash %s -> %d cell(s) (%.0f,%.0f,%d w=%d h=%d)",
        e.__name or "?",
        #(e.__cells or {}),
        e.x or 0,
        e.y or 0,
        e.z or 0,
        e.w or 1,
        e.h or 1
    )
end

--- Advance the simulation by `dt` seconds: tick every living entity's
--- `:update(dt)` hook. Skips dead slots via the alive tombstone. Mixins
--- override update (PhysicsObject runs euler+fall; future AI/Health tick
--- here). Entities without an update method (the no-op inherited from
--- Entity) still iterate but do nothing — cheap. Called once per frame
--- by the real-time loop in main.lua.
---@param dt number  Seconds elapsed since the last update.
function world.update(dt)
    local a = world.alive
    local slots = world.slots
    local n = world.capacity
    for i = 1, n do
        if a[i - 1] == 1 then
            local e = slots[i]
            local u = e.update
            if u ~= nil then
                u(e, dt)
            end
        end
    end
end

--- Advance every living widget's `:update(dt)` hook. Mirrors
--- world.update but for the widget pool. Called every frame by main.lua
--- (regardless of game state) so UI mixins like Anchor can recompute.
---@param dt number
function world.update_widgets(dt)
    local a = world.widgets_alive
    local slots = world.widgets_slots
    local n = world.widgets_capacity
    for i = 1, n do
        if a[i - 1] == 1 then
            local w = slots[i]
            local u = w.update
            if u ~= nil then
                u(w, dt)
            end
        end
    end
end

return world
