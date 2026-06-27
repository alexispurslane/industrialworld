--- Progress-bar widget archetype.

local Widget = require("widget")
local ScreenRect = require("mixins.ui.screen_rect")
local ProgressFill = require("mixins.ui.progress_fill")
local bus = require("event")

local ProgressBar, super = class("ProgressBar", Widget):mixin(ScreenRect, ProgressFill)

function ProgressBar:init(con, id, x, y, width, bg, fill_bg)
    self.con = con
    super.init(self)
    ScreenRect.init(self, x, y, width, 1)
    ProgressFill.init(self, width, bg, fill_bg)
    self.id = id
    local progress_event = ("progress:%s"):format(tostring(id))
    local destroy_event = ("progress:%s:destroy"):format(tostring(id))
    bus.subscribe(self, progress_event, function(p)
        self:set_percent(p)
    end)
    bus.subscribe(self, destroy_event, function()
        self:destroy()
    end)
end

function ProgressBar:set(p)
    self:set_percent(p)
end

function ProgressBar:draw()
    ProgressFill.draw(self)
end

return ProgressBar
