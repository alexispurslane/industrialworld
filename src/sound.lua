--- Spatial audio engine.
---
--- A singleton module wrapping the miniaudio-based C engine in src/audio.c.
--- It caches buffers (loaded from WAV or generated in-memory), plays them
--- at a position relative to the player, and applies:
---   * per-wall muffling via a straight 3D raycast from the emitter to
---     the player,
---   * left/right panning based on the emitter's X offset from the player.
---
--- The underlying C code uses miniaudio, which is cross-platform: CoreAudio
--- on macOS, WASAPI on Windows, ALSA/Pulse/JACK on Linux. No macOS-specific
--- backend is hardcoded on the Lua side.
---
--- Reach via `local sound = require("sound")`.

local ffi = require("ffi")
local bit = require("bit")
local math = require("math")
local world = require("world")
local raycast3d = require("pathfinding.raycast3d")
local tile = require("tile")
local log = require("log")
local L = log.get("sound")

local sound = {
    enabled = false,
}

local MUFFLE_PER_WALL = 0.75
local PAN_SCALE = 0.1 -- cells^-1, clamped to [-1,1]; sign selects ear.

local cdef_done = false
local SAMPLE_RATE = 44100

local buffers = {} -- id -> { file = path } | { cdata = cdata, bytes = int }
local voices = {} -- slot index -> { cdata = cdata? }

--- FFI declarations for the C engine in src/audio.c.
local function ensure_cdef()
    if cdef_done then
        return
    end
    ffi.cdef([[
        int iw_audio_init(void);
        void iw_audio_shutdown(void);
        int iw_audio_play_file(const char *path, float volume, float pan);
        int iw_audio_play_buffer(const void *data, int bytes, int channels,
                                 int sample_rate, float volume, float pan);
        int iw_audio_voice_is_playing(int slot);
        void iw_audio_voice_stop(int slot);
    ]])
    cdef_done = true
end

--- Clamp `v` into [lo, hi].
local function clamp(v, lo, hi)
    if v < lo then
        return lo
    elseif v > hi then
        return hi
    end
    return v
end

--- Count opaque cells on a straight 3D ray from (ax,ay,az) to (bx,by,bz).
--- The start cell is excluded by raycast3d; the end cell is included but
--- is typically the player's open floor cell.
local function count_walls_between(ax, ay, az, bx, by, bz)
    local m = world.map
    if m == nil then
        return 0
    end
    local ray = raycast3d.run({
        dims = { m.w, m.h, m.d },
        a = { ax, ay, az },
        b = { bx, by, bz },
    })
    local Opaque = tile.TileFlags.Opaque
    local flags = m.flags
    local walls = 0
    for _, cell in ipairs(ray) do
        local fv = flags:index(cell[1], cell[2], cell[3])
        if bit.band(fv, Opaque) ~= 0 then
            walls = walls + 1
        end
    end
    return walls
end

--- Initialize the miniaudio engine. Safe to call repeatedly. Logs and
--- disables itself on failure so the game can run without audio hardware.
function sound.init()
    ensure_cdef()
    if sound.enabled then
        return
    end

    local ok, err = pcall(function()
        if ffi.C.iw_audio_init() ~= 0 then
            error("iw_audio_init failed")
        end
    end)

    if not ok then
        L:warn("sound unavailable: %s", err)
        sound.enabled = false
        return
    end

    sound.enabled = true
    L:info("sound initialized")
end

--- Tear down the audio engine and free all cached buffers/voices.
function sound.shutdown()
    if not sound.enabled then
        return
    end
    for slot in pairs(voices) do
        ffi.C.iw_audio_voice_stop(slot)
    end
    voices = {}
    buffers = {}
    ffi.C.iw_audio_shutdown()
    sound.enabled = false
end

--- Load a PCM WAV file. miniaudio decodes it at play time.
---@param id string   Engine sound id used by play() and SoundEmitter.
---@param path string Filesystem path to the .wav.
function sound.load(id, path)
    if not sound.enabled then
        return
    end
    assert(type(id) == "string", "sound.load: id must be a string")
    assert(type(path) == "string", "sound.load: path must be a string")
    buffers[id] = { file = path }
    L:debug("registered file sound '%s' -> %s", id, path)
end

