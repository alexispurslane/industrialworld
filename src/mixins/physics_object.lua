--- PhysicsObject mixin (composed: Collidable + gravity + integrator).
---
--- The "basic silly physics engine". An entity whose motion is driven
--- ENTIRELY by the semi-implicit Euler integrator in Position — no direct
--- position writes, no teleport `fall()`, no discrete tile step. Motion
--- comes from acceleration impulses (`self:accelerate(...)` — e.g. the
--- player's arrow-key handler) and a constant downward gravity; friction
--- damps horizontal velocity each frame so impulses decay and you slide
--- to a stop. Collisions (terrain solidity + entity occupancy) are
--- resolved AXIS-BY-AXIS against the fractional post-integration
--- position: stepping one axis, if the cell now entered is blocked, the
--- entity snaps to that cell boundary and that axis's velocity is zeroed
--- — so you slide ALONG a wall when you hit it diagonally, and gravity
--- lands you gently on the floor instead of snapping down a z-stack.
---
--- This is law 2: "movement + gravity + collision" exists ONLY at the
--- intersection of Collidable + gravity + the integrator, is reusable
--- across archetypes, and coordinates three mixins (Collidable for the
--- mask/emit, Position for the integrator, the gravity flag) — so it lives
--- as an override on a composed mixin, NOT in subclasses. Mix it BEFORE
--- Drawable so its `update`/collision resolution win first-wins over
--- Drawable's plain Position.update.
---
--- `obeys_gravity` (init flag, default false): pass true for an entity
--- that should fall. When false, `az` stays 0 (no vertical baseline), so
--- the same mixin serves gravity-less collidables too.
---
--- Collision resolution does NOT itself emit "moved": motion is now
--- continuous (per-frame), so the camera follows every frame (synced in
--- the screen draw from `world.player`), not on a discrete event. Landing
--- / wall-strike still emit `collision` + the class-named pairing (so
--- stairs reactions fire, the message log can narrate bumps, etc.) exactly
--- as the old `Collidable:move` path did — the resolver calls the SAME
--- `emit_collision_with`.

local mixin = require("classes").mixin
local Collidable = require("mixins.collidable")
local world = require("world")
local tile = require("tile")
local bus = require("event")
local log = require("log")
local L = log.get("physics")

-- Tuning comes from `world` (GRAVITY / FRICTION) so it lives with the
-- other engine constants and is tweakable in one place. Required lazily
-- inside the hot loop? No — `world` is already a module singleton built
-- before any entity ticks, so a top-level local is fine.
local GRAVITY = world.GRAVITY
local FRICTION = world.FRICTION -- default per-instance friction (see init)

-- Velocity below which a horizontal axis gets SOFT-SNAPPED to the cell
-- boundary in its direction of last motion (see `soft_snap_axis`), but
-- ONLY when no impulse was applied to that axis this frame (the gate in
-- `update` step 5). Serves two purposes at once:
--   * TAP re-grid: a short tap releases with a v below this threshold, so
--     the next input-free frame snaps it cleanly to ~1 cell (the high
--     STEP_ACCEL would otherwise build overshoot during multi-frame taps).
--   * COAST termination: a genuine hold coasts (v decays exponentially via
--     friction) until v drops below this threshold, then re-grids to the
--     cell being entered — a graceful slide-to-stop. Co-sets the slide
--     length: lower here = longer coast before re-grid; higher = snappier.
local SOFT_SNAP_V = 10.0 -- cells/sec

local PhysicsObject = mixin({}, Collidable)

-- Sub-cell epsilon for the v>0 (moving +) snap: rests the entity just
-- BELOW the blocked boundary so floor(pos) stays inside the free cell
-- (the blocked cell's neighbor) — avoids an ugly backward teleport on a
-- wall brush. The v<0 (landing) snap uses exact integer cells (no EPS)
-- so resting z lands on a clean integer (downstream floors for cell
-- compares; an integer z keeps the player drawn in the right z-window).
local EPS = 1e-3

--- Initialize 3D position + collision mask (Collidable leaf) + gravity +
--- friction + mass. Takes a NAMED-FIELD table so the ~9 params (x/y/z
--- numbers, mask int, gravity bool, friction/mass numbers, w/h ints —
--- many same-typed) are disambiguated at the call site, not by position.
--- All fields optional except what the archetype needs. The entity is NOT
--- pre-settled on spawn: gravity pulls it down on the first `update` and
--- the resolver lands it. (Previously this called a teleporting `fall()`;
--- that path is gone — motion is integrator-only now.)
---
--- Fields:
---   x,y,z        — spawn position (Position leaf).
---   mask         — OR of Collision.* flags (Collidable leaf; default 0).
---   obeys_gravity — pass true to make it fall (default false).
---   friction     — per-second velocity retention (default world.FRICTION).
---                   Lower = grippier (snappier stop), higher = slideyer.
---   mass         — impulse resolution mass (default 1.0). Δv = J / mass,
---                   so a heavy body (mass 10) barely budges when shoved
---                   while a light crate (mass 0.1) launches. Knockback
---                   emits the MOVER's momentum (m_mover * v_mover) as the
---                   impulse; the target's own mass converts it to Δv.
---   w,h          — tile footprint dimensions (default 1,1 = single cell).
---                   Threaded to Collidable.init -> Position.init; all
---                   collision/occupancy/render paths cover the footprint.
---   vx,vy,vz     — initial velocity (default 0; Position leaf).
---@param opts? table  see fields above.
function PhysicsObject:init(opts)
    opts = opts or {}
    Collidable.init(self, opts)
    self.obeys_gravity = opts.obeys_gravity or false
    self.friction = opts.friction or FRICTION
    self.mass = opts.mass or 1.0
    -- Tag this instance as a PhysicsObject so collision resolution can
    -- cheaply identify knockable entity blockers (vs tile defs / "oob") and
    -- emit a knockback impulse scoped to them. Set AFTER Collidable.init so
    -- a fresh pooled slot (wiped by world.allocate) gets the flag every
    -- recycle.
    self.is_physics_object = true
    -- Listen for knockback impulses scoped to THIS entity (targeted event,
    -- mirroring the widget:click convention: a payload carrying identity so
    -- the handler can filter without holding cross-entity references). One
    -- subscription per entity, tracked on self._unsubs for teardown on destroy
    -- (so a destroyed entity stops receiving shoves — no dangling refs).
    -- Law 2: knockback is the cross-capability orchestration of collision +
    -- the integrator, reusable across EVERY archetype, so it lives here on the
    -- composed mixin rather than a per-archetype mixin every subclass must
    -- remember to compose. Every PhysicsObject is knockable by default.
    bus.subscribe(self, "knockback", function(p)
        if p.target ~= self then
            return
        end
        self:apply_impulse(p.ix or 0, p.iy or 0, p.iz or 0)
        L:debug(
            "[%s] knockback impulse (%.1f,%.1f,%.1f) from %s",
            self.__name or "?",
            p.ix or 0,
            p.iy or 0,
            p.iz or 0,
            (p.source and p.source.__name) or "?"
        )
    end)
    L:debug(
        "[%s] init gravity=%s friction=%s at (%d,%d,%d)",
        self.__name or "?",
        self.obeys_gravity,
        self.friction,
        opts.x or 0,
        opts.y or 0,
        opts.z or 0
    )
end

--- Return the blocker at cell (cx,cy,cz), or nil if walkable, or the
--- string "oob" if the cell is off-map (treated as a block with no name
--- to emit). Mirrors the lookup `Collidable:move` did: tile SoA type ->
--- fixed `tile.defs` entry -> mask AND; then the entity occupancy hash.
---@param cx integer
---@param cy integer
---@param cz integer
---@return table|string|nil blocker  tile def, entity, "oob", or nil.
function PhysicsObject:cell_blocker(cx, cy, cz)
    local map = world.map
    if not map:in_bounds(cx, cy, cz) then
        return "oob"
    end
    local tv = map.types:index(cx, cy, cz)
    local cb = tile.defs[tv]
    if cb ~= nil and self:should_collide(cb) then
        return cb
    end
    local e = world.entity_at(cx, cy, cz, self)
    if e ~= nil and self:should_collide(e) then
        return e
    end
    return nil
end

--- Test whether ANY cell of this entity's footprint is blocked, with the
--- moving axis pinned to `cell_value` (the candidate origin cell along
--- the march) and the OTHER axes fixed at the entity's CURRENT floored
--- position. Returns the first blocker found (tile def / entity / "oob")
--- or nil if the whole footprint is clear.
---
--- This generalizes the single-cell `cell_blocker` test used by the swept
--- march and soft-snap to multi-tile bodies. The march iterates the ORIGIN
--- cell from `floor(old)+dir` toward `floor(target)`; at each candidate
--- origin the newly-entered cell is always the FAR edge of the footprint
--- (`floor(x)+w-1` for +x, etc.), so the existing rest math
--- (cell-EPS / cell+1) stays correct for any w,h — only the block-test
--- broadens from one cell to the w×h footprint. `footprint_at` itself is
--- pure spatial state (law 1) and lives on Position; this is the collision
--- ORCHESTRATION over it (law 2), so it lives here on PhysicsObject.
---@param axis string  "x", "y", or "z".
---@param cell_value integer  candidate origin cell along `axis`.
---@return table|string|nil blocker  first blocker found, or nil.
function PhysicsObject:footprint_blocked_at_origin(axis, cell_value)
    local fx, fy, fz = math.floor(self.x), math.floor(self.y), math.floor(self.z)
    if axis == "x" then
        fx = cell_value
    elseif axis == "y" then
        fy = cell_value
    else
        fz = cell_value
    end
    for _, c in ipairs(self:footprint_at(fx, fy, fz)) do
        local blk = self:cell_blocker(c.cx, c.cy, c.cz)
        if blk ~= nil then
            return blk
        end
    end
    return nil
end

--- Soft-snap a horizontal axis to the cell boundary in the direction of
--- last motion, when its velocity has decayed below `SOFT_SNAP_V`. This
--- completes the integrator's friction tail discretely: instead of
--- asymptoting toward rest over ~1s of imperceptible sub-cell drift, the
--- entity re-grids cleanly to the cell it was entering (forward in the
--- direction it was moving). So a TAP lands on a cell boundary (reads as
--- a clean step) and a RUN coasts to a graceful slide-to-stop that
--- finally snaps — no per-input logic, no origin capture, no key-release
--- event. Because it lives in `update`, every entity running the
--- integrator (NPCs, projectiles, knockback) benefits.
---
--- "Direction of last motion" = sign of the axis's current velocity; a
--- zero-velocity mid-cell entity (e.g. just spawned, or post-teleport from
--- stairs) snaps FORWARD (ceil) to complete the step it would have taken.
--- A blocked landing cell RESTS at the near boundary AND emits a collision
--- there (via `hit_blocker`) — so a knocked body re-gridding INTO a special
--- tile like Stairs triggers the shunt, instead of being silently arrested
--- on the doorstep (the bug that made heavy dummies stop 1 cell short).
--- NOT applied to z — gravity lands z cleanly via the swept march, and
--- soft-snapping vertical would fight jumps/stairs.
---@param axis string  "x" or "y".
function PhysicsObject:soft_snap_axis(axis)
    local v = self["v" .. axis]
    if math.abs(v) >= SOFT_SNAP_V then
        return -- still moving with intent; let friction continue
    end
    local p = self[axis]
    if math.floor(p) == p then
        -- already exactly on a cell boundary: nothing to snap, but zero v
        -- so the asymptotic tail doesn't keep micro-drifting.
        self["v" .. axis] = 0
        return
    end
    local target = (v >= 0) and math.ceil(p) or math.floor(p)
    -- Test the FULL footprint at the candidate origin `target` (not just
    -- one cell): a multi-tile body re-gridding must not overlap a wall.
    local blk = self:footprint_blocked_at_origin(axis, target)
    if blk == nil then
        self[axis] = target
    else
        -- Target cell is blocked: rest at its NEAR boundary (so floor(pos)
        -- stays in the free cell behind) and emit a collision there. This is
        -- the fix for shoved-bodies-stuck-on-the-doorstep: a knock that
        -- leaves v just under SOFT_SNAP_V wants to re-grid into the blocked
        -- cell — we must trigger the collision (stairs shunt, knockback to a
        -- crate, etc.), NOT silently arrest. Same momentum semantics as the
        -- swept march (J = m_mover * v, captured pre-zero).
        local dir = (v >= 0) and 1 or -1
        self[axis] = (dir > 0) and (target - EPS) or (target + 1)
        self:hit_blocker(axis, blk, v)
    end
    -- Terminal: zero v so the integrator doesn't re-ignite the tail next
    -- frame. (Acceleration is cleared in update's step 3.)
    self["v" .. axis] = 0
    world.occ_rehash(self)
end

--- Look up the friction coefficient of the tile SUPPORTING this entity:
--- the cell directly below its current cell
--- `(floor(x), floor(y), floor(z) - 1)` — gravity lands the entity
--- resting on the Solid tile one z below, so that tile is the surface
--- it's standing on / sliding across. Returns the tile def's `.friction`
--- if it has one, else the per-instance `self.friction` fallback
--- (airborne over OOB, off-map, or a tile type with no Surface state).
---
--- Called every frame from `update`'s friction step, so it stays cheap:
--- one in_bounds check + one map array index + one table lookup.
---@return number  per-second velocity retention.
function PhysicsObject:surface_friction()
    local map = world.map
    local bx, by, bz = math.floor(self.x), math.floor(self.y), math.floor(self.z) - 1
    if not map:in_bounds(bx, by, bz) then
        return self.friction
    end
    local def = tile.defs[map.types:index(bx, by, bz)]
    if def and def.friction then
        return def.friction
    end
    return self.friction
end

--- Apply an IMPULSE (momentum J, in mass·cells/sec units) to this body.
--- The velocity change is `Δv = J / mass` — the physically correct
--- impulse/momentum relation. A heavy body (mass 10) gets a small Δv
--- from the same impulse that launches a light crate (mass 0.1). This is
--- the correct primitive for knockback, explosions, jumps, and any
--- one-shot velocity change; unlike `accelerate` (per-frame acceleration,
--- cleared each `update`), an impulse's effect is frame-rate-independent.
---
--- Mass-aware impulse lives HERE (on PhysicsObject), not on Position:
--- mass is a dynamics property (Position is pure kinematics). The knockback
--- event carries the mover's MOMENTUM as the impulse; the target's own
--- `apply_impulse` converts it to Δv via its own mass — so callers stay
--- agnostic of the target's mass.
---@param jx number  impulse (momentum) on x.
---@param jy number  impulse (momentum) on y.
---@param jz number? impulse (momentum) on z.
function PhysicsObject:apply_impulse(jx, jy, jz)
    local m = self.mass or 1.0
    self.vx = self.vx + jx / m
    self.vy = self.vy + jy / m
    self.vz = self.vz + (jz or 0) / m
end

--- Resolve the just-stepped `axis` against the tile grid + occupancy.
--- Emit collision + knockback for a block found while moving this axis.
--- Shared by the swept march and the soft-snap: both discover a blocker
--- in a cell the entity is entering and must react identically (emit the
--- `collision`/class-named events, and if the blocker is a PhysicsObject,
--- deliver the mover's momentum as a knockback impulse). Factored so the two
--- paths can't drift apart (the old bug: soft-snap found a blocked snap
--- target and SILENTLY dropped it, so a shoved body resting adjacent to a
--- stairs never triggered the shunt).
---
--- `mv` is the mover's PRE-collision velocity on `axis` (captured before
--- the caller zeroes it) — that's the momentum transferred (J = m_mover*v).
--- Position must already be at the resting point when this is called.
---@param axis string  "x", "y", or "z".
---@param blk table|string  the blocker (tile def, entity, or "oob").
---@param mv number  mover's pre-collision velocity on `axis`.
function PhysicsObject:hit_blocker(axis, blk, mv)
    if blk == "oob" then
        return -- off-map: no named blocker to emit (matches Collidable:move)
    end
    L:debug(
        "[%s] %s-axis blocked by %s at (%.0f,%.0f,%d)",
        self.__name or "?",
        axis,
        blk.__name or "?",
        self.x or 0,
        self.y or 0,
        self.z or 0
    )
    self:emit_collision_with(blk)
    if blk.is_physics_object then
        local mm = self.mass or 1.0
        local jx = (axis == "x") and (mm * mv) or 0
        local jy = (axis == "y") and (mm * mv) or 0
        local jz = (axis == "z") and (mm * mv) or 0
        bus.emit("knockback", { target = blk, source = self, ix = jx, iy = jy, iz = jz })
    end
end

--- Move the entity along ONE axis for `dt`, integrating velocity (semi-
--- implicit Euler) and resolving collisions via a SWEPT, cell-by-cell
--- march from the pre-step position to the target position. Replaces the
--- old step-then-resolve-the-destination-cell scheme, which TUNNELED: a
--- mover faster than 1 cell/frame could jump over a 1-cell-thick wall
--- (its destination cell landed beyond the wall, never testing the
--- wall's cell). The swept march tests EVERY cell entered along the path
--- and stops at the first block, so no velocity can skip a thin wall.
---
--- Algorithm: update v (semi-implicit), then iterate the SEQUENCE of
--- integer cells entered from floor(old) toward floor(target), testing
--- each via `cell_blocker` (other axes' cells held fixed at their current
--- values). The first blocked cell rests the entity at that cell's NEAR
--- boundary (the boundary shared with the free cell it came from) and
--- zeroes this axis's velocity — so floor(pos) stays in the free cell.
--- On a clear path, advance straight to `target`. Iterating INTEGER cells
--- (not float boundaries) sidesteps the exact-on-boundary ambiguity that
--- would otherwise infinite-loop or skip cells: we always test cell
--- `start+dir`, `start+2*dir`, ... up to `floor(target)`, inclusive.
---
--- Rest convention (matches the old resolver):
---   dir > 0: rest at `cell - EPS` (just below the blocked cell's lower
---     boundary; floor -> the free cell behind, smooth wall rest).
---   dir < 0: rest at `cell + 1` (the blocked cell's upper boundary, the
---     free cell above; for the z axis with downward v this IS the landing,
---     resting on an integer z just above the floor tile).
---
--- Emits `collision` (+ class-named) for tile/entity blocks, and a
--- targeted `knockback` carrying the mover's MOMENTUM (J = m_mover * v)
--- when the blocker is itself a PhysicsObject — the target's own mass
--- converts J to Δv. Pure momentum transfer; shoving a body heavy vs
--- light differs by mass, identically for every archetype (law 2).
---
--- `old` is captured internally and other-axis coords are snapshotted
--- before marching, since x-before-y-before-z means later axes use the
--- already-resolved earlier axes (e.g. the z landing uses final x,y).
---@param axis string  "x", "y", or "z".
---@param dt number  Seconds elapsed since the last update.
function PhysicsObject:swept_move_axis(axis, dt)
    local vname = "v" .. axis
    local aname = "a" .. axis
    -- 1. Semi-implicit Euler: update velocity first, then march with it.
    self[vname] = self[vname] + self[aname] * dt
    local v = self[vname]
    if v == 0 then
        return -- no motion this axis; nothing to sweep or resolve
    end
    local old = self[axis]
    local target = old + v * dt
    local dir = v > 0 and 1 or -1
    -- Other-axis cell coords are implicit (footprint_blocked_at_origin
    -- reads self.x/y/z's current floored value), fixed during this axis's
    -- sweep since only `axis` moves here. x-before-y-before-z means later
    -- axes use the already-resolved earlier axes.
    -- Iterate the integer cells ENTERED: start+dir, start+2*dir, ... up to
    -- floor(target) (the cell `target` lands in — entering it is real: to
    -- reach pos=12.0 from below you cross the boundary at 12.0 into cell 12).
    -- At each candidate ORIGIN cell, test the FULL w×h footprint (not just
    -- one cell) so a multi-tile body can't tunnel its far edge through a
    -- thin wall. The newly-entered cell is always the footprint's far edge,
    -- so the rest math (cell-EPS / cell+1) stays correct for any w,h.
    local start_cell = math.floor(old)
    local last_cell = math.floor(target)
    local cell = start_cell + dir
    while (dir > 0 and cell <= last_cell) or (dir < 0 and cell >= last_cell) do
        local blk = self:footprint_blocked_at_origin(axis, cell)
        if blk ~= nil then
            -- Rest at the NEAR boundary of the blocked cell (the shared
            -- edge with the free cell we came from) and stop this axis.
            self[axis] = (dir > 0) and (cell - EPS) or (cell + 1)
            self:hit_blocker(axis, blk, v) -- emit collision + knockback (shared)
            self[vname] = 0
            return -- stopped at first block; don't continue the march
        end
        cell = cell + dir
    end
    -- No block in any entered cell: move freely to the integrated target.
    self[axis] = target
end

--- Per-frame tick. The whole motion pipeline, integrator-only:
---   1. Vertical baseline: `az = -GRAVITY` (gravity-bound entities). This
---      OVERWRITES any transient vertical input each frame — the player
---      only accelerates horizontally, and stairs bump `vz` directly (not
---      `az`), so gravity stays the sole owner of vertical acceleration.
---   2. Per axis (x, then y, then z): SWEPT integrate + resolve via
---      `swept_move_axis` — semi-implicit Euler update, then a cell-by-cell
---      march from the old position to the integrated target, testing every
---      cell entered and stopping at the first block. Swept (not
---      destination-only) so no velocity can tunnel through a thin wall.
---      x-before-y-before-z means the z landing uses the final horizontal
---      position. Per-axis resolution gives sliding: a diagonal into a
---      corner zeroes only the blocked axis, leaving the other to carry
---      you along the wall.
---   3. Consume the horizontal input impulses for this frame (`ax`/`ay`
---      cleared — they were accumulated by `accelerate` calls since the
---      last frame and must not persist, or a single tap would accelerate
---      forever). `az` is NOT cleared: it's the gravity baseline, reset at
---      the top next frame.
---   4. Friction: `vx,vy *= surface_friction^dt` — frame-rate-independent
---      damping toward rest so you coast to a stop after the impulse. The
---      coefficient is read from the tile supporting the entity this frame
---      (a slidey ramp vs a grippy floor), falling back to the instance
---      default. Vertical is gravity/landing-managed, not friction-damped.
---   5. Soft-snap: any horizontal axis below SOFT_SNAP_V snaps to the cell
---      boundary in its direction of last motion — completes the friction
---      tail discretely (tap lands on a cell; run re-grids at rest).
---   6. Re-sync the occupancy hash (x/y/z may have crossed cells).
---
--- Overrides Position.update (first-wins: this method is on the composed
--- mixin, copied into the class table).
---@param dt number  Seconds elapsed since the last update.
function PhysicsObject:update(dt)
    -- 1. Gravity baseline (vertical). az is reset fresh each frame; any
    --    vertical `accelerate` call is intentionally discarded here.
    self.az = self.obeys_gravity and -GRAVITY or 0
    -- 2. Per-axis swept integrate + resolve. swept_move_axis does the
    --    semi-implicit Euler step AND the cell-by-cell collision march in
    --    one call (testing every cell entered, so fast movers can't tunnel
    --    through thin walls). x-before-y-before-z; later axes use the
    --    already-resolved earlier axes (e.g. the z landing uses final x,y).
    self:swept_move_axis("x", dt)
    self:swept_move_axis("y", dt)
    self:swept_move_axis("z", dt)
    -- 3. Consume horizontal input impulses (they're per-frame; don't leak).
    -- Capture whether an impulse was applied to each horizontal axis THIS
    -- frame: soft-snap (step 5) must NOT fire on an axis that received
    -- input this frame, or it zeroes the velocity the impulse just built
    -- -- snapping a cell every frame during the 0->cruise ramp (a 3-frame
    -- tap would jump 3 cells; a hold would never build coasting velocity).
    -- The snap exists to complete the friction tail AT NEAR-REST, after
    -- input has ceased -- not to interrupt active acceleration.
    local input_x = self.ax ~= 0
    local input_y = self.ay ~= 0
    self.ax = 0
    self.ay = 0
    -- 4. Friction dampens horizontal velocity. The coefficient comes from
    --    the tile SUPPORTING the entity this frame (its `.friction`), so a
    --    grippy floor vs a slidey ramp vs ice each feel different; falls
    --    back to the per-instance `self.friction` when there's no surface
    --    (airborne over OOB, off-map). Raised to the dt exponent for
    --    frame-rate independence. Vertical is gravity/landing-managed.
    if dt > 0 then
        local f = self:surface_friction() ^ dt
        self.vx = self.vx * f
        self.vy = self.vy * f
    end
    -- 5. Soft-snap any horizontal axis that has decayed below SOFT_SNAP_V
    --    to the cell boundary in its direction of last motion — but ONLY an
    --    axis that received NO impulse this frame (see step 3). Completes
    --    the friction tail discretely at near-rest (tap lands on a cell; run
    --    re-grids after coasting) without zeroing mid-ramp velocity.
    if not input_x then
        self:soft_snap_axis("x")
    end
    if not input_y then
        self:soft_snap_axis("y")
    end
    -- 6. Re-sync the spatial hash for the new cell.
    world.occ_rehash(self)
end

return PhysicsObject
