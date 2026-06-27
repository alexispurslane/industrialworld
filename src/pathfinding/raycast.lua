--- Grid ray traversal: which cells a straight line crosses.
--
-- WHEN TO USE THIS:
--   Projectiles, beams, "draw a line from A to B" previews, and as the
--   backbone of `line_of_sight`. Returns the ordered list of cells the
--   ray passes through (Bresenham + the "supercover" variant that
--   includes diagonally-touched cells so you don't tunnel through corners).
--
-- WHEN NOT TO: for a visibility/can-see query, use `line_of_sight`
--   directly (it consults your map's `Opaque` flag and returns a bool).
--   For gameplay routes around obstacles, use `find_path`.

local grid = require("pathfinding.grid")

local raycast = {}

--- Walk the cells crossed by the segment from (ax,ay,az) to (bx,by,bz)
--- in the same Z-layer. Returns the list (excluding the start cell,
--- including the end). `supercover` (default true) includes cells the
--- ray merely touches at a corner; set false for bare Bresenham.
---
--- NOTE: this is 2D-in-layer. For a truly 3D ray (e.g. a projectile
--- climbing a ramp) lift the same algorithm to x/y/z deltas — left as a
--- follow-up until something needs it; most LOS/projectiles stay planar.
---
--- @param opts table  `{ dims, a = {x,y}, b = {x,y}, z?, supercover? }`.
--- @return table cells  Ordered list of {x,y} cells crossed (excl. start).
function raycast.run(opts)
    local dims = opts.dims
    local w, h = dims[1], dims[2]
    local z = opts.z or 0
    local supercover = opts.supercover ~= false
    local a, b = opts.a, opts.b
    local x0, y0 = a[1], a[2]
    local x1, y1 = b[1], b[2]

    local dx = math.abs(x1 - x0)
    local dy = math.abs(y1 - y0)
    local sx = x0 < x1 and 1 or -1
    local sy = y0 < y1 and 1 or -1
    local err = dx - dy

    local cells = {}
    local x, y = x0, y0
    local n = 0
    while true do
        if x == x1 and y == y1 then
            break
        end
        local e2 = 2 * err
        local stepped_x = false
        local stepped_y = false
        if e2 > -dy then
            err = err - dy
            x = x + sx
            stepped_x = true
        end
        if e2 < dx then
            err = err + dx
            y = y + sy
            stepped_y = true
        end
        n = n + 1
        cells[n] = { x, y }
        if supercover and stepped_x and stepped_y then
            -- The ray crossed a corner; include the cell diagonal to the
            -- step so a vertical/horizontal wall on either axis can't be
            -- tunneled through.
            n = n + 1
            cells[n] = { x - sx, y }
            n = n + 1
            cells[n] = { x, y - sy }
        end
    end
    return cells
end

return raycast