--- Register a generated mono16 sine tone.
---@param id string          Engine sound id.
---@param freq number        Frequency in Hz.
---@param duration number    Length in seconds.
---@param volume? number     0..1 peak amplitude (default 0.5).
function sound.register_tone(id, freq, duration, volume)
    volume = volume or 0.5
    assert(type(id) == "string", "sound.register_tone: id required")
    assert(type(freq) == "number" and freq > 0, "sound.register_tone: freq > 0")
    assert(type(duration) == "number" and duration > 0, "sound.register_tone: duration > 0")

    local n = math.floor(SAMPLE_RATE * duration)
    if n <= 0 then
        return
    end
    local cdata = ffi.new("int16_t[?]", n)
    local amp = volume * 32767
    local fade = math.min(n, math.floor(SAMPLE_RATE * 0.01))
    for i = 0, n - 1 do
        local t = i / SAMPLE_RATE
        local s = math.sin(2 * math.pi * freq * t)
        local env = 1.0
        if i < fade then
            env = i / fade
        elseif i >= n - fade then
            env = (n - 1 - i) / fade
        end
        cdata[i] = math.floor(amp * s * env)
    end

    buffers[id] = { cdata = cdata, bytes = n * 2 }
    L:debug("registered tone '%s' (%d samples)", id, n)
end

--- Register a generated mono16 noise burst.
---@param id string          Engine sound id.
---@param duration number    Length in seconds.
---@param volume? number     0..1 peak amplitude (default 0.5).
function sound.register_noise(id, duration, volume)
    volume = volume or 0.5
    assert(type(id) == "string", "sound.register_noise: id required")
    assert(type(duration) == "number" and duration > 0, "sound.register_noise: duration > 0")

    local n = math.floor(SAMPLE_RATE * duration)
    if n <= 0 then
        return
    end
    local cdata = ffi.new("int16_t[?]", n)
    local amp = volume * 32767
    local fade = math.min(n, math.floor(SAMPLE_RATE * 0.005))
    for i = 0, n - 1 do
        local env = 1.0
        if i < fade then
            env = i / fade
        elseif i >= n - fade then
            env = (n - 1 - i) / fade
        end
        cdata[i] = math.floor(amp * (math.random() * 2 - 1) * env)
    end

    buffers[id] = { cdata = cdata, bytes = n * 2 }
    L:debug("registered noise '%s' (%d samples)", id, n)
end

--- Play a cached sound at world position (x,y,z) with the engine's
--- spatialization: muffled by each opaque wall on the straight ray to
--- the player, and panned left/right by the emitter's X offset.
---@param id string      Cached sound id.
---@param x number       Emitter X.
---@param y number       Emitter Y.
---@param z number       Emitter Z.
---@param volume? number Base volume 0..1 (default 1).
function sound.play(id, x, y, z, volume)
    volume = volume or 1.0
    if not sound.enabled then
        return
    end
    local buf = buffers[id]
    if buf == nil then
        L:warn("sound.play: unknown id '%s'", id)
        return
    end

    local player = world.player
    if player == nil then
        -- No listener yet: play centered and unmuffled.
        player = { x = x, y = y, z = z }
    end

    local ex, ey, ez = math.floor(x), math.floor(y), math.floor(z)
    local px, py, pz = math.floor(player.x), math.floor(player.y), math.floor(player.z)
    local walls = count_walls_between(ex, ey, ez, px, py, pz)
    local final_volume = clamp(volume * (MUFFLE_PER_WALL ^ walls), 0, 1)
    if final_volume <= 0.001 then
        L:trace("'%s' inaudible (%d walls)", id, walls)
        return
    end

    local dx = x - player.x
    local pan = clamp(dx * PAN_SCALE, -1, 1)

    local slot
    if buf.file ~= nil then
        slot = ffi.C.iw_audio_play_file(buf.file, final_volume, pan)
    else
        slot = ffi.C.iw_audio_play_buffer(buf.cdata, buf.bytes, 1, SAMPLE_RATE, final_volume, pan)
    end

    if slot >= 0 then
        -- Keep buffer-backed cdata alive while the voice plays.
        voices[slot] = { cdata = buf.cdata }
        L:debug(
            "play '%s' walls=%d volume=%.3f pan=%.2f slot=%d",
            id,
            walls,
            final_volume,
            pan,
            slot
        )
    else
        L:trace("dropped '%s' (no free voice slots)", id)
    end
end

--- Poll and release finished voices. Call once per frame.
function sound.update(_dt)
    if not sound.enabled then
        return
    end
    for slot in pairs(voices) do
        if ffi.C.iw_audio_voice_is_playing(slot) == 0 then
            ffi.C.iw_audio_voice_stop(slot)
            voices[slot] = nil
        end
    end
end

return sound
