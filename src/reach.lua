--- Walking-reachability ergonomics, mirroring the FOV API shape.
--
-- WHEN TO USE THIS:
--   "What can this actor WALK to?" — the reachable tile set, the reachable
--   entity set, "can I reach this specific entity" (by reference or by
--   collision category), and the union of all of these over several
--   viewpoints (squad reach). Reach via `local reach = require("reach")`.
--
-- WHEN NOT TO: for SIGHT (lines of sight, what's visible through air),
--   use `fov` (`fov.visible_*` / `fov.can_see`): rays + the `Opaque` flag.
--   This module is about WALKING reach: terrain `passable`, dynamic
--   `occupied` blockers, and z-`transition` edges (the same abstract-map
--   callbacks the pathfinding searchers take). For one concrete A→B
--   polyline route you want to WALK, call `pathfinding.find_path` directly
--   (this module's `can_reach` only reports reachABILITY, not the path);
--   for a flow-field of costs-to-everywhere use `pathfinding.distance_field`.
--
-- RELATIONSHIP TO PATHFINDING: this is a thin ergonomic layer. It does NOT
--   introduce new algorithms — it wraps the fastest appropriate searcher
--   per operation, picking like the pathfinding convention demands:
--     * Lists / multi-target / multi-viewpoint / bitmask-target queries
--       build a reachability FIELD via `pathfinding.flood` (one BFS/Dijkstra
--       per viewpoint; the reached-cell set is the field). For a SET of
--       viewpoints the per-viewpoint reached sets are unioned into one
--       deduped list (one OR-ed union, presented as one result).
--     * A single `can_reach(from, entityRef)` test uses ONE
--       `pathfinding.find_path` (A*; the heuristic prunes to the target, so
--       it's cheaper than a full flood for one close pair — the reach
--       analogue of `fov.can_see`'s single ray, which is also cheaper than
--       a full FOV field).
--   This mirrors FOV's "ray for the single test, field for the list" split.
--
-- GATING (range vs budget): FOV gates on a `range` + Euclidean/Chebyshev
--   `shape` (a physical extent). Walking reach gates on COST: pass
--   `opts.budget = N` (max total path cost) to bound how far the search
--   fans — a wall-respecting "how far can I walk in N steps" radius. With
--   no budget, flood expands over ALL reachable passable cells (connectivity
--   over the whole level). A `shape` does not apply to walking reach: the
--   reachable region is naturally irregular (walls carve it), so there's no
--   circle/square to impose — `budget` is the reach gate.
--
-- ENTITY REACHABILITY: same convention as FOV — an entity is reachable iff
--   its cell is in the reachable region. Enumerated via the `entities_at`
--   spatial-hash callback. `can_reach(entityRef)` paths to the entity's OWN
--   cell with an `occupied` wrapper that SKIPS the target entity itself
--   (you can walk onto the tile an entity occupies; it's the goal, not a
--   blocker), so an entity standing in a doorway is still reachable.
--
-- OPTS (the standard pathfinding searcher opts, PLUS `entities_at` for
--   entity queries):
--   dims        = {w,h,d}            grid extent (matches Map)
--   passable    = function(x,y,z)->bool  e.g. TileFlags.Walkable
--   occupied    = function(x,y,z)->bool  dynamic blocker (live entities)
--   transition  = function(x,y,z,opts)->iter  z-edges (default: stairs/ramp)
--   cost        = function(ax,ay,az, bx,by,bz)->number  (default uniform 1)
--   diagonal    = true                  8-dir (octile, no corner cutting)
--   budget      = N                     max total path cost (reach radius)
--   entities_at = function(x,y,z)->list|nil  spatial-hash bucket (entity fn)
--
-- Positions are `{x,y,z}` tables (the Position mixin state shape). `from`
-- is one such; `positions` is a list of them. `target` is an entity
-- reference (a table with Position `.x`/`.y`/`.z`, or a `{x,y,z}` array)
-- OR an integer `Collision.*` bitmask (for "can I reach any entity of
-- collision category X?").

local bit = require("bit")

local flood = require("pathfinding.flood").run
local find_path = require("pathfinding.find_path").run

local reach = {}

----------------------------------------------------------------------------------------------------
-- Internals
----------------------------------------------------------------------------------------------------

--- Build a flood opts table from the reach caller's `opts` + a `source`,
--- carrying through every pathfinding searcher field (defaults applied by
--- `grid.normalize` inside flood). Does NOT mutate the caller's table.
---@param opts table  Reach caller opts.
---@param source table  {x,y,z} viewpoint.
---@return table flood_opts
local function flood_opts(opts, source)
    return {
        dims = opts.dims,
        passable = opts.passable,
        cost = opts.cost,
        occupied = opts.occupied,
        transition = opts.transition,
        diagonal = opts.diagonal,
        budget = opts.budget,
        map = opts.map, -- default_transition reads .types
        source = source,
    }
end

--- Read an entity's integer cell + layer. Accepts an entity table (with
--- Position-mixin `.x`/`.y`/`.z`) OR a plain `{x,y,z}` array. Floors floats.
---@param target table  Entity or position table.
---@return integer ex, integer ey, integer ez
local function target_cell(target)
    local ex = math.floor(target.x or target[1] or 0)
    local ey = math.floor(target.y or target[2] or 0)
    local ez = target.z or target[3]
    return ex, ey, ez
end

--- Collect entities from the reached-cell list via the `entities_at` bucket
--- callback. No dedup needed — each entity lives in exactly one cell, and
--- `reached` already holds distinct cells (flood never re-visits).
---@param opts table  Reach caller opts (carries .entities_at).
---@param reached table  flood's reached-cell list ({{x,y,z}, ...}).
---@return table entities  Flat list of entity tables.
local function collect_entities(opts, reached)
    local ea = opts.entities_at
    local ents, n = {}, 0
    if ea == nil then
        return ents
    end
    for _, c in ipairs(reached) do
        local bucket = ea(c[1], c[2], c[3])
        if bucket ~= nil then
            for _, e in ipairs(bucket) do
                n = n + 1
                ents[n] = e
            end
        end
    end
    return ents
end

--- First entity in any reached cell whose collision `mask` shares any bit
--- with `mask_filter`, or nil. Used by the bitmask form of `can_reach`
--- ("can I reach any entity of collision category X from here?").
---@param opts table  Reach caller opts (carries .entities_at).
---@param reached table  flood's reached-cell list.
---@param mask_filter integer  Collision category bitmask to test.
---@return table|nil entity
local function first_matching_entity(opts, reached, mask_filter)
    local ea = opts.entities_at
    if ea == nil then
        return nil
    end
    for _, c in ipairs(reached) do
        local bucket = ea(c[1], c[2], c[3])
        if bucket ~= nil then
            for _, e in ipairs(bucket) do
                if bit.band(e.mask or 0, mask_filter) ~= 0 then
                    return e
                end
            end
        end
    end
    return nil
end

--- Union the reached-cell lists of several floods into one deduped list,
--- keyed by linear cell index (z-major, matching Map). Each viewpoint
--- contributes its own reachable region; the union is "anything any of the
--- viewpoints can walk to". Dedup is needed because floods' regions overlap.
---@param dims table  {w,h,d} for the linear-index computation.
---@param per_source table  List of flood results, each with a `.reached` list.
---@return table cells  Deduped list of {x,y,z} cell tables.
local function union_cells(dims, per_source)
    local w, h = dims[1], dims[2]
    local seen = {}
    local list, n = {}, 0
    for _, res in ipairs(per_source) do
        for _, c in ipairs(res.reached) do
            local i = ((c[3] * h) + c[2]) * w + c[1]
            if not seen[i] then
                seen[i] = true
                n = n + 1
                list[n] = c
                -- flood returns the SAME {x,y,z} table objects it built; the
                -- dedup set only guards membership, so sharing the cell
                -- tables across the union is safe (read-only to consumers).
            end
        end
    end
    return list
end

--- Single-pair reachability via one A* `find_path` from `from` to the
--- target's cell. The fastest single-pair primitive (heuristic prunes to
--- the goal, cheaper than a full flood for one close target). Uses an
--- `occupied` wrapper that SKIPS the target entity's own cell — you can
--- walk ONTO the tile an entity occupies; only OTHER dynamic blockers
--- gate the path. Returns true iff find_path reports a route (status
--- "reached"). Respects `passable`/`cost`/`transition`/`diagonal`/`budget`.
---
--- Goal passability: find_path bails if the goal tile isn't `passable`.
--- That's correct for walking reach (you can't path onto a wall); entities
--- stand on walkable floor in practice, so the common case just works.
---@param opts table  Reach caller opts.
---@param from table  {x,y,z} source cell.
---@param tx integer  Target cell x.
---@param ty integer  Target cell y.
---@param tz integer  Target cell z.
---@return boolean reachable
local function path_reaches(opts, from, tx, ty, tz)
    local base_occupied = opts.occupied
    --- occupied wrapper: the target cell is the GOAL, not a blocker — skip
    --- it so the pather can step onto it (and onto a doorway an entity
    --- blocks). All other occupied cells gate as usual.
    local function occupied_skip_target(x, y, z)
        if x == tx and y == ty and z == tz then
            return false
        end
        if base_occupied then
            return base_occupied(x, y, z)
        end
        return false
    end
    local o = {
        dims = opts.dims,
        passable = opts.passable,
        cost = opts.cost,
        occupied = occupied_skip_target,
        transition = opts.transition,
        diagonal = opts.diagonal,
        budget = opts.budget,
        map = opts.map,
        start = { from[1], from[2], from[3] },
        goal = { tx, ty, tz },
    }
    local _path, status = find_path(o)
    return status == "reached"
