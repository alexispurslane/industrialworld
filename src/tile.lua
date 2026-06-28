--- Tile schema + field-kind enum.
---
--- A plain table (NOT a class): describes the per-tile properties the Map
--- stores. The Map module introspects this to generate one z-major FFI
--- array per property (SoA), so adding a property is "add a line under
--- `schema`" — storage generates itself.
---
--- CONVENTION: 0 is the null/default value for every field. `Map.new`
--- zero-fills every array (free via ffi.new), so a fresh map starts with
--- `type = Open`, `flags = none`. Declare value enums accordingly: the
--- "empty" member is value 0.
---
--- Field specs: a property maps to `{ kind = FieldKind.X, ... }`:
---   kind = Enum     + enum = <enum table>  -> narrowest unsigned ctype
---                                          that fits the enum's max value
---   kind = Integer  + bytes? = 1|2|4|8      -> int8/16/32/64_t (default 4)
---   kind = Double                          -> double
---   kind = String                          -> const char* (interned; see Map:intern)

--- Field storage kinds. Not stored in the map (metadata only), so the
--- 0-null convention does not apply; explicit values for readability.
local FieldKind = enum({
    Enum = 1,
    Integer = 2,
    Double = 3,
    String = 4,
})

--- Terrain type. 0 = open air (the default).
local TileType = enum({
    Open = 0,
    Floor = 1,
    Wall = 2,
    StairsDown = 3,
    StairsUp = 4,
    Ramp = 5,
})

--- Per-tile bitflags. 0 = no flags (the default).
local TileFlags = enum.flags("Walkable", "Opaque", "Visible")

--- Per-tile-type definition. ONE lookup table: each entry is a composed
--- mixin instance (`mixin({}, Renderable, Collidable)`) carrying that
--- type's appearance (Renderable: fg/bg/glyphs) AND collision mask
--- (Collidable: .mask), plus Position state (unused until a tile is
--- promoted to an individual entity — the extra capability is intentional,
--- so chunks can be ripped out of the map and made into entities).
---
--- Consumers:
---   * Map renderer (world.lua): reads `def.glyphs[1]` / `.fg` / `.bg`
---     to build the shaded appearance cache (Renderable state).
---   * Collision (mixins/collidable.lua): reads `def.mask` via
---     `should_collide` (Collidable state).
---   * Player bg: reads `def.bg` for the tile under it.
--- Each entry is a SINGLE shared instance across every tile of that type
--- (no per-tile allocation). Tile types absent from the table fall back to
--- Open (value 0, the map zero-fill default) — but we always define Open.
local mixin = require("classes").mixin
local Renderable = require("mixins.renderable")
local Collidable = require("mixins.collidable")
local Surface = require("mixins.surface")
local Collision = require("collision")
local palette = require("palette")

local TileMixin = mixin({}, Renderable, Collidable, Surface)

--- Decode the first UTF-8 codepoint of `s` to an integer. Local copy of
--- Renderable's (not exported there) so `def_box` can convert the box-
--- drawing string table to codepoints once at load (the renderer passes
--- integers straight to put_rgb, never decoding per cell in the hot loop).
---@param s string
---@return integer
local function to_codepoint(s)
    local b = string.byte(s)
    if b < 0x80 then
        return b
    elseif b < 0xC0 then
        return 0xFFFD
    elseif b < 0xE0 then
        return (b - 0xC0) * 64 + (string.byte(s, 2) - 0x80)
    elseif b < 0xF0 then
        return (b - 0xE0) * 4096 + (string.byte(s, 2) - 0x80) * 64 + (string.byte(s, 3) - 0x80)
    else
        return (b - 0xF0) * 262144
            + (string.byte(s, 2) - 0x80) * 4096
            + (string.byte(s, 3) - 0x80) * 64
            + (string.byte(s, 4) - 0x80)
    end
end

--- Build a tile-type definition instance: a Renderable appearance + a
--- collision mask. Position state (x/y/vx/vy) is left nil — it only
--- matters once a tile is promoted to a positioned entity.
---@param fg table
---@param bg table
---@param glyph string|integer
---@param mask? integer  OR of Collision.* (nil/0 = collides with nothing).
---@return table
--- `friction?` (number) is this surface's per-second velocity retention
--- (default Surface.DEFAULT — the pre-Surface engine value). Pass a
--- smaller value for a grippier surface (mud), larger for a slideyer one
--- (ice). PhysicsObject reads this from the supporting tile each frame.
local function def(fg, bg, glyph, mask, friction)
    local t = setmetatable({}, TileMixin)
    Renderable.init(t, fg, bg, glyph)
    Surface.init(t, friction)
    t.mask = mask or 0
    return t
end

