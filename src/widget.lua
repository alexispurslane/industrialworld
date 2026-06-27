--- UI widget base class.
---
--- Widgets are *engine objects*, not game entities. Their lifecycle mirror
--- Entity's: Widget.new routes through world.allocate_widget, and
--- Widget:destroy routes through world.destroy_widget. The actual pool,
--- tombstone, and event dispatch live in world.lua / main.lua, just like
--- the entity pool and the game loop.

local class = require("classes")
local world = require("world")

local Widget = class("Widget")

function Widget:init() end
function Widget:update(dt) end
function Widget:draw() end

function Widget:destroy()
    world.destroy_widget(self)
end

--- Route construction through the world widget pool, the same way
--- Entity.new routes through the entity pool.
function Widget.new(cls, ...)
    return world.allocate_widget(cls, ...)
end

return Widget
