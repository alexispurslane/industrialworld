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
--- @return table field  `{ gscore = int32[count] cdata (0 for unreachable,
---                         guarded by `state` — see below),
---                         state = uint8[count] cdata (0=unseen, 1=open, 2=closed),
---                         status = "ok"|"budget_exhausted"|"node_cap_exhausted", source }`.
function distance_field.run(opts)
    local o = grid.normalize(opts)
    local w, h, d, count = o.w, o.h, o.d, o.count
    local src = opts.source
    local sx, sy, sz = src[1], src[2], src[3]

    -- Optional `box` = {minx,miny,minz,maxx,maxy,maxz} in GLOBAL cell coords:
    -- a sub-region guaranteed to contain every cell the search can reach
    -- (callers size it source ± (budget_radius + margin)). When set, we
    -- borrow a box-scoped scratch (`get_box`) that zeroes ONLY the box
    -- sub-range of `state` — a tiny memset instead of a full-map one on
    -- huge maps — and we record every reached cell in a `visited` list so
    -- callers iterate the reached set (a few thousand) instead of scanning
    -- 0..count-1 (40 M+). The flood loop itself is UNCHANGED: it still uses
    -- full-map `grid.cell` indices, and budget bounding guarantees it never
    -- opens (or even reads meaningfully) a cell outside the box. Stale
    -- state outside the box is therefore never consumed.
    local box = opts.box
    local s
    if box ~= nil then
        local minx, miny, minz = box[1], box[2], box[3]
        local maxx, maxy, maxz = box[4], box[5], box[6]
        if minx < 0 then
            minx = 0
        end
        if miny < 0 then
            miny = 0
        end
        if minz < 0 then
            minz = 0
        end
        if maxx > w - 1 then
            maxx = w - 1
        end
        if maxy > h - 1 then
            maxy = h - 1
        end
        if maxz > d - 1 then
            maxz = d - 1
        end
        local bw = maxx - minx + 1
        local bh = maxy - miny + 1
        local bd = maxz - minz + 1
        s = scratch.get_box(count, w, h, {
            minx,
            miny,
            minz,
            maxx,
            maxy,
            maxz,
        })
    else
        s = scratch.get(count)
    end
    local gscore = s.gscore
    local parent = s.parent
    local state = s.state

    local sc = grid.cell(w, h, sx, sy, sz)
    gscore[sc] = 0
    state[sc] = OPEN
    local open = heap.new()
    heap.push(open, 0, sc)

    -- Reached-cell log (box mode only): global cell index of every cell the
    -- flood opened, recorded once on first UNSEEN->OPEN (incl. the source).
    -- Callers iterate this instead of 0..count-1 (see `box` doc above).
    local visited = box ~= nil and { sc } or nil

    local out = {}
    local expanded = 0
    local budget = o.budget
    local node_cap = o.node_cap

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
        if expanded > node_cap then
            return {
                gscore = gscore,
                state = state,
                status = "node_cap_exhausted",
                source = sc,
                parent = parent,
                visited = visited,
            }
        end
        local cur_g = gscore[cur]
        -- COST budget: once the cheapest-open cell already costs more than
        -- `budget`, every remaining open cell is too (Dijkstra pops in
        -- g-score order), so the cost-bounded region is complete.
        if budget ~= nil and cur_g > budget then
            return {
                gscore = gscore,
                state = state,
                status = "budget_exhausted",
                source = sc,
                parent = parent,
                visited = visited,
            }
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
                -- Don't relax cells already over the cost budget: they are
                -- outside the requested reach radius; leaving them off the
                -- heap keeps the cost-bounded region tight and lets cells
                -- UNDER budget elsewhere still pop and expand.
                if budget == nil or tentative <= budget then
                    if state[nc] ~= OPEN or tentative < gscore[nc] then
                        parent[nc] = cur
                        gscore[nc] = tentative
                        heap.push(open, tentative, nc)
                        if state[nc] ~= OPEN then
                            state[nc] = OPEN
                            if visited ~= nil then
                                visited[#visited + 1] = nc
                            end
                        end
                    end
                end
            end
        end
        ::continue::
    end

    return {
        gscore = gscore,
        state = state,
        status = "ok",
        source = sc,
        parent = parent,
        visited = visited,
    }
end

return distance_field
