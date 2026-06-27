--- Dijkstra search run FROM a goal — the many-actors-one-target primitive.
--
-- WHEN TO USE THIS:
--   Many NPCs all heading to ONE target (the player, an alarm, a rally
--   point). Runs ONE search from the target outward; each NPC then steps
--   to the neighboring cell with the LOWEST gscore (gradient descent).
--   Pays one search instead of N A* calls per turn — the standard
--   roguelike perf trick, worth it the moment you have >~3 actors sharing
--   a destination. Also feeds "best step toward goal" queries and
--   flow-field steering.
--
-- WHEN NOT TO: a single actor routing to one target wants `find_path`
--   (cheaper due to the heuristic). Identical math to `distance_field`
--   (Dijkstra is symmetric); this is the purpose-named entry point.

local distance_field = require("pathfinding.distance_field")

local descent_field = {}

--- Run a Dijkstra expansion FROM `goal` over all reachable cells.
--- Returns the same field shape as `distance_field.run`; the goal is the
--- `source`. To steer an actor at cell `c`, pick the passable neighbor
--- with the smallest field gscore.
--- @param opts table  Same as distance_field.run, with `source` = goal.
--- @return table field
function descent_field.run(opts)
    return distance_field.run(opts)
end

--- Pick the next step an actor at (x,y,z) should take to descend a
--- field toward its source. Returns (nx,ny,nz) of the lowest-gscore
--- passable neighbor, or nil if at a local minimum (already there / no
--- path). Honors the same passable/occupied/diagonal semantics as the
--- search that built the field.
--- @param field table   A field returned by descent_field/distance_field.
--- @param opts table    Original normalized options (w,h,d,passable,...).
--- @param x integer
--- @param y integer
--- @param z integer
--- @return integer|nil nx
--- @return integer|nil ny
--- @return integer|nil nz
function descent_field.step(field, opts, x, y, z)
    local grid_module = require("pathfinding.grid")
    local w, h = opts.w, opts.h
    local gscore = field.gscore
    local cur = grid_module.cell(w, h, x, y, z)
    if gscore[cur] == 0 then
        return nil -- at source
    end
    local out = {}
    grid_module.neighbors(x, y, z, opts, out)
    local best_cost, bx, by, bz = nil, nil, nil, nil
    local i, n = 1, #out
    while i <= n do
        local nx, ny, nz = out[i], out[i + 1], out[i + 2]
        i = i + 4
        local nc = grid_module.cell(w, h, nx, ny, nz)
        local g = gscore[nc]
        if g > 0 or nc == field.source then
            if best_cost == nil or g < best_cost then
                best_cost, bx, by, bz = g, nx, ny, nz
            end
        end
    end
    return bx, by, bz
end

return descent_field
