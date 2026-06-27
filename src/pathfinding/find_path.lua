--- Single-route A* from one cell to another.
--
-- WHEN TO USE THIS:
--   You want ONE actor to navigate from A to B over the grid. Returns
--   a concrete polyline (list of cells to walk) + the total path cost.
--   Reads your map's passability (a `passable(x,y,z)` callback — usually
--   `TileFlags.Walkable`), optional per-step `cost`, optional dynamic
--   `occupied` blockers (live entities), and z-transitions via
--   `transition` (default reads `TileType.StairsUp/StairsDown/Ramp`).
--   Honors `diagonal = true` (8-dir octile, no corner cutting) or 4-dir.
--
-- WHEN NOT TO: for many actors heading to ONE target, use
--   `descent_field` (one search feeds them all). For "how far is every
--   reachable cell" use `distance_field`. For "is X connected to Y at
--   all / within budget N" use `flood`. These avoid re-running A* N times.

local heap = require("pathfinding.heap")
local scratch = require("pathfinding.scratch")
local grid = require("pathfinding.grid")

local find_path = {}

local UNSEEN, OPEN, CLOSED = scratch.UNSEEN, scratch.OPEN, scratch.CLOSED

-- Octile heuristic (8-dir) / Manhattan (4-dir). Admissible for uniform
-- costs; for non-uniform cost() this is an inadmissible-but-useful guide
-- (A* may not be optimal but stays fast — document if it matters).
local function heuristic(opts, x, y, z, gx, gy, gz)
    local dx, dy, dz = math.abs(x - gx), math.abs(y - gy), math.abs(z - gz)
    if opts.diagonal then
        -- 3D octile: orthogonal = D, diagonal (in-layer) = D*sqrt(2)≈1.414.
        local diag = math.min(dx, dy)
        local straight = dx + dy - 2 * diag
        return straight + diag * 1.41421356 + dz
    else
        return dx + dy + dz
    end
end

--- Find a minimum-cost route from `start` to `goal`.
---
--- @param opts table  `{ dims, start, goal, passable, cost?, occupied?,
---                     transition?, diagonal?, budget? }` (see grid.normalize).
--- @return table|nil path   List of `{x,y,z}` cells start..goal inclusive, or nil.
--- @return string status    "reached" | "none" | "budget_exhausted".
--- @return integer|nil cost Total path cost (only when status=="reached").
function find_path.run(opts)
    local o = grid.normalize(opts)
    local w, h, d, count = o.w, o.h, o.d, o.count
    local start, goal = opts.start, opts.goal
    local sx, sy, sz = start[1], start[2], start[3]
    local gx, gy, gz = goal[1], goal[2], goal[3]

    if not o.passable(gx, gy, gz) or o.occupied(gx, gy, gz) then
        return nil, "none", nil
    end

    local s = scratch.get(count)
    local gscore = s.gscore
    local parent = s.parent
    local state = s.state

    local gc = grid.cell(w, h, gx, gy, gz)
    local sc = grid.cell(w, h, sx, sy, sz)

    local open = heap.new()
    gscore[sc] = 0
    state[sc] = OPEN
    heap.push(open, heuristic(o, sx, sy, sz, gx, gy, gz), sc)

    local out = {} -- reused neighbor accumulator
    local expanded = 0
    local budget = o.budget

    while true do
        local cur, _ = heap.pop(open)
        if cur == nil then
            return nil, "none", nil
        end
        if state[cur] == CLOSED then
            -- stale duplicate entry; skip.
            goto continue
        end
        if cur == gc then
            -- Reconstruct path by walking parents back to start.
            local path = {}
            local c = gc
            local n = 0
            while c ~= sc do
                local cz = math.floor(c / (w * h))
                local rem = c - cz * w * h
                local cy = math.floor(rem / w)
                local cx = rem - cy * w
                n = n + 1
                path[n] = { cx, cy, cz }
                c = parent[c]
            end
            n = n + 1
            path[n] = { sx, sy, sz }
            -- reverse to start..goal
            for i = 1, math.floor(n / 2) do
                path[i], path[n - i + 1] = path[n - i + 1], path[i]
            end
            return path, "reached", gscore[gc]
        end
        state[cur] = CLOSED
        expanded = expanded + 1
        if expanded > budget then
            return nil, "budget_exhausted", nil
        end

        local cz = math.floor(cur / (w * h))
        local rem = cur - cz * w * h
        local cy = math.floor(rem / w)
        local cx = rem - cy * w

        grid.neighbors(cx, cy, cz, o, out)
        local i, n = 1, #out
        while i <= n do
            local nx, ny, nz, step = out[i], out[i + 1], out[i + 2], out[i + 3]
            i = i + 4
            local nc = grid.cell(w, h, nx, ny, nz)
            if state[nc] ~= CLOSED then
                local tentative = gscore[cur] + step
                if state[nc] ~= OPEN or tentative < gscore[nc] then
                    parent[nc] = cur
                    gscore[nc] = tentative
                    local f = tentative + heuristic(o, nx, ny, nz, gx, gy, gz)
                    heap.push(open, f, nc)
                    if state[nc] ~= OPEN then
                        state[nc] = OPEN
                    end
                end
            end
        end
        ::continue::
    end
end

return find_path
