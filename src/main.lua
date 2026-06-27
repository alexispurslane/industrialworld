--- Main entry point for the industrialworld demo.
---
--- Opens a libtcod context with the vendored terminal.png font as a
--- tileset, renders a border + label, and runs a blocking event loop
--- until Escape is pressed. Exercises the full vendored-LuaJIT + libtcod
--- + FFI wrapper stack end to end.
---
--- Also sets up entity storage (a pooled, pre-allocated entity table +
--- dense cffi alive-tombstone, see below) and a Map.

-- Expose the OOP + enum DSLs as globals so every game module can define
-- classes/enums with `class "Foo"` / `mixin({}, ...)` / `enum(...)`.
-- `class` is the DSL module; `class.mixin` / `class.enum` follow.
_G.class = require("classes")
_G.mixin = _G.class.mixin
_G.enum = require("enums")

-- The world (entity pool + Map + camera) is a singleton MODULE
-- (src/world.lua), required everywhere it's needed -- NOT a global.
-- `bus` (src/event.lua) is likewise a singleton module: require it where
-- you need it (`local bus = require("event")`); Lua's module cache makes
-- every require return the same bus object, so all subscribers and all
-- emitters share one registry.
local ffi = require("ffi")
local tcod = require("industrialworld.tcod")
local Entity = require("entity")
local world = require("world")
local bus = require("event")
local log = require("log")
local L = log.get("main")

-- Log floor: override via the IW_LOG env var ("trace"/"debug"/"info"/...).
-- Defaults to "info" so production runs aren't spammed; the DEBUG
-- instrumentation below is visible when you run with IW_LOG=debug.
local env_lvl = os.getenv("IW_LOG")
if env_lvl ~= nil then
    log.set_level(env_lvl)
end
----------------------------------------------------------------------------------------------------

