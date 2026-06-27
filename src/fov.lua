--- Field-of-view / line-of-sight queries over the engine's z-major grid.
--
-- WHEN TO USE THIS:
--   "What can this actor see?" — the visible voxel set, the visible entity
--   set, "is this specific entity in view" (by reference or by collision
--   category), and the union of all of these over several viewpoints
--   (multi-tile or squad vision). Reach via `local fov = require("fov")`.
--
-- WHEN NOT TO: for a single yes/no "can A see B" with no range/shape and
--   no need to enumerate, `fov.line_of_sight` is a thinner seam (one 3D
--   ray). FOV is about SIGHT (rays blocked by the `Opaque` tile flag),
--   not walking reachability (that's `reach`).
--
-- DESIGN: NATIVELY 3D. Sight rays travel in 3D from the viewer's voxel to
--   each candidate voxel via a 3D Amanatides-&-Woo voxel DDA (the same
--   algorithm as `pathfinding.raycast3d`), consulting the map's `Opaque`
--   predicate on EVERY voxel the ray enters — including voxels ABOVE the
--   viewer. So a solid floor/ceiling voxel naturally cuts off upper
--   layers (a "skylight" of Open air above lets the ray climb; a Wall/
--   Floor ceiling stops it), and a wall on the viewer's layer blocks the
--   ray in-plane. Each ray marks every voxel it reaches as visible and
--   STOPS past the first opaque voxel — so opaque voxels are seen (you
--   see the blocking face) but nothing beyond them. SUPERCOVER ties: when
--   the ray crosses two or three voxel boundaries at the SAME t (it
--   passes exactly through a voxel edge/corner), the edge/corner-touched
--   neighbor voxels are ALSO visited — so a wall on any face of an edge
--   crossing blocks the ray (no diagonal tunneling, the 3D generalization
--   of the 2D supercover guarantee).
--
--   The fast variants:
--     * Single-target tests (can_see an entity REFERENCE) use ONE 3D ray
--       to that voxel (no field built) — the cheapest pathfinding
--       primitive, exactly as `line_of_sight` does.
--     * List / multi-target / multi-viewpoint queries build a visibility
--       FIELD — a `uint8_t[count]` cdata buffer (one byte per voxel, same
--       memory discipline as the pathfinding scratch buffers) — by casting
--       one 3D ray to every voxel in the 3D shape extent and OR-ing into
--       it. The per-ray DDA is INLINED to write straight into the cdata,
--       so a full field costs ZERO Lua allocations steady-state (no
--       per-cell / per-ray table churn). For a SET of viewpoints the same
--       buffer is reused and OR-ed across all of them, so a squad-vision
--       query is one field, not N.
--
-- SHAPE / RANGE: `range` is an integer radius. `shape` is "sphere"
--   (default; 3D Euclidean ball, dx²+dy²+dz² <= range²) or "box"
--   (3D Chebyshev cube, |dx|,|dy|,|dz| <= range — a
--   (2*range+1)³ cube centered on the viewer). The shape bounds the
--   candidate extent; it does NOT curve around walls (a visible voxel is
--   always within the shape AND has an unobstructed 3D ray to it).
--
-- ENTITY VISIBILITY: an entity is visible iff its voxel is in the visible
--   field. Entities are enumerated via the `entities_at(x,y,z)` callback
--   (the spatial-hash bucket — pass `function(x,y,z) return world.occ[...] end`
--   or similar; nil/absent → entity functions return empty). Entities do
--   NOT block sight in this model (a goblin doesn't occlude what's behind
--   it) — sight-blocking is the terrain `Opaque` flag's job, by design.
--
-- OPTS (same abstract-map-callbacks shape as the pathfinding searchers):
--   dims        = {w,h,d}            grid extent (matches Map)
--   opaque      = function(x,y,z)->bool  voxel sight-block (TileFlags.Opaque)
--   entities_at = function(x,y,z)->list|nil  spatial-hash bucket (optional)
--   range       = integer           vision radius
--   shape       = "sphere"|"box"  (default "sphere")
--
-- Positions are `{x,y,z}` tables (the engine Position mixin state shape);
-- a single `from` is one such table, a set is a list of them.

local ffi = require("ffi")

local raycast3d = require("pathfinding.raycast3d")

local fov = {}

----------------------------------------------------------------------------------------------------
-- Internals
----------------------------------------------------------------------------------------------------

--- Validate + normalize caller opts into a tight table the hot loops read.
--- Mirrors `pathfinding.grid.normalize`'s role (defaults + asserts) but slim:
--- FOV needs dims/opaque/range/shape only (+ entities_at for entity queries).
---@param opts table  Raw caller options.
---@return table o  Normalized options.
local function normalize(opts)
    local dims = opts.dims
    assert(type(dims) == "table" and #dims == 3, "fov: opts.dims = {w,h,d} required")
    local w, h, d = dims[1], dims[2], dims[3]
    local opaque = opts.opaque
    assert(type(opaque) == "function", "fov: opts.opaque(x,y,z)->bool required")
    local range = opts.range
    assert(type(range) == "number" and range >= 0, "fov: opts.range (integer >= 0) required")
    local shape = opts.shape or "sphere"
    assert(shape == "sphere" or shape == "box", "fov: opts.shape = 'sphere'|'box'")
    return {
        w = w,
        h = h,
        d = d,
        count = w * h * d,
        opaque = opaque,
        entities_at = opts.entities_at, -- optional; nil => no entity enumeration
        range = math.floor(range),
        shape = shape,
    }
end

--- True if `(dx, dy, dz)` lies within the shape of radius `r`.
---@param o table  Normalized options.
---@param dx integer
---@param dy integer
---@param dz integer
---@return boolean
local function in_shape(o, dx, dy, dz)
    local r = o.range
    if o.shape == "box" then
        return math.abs(dx) <= r and math.abs(dy) <= r and math.abs(dz) <= r
    end
    return dx * dx + dy * dy + dz * dz <= r * r
end

--- Mark voxel `(cx, cy, cz)` visible in `vis` and report whether it is
--- opaque (a blocker). Module-level (no closure alloc) so the inlined
--- per-ray DDA can call it without per-ray allocation — matches the
--- original 2D FOV's zero-alloc steady-state discipline. Returns true if
--- the voxel was opaque (the caller stops the ray there, having marked the
--- blocker visible — you see the wall face). Voxels already marked (vis=1)
--- are NOT re-tested for opacity (a previously-seen blocker already
--- stopped some other ray; a previously-seen clear voxel needn't be
--- re-checked) — the first ray to reach a voxel owns its opacity verdict.
---@param w integer
---@param h integer
---@param d integer
---@param vis any  uint8_t[count] cdata, mutated in place.
---@param opacity function  opaque(x,y,z)->bool
---@param cx integer
---@param cy integer
---@param cz integer
---@return boolean blocked  True if this voxel is opaque (ray stops).
local function emit_cell(w, h, d, vis, opacity, cx, cy, cz)
    if cx >= 0 and cx < w and cy >= 0 and cy < h and cz >= 0 and cz < d then
        local i = ((cz * h) + cy) * w + cx
        -- Mark visible (idempotent: an earlier ray may have marked this
        -- cell already; that's fine). BUT test opacity on EVERY visit — a
        -- blocker stops ALL rays through it, not just the first one that
        -- discovered it. (Marking-without-testing would let a later ray
        -- pass THROUGH an already-seen wall and reveal cells beyond it,
        ---  which is wrong: a wall blocks sight regardless of whether
        ---  you've seen its face before.)
        vis[i] = 1
        if opacity(cx, cy, cz) then
            return true
        end
    end
    return false
end

--- Cast one 3D Amanatides-&-Woo voxel-DDA ray from `(sx,sy,sz)` to
--- `(tx,ty,tz)`, marking every voxel it reaches as visible in `vis`. A
--- voxel is marked BEFORE its opacity is tested, so a blocking wall is
--- itself seen (you see the face, not past it); the ray then stops, so
--- voxels beyond an opaque blocker stay unmarked. Supercover ties
--- (the ray crosses a voxel edge/corner exactly) emit the edge/corner-
--- touched neighbors too, so a wall on any face of the crossing blocks.
---
--- Inlined (not `raycast3d.run`) so the walk writes straight into the
--- field cdata with zero per-voxel / per-ray table allocation — the
--- field builder casts one ray per candidate voxel, and this is the
--- inner loop. The DDA math mirrors `pathfinding.raycast3d` exactly.
---@param o table  Normalized options.
---@param sx integer  Source voxel x.
---@param sy integer  Source voxel y.
---@param sz integer  Source voxel z.
---@param tx integer  Target voxel x.
---@param ty integer  Target voxel y.
---@param tz integer  Target voxel z.
---@param vis any  uint8_t[count] cdata, mutated in place.
local function cast_ray3d(o, sx, sy, sz, tx, ty, tz, vis)
    local w, h, d = o.w, o.h, o.d
    local opacity = o.opaque
    local ex, ey, ez = tx, ty, tz

    local ax, ay, az = sx + 0.5, sy + 0.5, sz + 0.5
    local bx, by, bz = tx + 0.5, ty + 0.5, tz + 0.5
    local ddx, ddy, ddz = bx - ax, by - ay, bz - az
    local stepX = ddx > 0 and 1 or (ddx < 0 and -1 or 0)
    local stepY = ddy > 0 and 1 or (ddy < 0 and -1 or 0)
    local stepZ = ddz > 0 and 1 or (ddz < 0 and -1 or 0)
    if stepX == 0 and stepY == 0 and stepZ == 0 then
        return
    end

    local x, y, z = sx, sy, sz
    local tMaxX, tMaxY, tMaxZ, tDeltaX, tDeltaY, tDeltaZ
    if stepX ~= 0 then
        tMaxX = ((stepX > 0 and (x + 1) or x) - ax) / ddx
        tDeltaX = math.abs(1 / ddx)
    else
        tMaxX, tDeltaX = math.huge, math.huge
    end
    if stepY ~= 0 then
        tMaxY = ((stepY > 0 and (y + 1) or y) - ay) / ddy
        tDeltaY = math.abs(1 / ddy)
    else
        tMaxY, tDeltaY = math.huge, math.huge
    end
    if stepZ ~= 0 then
        tMaxZ = ((stepZ > 0 and (z + 1) or z) - az) / ddz
        tDeltaZ = math.abs(1 / ddz)
    else
        tMaxZ, tDeltaZ = math.huge, math.huge
    end

    local max_iter = (w + h + d) * 2 + 4
    for _ = 1, max_iter do
        -- Min t and which ACTIVE axes tie there.
        local min_t = tMaxX
        if tMaxY < min_t then
            min_t = tMaxY
        end
        if tMaxZ < min_t then
            min_t = tMaxZ
        end
        local aX = stepX ~= 0 and tMaxX <= min_t + 1e-12
        local aY = stepY ~= 0 and tMaxY <= min_t + 1e-12
        local aZ = stepZ ~= 0 and tMaxZ <= min_t + 1e-12

        -- Per-axis deltas for the tied axes (offsets from current x,y,z).
        local dxX = aX and stepX or 0
        local dxY = aY and stepY or 0
        local dxZ = aZ and stepZ or 0

        -- Emit the supercover cells for this tie set: every non-empty
        -- subset of the tied axes, proper subsets first, the full step
        -- last. If ANY emitted voxel is opaque, the ray stops there (but
        -- the blocker was still marked visible above). This is a 3D
        -- generalization of the 2D supercover; the explicit cases keep
        -- the hot loop allocation-free (no subset-table built).
        if aX and aY and aZ then
            -- 7 cells: 3 singles, 3 pairs, 1 triple.
            if emit_cell(w, h, d, vis, opacity, x + dxX, y, z) then
                return
            end
            if emit_cell(w, h, d, vis, opacity, x, y + dxY, z) then
                return
            end
            if emit_cell(w, h, d, vis, opacity, x, y, z + dxZ) then
                return
            end
            if emit_cell(w, h, d, vis, opacity, x + dxX, y + dxY, z) then
                return
            end
            if emit_cell(w, h, d, vis, opacity, x + dxX, y, z + dxZ) then
                return
            end
            if emit_cell(w, h, d, vis, opacity, x, y + dxY, z + dxZ) then
                return
            end
            local fx, fy, fz = x + dxX, y + dxY, z + dxZ
            if emit_cell(w, h, d, vis, opacity, fx, fy, fz) then
                return
            end
            x, y, z = fx, fy, fz
            tMaxX, tMaxY, tMaxZ = tMaxX + tDeltaX, tMaxY + tDeltaY, tMaxZ + tDeltaZ
        elseif aX and aY then
            if emit_cell(w, h, d, vis, opacity, x + dxX, y, z) then
                return
            end
            if emit_cell(w, h, d, vis, opacity, x, y + dxY, z) then
                return
            end
            local fx, fy = x + dxX, y + dxY
            if emit_cell(w, h, d, vis, opacity, fx, fy, z) then
                return
            end
            x, y = fx, fy
            tMaxX, tMaxY = tMaxX + tDeltaX, tMaxY + tDeltaY
        elseif aX and aZ then
            if emit_cell(w, h, d, vis, opacity, x + dxX, y, z) then
                return
            end
            if emit_cell(w, h, d, vis, opacity, x, y, z + dxZ) then
                return
            end
            local fx, fz = x + dxX, z + dxZ
            if emit_cell(w, h, d, vis, opacity, fx, y, fz) then
                return
            end
            x, z = fx, fz
            tMaxX, tMaxZ = tMaxX + tDeltaX, tMaxZ + tDeltaZ
        elseif aY and aZ then
            if emit_cell(w, h, d, vis, opacity, x, y + dxY, z) then
                return
            end
            if emit_cell(w, h, d, vis, opacity, x, y, z + dxZ) then
                return
            end
            local fy, fz = y + dxY, z + dxZ
            if emit_cell(w, h, d, vis, opacity, x, fy, fz) then
                return
            end
            y, z = fy, fz
            tMaxY, tMaxZ = tMaxY + tDeltaY, tMaxZ + tDeltaZ
        elseif aX then
            local fx = x + dxX
            if emit_cell(w, h, d, vis, opacity, fx, y, z) then
                return
            end
            x = fx
            tMaxX = tMaxX + tDeltaX
        elseif aY then
            local fy = y + dxY
            if emit_cell(w, h, d, vis, opacity, x, fy, z) then
                return
            end
            y = fy
            tMaxY = tMaxY + tDeltaY
        else -- aZ
            local fz = z + dxZ
            if emit_cell(w, h, d, vis, opacity, x, y, fz) then
                return
            end
            z = fz
            tMaxZ = tMaxZ + tDeltaZ
        end

        if x == ex and y == ey and z == ez then
            return
        end
    end
end

--- Build the 3D visibility field for one or more viewpoints, OR-ing into a
--- single shared `uint8_t[count]` cdata (so a squad-vision query is one
--- field, not N). For each viewpoint: mark its own voxel visible, then cast
--- a 3D ray to every OTHER voxel in its 3D shape extent (the candidate
--- voxels are the gap-free fan targets — one ray per in-extent voxel).
--- Rays climb through layers (Open air above) and stop at opaque voxels,
--- so upper layers are revealed only where the column above is open.
---@param o table  Normalized options.
---@param positions table  List of {x,y,z} viewpoints.
---@return any vis  uint8_t[count] cdata, 1 where a voxel is visible from any viewpoint.
local function compute_field(o, positions)
    local w, h, d = o.w, o.h, o.d
    local r = o.range
    local vis = ffi.new("uint8_t[?]", o.count)
    for _, p in ipairs(positions) do
        local sx, sy, sz = p[1], p[2], p[3]
        if sx >= 0 and sx < w and sy >= 0 and sy < h and sz >= 0 and sz < d then
            vis[((sz * h) + sy) * w + sx] = 1 -- viewer sees its own voxel
            for ddz = -r, r do
                local tz = sz + ddz
                if tz >= 0 and tz < d then
                    for ddy = -r, r do
                        local ty = sy + ddy
                        if ty >= 0 and ty < h then
                            for ddx = -r, r do
                                if
                                    (ddx ~= 0 or ddy ~= 0 or ddz ~= 0)
                                    and in_shape(o, ddx, ddy, ddz)
                                then
                                    local tx = sx + ddx
                                    if tx >= 0 and tx < w then
                                        cast_ray3d(o, sx, sy, sz, tx, ty, tz, vis)
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    return vis
end

--- Collect the visible voxels into a list of `{x,y,z}` tables, one per
--- visible voxel, deduped (overlapping viewpoint bboxes can both mark a
--- voxel; the `seen` set keeps the output unique). Iterates each
--- viewpoint's 3D shape bbox and reads the field rather than scanning the
--- whole volume (the field cdata spans w*h*d; a full scan would be wasted
--- on a tiny vision radius).
---@param o table  Normalized options.
---@param vis any  uint8_t[count] field from compute_field.
---@param positions table  The same viewpoints (to bound the scan bboxes).
---@return table cells  List of {x,y,z} visible voxel tables.
local function collect_cells(o, vis, positions)
    local w, h, d = o.w, o.h, o.d
    local r = o.range
    local seen = {} -- [cell_idx] = true; dedup across overlapping bboxes
    local list, n = {}, 0
    for _, p in ipairs(positions) do
        local sx, sy, sz = p[1], p[2], p[3]
        sz = math.max(0, math.min(d - 1, sz))
        for ddz = -r, r do
            local cz = sz + ddz
            if cz >= 0 and cz < d then
                for ddy = -r, r do
                    local cy = sy + ddy
                    if cy >= 0 and cy < h then
                        for ddx = -r, r do
                            if in_shape(o, ddx, ddy, ddz) then
                                local cx = sx + ddx
                                if cx >= 0 and cx < w then
                                    local i = ((cz * h) + cy) * w + cx
                                    if vis[i] == 1 and not seen[i] then
                                        seen[i] = true
                                        n = n + 1
                                        list[n] = { cx, cy, cz }
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    return list
end

--- Collect visible entities: for each visible voxel, read its spatial-hash
--- bucket via `entities_at`. No dedup needed — each entity lives in
--- exactly one voxel, and collect_cells already deduped the voxels.
---@param o table  Normalized options.
---@param cells table  Output of collect_cells.
---@return table entities  Flat list of entity tables.
local function collect_entities(o, cells)
    local ea = o.entities_at
    local ents, n = {}, 0
    if ea == nil then
        return ents
    end
    for _, c in ipairs(cells) do
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

--- First entity in any visible voxel whose collision `mask` shares any bit
--- with `mask_filter`, or nil. Used by the bitmask form of `can_see`
--- ("can I see any entity of collision category X from here?").
---@param o table  Normalized options.
---@param cells table  Visible voxels.
---@param mask_filter integer  Collision category bitmask to test.
---@return table|nil entity
local function first_matching_entity(o, cells, mask_filter)
    local ea = o.entities_at
    if ea == nil then
        return nil
    end
    for _, c in ipairs(cells) do
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

--- Single-ray visibility test: can `(from)` see the cell occupied by
--- `target`? Reuses the general `raycast3d.run` (one 3D ray; allocation
--- is negligible for a single ray). Walks the ray; the target cell is
--- reached iff no opaque voxel lies strictly before it on the ray. The
--- target's OWN opacity is never tested against itself (you can always see
--- the thing you're looking at, modulo range + blockers).
---
--- Fails fast on: viewer/target out of bounds, target outside the shape
--- extent (range gate), or an opaque voxel blocking the ray before the
--- target.
---@param o table  Normalized options.
---@param from table  {x,y,z} viewer cell.
---@param target table  Entity/{x,y,z} being tested.
---@return boolean visible
local function ray_to_target(o, from, target)
    local w, h, d = o.w, o.h, o.d
    local sx, sy, sz = from[1], from[2], from[3]
    local ex, ey, ez = target_cell(target)
    if sx < 0 or sx >= w or sy < 0 or sy >= h or sz < 0 or sz >= d then
        return false
    end
    if ex < 0 or ex >= w or ey < 0 or ey >= h or ez < 0 or ez >= d then
        return false
    end
    if sx == ex and sy == ey and sz == ez then
        return true -- same cell: trivially visible
    end
    if not in_shape(o, ex - sx, ey - sy, ez - sz) then
        return false -- beyond range / outside the shape extent
    end
    local opacity = o.opaque
    local cells = raycast3d.run({ dims = { w, h, d }, a = { sx, sy, sz }, b = { ex, ey, ez } })
    for _, c in ipairs(cells) do
        -- A cell EQUAL to the target is reached, not tested: you see the
        -- thing at the target (its own opacity is exempt). The ray walks
        -- in supercover order; proper subsets of a tie precede the full
        -- step, so a target sitting on a crossed corner is matched as the
        -- full step and not blocked by itself.
        if c[1] == ex and c[2] == ey and c[3] == ez then
            return true
        end
        if opacity(c[1], c[2], c[3]) then
            return false
        end
    end
    return true -- reached the end (target emitted last) without a blocker
end

----------------------------------------------------------------------------------------------------
-- Public API
----------------------------------------------------------------------------------------------------

--- List of visible voxels from one viewpoint: every cell `{x,y,z}` with an
--- unobstructed 3D ray from `from` within the shape extent. Opaque voxels
--- are seen; cells beyond an opaque wall or ceiling are excluded.
---
--- @param from table  {x,y,z} viewer cell.
--- @param opts table  `{ dims, opaque, range, shape?, entities_at? }`.
--- @return table tiles  List of {x,y,z} cell tables.
function fov.visible_tiles(from, opts)
    local o = normalize(opts)
    local vis = compute_field(o, { from })
    return collect_cells(o, vis, { from })
end

--- List of visible entities from one viewpoint: every entity whose cell is
--- in the visibility field. Enumerated via the `entities_at` spatial-hash
--- callback. Entities don't block sight (terrain `Opaque` does, by design).
---
--- @param from table  {x,y,z} viewer cell.
--- @param opts table  `{ dims, opaque, range, shape?, entities_at }`.
--- @return table entities  Flat list of entity tables.
function fov.visible_entities(from, opts)
    local o = normalize(opts)
    local vis = compute_field(o, { from })
    local cells = collect_cells(o, vis, { from })
    return collect_entities(o, cells)
end

--- Union of visible tiles AND entities from a SET of viewpoints
--- (multi-tile bodies, squad vision). One shared 3D visibility field is
--- OR-ed across all viewpoints (one field, not N), then cells + entities
--- are collected from it. Overlapping viewpoints naturally dedupe.
---
--- @param positions table  List of {x,y,z} viewpoints.
--- @param opts table  `{ dims, opaque, range, shape?, entities_at }`.
--- @return table result  `{ tiles = list of {x,y,z}, entities = list }`.
function fov.visible_from_set(positions, opts)
    local o = normalize(opts)
    local vis = compute_field(o, positions)
    local cells = collect_cells(o, vis, positions)
    local ents = collect_entities(o, cells)
    return { tiles = cells, entities = ents }
end

--- Can `from` see a given entity? `target` is either:
---   * an entity REFERENCE (a table with Position `.x`/`.y`/`.z`, or a
---     `{x,y,z}` array) — tested with ONE 3D ray (fast, no field);
---     returns true iff no opaque voxel lies strictly between viewer and
---     target within the shape extent.
---   * an integer collision bitmask — tested by building the 3D visibility
---     field and scanning visible cells' buckets for any entity whose
---     `.mask` shares a bit ("can I see any entity of collision category X?").
---
--- @param from table  {x,y,z} viewer cell.
--- @param target table|integer  Entity reference OR Collision.* bitmask.
--- @param opts table  `{ dims, opaque, range, shape?, entities_at? }`.
--- @return boolean visible
function fov.can_see(from, target, opts)
    local o = normalize(opts)
    if type(target) == "number" then
        local vis = compute_field(o, { from })
        local cells = collect_cells(o, vis, { from })
        return first_matching_entity(o, cells, target) ~= nil
    end
    return ray_to_target(o, from, target)
end

--- Can ANY of `positions` see `target`? `target` is an entity reference or
--- a collision bitmask, same two forms as `can_see`:
---   * entity reference: one 3D ray per viewpoint; true if any reaches it.
---   * bitmask: one shared 3D visibility field OR-ed across all viewpoints,
---     then a single bucket scan.
---
--- @param positions table  List of {x,y,z} viewpoints.
--- @param target table|integer  Entity reference OR Collision.* bitmask.
--- @param opts table  `{ dims, opaque, range, shape?, entities_at? }`.
--- @return boolean visible
function fov.can_see_from_set(positions, target, opts)
    local o = normalize(opts)
    if type(target) == "number" then
        local vis = compute_field(o, positions)
        local cells = collect_cells(o, vis, positions)
        return first_matching_entity(o, cells, target) ~= nil
    end
    for _, p in ipairs(positions) do
        if ray_to_target(o, p, target) then
            return true
        end
    end
    return false
end

--- Single-pair boolean sight seam: can cell `a` see cell `b` (3D)? Casts
--- one 3D voxel-DDA ray and consults `opts.opaque`; returns the bool PLUS
--- the first opaque blocker (useful for rendering the obstruction or for
--- projectile impact points). This is the thinnest sight primitive;
--- `fov.can_see(from, entity)` is the ergonomic single-target form (with
--- range/shape gating + entity-position resolution), and `fov.visible_*`
--- are the many-at-once forms. Implemented in `fov.line_of_sight`.
---
--- @param opts table  `{ dims, a = {x,y,z}, b = {x,y,z}, opaque }`.
--- @return boolean visible
--- @return table|nil blocker  First {x,y,z} cell on the ray that was opaque.
fov.line_of_sight = require("fov.line_of_sight").run

return fov
