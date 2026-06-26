--- A tiny OOP DSL: classes + mixins.
---
--- Exposes `class` and `mixin` (wired as globals by `main.lua`) so game
--- code can define entities without touching metatables directly.
---
--- GUARDRAILS (see AGENTS.md "OOP convention" for the full laws):
---   * Mixins define capabilities — a mixin bundles the *state* and the
---     *methods* for one narrow capability ("can be hurt" → hp + damage).
---   * Mixins compose: `mixin({}, A, B)` builds a new mixin that includes
---     both. Orchestration of emergent behavior between capabilities lives
---     in such composed mixins (override a method, delegate to the leaves
---     by name: `Flammable.light(self)`). This keeps coupling out of leaf
---     mixins and out of subclasses.
---   * Subclasses are thin *archetypes*: a named, instantiable preset of
---     base + mixins. Single inheritance; the parent is the base class (or
---     another archetype). `super` (returned by `class`) is for delegating
---     to the parent only — NOT for mixin orchestration.
---   * There is exactly one base Entity class; everything else subscribes
---     to it plus mixins.
---   * Mixin state is NOT namespaced on instances — `self.hp`, not
---     `self.Health.hp`. Only the owning mixin and the archetype should
---     touch a piece of state.
---
--- Usage:
---
---     -- a leaf mixin: plain table with state + methods
---     local Flammable = {}
---     function Flammable:init() self.on_fire = false end
---     function Flammable:light() self.on_fire = true end
---
---     -- a composed mixin that orchestrates two capabilities
---     local Burning = mixin({}, Flammable, Soakable)
---     function Burning:light()
---         if self.wet then return end          -- Soakable's state, read intentionally
---         Flammable.light(self)                -- delegate to the leaf
---     end
---     function Burning:init()
---         Flammable.init(self)
---         Soakable.init(self)
---     end
---
---     -- a subclass: thin archetype. super = Entity (the parent).
---     local Torch, super = class("Torch", Entity):mixin(Burning)
---     function Torch:init(x, y)
---         super.init(self, x, y)   -- delegate to parent (base class)
---         Burning.init(self)        -- wake the composed mixin explicitly
---     end
---
---     local t = Torch(10, 20)    -- or Torch:new(10, 20)

--- Copy methods from mixins into a target table.
--- Recurses across all mixin arguments so `mixin(t, A, B, C)` works.
--- First-wins: a key already on the target is kept; later mixins only
--- fill gaps. Never copies a mixin's `init`/`included` hooks (those are
--- called explicitly). Fires `mixin:included(target)` once per mixin.
---
--- Works on EITHER a class table (via the `:mixin(...)` method) or a
--- plain table (to compose a new mixin from other mixins):
---   local Burning = mixin({}, Flammable, Soakable)
---@param target table  The table being built (a class or a fresh {}).
---@param m? table       The next mixin to apply (nil = terminal).
---@return table target  The target table (for fluent chaining / assignment).
local function mixin(target, m, ...)
    if m == nil then
        return target
    end
    if type(m) == "table" then
        for k, v in pairs(m) do
            -- Never copy a mixin's own lifecycle hooks; they are called
            -- explicitly from an init chain.
            --
            -- rawget (not target[k]): first-wins considers only the target's
            -- OWN fields. A parent's inherited methods (e.g. Entity's no-op
            -- `update` stub, reached via __index) must NOT shadow a mixin's
            -- real method — capabilities come from mixins (law 1), so a mixin
            -- supplying `update` overrides the base stub.
            if k ~= "init" and k ~= "included" and rawget(target, k) == nil then
                target[k] = v
            end
        end
        if type(m.included) == "function" then
            m:included(target)
        end
    end
    return mixin(target, ...)
end

--- Construct an instance of `cls` and run its init chain.
---@param cls table  The class table (has `__index = cls`).
---@return table instance The new instance.
local function new(cls, ...)
    local self = setmetatable({}, cls)
    if cls.init then
        cls.init(self, ...)
    end
    return self
end

--- Define a class. Single inheritance.
--- Forms:
---   class "Name"               -- base class (no parent)
---   class(parent)              -- anonymous subclass
---   class("Name", parent)      -- named subclass (parent returned as `super`)
---@param name? string|table Class name, or a parent class for `class(parent)`.
---@param parent? table Optional parent class.
---@overload fun(name: string): table, nil
---@overload fun(parent: table): table, table
---@overload fun(name: string, parent: table): table, table
---@return table cls The new class table.
---@return table|nil parent The parent class (for `super = ...`).
local function classify(name, parent)
    if type(name) == "table" then
        -- `class(parent)` shorthand: first arg is the parent, not a name.
        name, parent = nil, name
    end
    -- The class table gets a dedicated metatable so it (a) inherits the
    -- parent's class-level methods via `__index` and (b) is callable via
    -- `__call` (so `Enemy(x, y)` works as sugar for `Enemy:new(x, y)`).
    -- Each class owns its own metatable, so subclasses get their own
    -- `__call` bound to the right class — no parent-chain surprises.
    local cls = setmetatable({}, {
        __index = parent,
        __call = function(c, ...)
            -- Dispatch through `cls.new` (NOT the `new` upvalue) so a
            -- subclass inherits its parent's `new` override — e.g. game
            -- entities override Entity.new to route through `allocate`,
            -- and Goblin() must hit that override, not the base ctor.
            return c.new(c, ...)
        end,
    })
    cls.__index = cls -- instances dispatch through cls, then fall through to parent.
    cls.__name = name or "anonymous"
    cls.__parent = parent
    -- `Class:mixin(M1, M2)` applies the free `mixin` then returns `(cls, parent)`
    -- so the fluent multireturn `local Foo, super = class(...)​:mixin(...)` works.
    cls.mixin = function(self, ...)
        mixin(self, ...)
        return self, self.__parent
    end
    -- Only install the generic `new` on a root class (no parent). A
    -- subclass must inherit its parent's `new` via `__index` fall-through,
    -- so an override like `Entity.new -> allocate` is honored by subclasses
    -- instead of being shadowed by the generic ctor assigned at class time.
    if parent == nil then
        cls.new = new
    end
    return cls, parent
end
-- `class` and the free `mixin` function are both available. main.lua wires
-- both as globals; `mixin({}, ...)` composes mixins, `Class:mixin(...)` applies
-- them to a class (same function, two call sites).
--
-- `class` is a callable table (not a plain function) so it can carry the
-- `.mixin` field alongside `__call`.
return setmetatable({
    mixin = mixin,
}, {
    __call = function(_, ...)
        return classify(...)
    end,
})
