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
local Map = require("map")
local tile = require("tile")

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

-- Radius (cells) of the "skylight" hole cut into the ceiling layers
-- centered on the player. Within this disc the above layers are NOT drawn,
-- so the player + immediate surroundings stay visible; outside the disc the
-- above z-levels render dimmed. Squared for the distance test.
local CEIL_HOLE_RADIUS = 5
local CEIL_HOLE_R2 = CEIL_HOLE_RADIUS * CEIL_HOLE_RADIUS

local world = {
    capacity = INITIAL_ENTITY_CAP,
    slots = {}, -- slots[1..capacity] = pooled Lua tables, pre-allocated below
    alive = ffi.new("uint8_t[?]", INITIAL_ENTITY_CAP), -- 0=dead, 1=alive (0-based)
    map = Map(2000, 2000, 10), -- the game world's Map (schema-driven SoA; zero-filled)
    cam = { x = 1000, y = 1000, z = 9, z_offset = 0 }, -- camera center cell, z layer, + peek offset
    _shade = {}, -- depth-shaded appearance cache (rebuilt on cam.z change)
    _shade_max_depth = -1,
}

-- Pre-allocate the pool of empty tables once.
for i = 1, world.capacity do
    world.slots[i] = {}
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
    return e
end

--- Mark `e`'s slot dead so it can be recycled by a later allocate. Calls
--- the entity's mixin teardown chain FIRST (so subscribers unsubscribe
--- before the table is wiped/reused). Does NOT free the Lua table (the
--- pool retains it for recycling).
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
    local i = rawget(e, "__slot")
    if i ~= nil then
        world.alive[i - 1] = 0
    end
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

--- Render the map to `con`, centered on the camera. Two passes:
---   1. Below/at: draws z layers 0..cam.z bottom-to-top (upper overwrites
---      lower), each darkened toward black by depth below cam.z. Open is
---      clear (skipped) so lower layers show through.
---   2. Ceiling: draws z layers cam.z+1 .. ceil_top bottom-to-top, dimmed
---      by height above the camera — EXCEPT a disc of CEIL_HOLE_RADIUS
---      around the player (camera center) is left clear (a "skylight") so
---      the current layer + player stay visible through the ceiling.
--- Tiles with a `connect` spec resolve their glyph per-cell (box-drawing
--- walls etc.); other tiles use their cached fixed glyph.
---@param con table  tcod.Console
function world.render_map(con)
    local cam = world.cam
    local map = world.map
    local W, H = map.w, map.h
    local D = map.d
    local cols, rows = con:width(), con:height()
    local ox = cam.x - math.floor(cols / 2)
    local oy = cam.y - math.floor(rows / 2)
    local above_count = (D - 1) - cam.z
    if
        world._shade == nil
        or world._shade_max_depth ~= cam.z
        or world._shade_above_count ~= above_count
    then
        rebuild_shade(cam.z, above_count)
    end
    local shade = world._shade
    local types = map.types.cdata
    for z = 0, cam.z do
        local d = cam.z - z
        local entry = shade[d]
        if entry ~= nil then
            for cy = 0, rows - 1 do
                local wy = oy + cy
                if wy >= 0 and wy < H then
                    for cx = 0, cols - 1 do
                        local wx = ox + cx
                        if wx >= 0 and wx < W then
                            local i = ((z * H) + wy) * W + wx
                            local tv = types[i]
                            local s = entry[tv]
                            if s ~= nil then
                                con:put_rgb(
                                    cx,
                                    cy,
                                    resolve_glyph(types, W, H, D, wx, wy, z, tv, s),
                                    s.fg,
                                    s.bg
                                )
                            end
                        end
                    end
                end
            end
        end
    end
    -- Ceiling pass.
    local above = world._shade_above
    local cpx, cpy = cam.x, cam.y
    local ceil_top = cam.z + (world.cam.z_offset or 0)
    for z = cam.z + 1, ceil_top do
        local h = z - cam.z
        local entry = above[h]
        if entry ~= nil then
            for cy = 0, rows - 1 do
                local wy = oy + cy
                if wy >= 0 and wy < H then
                    local ddy = wy - cpy
                    for cx = 0, cols - 1 do
                        local wx = ox + cx
                        if wx >= 0 and wx < W then
                            local ddx = wx - cpx
                            -- Skip the skylight hole: leave the current
                            -- layer visible in a disc around the player.
                            if ddx * ddx + ddy * ddy > CEIL_HOLE_R2 then
                                local i = ((z * H) + wy) * W + wx
                                local tv = types[i]
                                local s = entry[tv]
                                if s ~= nil then
                                    con:put_rgb(
                                        cx,
                                        cy,
                                        resolve_glyph(types, W, H, D, wx, wy, z, tv, s),
                                        s.fg,
                                        s.bg
                                    )
                                end
                            end
                        end
                    end
                end
            end
        end
    end
end

--- Draw every living entity that exposes a `draw(console, cam)` method.
--- Draws entities on the camera's z layer (full brightness) AND those on
--- layers ABOVE (z > cam.z) — the "ceiling" entities visible through the
--- skylight — EXCEPT entities within CEIL_HOLE_RADIUS of the camera (the
--- player) which are skipped so the hole stays clear around the player.
--- Entities below the camera (z < cam.z) are not drawn. Scans the pooled
--- slots [1..capacity], skipping dead ones via the `world.alive` tombstone.
--- Entities without a `draw` method are skipped.
---@param con table  tcod.Console
function world.draw_entities(con)
    local cam = world.cam
    local cz = cam.z
    local ceil_top = cz + (cam.z_offset or 0)
    local n = world.capacity
    local alive = world.alive
    local slots = world.slots
    local cpx, cpy = cam.x, cam.y
    for i = 1, n do
        if alive[i - 1] == 1 then
            local e = slots[i]
            local ez = e.z or 0
            -- Draw entities on the player's layer (full) and above, up to
            -- the peek height (ceiling entities). Above ceil_top or below
            -- the player's layer: skip.
            if ez >= cz and ez <= ceil_top then
                -- Above-layer entities inside the skylight hole are
                -- skipped so the hole reads clear around the player.
                if ez > cz then
                    local ddx = math.floor(e.x) - cpx
                    local ddy = math.floor(e.y) - cpy
                    if ddx * ddx + ddy * ddy <= CEIL_HOLE_R2 then
                        goto next_slot
                    end
                end
                local d = e.draw
                if d ~= nil then
                    d(e, con, cam)
                end
            end
            ::next_slot::
        end
    end
end

--- Find the first living entity (other than `ignore`) occupying cell
--- (x,y,z), or nil. A linear scan of the pool — O(capacity), fine for
--- turn-based moves (one step per keypress). Used by entity-vs-entity
--- collision (Collidable:move) to detect e.g. a Stairs at the destination.
---@param x integer
---@param y integer
---@param z integer
---@param ignore? table  Skip this entity (the mover itself).
---@return table|nil
function world.entity_at(x, y, z, ignore)
    local a = world.alive
    local slots = world.slots
    for i = 1, world.capacity do
        if a[i - 1] == 1 then
            local e = slots[i]
            if
                e ~= ignore
                and math.floor(e.x) == x
                and math.floor(e.y) == y
                and (e.z or 0) == z
            then
                return e
            end
        end
    end
    return nil
end

return world