end

----------------------------------------------------------------------------------------------------
-- Public API
----------------------------------------------------------------------------------------------------

--- List of tiles reachable by WALK from one viewpoint: every cell
--- `{x,y,z}` you can path to (respecting `passable`/`occupied`/`transition`,
--- bounded by `budget` if set). Wraps `pathfinding.flood`.
---
--- @param from table  {x,y,z} source cell.
--- @param opts table  `{ dims, passable, cost?, occupied?, transition?, diagonal?, budget?, entities_at? }`.
--- @return table tiles  List of {x,y,z} cell tables.
function reach.reachable_tiles(from, opts)
    local res = flood(flood_opts(opts, from))
    return res.reached
end

--- List of entities reachable by WALK from one viewpoint: every entity
--- whose cell is in the reachable region. Enumerated via `entities_at`.
---
--- @param from table  {x,y,z} source cell.
--- @param opts table  `{ dims, passable, entities_at, cost?, occupied?, transition?, diagonal?, budget? }`.
--- @return table entities  Flat list of entity tables.
function reach.reachable_entities(from, opts)
    local res = flood(flood_opts(opts, from))
    return collect_entities(opts, res.reached)
end

--- Union of reachable tiles AND entities from a SET of viewpoints (squad
--- reach). Runs one flood per viewpoint and unions their reached regions
--- into one deduped cell list + the entities across all of them. Overlapping
--- regions naturally dedupe. (`flood` can't multi-seed, so this is N floods;
--- bounded by `budget`, so each is a small region — fine for a squad radius.)
---
--- @param positions table  List of {x,y,z} viewpoints.
--- @param opts table  `{ dims, passable, entities_at?, cost?, occupied?, transition?, diagonal?, budget? }`.
--- @return table result  `{ tiles = list of {x,y,z}, entities = list }`.
function reach.reachable_from_set(positions, opts)
    local per_source = {}
    for _, p in ipairs(positions) do
        per_source[#per_source + 1] = flood(flood_opts(opts, p))
    end
    local cells = union_cells(opts.dims, per_source)
    local ents = collect_entities(opts, cells)
    return { tiles = cells, entities = ents }
end

--- Can `from` reach a given target by WALK? `target` is either:
---   * an entity REFERENCE (with Position `.x`/`.y`/`.z`, or `{x,y,z}`) —
---     tested with ONE `find_path` (A*, heuristic-pruned, faster than a
---     full flood for one target; the reach analogue of `fov.can_see`'s
---     single ray). Paths to the entity's own cell with the target itself
---     skipped as a blocker.
---   * an integer Collision bitmask — tested by flooding and scanning
---     reached cells' buckets for any entity whose `.mask` shares a bit
---     ("can I reach any entity of collision category X?").
---
--- @param from table  {x,y,z} source cell.
--- @param target table|integer  Entity reference OR Collision.* bitmask.
--- @param opts table  `{ dims, passable, cost?, occupied?, transition?, diagonal?, budget?, entities_at? }`.
--- @return boolean reachable
function reach.can_reach(from, target, opts)
    if type(target) == "number" then
        local res = flood(flood_opts(opts, from))
        return first_matching_entity(opts, res.reached, target) ~= nil
    end
    ---@cast target table
    local tx, ty, tz = target_cell(target)
    return path_reaches(opts, from, tx, ty, tz)
end

--- Can ANY of `positions` reach `target` by WALK? `target` is an entity
--- reference or a collision bitmask, same two forms as `can_reach`:
---   * entity reference: one `find_path` per viewpoint; true if any reports
---     "reached". (A* per viewpoint; each prunes, so N close pairs are cheap.)
---   * bitmask: flood-union from all viewpoints, then a single bucket scan.
---
--- @param positions table  List of {x,y,z} viewpoints.
--- @param target table|integer  Entity reference OR Collision.* bitmask.
--- @param opts table  `{ dims, passable, cost?, occupied?, transition?, diagonal?, budget?, entities_at? }`.
--- @return boolean reachable
function reach.can_reach_from_set(positions, target, opts)
    if type(target) == "number" then
        local per_source = {}
        for _, p in ipairs(positions) do
            per_source[#per_source + 1] = flood(flood_opts(opts, p))
        end
        local cells = union_cells(opts.dims, per_source)
        return first_matching_entity(opts, cells, target) ~= nil
    end
    ---@cast target table
    local tx, ty, tz = target_cell(target)
    for _, p in ipairs(positions) do
        if path_reaches(opts, p, tx, ty, tz) then
            return true
        end
    end
    return false
end

return reach