--- Standard 4-connected box-drawing glyph table, indexed by the
--- connectivity mask (bit 0=N, 1=E, 2=S, 3=W; mask = N|E<<1|S<<2|W<<3).
--- Corners (┌┐└┘), straights (─│), T's, the cross, and half-line stubs
--- for dead-ends. Isolated tiles (mask 0) use "·". A neighbor counts as
--- "connected" if its tile-type is in the tile def's `connect` set.
local BOX_4 = {
    [0] = "·", -- isolated
    [1] = "╵", -- N
    [2] = "╶", -- E
    [3] = "└", -- N+E
    [4] = "╷", -- S
    [5] = "│", -- N+S
    [6] = "┌", -- S+E
    [7] = "├", -- N+E+S
    [8] = "╴", -- W
    [9] = "┘", -- N+W
    [10] = "─", -- E+W
    [11] = "┴", -- N+E+W
    [12] = "┐", -- S+W
    [13] = "┤", -- N+S+W
    [14] = "┬", -- E+S+W
    [15] = "┼", -- N+E+S+W
}

--- Build a tile-type definition whose glyph is NEIGHBOR-AWARE: a 4-bit
--- N/E/S/W connectivity mask selects from `spec.glyphs` (a mask-keyed
--- string table, e.g. BOX_4). A neighbor counts toward the mask if its
--- tile-type is in `spec.connect`. Resolution happens per-cell in the
--- renderer; the default codepoint (mask-0 entry, or `spec.default`) is
--- the fallback. `default` on the spec overrides the mask-0 fallback.
---
--- Mask convention (bit positions): N=1 (0,-1), E=2 (+1,0), S=4 (0,+1),
--- W=8 (-1,0). So e.g. a wall with walls to N+E (mask 3) draws "└". When
--- `spec.z == true`, the mask additionally uses bit 16 = cell-above (z+1)
--- linked and bit 32 = cell-below (z-1) linked (6-bit lookup, 64-entry
--- glyphs table). Default: `z` falsy → fast 4-bit path (no vertical reads).
---@param fg table
---@param bg table
---@param mask integer  Collision.* bit(s).
---@param spec table  `{ connect={TileType,...}, glyphs={...}, default?="·", z? = true, friction? = number }`.
---@return table
local function def_box(fg, bg, mask, spec)
    -- The base glyph passed to Renderable.init: the spec's default (mask-0
    -- entry, or spec.default). It's the fallback when the renderer's
    -- mask-lookup misses and the def's own .glyphs[1] is consulted.
    local default_ch = spec.default or spec.glyphs[0] or "·"
    local t = def(fg, bg, default_ch, mask, spec.friction)
    -- Precompute the link set (types this tile connects to) as a fast
    -- {[tv]=true} table, and convert the glyphs string table to integer
    -- codepoints — both once, at load; the hot loop reads them as-is.
    local link = {}
    for _, tv in ipairs(spec.connect) do
        link[tv] = true
    end
    local glyphs_cp = {}
    for m, s in pairs(spec.glyphs) do
        glyphs_cp[m] = to_codepoint(s)
    end
    t.connect = {
        link = link,
        glyphs = glyphs_cp, -- {[mask]=codepoint}
        default = to_codepoint(default_ch),
        -- `z` (only meaningful if true): opt into 6-bit glyph resolution —
        -- the renderer also reads the cell above/below and sets bit 16=up /
        -- 32=down on the connectivity mask, indexing the same `glyphs`
        -- table with those bits. Default false: the fast 4-bit cardinal
        -- path (N/E/S/W only). Future vertical-spanning tiles (columns,
        -- pillars) opt in with `z = true` and a 64-entry `glyphs` table.
        z = spec.z == true,
    }
    return t
end

local Defs = {
    -- Open: a much darker filled background (a space on a dark cell fills
    -- the whole cell with the bg, so it reads as solid-black "void").
    [TileType.Open] = def(palette.soot, palette.soot, " "),
    [TileType.Floor] = def(palette.floor_fg, palette.floor_bg, " ", Collision.Solid),
    -- Wall: box-drawing glyph chosen per-cell by which neighbors are walls
    -- (connectivity mask → BOX_4 entry; e.g. N+E = "└"). The bg is a filled
    -- weathered concrete; the fg is the box glyph (darker slate so it shows).
    [TileType.Wall] = def_box(
        palette.wall_fg,
        palette.wall_bg,
        Collision.Solid,
        { connect = { TileType.Wall }, glyphs = BOX_4, default = "·" }
    ),
    [TileType.StairsDown] = def(palette.stairs, palette.iron, ">"),
    [TileType.StairsUp] = def(palette.safety_yellow, palette.iron, "<"),
    [TileType.Ramp] = def(palette.floor_fg, palette.mud, "^"),
}

-- Tag each tile def with its type name (TileType reverse lookup) so the
-- collision-event emitter can name the tile side ("collision:Player:Wall").
-- Entity instances name themselves via their class's `__name`; tile defs
-- have no class, so this field stands in.
for type_val, d in pairs(Defs) do
    d.__name = TileType[type_val]
end

return {
    FieldKind = FieldKind,
    schema = {
        types = { kind = FieldKind.Enum, enum = TileType },
        flags = { kind = FieldKind.Enum, enum = TileFlags },
    },
    TileType = TileType,
    TileFlags = TileFlags,
    defs = Defs,
    Collision = Collision,
    BOX_4 = BOX_4,
}
