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

-- Field-of-view (native 3D; see src/fov.lua). The player's vision is a
-- constant-radius 3D sphere of opaque-blocked rays; each frame the set of
-- Visible cells is recomputed from the player's cell and Explored
-- (memory) is the union of every Visible set ever computed. Cells with
-- NEITHER flag render dark (default-dark world). Explored-but-not-Visible
-- cells render at MEMORY_BRIGHTNESS (applied ON TOP of the depth/height
-- shade) so remembered terrain keeps its per-layer falloff but reads dim.
-- Exposed on `world` (world.VISION_RANGE / world.VISION_SHAPE) so callers
-- / tests can tune; the locals below are the hot-loop reads.
local VISION_RANGE = 8
local VISION_SHAPE = "sphere" -- 3D Euclidean ball
local MEMORY_BRIGHTNESS = 0.35

-- Physics tuning (the "basic silly physics engine"). Movement is
-- impulse-driven: a keypress calls `self:accelerate(STEP_ACCEL*dx, ...)`;
-- gravity is a constant downward `az`; friction damps horizontal velocity
-- per second as `FRICTION^dt` (retains FRICTION-fraction/s, so you slide to
-- a stop shortly after releasing input). Stairs give a direct velocity bump
-- (SHUNT_VZ vertical / SHUNT_VH forward) in place of a teleport shunt.
-- Exposed on `world` for callers (player, stairs, PhysicsObject).
local GRAVITY = 20 -- cells/sec^2 downward (obeys_gravity entities)
local STEP_ACCEL = 60 -- cells/sec^2 per arrow-key impulse (horizontal)
local FRICTION = 0.02 -- per-second horizontal velocity retention (0.02 = 2%/s)
local SHUNT_VZ = 7 -- cells/sec upward/downward bump a stairs imparts
local SHUNT_VH = 3 -- cells/sec forward bump a stairs imparts

