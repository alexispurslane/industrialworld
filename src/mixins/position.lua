--- Position mixin (3D).
---
--- Spatial state: position, velocity, acceleration — all three-axis
--- (x, y, z), PLUS an integer tile FOOTPRINT `w`×`h` (cells). The origin
--- `(x, y)` is the footprint's TOP-LEFT corner: the entity occupies cells
--- `[floor(x) .. floor(x)+w-1] × [floor(y) .. floor(y)+h-1]` at layer
--- `floor(z)`. Defaults to `1×1` (a single cell) so every existing
--- archetype keeps working unchanged. Multi-tile entities set `w`/`h` > 1
--- at construction (threaded through the init chain); all spatial systems
--- (collision, occupancy hash, FOV cull, rendering) iterate the footprint
--- instead of assuming one entity = one cell. z stays single-layer
--- (multi-z bodies are a separate concern).
---
--- Two ways to move, and the consumer picks whichever fits:
---   * instant: `self:move(dx, dy, dz)` offsets position directly,
---     bypassing the physics integrator. Use for discrete steps of
---     NON-player entities (the player no longer uses this — its movement
---     is impulse-driven via the integrator; see PhysicsObject). `dz`
---     defaults to 0 so 2D callers keep working.
---   * integrated: set velocity / acceleration (`set_velocity`,
---     `set_acceleration`, `accelerate`) and let `update(dt)` integrate
---     motion each frame (semi-implicit Euler: v += a*dt; p += v*dt, per
---     axis — factored as `step_axis` so a composed mixin can resolve
---     collisions axis-by-axis). Use for the player, projectiles,
---     particles, knockback, drift.
---
--- Leaf mixin (law 1): owns its own state only; knows nothing of other
--- mixins. `update` overrides Entity's no-op (first-wins copy on the
--- class table). Position is the single owner of `self.z` (previously
--- PhysicsObject set it); every reader (camera, collision, render) goes
--- through `self.z` directly, no more `self.z or 0` sprinkled across
--- call sites.

local Position = {}

--- Initialize position; velocity/acceleration default to zero. Takes a
--- NAMED-FIELD table so the spatial params (3 numbers x/y/z, 3 numbers
--- vx/vy/vz, 2 ints w/h — eight same-typed-ish args) are disambiguated
--- at the call site instead of by position. All fields optional.
---@param opts? table  {x=,y=,z=,vx=,vy=,vz=,w=,h=} (all default: zero / 1).
function Position:init(opts)
    opts = opts or {}
    self.x = opts.x or 0
    self.y = opts.y or 0
    self.z = opts.z or 0
    self.vx = opts.vx or 0
    self.vy = opts.vy or 0
    self.vz = opts.vz or 0
    self.ax = 0
    self.ay = 0
    self.az = 0
    -- Integer tile footprint (cells). Defaults to 1×1 — the universal
    -- single-cell case. Origin (x,y) is the footprint's top-left, so the
    -- occupied set is [floor(x)..floor(x)+w-1] × [floor(y)..floor(y)+h-1].
    self.w = opts.w or 1
    self.h = opts.h or 1
end

--- Offset position by a fixed amount, instantly. Does not touch
--- velocity or acceleration. `dz` defaults to 0 so 2D callers
--- (move(dx,dy)) keep working.
---@param dx number
---@param dy number
---@param dz? number  default 0.
function Position:move(dx, dy, dz)
    self.x = self.x + dx
    self.y = self.y + dy
    self.z = self.z + (dz or 0)
end

--- Set velocity directly (cells/sec).
---@param vx number
---@param vy number
---@param vz number
function Position:set_velocity(vx, vy, vz)
    self.vx = vx
    self.vy = vy
    self.vz = vz or 0
end

--- Set acceleration directly (cells/sec^2).
---@param ax number
---@param ay number
---@param az number
function Position:set_acceleration(ax, ay, az)
    self.ax = ax
    self.ay = ay
    self.az = az or 0
end

--- Add to current acceleration (impulse-accumulation style: apply several
--- forces over a frame, then integrate once).
---@param ax number
---@param ay number
---@param az number
function Position:accelerate(ax, ay, az)
    self.ax = self.ax + ax
    self.ay = self.ay + ay
    self.az = self.az + (az or 0)
end

--- Return the cell coordinates `{cx=,cy=,cz=}` of this entity's tile
--- footprint at integer origin `(fx, fy, fz)`: the `w`×`h` box
--- `[fx..fx+w-1] × [fy..fy+h-1]` at layer `fz`. Defaults to 1×1.
--- Centralizes "which cells does this body occupy" so every spatial
--- system (collision, occupancy hash, FOV cull) iterates one source of
--- truth instead of re-deriving the footprint. Pure spatial state (law 1)
--- — no collision/render deps — so it lives here on Position, available
--- to every composed mixin (Collidable, PhysicsObject, Drawable).
---@param fx integer  origin cell x (top-left).
---@param fy integer  origin cell y (top-left).
---@param fz integer  layer.
---@return table[] cells  list of {cx=,cy=,cz=}.
function Position:footprint_at(fx, fy, fz)
    local w = self.w or 1
    local h = self.h or 1
    local cells = {}
    for cx = fx, fx + w - 1 do
        for cy = fy, fy + h - 1 do
            cells[#cells + 1] = { cx = cx, cy = cy, cz = fz }
        end
    end
    return cells
end

--- Integrate ONE axis by `dt` seconds (semi-implicit Euler: velocity
--- first, then position). Factored out of `update` so a composed mixin
--- (PhysicsObject) can step + collision-resolve axis-by-axis for sliding /
--- per-axis blocking, instead of moving all three at once and having to
--- guess which axis caused a diagonal collision. Position stays the single
--- owner of the Euler formula.
---@param axis string  "x", "y", or "z".
---@param dt number  Seconds elapsed since the last update.
function Position:step_axis(axis, dt)
    local v = "v" .. axis
    local a = "a" .. axis
    self[v] = self[v] + self[a] * dt
    self[axis] = self[axis] + self[v] * dt
end

--- Integrate motion by `dt` seconds (semi-implicit Euler: velocity first,
--- then position, per axis). Override Entity's no-op update. Equivalent to
--- three `step_axis` calls in sequence (x, y, z) with no collision
--- resolution — use this for entities that don't collide (or override
--- `update` in a composed mixin that resolves per-axis).
---@param dt number  Seconds elapsed since the last update.
function Position:update(dt)
    self:step_axis("x", dt)
    self:step_axis("y", dt)
    self:step_axis("z", dt)
end

return Position
