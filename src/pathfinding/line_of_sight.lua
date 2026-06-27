--- Boolean line-of-sight: can one cell see another?
--
-- WHEN TO USE THIS:
--   Ranged targeting ("can the player shoot this goblin?"), stealth
--   checks, "is this in view" for triggers, and as the reusable seam for
--   a future FOV/lighting module (FUTURE_WORK #1) — FOV will fan LOS
--   rays outward and reuse this + the `Opaque` predicate. Returns a bool
--   plus the first opaque cell that blocks the ray (useful for rendering
--   the obstruction or for projectile impact points).
--
-- WHEN NOT TO: this is a yes/no + blocker. For the actual cell list a
--   ray crosses, use `raycast`. For routes around cover, `find_path`.

local raycast = require("pathfinding.raycast")

local line_of_sight = {}

--- True if no opaque cell lies between `a` and `b` in the same Z-layer.
--- Uses the supercover ray (corner-touching cells included) so a diagonal
--- wall corner blocks sight as it should.
---
--- @param opts table  `{ dims, a = {x,y}, b = {x,y}, z?, opaque }` where
---                     `opaque(x,y,z) -> bool` reports opacity (usually
---                     `TileFlags.Opaque`).
--- @return boolean visible
--- @return table|nil blocker  First {x,y} cell on the ray that was opaque.
function line_of_sight.run(opts)
    local opaque = opts.opaque
    assert(type(opaque) == "function", "line_of_sight: opts.opaque(x,y,z)->bool required")
    local z = opts.z or 0
    local cells = raycast.run(opts)
    for _, c in ipairs(cells) do
        if opaque(c[1], c[2], z) then
            return false, c
        end
    end
    return true, nil
end

return line_of_sight
