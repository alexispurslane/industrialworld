--- SoundEmitter mixin (leaf).
---
--- Gives a game entity the ability to emit a sound at its current
--- position. Requires the host archetype to have Position state
--- (self.x / self.y / self.z).
---
--- The mixin stores a sound asset id and base volume. Calling
--- `self:emit_sound()` plays the sound through the spatial audio engine
--- (wall-muffled + left/right panned relative to the player) AND
--- broadcasts a `"sound"` event on the bus so NPCs can "hear" it. The
--- event payload is `{ id = sound_id, x = ..., y = ..., z = ... }`.
---
--- For periodically noisy objects (fires, machinery), pass
--- `opts.emit_interval = { min = 1, max = 3 }` (or a single number) and
--- call `SoundEmitter.step(self, dt)` from the archetype's `update`.

local bus = require("event")
local sound = require("sound")

local SoundEmitter = {}

---@param self table  Host entity; must already have x/y/z from Position.
---@param opts table  { sound_id = string, volume = number?, emit_interval = number|{min,max}? }
function SoundEmitter.init(self, opts)
    opts = opts or {}
    local id = opts.sound_id
    assert(type(id) == "string", "SoundEmitter.init: opts.sound_id required")
    assert(
        type(self.x) == "number" and type(self.y) == "number" and type(self.z) == "number",
        "SoundEmitter.init: host must have Position (x/y/z)"
    )

    self.sound_id = id
    self.sound_volume = opts.volume or 1.0

    local interval = opts.emit_interval
    if interval ~= nil then
        if type(interval) == "number" then
            self.sound_emit_min = interval
            self.sound_emit_max = interval
        else
            self.sound_emit_min = interval.min or 1
            self.sound_emit_max = interval.max or self.sound_emit_min
        end
        self.sound_emit_timer = math.random() * (self.sound_emit_max - self.sound_emit_min)
            + self.sound_emit_min
    else
        self.sound_emit_min = nil
        self.sound_emit_max = nil
        self.sound_emit_timer = nil
    end
end

local function next_interval(self)
    local min = self.sound_emit_min or 0
    local max = self.sound_emit_max or min
    return math.random() * (max - min) + min
end

--- Advance the periodic-emission timer. Archetypes call this from their
--- own `update(dt)` when they want automatic repeated sounds.
---@param dt number
function SoundEmitter.step(self, dt)
    if self.sound_emit_timer == nil then
        return
    end
    self.sound_emit_timer = self.sound_emit_timer - dt
    if self.sound_emit_timer <= 0 then
        self:emit_sound()
        self.sound_emit_timer = next_interval(self)
    end
end

--- Play the sound at the entity's position and notify listeners.
function SoundEmitter.emit_sound(self)
    sound.play(self.sound_id, self.x, self.y, self.z, self.sound_volume)
    bus.emit("sound", { id = self.sound_id, x = self.x, y = self.y, z = self.z })
end

return SoundEmitter