local function main()
    local cols, rows = 80, 50

    -- Load the vendored DejaVu 16×16 square tileset. It is a 32×8 TCOD-layout
    -- sheet, so we pass tcod.charmap_tcod to map ASCII codepoints to the right tiles.
    local tileset, terr = tcod.Tileset.load_font("terminal.png", 32, 8, tcod.charmap_tcod)
    if not tileset then
        log.get("main"):error("failed to load tileset: %s", terr or "unknown")
        return 1
    end

    local ctx, err = tcod.Context.new({
        columns = cols,
        rows = rows,
        window_title = "industrialworld",
        vsync = true,
        renderer = tcod.renderer_sdl2,
        tileset = tileset,
    })
    if not ctx then
        log.get("main"):error("failed to create context: %s", err or "unknown")
        return 1
    end

    local con = tcod.Console.new(cols, rows)
    if not con then
        log.get("main"):error("failed to create console")
        ctx:shutdown()
        return 1
    end

    log.get("main"):info("industrialworld ready (%dx%d) log=%s", cols, rows, env_lvl or "info")

    -- Simple test map for the gravity model (FLOOR IS SOLID ground; walk in
    -- the OPEN AIR cell above it; gravity rests when the cell below is Solid):
    --   z=0 : FULL of Floor (Solid) — the ground.
    --   z=1 : OPEN air (default) with a WALL outline around the room edges
    --         (Solid: blocks walking, supports above). This is the walkable
    --         layer — entities rest here with z=0 floor below them.
    --   z=2 : FULL of Wall — the ceiling (above the player; not rendered
    --         since the camera draws only z=0..cam.z = 0..1).
    local tile_mod = require("tile")
    local TT = tile_mod.TileType
    local m = world.map
    local cx, cy = 1000, 1000
    local W = m.w
    local H = m.h
    local types = m.types.cdata
    -- Full-layer fills via raw cdata (one linear write run per layer).
    for i = 0, W * H - 1 do
        types[i] = TT.Floor
    end
    local z2_base = 2 * W * H
    for i = z2_base, z2_base + W * H - 1 do
        types[i] = TT.Wall
    end
    -- z=1: wall outline around a room centered on (cx, cy).
    local rx0, ry0, rx1, ry1 = cx - 40, cy - 25, cx + 40, cy + 25
    local function set1(x, y, tv)
        m.types:set(x, y, 1, tv)
    end
    for x = rx0, rx1 do
        set1(x, ry0, TT.Wall)
        set1(x, ry1, TT.Wall)
    end
    for y = ry0, ry1 do
        set1(rx0, y, TT.Wall)
        set1(rx1, y, TT.Wall)
    end
    -- A couple of interior wall pillars to vary the walkable space.
    for _, dx in ipairs({ -20, 0, 20 }) do
        for _, dy in ipairs({ -10, 10 }) do
            set1(cx + dx, cy + dy, TT.Wall)
        end
    end

    -- An upper alcove reachable via a Stairs, to test the upstairs shunt.
    -- A raised solid platform at z=1 (Floor) supports a walkable z=2 air
    -- patch carved out of the ceiling wall. The Stairs sits at the
    -- platform's edge (z=1); the player walks into it and is shunted up
    -- onto the platform (z=2, one cell past the stairs).
    -- Platform (z=1 solid) + open upper air (z=2) over a 5x5 area.
    local px0, py0, px1, py1 = cx + 25, cy - 2, cx + 29, cy + 2
    for y = py0, py1 do
        for x = px0, px1 do
            m.types:set(x, y, 1, TT.Floor) -- platform: solid, supports z=2 walkers
            m.types:set(x, y, 2, TT.Open) -- carve open air in the ceiling
        end
    end
    -- Two-way vertical link forming a loop the player can traverse without
    -- ever getting trapped:
    --   Up-stairs  at (cx+24, cy, 1): approached from the left, lands at
    --              (cx+25, cy, 2) — open air on the platform.
    --   Down-stairs at (cx+29, cy, 2): approached from the left (after
    --              walking across the platform), lands at (cx+30, cy, 1) —
    --              OUTSIDE the platform, in the main room's z=1 open air
    --              (z=0 floor below supports it). Has escapes on every
    --              side, so the player is never stuck.
    local Stairs = require("stairs")
    Stairs(cx + 24, cy, 1, "up")
    Stairs(cx + 29, cy, 2, "down")

    -- Spawn the player in the z=1 air at the room center. Player:init ->
    -- PhysicsObject.init -> fall(): cell below z=0 is Floor Solid -> rests
    -- at z=1. Free to walk the z=1 interior, bounded by the wall outline.
    local Player = require("player")
    local player = Player(cx, cy, 1)
    -- The init-time fall isn't bus-tracked (the camera subscribes to "moved"
    -- below, after this), so snap the camera to the player's post-fall pos.
    world.cam.x = math.floor(player.x)
    world.cam.y = math.floor(player.y)
    world.cam.z = player.z

    -- Render the map and present.
    con:clear()
    world.render_map(con)
    -- Draw entities (any living slot with a `draw` method) on top of the map.
    world.draw_entities(con)
    ctx:present(con)

    -- Keybinds (raw vk -> semantic emit). The real-time loop below drains
    -- pending keypresses each frame and emits BOTH a general
    -- `keypress:<vk>` event (for any mixin/system that wants raw keys) AND
    -- the bound semantic action (move/peek/quit). Mixins listen for the
    -- semantics they care about; the general keypress channel is the escape
    -- hatch for ad-hoc key reactions. Explicit per-key emits (few, fixed
    -- binds) instead of a packed table — avoids unpack and keeps arg types
    -- visible to the linter.
    local key = tcod.key
    local quit = false
    bus.subscribe(world, "quit", function()
        L:debug("quit requested")
        quit = true
    end)

    -- Camera follows the player: subscribe to `moved` (emitted by Player
    -- after it acts) and refocus cam.x/y/z onto the player.
    bus.subscribe(world, "moved", function(p)
        L:debug("camera follow -> (%.0f,%.0f,%d)", p.x, p.y, p.z)
        world.cam.x = math.floor(p.x)
        world.cam.y = math.floor(p.y)
        world.cam.z = p.z
    end)

    -- Real-time frame pump. Each iteration:
    --   1. Drain ALL pending input events (nonblocking; check_for_event
    --      returns 0 when the queue is empty). Keybinds emit semantic
    --      actions (move/peek/quit) into the bus — input stays event-
    --      driven, but the sim no longer BLOCKS on input.
    --   2. Compute dt via os.clock() (seconds since last frame).
    --   3. world.update(dt) ticks every living entity's :update(dt) —
    --      PhysicsObject runs euler+fall, so gravity re-settles every
    --      frame whether the entity moved discretely or via velocity.
    --   4. Render + present.
    --   5. Sleep to cap the framerate (~60 FPS) so we don't spin the CPU.
    -- The old blocking wait_for_event is gone; the sim now advances in real
    -- time independent of keypresses, which is what unblocks NPCs, DoTs,
    -- animations, etc. Keybinds still emit BOTH the semantic action AND the
    -- raw keypress:<vk> channel, as before.
    local last = os.clock()
    local FRAME_TIME = 1 / 60 -- target 60 FPS
    while not quit do
        -- 1. Drain pending input (nonblocking).
        while true do
            local ev, kev = tcod.check_for_event(tcod.event_key_press)
            if ev == 0 then
                break
            end
            local vk = tonumber(kev.vk)
            L:debug("key vk=%d", vk)
            -- General raw-key channel: keypress:<vk>.
            bus.emit(("keypress:%d"):format(vk))
            -- Semantic channel: the bound action, if any.
            if vk == key.right then
                bus.emit("move", 1, 0)
            elseif vk == key.left then
                bus.emit("move", -1, 0)
            elseif vk == key.up then
                bus.emit("move", 0, -1)
            elseif vk == key.down then
                bus.emit("move", 0, 1)
            elseif vk == key.pageup then
                world.peek(1)
            elseif vk == key.pagedown then
                world.peek(-1)
            elseif vk == key.escape then
                bus.emit("quit")
            end
        end

        -- 2. dt since last frame.
        local now = os.clock()
        local dt = now - last
        last = now

        -- 3. Advance the simulation.
        world.update(dt)

        -- 4. Render + present.
        con:clear()
        world.render_map(con)
        world.draw_entities(con)
        ctx:present(con)

        -- 5. Cap framerate. vsync (set on context creation) already
        --    synchronizes ctx:present() to the display refresh (~60Hz),
        --    so this is belt-and-suspenders. Try luasocket's sleep if
        --    available in the host; if not (embedded host may not ship
        --    it), rely on vsync alone and skip — no crash. Resolved once.
        local elapsed = os.clock() - now
        local remaining = FRAME_TIME - elapsed
        if remaining > 0 and _G._sleep_fn ~= nil then
            _G._sleep_fn(remaining)
        elseif remaining > 0 and _G._sleep_tried == nil then
            _G._sleep_tried = true
            local ok, sock = pcall(require, "socket")
            if ok and type(sock.sleep) == "function" then
                _G._sleep_fn = sock.sleep
                sock.sleep(remaining)
            end
        end
    end

    con:shutdown()
    ctx:shutdown()
    return 0
end

return main()
