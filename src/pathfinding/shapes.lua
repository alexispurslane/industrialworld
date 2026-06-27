--- Pure-geometric extent iterators: circles and spheres of cells.
--
-- WHEN TO USE THIS:
--   When you want a pure RADIUS — every cell within distance R of a
--   center, IGNORING walls. Use for AOE noise extents, particle placement,
--   "is this even in range at all" checks, and anywhere terrain doesn't
--   gate the effect. Cheap (no search, just over a bounding box).
--
-- WHEN NOT TO: if the effect must RESPECT walls (an explosion that
--   shouldn't pass through them, a shout that muffled stone stops), use
--   `flood(start, budget)` — it's `flood` with a budget that gives a
--   wall-respecting radius. `within_radius` is the wrong tool there.

local shapes = {}

--- Iterate every 2D cell within Chebyshev/Euclidean radius `r` of
--- `(cx, cy)` in layer `z`. Returns a flat list of `{x,y}` tables. Uses
--- the Euclidean test (distance <= r) so it's a true circle, not a
--- square; for a square (Chebyshev) extent just iterate the bounding box.
---
--- @param opts table  `{ dims, center = {x,y}, z?, r (integer) }`.
--- @return table cells  List of {x,y} cell tables.
function shapes.within_radius(opts)
    local dims = opts.dims
    local w, h = dims[1], dims[2]
    local cx, cy = opts.center[1], opts.center[2]
    local r = opts.r
    local out = {}
    local n = 0
    local r2 = r * r
    for dy = -r, r do
        for dx = -r, r do
            local x, y = cx + dx, cy + dy
            if x >= 0 and x < w and y >= 0 and y < h then
                if dx * dx + dy * dy <= r2 then
                    n = n + 1
                    out[n] = { x, y }
                end
            end
        end
    end
    return out
end

--- Iterate every 3D cell within radius `r` of `(cx, cy, cz)` (a sphere).
---
--- @param opts table  `{ dims, center = {x,y,z}, r (integer) }`.
--- @return table cells  List of {x,y,z} cell tables.
function shapes.within_sphere(opts)
    local dims = opts.dims
    local w, h, d = dims[1], dims[2], dims[3]
    local cx, cy, cz = opts.center[1], opts.center[2], opts.center[3]
    local r = opts.r
    local out = {}
    local n = 0
    local r2 = r * r
    for dz = -r, r do
        for dy = -r, r do
            for dx = -r, r do
                local x, y, z = cx + dx, cy + dy, cz + dz
                if x >= 0 and x < w and y >= 0 and y < h and z >= 0 and z < d then
                    if dx * dx + dy * dy + dz * dz <= r2 then
                        n = n + 1
                        out[n] = { x, y, z }
                    end
                end
            end
        end
    end
    return out
end

return shapes