-- X-ray hole through VISIBLE ceilings. Even with native-3D FOV revealing
-- open-ceiling voxels, the player wants a clear cutout around them through
-- any VISIBLE above-layer cells (a platform above, stairs head) so the
-- player cell reads and nearby above-layer content shows without the
-- ceiling-floor occluding it. Applied ONLY to cells that are BOTH visible
-- (in the FOV) AND on a layer above the camera (z > cam.z) — memory/dark
-- cells are untouched (no hole carved into remembered terrain). Rings by
-- squared horizontal distance from the player cell:
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
    _shade = {}, -- depth-shaded appearance cache (rebuilt on cam.z change)
    _shade_max_depth = -1,
    -- Vision config (tunable; the hot-loop reads use the module locals
    -- VISION_RANGE / VISION_SHAPE above, so changing these at runtime
    -- requires updating those too — kept here for discoverability/tests).
    VISION_RANGE = VISION_RANGE,
    VISION_SHAPE = VISION_SHAPE,
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
--- the player via the `moved` subscription in main.lua). NATIVE 3D FOV
--- (src/fov.lua): one 3D supercover ray per candidate voxel in the vision
--- sphere, blocked by any `Opaque` voxel — so walls block in-plane and a
--- solid ceiling cuts off upper layers except where it's Open (a
--- skylight lets rays climb). Each frame:
---   1. Clear `TileFlags.Visible` on EVERY cell (the per-frame visibility
---      set is ephemeral; only `Explored` accumulates).
---   2. Compute the visible set from the player's cell.
---   3. Mark `Visible` + OR `Explored` on the cells that are ALSO in the
---      RENDERED z-window (0..cam.z + z_offset) — the same cut render_map
---      uses. Cells in the FOV ball but ABOVE the peek height are discarded:
---      they never paint, so they must not enter memory either. This keeps
---      memory consistent with what the player actually SAW rendered.
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
    local ExploredBit = TF.Explored
    local OpaqueBit = TF.Opaque
    -- 1. Clear this frame's Visible everywhere (Explored persists).
    for i = 0, map.count - 1 do
        flags[i] = bit.band(flags[i], bit.bnot(VisibleBit))
    end
    -- 2. Compute the visible set from the camera cell (the player).
    local cam = world.cam
    local vis_tiles = fov.visible_tiles({ cam.x, cam.y, cam.z }, {
        dims = { W, H, D },
        opaque = function(x, y, z)
            return bit.band(flags[((z * H) + y) * W + x], OpaqueBit) ~= 0
        end,
        range = VISION_RANGE,
        shape = VISION_SHAPE,
    })
    -- 3. Mark Visible + Explored, but ONLY on cells in the rendered z-window
    --    (0..cam.z + z_offset) — the same cut render_map applies. Visible
    --    cells above the peek height never paint, so they don't enter the
    --    Visible flag (renderer wouldn't read them) NOR the Explored union
    --    (memory must match what was actually seen). Explored is sticky, so
    --    re-setting is a no-op for already-remembered cells.
    local z_max = cam.z + (cam.z_offset or 0)
    local both = bit.bor(VisibleBit, ExploredBit)
    for _, c in ipairs(vis_tiles) do
        local cz = c[3]
        if cz >= 0 and cz <= z_max then
            local i = ((cz * H) + c[2]) * W + c[1]
            flags[i] = bit.bor(flags[i], both)
        end
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

--- Render the map to `con`, centered on the camera. DEFAULT-DARK:
--- cells with NEITHER `TileFlags.Visible` (currently in the player's FOV)
--- NOR `TileFlags.Explored` (memory — ever seen) render nothing (the
--- world opens black and is revealed as the player moves). `world.update_fov`
--- recomputes the Visible set each frame from the camera (player) cell;
--- Explored is the sticky union of every Visible set, so memory accumulates.
---
--- Per cell, one z loop 0..ceil_top (ceil_top = cam.z + z_offset):
---   • Visible  → full shaded appearance (depth-below / height-above falloff,
---     the same shade cache as before).
---   • Explored (not Visible) → the same shaded appearance DIMMED by
---     MEMORY_BRIGHTNESS (0.35), applied ON TOP of the depth/height shade,
---     so remembered terrain keeps its per-layer falloff but reads dim.
---   • neither flag → no `put` at all (the cell stays at con:clear's bg).
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
    local TF = tile.TileFlags
    local VisibleBit = TF.Visible
    local ExploredBit = TF.Explored
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
            local tv = types[((bz * H) + wy) * W + wx]
            if tv ~= Open then
                local s = shade[camz - bz][tv]
                if s ~= nil then
                    return s.fg, s.bg
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
                            local is_explored = bit.band(fl, ExploredBit) ~= 0
                            if is_visible or is_explored then
                                local tv = types[i]
                                local s = entry[tv]
                                if s ~= nil then
                                    local ch = resolve_glyph(types, W, H, D, wx, wy, z, tv, s)
                                    local fg, bg = s.fg, s.bg
                                    if not is_visible then
                                        -- Memory: dim the same shade by
                                        -- MEMORY_BRIGHTNESS (keeps the
                                        -- depth/height falloff; reads dim).
                                        fg = shade_color(fg, MEMORY_BRIGHTNESS)
                                        bg = shade_color(bg, MEMORY_BRIGHTNESS)
                                        con:put_rgb(cx, cy, ch, fg, bg)
                                    elseif z > camz then
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
--- MEMORY SHOWS NO ENTITIES: explored-but-not-visible cells render their
--- terrain dimmed (render_map) but their entities are skipped — you
--- remember the shape of a room, not the goblin that was in it. Entities
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
            -- currently in the player's FOV. Memory cells' entities stay
            --- hidden by design.
            if math.floor(ez) >= cz and math.floor(ez) <= ceil_top then
                local ex, ey = math.floor(e.x), math.floor(e.y)
                local fi = ((math.floor(ez) * H) + ey) * W + ex
                if
                    ex >= 0
                    and ex < W
                    and ey >= 0
                    and ey < H
                    and bit.band(flags[fi], VisibleBit) ~= 0
                then
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

--- Cell index for an entity's current floor() position. Mirrors the
--- Map's z-major layout so a cell's bucket lives at the same index the
--- map uses for that (x,y,z). Local helper for occ_*.
---@param e table
---@return integer
local function cell_idx(e)
    local map = world.map
    local x = math.floor(e.x or 0)
    local y = math.floor(e.y or 0)
    local z = math.floor(e.z)
    return ((z * map.h) + y) * map.w + x
end

--- Remove `e` from its old occupancy bucket (if any). Idempotent: a no-op
--- if `e.__cell` is unset (entity never added, or already removed). Does
--- NOT bounds-check the old cell — a teleport past the map edge still
--- cleans up the old bucket by index. Scans the (usually 1-element)
--- bucket list for `e` and removes it; list shrinks but is not pruned.
---@param e table
function world.occ_remove(e)
    local old = rawget(e, "__cell")
    if old == nil then
        return
    end
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
    e.__cell = nil
end

--- Re-sync `e`'s occupancy entry to its CURRENT floor() cell. Removes it
--- from the old bucket (if any) and adds it to the new one. Idempotent
--- and safe to call before an entity is tracked (allocate calls it
--- post-init, before __cell is set; occ_remove no-ops). Stale cells
--- (entity off-map) are still tracked by index so a later occ_remove
--- finds the bucket. Call from every position-changing path
--- (allocate/destroy, Collidable:move, PhysicsObject.update).
---@param e table
function world.occ_rehash(e)
    local new_cell = cell_idx(e)
    local old = rawget(e, "__cell")
    if old == new_cell then
        return
    end
    if old ~= nil then
        world.occ_remove(e)
    end
    local bucket = world.occ[new_cell]
    if bucket == nil then
        bucket = {}
        world.occ[new_cell] = bucket
    end
    bucket[#bucket + 1] = e
    e.__cell = new_cell
    L:trace(
        "occ_rehash %s -> cell %d (%.0f,%.0f,%d)",
        e.__name or "?",
        new_cell,
        e.x or 0,
        e.y or 0,
        e.z or 0
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
