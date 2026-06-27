--- 3D grid ray traversal: which voxels a straight 3D segment crosses.
--
-- WHEN TO USE THIS:
--   Native 3D field-of-view (a sight ray from the viewer's cell to a
--   target cell, climbing through layers — blocked by any opaque voxel
--   along the way, so a solid floor/ceiling naturally cuts off upper
--   layers), 3D projectiles/beams that climb ramps, and any "does this 3D
--   segment pass through this voxel" query. Returns the ordered list of
--   voxels the ray enters (excluding the start cell, including the end),
--   so callers can walk it and stop at the first opaque cell.
--
-- WHEN NOT TO: for a 2D-in-layer ray (planar LOS, planar projectiles,
--   draw-a-line previews), use `pathfinding.raycast` — cheaper (no Z
--   bookkeeping) and its 2D supercover is sufficient for planar needs.
--
-- ALGORITHM: Amanatides & Woo ("A Fast Voxel Traversal Algorithm for Ray
--   Tracing"), the standard 3D DDA. For each axis we track the t-value at
--   which the ray next crosses a voxel boundary; each step advances the
--   axis (or axes — on a tie) with the smallest t. SUPERCOVER EXTENSION:
--   when the ray crosses two or three boundaries at the SAME t (it passes
--   exactly through a voxel edge or corner), we step ALL tied axes and
--   ALSO emit the intermediate cells reached by stepping each tied subset
--   — so a wall on any side of an edge/corner crossing blocks the ray,
--   matching the 2D `raycast`'s supercover guarantee (no diagonal-tunnel).
--
-- ENDPOINTS: the ray is cast between cell CENTERS: from (ax+.5, ay+.5,
--   az+.5) to (bx+.5, by+.5, bz+.5). Walking starts in cell a (excluded
--   from the output) and ends when cell b is reached (included). A
--   degenerate segment (a == b) returns an empty list.
--
-- OUT-OF-BOUNDS: bounds are NOT clamped here — `dims` is only used to
--   short-circuit (the walk stops if it ever leaves the grid, since a ray
--   that exits can't re-enter a convex grid). Callers querying FOV should
--   bound their candidate extent to in-grid cells (fov does this).
--
-- @param opts table  `{ dims = {w,h,d}, a = {x,y,z}, b = {x,y,z} }`.
-- @return table cells  Ordered list of {x,y,z} voxels crossed (excl. start).
local raycast3d = {}

function raycast3d.run(opts)
    local dims = opts.dims
    local w, h, d = dims[1], dims[2], dims[3]
    local a, b = opts.a, opts.b
    local ax, ay, az = a[1] + 0.5, a[2] + 0.5, a[3] + 0.5
    local bx, by, bz = b[1] + 0.5, b[2] + 0.5, b[3] + 0.5

    -- Integer start cell.
    local x = a[1]
    local y = a[2]
    local z = a[3]

    -- Direction deltas (use the raw b-a delta; floor/ceil handle sign).
    local ddx, ddy, ddz = bx - ax, by - ay, bz - az

    -- Per-axis step direction (0 if the ray doesn't move on that axis).
    local stepX = ddx > 0 and 1 or (ddx < 0 and -1 or 0)
    local stepY = ddy > 0 and 1 or (ddy < 0 and -1 or 0)
    local stepZ = ddz > 0 and 1 or (ddz < 0 and -1 or 0)

    local cells = {}
    local n = 0

    -- Degenerate: a == b (no movement on any axis). Nothing to walk.
    if stepX == 0 and stepY == 0 and stepZ == 0 then
        return cells
    end

    -- tMaxX/Y/Z: t at which the ray first crosses the NEXT voxel boundary
    -- on each axis. For a ray starting mid-voxel, the next boundary in the
    -- +step direction is at +1 cell; in the -step direction at 0. With
    -- step 0, the axis never advances (tMax = +inf).
    -- tDeltaX/Y/Z: t change per whole-voxel crossing on each axis.
    local tMaxX, tMaxY, tMaxZ
    local tDeltaX, tDeltaY, tDeltaZ

    if stepX ~= 0 then
        local nxt = stepX > 0 and (x + 1) or x -- next boundary cell line
        tMaxX = (nxt - ax) / ddx
        tDeltaX = math.abs(1 / ddx)
    else
        tMaxX = math.huge
        tDeltaX = math.huge
    end
    if stepY ~= 0 then
        local nxt = stepY > 0 and (y + 1) or y
        tMaxY = (nxt - ay) / ddy
        tDeltaY = math.abs(1 / ddy)
    else
        tMaxY = math.huge
        tDeltaY = math.huge
    end
    if stepZ ~= 0 then
        local nxt = stepZ > 0 and (z + 1) or z
        tMaxZ = (nxt - az) / ddz
        tDeltaZ = math.abs(1 / ddz)
    else
        tMaxZ = math.huge
        tDeltaZ = math.huge
    end

    -- End cell: stop when reached.
    local ex, ey, ez = b[1], b[2], b[3]

    -- Order the three tMax values to find which axes tie at the minimum,
    -- then step them together (supercover). Returns a list of {dx,dy,dz}
    -- step-subsets to apply THIS step, in the order partial-then-whole so
    -- the emitted cells trace the ray's actual path (e.g. on an X+Y tie:
    -- step X only, step Y only, then both — emitting the two edge-touched
    -- cells before the diagonal). Each subset is applied iff its axis is
    -- active (step != 0). The whole (all-tied) subset lists last.
    local function step_subsets(min_t)
        -- Collect active axes that tie at min_t.
        local tx = (stepX ~= 0) and tMaxX <= min_t + 1e-12
        local ty = (stepY ~= 0) and tMaxY <= min_t + 1e-12
        local tz = (stepZ ~= 0) and tMaxZ <= min_t + 1e-12
        local subs = {}
        -- Single-axis partials first (edge-touched neighbors), then the
        -- full tie (the cell the ray actually enters). On a 2-axis tie:
        -- emit {X},{Y},{X,Y}. On a 3-axis tie: {X},{Y},{Z},{X,Y},{X,Z},{Y,Z},{X,Y,Z}.
        if tx and ty and tz then
            subs[1] = { 1, 0, 0 }
            subs[2] = { 0, 1, 0 }
            subs[3] = { 0, 0, 1 }
            subs[4] = { 1, 1, 0 }
            subs[5] = { 1, 0, 1 }
            subs[6] = { 0, 1, 1 }
            subs[7] = { 1, 1, 1 }
        elseif tx and ty then
            subs[1] = { 1, 0, 0 }
            subs[2] = { 0, 1, 0 }
            subs[3] = { 1, 1, 0 }
        elseif tx and tz then
            subs[1] = { 1, 0, 0 }
            subs[2] = { 0, 0, 1 }
            subs[3] = { 1, 0, 1 }
        elseif ty and tz then
            subs[1] = { 0, 1, 0 }
            subs[2] = { 0, 0, 1 }
            subs[3] = { 0, 1, 1 }
        else
            -- single axis only
            if tx then
                subs[1] = { 1, 0, 0 }
            elseif ty then
                subs[1] = { 0, 1, 0 }
            else
                subs[1] = { 0, 0, 1 }
            end
        end
        return subs
    end

    -- Advance the tMax values for the axes stepped in `sub`, by tDelta.
    local function advance(sub)
        if sub[1] ~= 0 then
            tMaxX = tMaxX + tDeltaX
        end
        if sub[2] ~= 0 then
            tMaxY = tMaxY + tDeltaY
        end
        if sub[3] ~= 0 then
            tMaxZ = tMaxZ + tDeltaZ
        end
    end

    local max_iter = (w + h + d) * 2 + 4 -- runaway guard (a segment can't cross more cells than sum-of-spans; +ties)
    for _ = 1, max_iter do
        -- Determine the min t and which axes tie there.
        local min_t = tMaxX
        if tMaxY < min_t then
            min_t = tMaxY
        end
        if tMaxZ < min_t then
            min_t = tMaxZ
        end
        -- On a tie, emit the edge/corner-touched cells BEFORE the full
        -- step (supercover). The partial subsets trace neighbors the ray
        -- glances; the final subset is the cell the ray actually enters.
        local subs = step_subsets(min_t)
        local last = subs[#subs]
        for i = 1, #subs do
            local sub = subs[i]
            -- Apply the step subset to get the new cell. Partials (i<#subs)
            -- are emitted but do NOT become the "current" cell for the next
            -- iteration's stepping base — only the full (last) subset
            -- advances the running (x,y,z); the partials just record the
            -- touched neighbor. (Since the partials differ from current
            -- by one axis and from the full by the other, and the full
            -- becomes the new current, this is consistent.)
            local cx = x + sub[1] * stepX
            local cy = y + sub[2] * stepY
            local cz = z + sub[3] * stepZ
            -- Bounds short-circuit: a ray that exited the grid won't
            -- re-enter (grid is convex); stop entirely.
            if cx < 0 or cx >= w or cy < 0 or cy >= h or cz < 0 or cz >= d then
                return cells
            end
            n = n + 1
            cells[n] = { cx, cy, cz }
            -- On reaching the end cell (via the full subset), the walk is
            -- done. (Partials could also land on the end cell for very
            -- short diagonal segments; either way, once we emit the end
            -- cell we stop.)
            if cx == ex and cy == ey and cz == ez then
                return cells
            end
        end
        -- Commit the full subset's step as the new running cell.
        x = x + last[1] * stepX
        y = y + last[2] * stepY
        z = z + last[3] * stepZ
        advance(last)
    end
    return cells
end

return raycast3d
