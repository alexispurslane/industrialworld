--- Position mixin.
---
--- Spatial state: position, velocity, acceleration. Two ways to move,
--- and the consumer picks whichever fits:
---   * instant: `self:move(dx, dy)` offsets position directly, bypassing
---     the physics integrator. Use for tile-based / discrete movement.
---   * integrated: set velocity / acceleration (`set_velocity`,
---     `set_acceleration`, `accelerate`) and let `update(dt)` integrate
---     motion each frame (semi-implicit Euler: v += a*dt; p += v*dt).
---     Use for projectiles, particles, knockback, drift.
---
--- Leaf mixin (law 1): owns its own state only; knows nothing of other
--- mixins. `update` overrides Entity's no-op (first-wins copy on the
--- class table).

local Position = {}

--- Initialize position; velocity/acceleration default to zero.
---@param x? number
---@param y? number
---@param vx? number
---@param vy? number
function Position:init(x, y, vx, vy)
    self.x = x or 0
    self.y = y or 0
    self.vx = vx or 0
    self.vy = vy or 0
    self.ax = 0
    self.ay = 0
end

--- Offset position by a fixed amount, instantly. Does not touch
--- velocity or acceleration.
---@param dx number
---@param dy number
function Position:move(dx, dy)
    self.x = self.x + dx
    self.y = self.y + dy
end

--- Set velocity directly (cells/sec).
---@param vx number
---@param vy number
function Position:set_velocity(vx, vy)
    self.vx = vx
    self.vy = vy
end

--- Set acceleration directly (cells/sec^2).
---@param ax number
---@param ay number
function Position:set_acceleration(ax, ay)
    self.ax = ax
    self.ay = ay
end

--- Add to current acceleration (impulse-accumulation style: apply several
--- forces over a frame, then integrate once).
---@param ax number
---@param ay number
function Position:accelerate(ax, ay)
    self.ax = self.ax + ax
    self.ay = self.ay + ay
end

--- Integrate motion by `dt` seconds (semi-implicit Euler: velocity first,
--- then position). Override Entity's no-op update.
---@param dt number  Seconds elapsed since the last update.
function Position:update(dt)
    self.vx = self.vx + self.ax * dt
    self.vy = self.vy + self.ay * dt
    self.x = self.x + self.vx * dt
    self.y = self.y + self.vy * dt
end

return Position
