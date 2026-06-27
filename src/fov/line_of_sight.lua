--- Boolean line-of-sight: can one cell see another?
--
-- Part of the FOV package (`require("fov").line_of_sight`): this is the
-- single-pair sight primitive, NATIVELY 3D. `pathfinding.raycast3d` walks
-- the voxels a 3D segment crosses (Amanatides-&-Woo DDA, with supercover
-- ties so diagonal wall corners block); this consults your map's `Opaque`
-- flag on each voxel and returns a bool plus the first opaque blocker.
-- FOV's field/list/entity queries (`fov.visible_tiles`, `fov.can_see`, ...)
-- are the many-at-once forms built on the same 3D traversal; this is the
-- thinnest seam for a "can A see B?" with no range/shape and no
-- enumeration.
--
-- WHEN TO USE THIS:
--   Ranged targeting ("can the player shoot this goblin?", climbing a
--   staircase/skylight line), stealth checks, "is this in view" for
--   triggers, and as the reusable seam for FOV — `fov.can_see(entity)`
--   casts one 3D ray just like this. Returns a bool plus the first opaque
--   voxel that blocks the ray (useful for rendering the obstruction or for
--   projectile impact points).
--
-- WHEN NOT TO: this is a yes/no + blocker. For the actual voxel list a
--   ray crosses, use `pathfinding.raycast3d`. For everything-in-view lists
--   (all visible tiles/entities), use `fov.visible_*` (one field, not one
--   ray per cell). For routes around cover, `pathfinding.find_path`.

local raycast3d = require("pathfinding.raycast3d")

local line_of_sight = {}

--- True if no opaque voxel lies between `a` and `b` (anywhere in 3D).
--- Uses the supercover 3D ray (edge/corner-touched voxels included) so a
--- diagonal wall corner blocks sight as it should, including climbs
--- through layers (an opaque floor/ceiling voxel above the viewer blocks
--- the ray up; Open air lets it climb — so "cut off by z-layers above"
--- happens naturally via the map's Opaque voxels).
---
--- @param opts table  `{ dims = {w,h,d}, a = {x,y,z}, b = {x,y,z}, opaque }` where
---                     `opaque(x,y,z) -> bool` reports opacity (usually a
---                     `TileFlags.Opaque` test).
--- @return boolean visible
--- @return table|nil blocker  First {x,y,z} voxel on the ray that was opaque.
function line_of_sight.run(opts)
    local opaque = opts.opaque
    assert(type(opaque) == "function", "line_of_sight: opts.opaque(x,y,z)->bool required")
    local dims = opts.dims
    local a, b = opts.a, opts.b
    local cells = raycast3d.run({ dims = { dims[1], dims[2], dims[3] }, a = a, b = b })
    for _, c in ipairs(cells) do
        if opaque(c[1], c[2], c[3]) then
            return false, c
        end
    end
    return true, nil
end

return line_of_sight
