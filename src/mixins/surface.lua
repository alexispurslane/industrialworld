--- Surface mixin (pure leaf).
---
--- The "stationary physics body" capability for TILES (and any other
--- non-moving collidable that acts as a floor): it carries the surface's
--- friction coefficient, the property a moving PhysicsObject reads to
--- damp its horizontal velocity while resting on / sliding across this
--- surface. Tiles are NOT entities (law 3/4: they don't tick, aren't in
--- the entity pool), so this is data on a shared singleton mixin instance
--- — one Surface state per tile TYPE, read by every entity standing on
--- that type. No methods beyond init: friction is a passive property the
--- integrator queries, not something the surface itself acts on.
---
--- `friction` is the per-second horizontal velocity retention applied as
--- `v *= friction^dt` each frame by PhysicsObject.update. Lower = grippier
--- (snappier stop), higher = slideyer (longer coast). Matches the
--- semantics of PhysicsObject's per-instance `self.friction`; the
--- integrator prefers this tile-driven value when a supporting tile exists
--- and falls back to the instance default otherwise (e.g. airborne over
--- OOB, or a tile type with no Surface state).
---
--- Pure leaf (law 1/2): knows nothing of Position, Collidable, or the
--- world. Its one field is read externally; nothing is computed here.

local Surface = {}

--- Default per-second velocity retention. Matches `world.FRICTION` (the
--- engine-wide default applied before tiles carried their own friction);
--- kept here so a tile def that omits an explicit value behaves exactly as
--- the pre-Surface engine did. Override per tile type for surface variety
--- (e.g. ice ~0.5, mud ~0.001).
Surface.DEFAULT = 0.02

--- Set this surface's friction coefficient.
---@param self table
---@param friction? number  per-second velocity retention (default Surface.DEFAULT).
function Surface.init(self, friction)
    self.friction = friction or Surface.DEFAULT
end

return Surface
