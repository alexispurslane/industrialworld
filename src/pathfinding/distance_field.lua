--- Single-source Dijkstra: shortest cost to EVERY reachable cell.
--
-- WHEN TO USE THIS:
--   You want the cost (or distance) from one cell to all reachable cells
--   at once — "how far is the player from every tile", "everything within
--   budget N of this goblin", want-propagation for AI influence maps.
--   Also the engine under `descent_field` (search toward one GOAL from
--   many starts). Symmetric on uniform grids, so distance_field(source)
--   and descent_field(goal) are the same search.
--
-- WHEN NOT TO: for a single A→B route, `find_path` is cheaper (heuristic
--   prunes). For pure connectivity (don't care about distances), `flood`
--   is cheaper still (no priority queue).

local heap = require("pathfinding.heap")
local scratch = require("pathfinding.scratch")
local grid = require("pathfinding.grid")

local distance_field = {}

local UNSEEN, OPEN, CLOSED = scratch.UNSEEN, scratch.OPEN, scratch.CLOSED

--- Compute the cost-to-reach for every cell from `source`.
---
--- @param opts table  `{ dims, source, passable, cost?, occupied?,
---                     transition?, diagonal?, budget? }`.
--- @return table field  `{ gscore = int32[count] cdata (0 for unreachable),
---                         status = "ok"|"budget_exhausted", source }`.
function distance_field.run(opts)
    local o = grid.normalize(opts)
    local w, h, d, count = o.w, o.h, o.d, o.count
    local src = opts.source
    local sx, sy, sz = src[1], src[2], src[3]

    local s = scratch.get(count)
    local gscore = s.gscore
    local parent = s.parent
    local state = s.state

    local sc = grid.cell(w, h, sx, sy, sz)
    gscore[sc] = 0
    state[sc] = OPEN
    local open = heap.new()
    heap.push(open, 0, sc)

    local out = {}
    local expanded = 0
    local budget = o.budget

    while true do
        local cur, _ = heap.pop(open)
        if cur == nil then
            break
        end
        if state[cur] == CLOSED then
            goto continue
        end
        state[cur] = CLOSED
        expanded = expanded + 1
        if expanded > budget then
            return { gscore = gscore, status = "budget_exhausted", source = sc, parent = parent }
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
                    heap.push(open, tentative, nc)
                    if state[nc] ~= OPEN then
                        state[nc] = OPEN
                    end
                end
            end
        end
        ::continue::
    end

    return { gscore = gscore, status = "ok", source = sc, parent = parent }
end

return distance_field
