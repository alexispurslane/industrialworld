--- Neighbor generation + option normalization shared by the searchers.
--
-- INTERNAL helper; not re-exported from `init.lua`. Turns a caller's
-- options table (`dims`, `diagonal`, `passable`, `cost`, `transition`,
-- `occupied`) into a uniform neighbor iterator over (nx, ny, nz, step_cost)
-- tuples. Keeps the per-search loops tight (one loop, no per-call table
-- assembly) and centralizes the z-transition policy in exactly one place.
--
-- Z-transitions (stairs/ramps) are NOT auto-derived from the grid layout
-- — a walker can't go up/down just because (x,y,z±1) is in-bounds. The
-- `transition` callback decides which vertical edges exist. The default
-- (`grid.default_transition`) reads the engine tile type (StairsUp /
-- StairsDown / Ramp) so call sites that already populate `map.types`
-- get correct 3D pathing for free; pass your own to model ladders,
-- flying, or arbitrary portals.

local ffi = require("ffi")
local tile = require("tile")

local grid = {}

-- Lateral neighbor offsets. 4-cardinal always; +4 diagonals when enabled.
-- Order is cardinal-first so a 4-dir caller iterating diags skips them.
local CARDINAL = {
    { 1, 0 },
    { -1, 0 },
    { 0, 1 },
    { 0, -1 },
}
local DIAGONAL = {
    { 1, 1 },
    { 1, -1 },
    { -1, 1 },
    { -1, -1 },
}

--- Default z-transition policy: permits a vertical edge when the tile at
--- (x,y,z) is a stair/ramp and the landing (x,y,z±1) is open enough to
--- stand on. Reads `map.types:index(x,y,z)` against the engine `TileType`
--- enum. Returns an iterator of (nx, ny, nz) landing cells.
--- Override per-search for ladders, flight, portals, etc.
---@param x integer
---@param y integer
---@param z integer
---@param opts table  Normalized options (carries .map/.passable/.dims).
---@return function  iterator -> (nx, ny, nz)
function grid.default_transition(x, y, z, opts)
    local map = opts.map
    if map == nil then
        return function() end
    end
    local t = map.types:index(x, y, z)
    local TileType = tile.TileType
    -- StairsUp: also go up; StairsDown: also go down; Ramp: both.
    local up = (t == TileType.StairsUp or t == TileType.Ramp)
    local down = (t == TileType.StairsDown or t == TileType.Ramp)
    local dirs = {}
    if up then
        dirs[#dirs + 1] = 1
    end
    if down then
        dirs[#dirs + 1] = -1
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

--- Normalize a caller options table: fill defaults, validate shapes,
--- and pre-resolve dims into the linear-index helper. Returns a NEW
--- table the searchers read off hot loops; does not mutate the caller's.
---@param opts table  Raw caller options.
---@return table norm  Normalized options.
function grid.normalize(opts)
    local dims = opts.dims
    assert(type(dims) == "table" and #dims == 3, "pathfinding: opts.dims = {w,h,d} required")
    local w, h, d = dims[1], dims[2], dims[3]
    local count = w * h * d

    local diagonal = opts.diagonal == true
    local passable = opts.passable
    assert(type(passable) == "function", "pathfinding: opts.passable(x,y,z)->bool required")

    -- cost(ax,ay,az, bx,by,bz) -> number, default uniform 1.
    local cost = opts.cost
    if cost == nil then
        cost = function()
            return 1
        end
    end

    -- occupied(x,y,z) -> bool, default never (pure-terrain pathing).
    local occupied = opts.occupied
    if occupied == nil then
        occupied = function()
            return false
        end
    end

    -- transition(x,y,z, opts) -> iterator of (nx,ny,nz); default reads tiles.
    local transition = opts.transition or grid.default_transition

    return {
        w = w,
        h = h,
        d = d,
        count = count,
        diagonal = diagonal,
        passable = passable,
        cost = cost,
        occupied = occupied,
        transition = transition,
        map = opts.map, -- optional; default_transition reads .types
        budget = opts.budget or (2 ^ 20), -- safety cap on nodes expanded
    }
end

--- Linearize (x,y,z) -> 0-based cell index over (w,h,d), z-major.
--- Matches Map:idx's layout exactly so callers can hand the same dims.
function grid.cell(w, h, x, y, z)
    return ((z * h) + y) * w + x
end

--- Yield all walkable neighbors of (x,y,z) as (nx,ny,nz,step_cost).
--- Pushes results into the caller-supplied `out` table (cleared first)
--- so the search loop avoids per-neighbor allocation.
---@param x integer
---@param y integer
---@param z integer
---@param opts table  Normalized options.
---@param out table  Reusable accumulator table.
function grid.neighbors(x, y, z, opts, out)
    local w, h, d = opts.w, opts.h, opts.d
    local passable = opts.passable
    local cost = opts.cost
    local occupied = opts.occupied
    -- Clear out without reallocating the backing array.
    for i = 1, #out do
        out[i] = nil
    end

    -- Cardinal lateral moves (always allowed set).
    for i = 1, #CARDINAL do
        local o = CARDINAL[i]
        local nx, ny = x + o[1], y + o[2]
        if nx >= 0 and nx < w and ny >= 0 and ny < h then
            local impassable = not passable(nx, ny, z) or occupied(nx, ny, z)
            if not impassable then
                local n = #out
                out[n + 1], out[n + 2], out[n + 3], out[n + 4] = nx, ny, z, cost(x, y, z, nx, ny, z)
            end
        end
    end

    -- Diagonals (optional). No corner-cutting: both orthogonal neighbors
    -- must be passable to take a diagonal step (standard roguelike rule).
    if opts.diagonal then
        for i = 1, #DIAGONAL do
            local o = DIAGONAL[i]
            local nx, ny = x + o[1], y + o[2]
            if nx >= 0 and nx < w and ny >= 0 and ny < h then
                if passable(x + o[1], y, z) and passable(x, y + o[2], z) then
                    if passable(nx, ny, z) and not occupied(nx, ny, z) then
                        local c = cost(x, y, z, nx, ny, z)
                        -- sqrt(2) for octile uniform grids; caller's cost()
                        -- is the authority, so just pass it through.
                        local n = #out
                        out[n + 1], out[n + 2], out[n + 3], out[n + 4] = nx, ny, z, c
                    end
                end
            end
        end
    end

    -- Vertical transitions (stairs/ramp/etc.) via the transition callback.
    for nx, ny, nz in opts.transition(x, y, z, opts) do
        if nz >= 0 and nz < d then
            local impassable = not passable(nx, ny, nz) or occupied(nx, ny, nz)
            if not impassable then
                local n = #out
                out[n + 1], out[n + 2], out[n + 3], out[n + 4] =
                    nx, ny, nz, cost(x, y, z, nx, ny, nz)
            end
        end
    end
end

return grid
