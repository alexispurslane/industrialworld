--- Position mixin (3D).
---
--- Spatial state: position, velocity, acceleration — all three-axis
--- (x, y, z). Two ways to move, and the consumer picks whichever fits:
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

--- Initialize position; velocity/acceleration default to zero.
---@param x? number
---@param y? number
---@param z? number
---@param vx? number
---@param vy? number
---@param vz? number
function Position:init(x, y, z, vx, vy, vz)
    self.x = x or 0
    self.y = y or 0
    self.z = z or 0
    self.vx = vx or 0
    self.vy = vy or 0
    self.vz = vz or 0
    self.ax = 0
    self.ay = 0
    self.az = 0
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
