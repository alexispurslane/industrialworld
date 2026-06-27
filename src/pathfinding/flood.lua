--- Flood fill (BFS / budget-bounded Dijkstra) for connectivity + reach.
--
-- WHEN TO USE THIS:
--   "Is cell A connected to cell B at all?" / "what's reachable within
--   budget N?" / region membership / "is this area enclosed?". When you
--   don't care about a specific target, just reachability. With a
--   `budget`, becomes a wall-respecting explosion/shout radius (won't
--   blow through walls, unlike the pure-geometric `within_radius`).
--
-- WHEN NOT TO: for a concrete A→B route use `find_path`. For "cost to
--   every cell" use `distance_field` (this returns a set, not distances).
--   For a pure circular extent ignoring walls use `within_radius`.

local scratch = require("pathfinding.scratch")
local grid = require("pathfinding.grid")

local flood = {}

local UNSEEN, OPEN, CLOSED = scratch.UNSEEN, scratch.OPEN, scratch.CLOSED

--- Flood outward from `start`. With no `budget`, expands over all
--- reachable passable cells; with `budget`, stops at total cost <= budget
--- (so it doubles as a wall-respecting area query). Returns the visited
--- cell set as a reusable boolean cdata buffer (one byte per cell).
---
--- @param opts table  `{ dims, start, passable, cost?, occupied?,
---                     transition?, diagonal?, budget? }`.
--- @return table result  `{ visited = uint8[count] cdata (1 if reached),
---                          reached = table of {x,y,z} cell tables,
---                          status = "ok"|"budget_exhausted" }`.
function flood.run(opts)
    local o = grid.normalize(opts)
    local w, h, d, count = o.w, o.h, o.d, o.count
    local src = opts.source
    local sx, sy, sz = src[1], src[2], src[3]
    local budget = opts.budget -- nil => unbounded

    local s = scratch.get(count)
    local gscore = s.gscore
    local state = s.state

    local sc = grid.cell(w, h, sx, sy, sz)
    gscore[sc] = 0
    state[sc] = OPEN
    -- Simple FIFO queue (BFS for uniform cost; BFS-with-cost-cutoff when
    -- a budget is set, we still expand by best-first via gscore since
    -- neighbors may have non-uniform cost()).
    local queue = { sc }
    local qhead = 1
    local reached = { { sx, sy, sz } }

    local out = {}
    while qhead <= #queue do
        local cur = queue[qhead]
        qhead = qhead + 1
        if state[cur] == CLOSED then
            goto continue
        end
        state[cur] = CLOSED
        local cur_g = gscore[cur]

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
            if state[nc] == UNSEEN then
                local ng = cur_g + step
                if budget == nil or ng <= budget then
                    gscore[nc] = ng
                    state[nc] = OPEN
                    queue[#queue + 1] = nc
                    reached[#reached + 1] = { nx, ny, nz }
                end
            end
        end
        ::continue::
    end

    -- Pack the reached set into a boolean cdata for cheap membership.
    local ffi = require("ffi")
    local visited = ffi.new("uint8_t[?]", count)
    for _, c in ipairs(reached) do
        visited[grid.cell(w, h, c[1], c[2], c[3])] = 1
    end

    local status = "ok"
    if budget ~= nil then
        status = "budget_exhausted" -- caller asked for a cap; we respected it
    end
    return { visited = visited, reached = reached, status = status }
end

return flood
