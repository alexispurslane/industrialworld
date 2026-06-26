--- The one base class. Everything else is an archetype (thin subclass)
--- over this plus mixins. See AGENTS.md "OOP convention" for the laws.
---
--- Entity carries ONLY the update-loop protocol: a single `:update(dt)`
--- entry point the game loop calls every frame. It owns no state and no
--- capabilities — position, rendering, health, input, etc. are all
--- mixins, per law 1.
---
--- The no-op `init` exists so archetypes can unconditionally delegate
--- `super.init(self)` (see Mechanics in AGENTS.md) without nil-guarding;
--- it sets no fields.
---
--- POOLING: game entities are pooled (see world.lua). `Entity.new` is
--- overridden to route through `world.allocate`, so the natural
--- `Goblin(x, y)` syntax borrows from the pool (0 alloc steady-state),
--- sets the alive bit, and runs `init` on the recycled table. `world` is
--- required at the top of this module; the singleton is in place before
--- any entity subclass is defined.

local class = require("classes")
local world = require("world")

local Entity = class("Entity")

function Entity:init() end

--- Advance this entity by `dt` seconds. No-op by default; archetypes and
--- mixins override to do real work.
---@param dt number  Seconds elapsed since the last update.
function Entity:update(dt) end

--- Override the DSL's generic `new`: game entities go through the pool
--- (`world.allocate`) instead of allocating a fresh table. `allocate`
--- wipes, binds the metatable, runs init, and marks the slot alive; we
--- just give it the class. Subclasses inherit this override via `__index`,
--- so `Goblin(...)` and `Goblin:new(...)` both pool. Engine-object classes
--- (Map, Field — no `Entity` parent) keep the plain `new` and allocate
--- fresh.
---@param cls table
---@return table instance
function Entity.new(cls, ...)
    return world.allocate(cls, ...)
end

--- Mark this entity's slot dead so it can be recycled by a later
--- `allocate`. Passthrough to `world.destroy` (which runs the mixin
--- teardown chain first, then sets the alive bit to 0). Subclasses
--- inherit this via `__index`, so `goblin:destroy()` works symmetrically
--- with `Goblin(...)`.
function Entity:destroy()
    world.destroy(self)
end

return Entity
