--- Main entry point for the industrialworld demo.
---
--- Opens a BearLibTerminal window configured with TWO TrueType tilesets
--- at disjoint Unicode ranges: DejaVuSansMono at offset 0 (ASCII/box-drawing
--- tiles, antialiased) and DejaVuSerif at 0xE000+ (Private Use Area) for
--- the messages panel text. BLT's global codespace resolves per-cell by
--- codepoint, so both fonts coexist on screen simultaneously.
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
local bit = require("bit")
local blt = require("industrialworld.blt")
local Entity = require("entity")
local world = require("world")
local bus = require("event")
local log = require("log")
local palette = require("palette")
local game_state = require("game_state")
local messages = require("messages")
local ui = require("ui")
local screens = require("screens")
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

    -- Open the BLT window + configure fonts. The config string is a
    -- semicolon-separated list of option groups. Two tilesets:
    --   • DejaVuSansMono at offset 0        → AA monospace tiles (ASCII,
    --     box-drawing, block elements). use-box-drawing/block-elements
    --     tell BLT to use the font's own glyphs for those ranges.
    --   • DejaVuSans    at offset 0xE000     → sans-serif glyphs for
    --     the messages panel and UI overlays (drawn via PUA codepoints,
    --     see messages.lua and blt.lua print_serif).
    -- Both share one global codespace; a cell's codepoint resolves to
    -- whichever tileset owns that range. cellsize is fixed square so
    -- tile centering math is unchanged from the libtcod model.
    if not blt.open() then
        log.get("main"):error("failed to open BearLibTerminal")
        return 1
    end
    local cfg = table.concat({
        "window.title='industrialworld'",
        "window.size=" .. cols .. "x" .. rows,
        "window.resizeable=true",
        "window.cellsize=16x16",
        "font: vendor/fonts/MonosquareExtended.ttf, size=24x24, mode=monochrome, align=center, use-box-drawing=false, use-block-elements=false, hinting=normal",
        "0xE000: vendor/fonts/DejaVuSans.ttf, size=16x16, align=center, hinting=normal",
        "input.filter=[keyboard+, mouse+]",
    }, "; ")
    if not blt.set(cfg) then
        log.get("main"):error("failed to configure BearLibTerminal fonts")
        blt.close()
        return 1
    end

    -- Console shim: records logical size for centering/cull math; draws
    -- route into BLT's global scene on layer 0. refresh() flips it.
    local con = blt.Console.new(cols, rows)

    log.get("main"):info("industrialworld ready (%dx%d) log=%s", cols, rows, env_lvl or "info")

    -- The message log panel reserves the bottom PANEL_H rows of the
    -- console. Compute the visible map region height once and stash it on
    -- the camera each frame so render_map + entity draws center + cull
    -- against the VISIBLE map region (above the panel), not the full
    -- console. Set before any render call this frame.
    local view_rows = rows - messages.PANEL_H
    world.cam.view_rows = view_rows
    world.cam.view_cols = cols

    -- Wire the message log: subscribe to the `message` event on the bus
    -- (systems narrate via `bus.emit("message", text, fg)`) and seed it
    -- with a welcome banner so the panel isn't empty on first frame.
    messages.init(con)
    bus.emit("message", "Welcome to industrialworld.", palette.text)

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

    -- Mark sight-blocking terrain: every Wall cell carries the `Opaque`
    -- flag, so native-3D FOV rays stop at walls AND at the solid z=2
    -- ceiling (that's what "cuts off" upper layers except where the
    -- alcove above carved it Open — a skylight the ray climbs through).
    -- Floor and Open air are not opaque (you see across the floor; an
    -- Open ceiling hole lets rays climb). One linear pass over the
    -- types array sets the bit — robust to future wall placement.
    local TF = tile_mod.TileFlags
    local Opaque = TF.Opaque
    local flags_cdata = m.flags.cdata
    for i = 0, m.count - 1 do
        if types[i] == TT.Wall then
            flags_cdata[i] = bit.bor(flags_cdata[i], Opaque)
        else
            flags_cdata[i] = bit.band(flags_cdata[i], bit.bnot(Opaque))
        end
    end

    -- Spawn the player in the z=1 air at the room center. Gravity (via
    -- PhysicsObject's per-axis resolver) lands it on the Solid floor below
    -- on the first update; the per-frame camera sync in GameScreen.draw
    -- follows it continuously. Store on world.player for that sync.
    local Player = require("player")
    local Dummy = require("dummy")
    local player = Player(cx, cy, 1)
    world.player = player
    -- A couple of inert dummies beside the player so you can immediately
    -- walk into them and feel mass-aware knockback + surface friction. The
    -- heavy `#` (mass 4) barely budges; the light `o` (mass 0.3) launches
    -- — same player sprint, different Δv = J/mass. The heavy one is a 2×2
    -- body (occupies 4 cells, tiles its `#` glyph across them) to exercise
    -- the multi-tile footprint path; the light one stays 1×1. Spawned in
    -- the air at z=1; gravity lands them on the floor on the first update,
    -- like the player.
    Dummy(cx - 3, cy - 1, 1, 4.0, "#", 2, 2)
    Dummy(cx - 3, cy + 1, 1, 0.3, "o")
    -- LIGHTING DEMO: plunge the map into darkness (the "sun" is gone) and
    -- drop a stationary Brazier (sphere light, radius 8) a few cells off so
    -- you can see a fixed lit pool vs the player's carried torch (radius 6,
    -- baked into Player). Validate: lit pools around both lights, dark
    -- unlit visible space stretching to the viewport edge (proving the
    -- unlimited player FOV), soft falloff at the radius edge, light stops
    -- at Opaque walls, and memory cells dim uniformly (no per-cell light).
    m.is_dark = true
    local Brazier = require("brazier")
    Brazier(cx + 5, cy - 6, 1, 13)
    -- Pre-first-frame camera snap (before the first update/draw runs).
    world.cam.x = math.floor(player.x)
    world.cam.y = math.floor(player.y)
    world.cam.z = math.floor(player.z)

    -- Render the map and present.
    con:clear()
    world.render_map(con, view_rows)
    -- Draw entities (any living slot with a `draw` method) on top of the map.
    world.draw_entities(con)
    -- Message log panel (drawn last so it overwrites any stray glyphs in
    -- its reserved bottom rows).
    messages.draw(con)
    con:refresh()

    -- Keybinds (raw TK_* code -> semantic emit). The real-time loop below
    -- drains pending keypresses each frame and emits BOTH a general
    -- `keypress:<vk>` event (for any mixin/system that wants raw keys) AND
    -- the bound semantic action (move/peek/quit). Mixins listen for the
    -- semantics they care about; the general keypress channel is the escape
    -- hatch for ad-hoc key reactions. Explicit per-key emits (few, fixed
    -- binds) instead of a packed table — avoids unpack and keeps arg types
    -- visible to the linter.
    local key = blt -- TK_* codes live directly on the blt module (blt.tk_up etc.)
    local quit = false
    bus.subscribe(world, "quit", function()
        L:debug("quit requested")
        quit = true
    end)

    -- Camera follows the player EVERY FRAME: GameScreen.draw syncs
    -- `world.cam` to `world.player` (floor x/y, z) before rendering, since
    -- the player's motion is now continuous (impulse + Euler integrator,
    -- no discrete "moved" event). The pre-first-frame snap above covers the
    -- gap before the first draw.

    -- Screen setup. main.lua switches screens in response to game-state
    -- changes; each screen owns its own draw/update/teardown logic.
    local current_screen = screens.MenuScreen(con)
    local pause_overlay = screens.PauseOverlay(con)

    bus.subscribe(world, "state_changed", function(_old, new)
        if new == game_state.Mode.Menu then
            current_screen:destroy()
            current_screen = screens.MenuScreen(con)
        elseif new == game_state.Mode.Playing then
            current_screen:destroy()
            current_screen = screens.GameScreen(con)
        end
        -- Paused keeps the gameplay screen; only the overlay changes.
    end)

    -- Real-time frame pump. Each iteration:
    --   1. Drain ALL pending input events (nonblocking). Input is routed
    --      through the centralized game_state: the menu, pause, and playing
    --      screens each bind their own keys.
    --   2. Compute dt via os.clock() (seconds since last frame).
    --   3. Advance the simulation only while Playing.
    --   4. Render the menu, the game, or the pause overlay as appropriate.
    --   5. Sleep to cap the framerate (~60 FPS) so we don't spin the CPU.
    -- Last cell reported by a mouse-move event, for deduplicating hover
    -- emits when the input queue contains multiple movement events.
    local last_mx, last_my = -1, -1
    local hover_widget = nil

    -- Held arrow-key set (polled movement model). BLT delivers a keyDown on
    -- every OS key-repeat too, but with an initial ~250ms gap and ~30ms
    -- repeats — far too coarse to accumulate velocity while holding. So we
    -- track held STATE here (press adds, release removes) and emit ONE
    -- aggregated `move` per frame while Playing, decoupling hold-feel from
    -- OS-repeat jitter. A tap = 1-2 frames of impulse (soft-snap completes
    -- a single cell); a hold = impulse every frame -> continuous accel ->
    -- the graceful slide-to-stop the integrator + soft-snap produce.
    -- Keyed by base scan code (the code with TK_KEY_RELEASED stripped).
    local held = {}
    local function is_released(vk)
        return bit.band(vk, key.tk_key_released) ~= 0
    end
    local function base_code(vk)
        return bit.band(vk, 0xFF) -- strip TK_KEY_RELEASED (0x100) bit
    end

    local last = os.clock()
    local FRAME_TIME = 1 / 60 -- target 60 FPS
    while not quit do
        -- 1. Drain pending input (nonblocking). BLT's read() dequeues one
        --    event code per call; has_input() is the nonblocking drain guard.
        while blt.has_input() do
            local vk = blt.read()
            if vk == 0 or vk < 0 then
                break
            end
            L:debug("key vk=%d", vk)
            local base = base_code(vk) -- scan code with RELEASED bit stripped
            local released = is_released(vk)
            -- General raw-key channel: keypress:<vk> (press only — releases
            -- carry the TK_KEY_RELEASED bit and are tracked via `held`).
            if not released then
                bus.emit(("keypress:%d"):format(vk))
            end

            -- Window events: close button and resize.
            if vk == key.tk_close then
                bus.emit("quit")
            elseif vk == key.tk_resized then
                local w = blt.state(key.tk_width)
                local h = blt.state(key.tk_height)
                con.w = w
                con.h = h
                view_rows = h - messages.PANEL_H
                world.cam.view_rows = view_rows
                world.cam.view_cols = w
                -- The message log spans the full width; update its bounds.
                messages.on_resize(w)
                L:info("window resized to %dx%d (view_rows=%d)", w, h, view_rows)
            end

            -- Mouse events. Clicks and hovers carry {x, y} data so UI
            -- widgets can test containment without knowing the console.
            if vk == key.tk_mouse_move then
                local mx = blt.state(blt.tk_mouse_x)
                local my = blt.state(blt.tk_mouse_y)
                if mx ~= last_mx or my ~= last_my then
                    bus.emit("mouse_hover", { x = mx, y = my })

                    local current_hover = world.widget_topmost({ x = mx, y = my }, "_hoverable")
                    if current_hover ~= hover_widget then
                        if hover_widget then
                            bus.emit(
                                "widget:hover",
                                { widget = hover_widget, x = mx, y = my, state = false }
                            )
                        end
                        hover_widget = current_hover
                        if hover_widget then
                            bus.emit(
                                "widget:hover",
                                { widget = hover_widget, x = mx, y = my, state = true }
                            )
                        end
                    end

                    last_mx, last_my = mx, my
                end
            elseif vk >= key.tk_mouse_left and vk <= key.tk_mouse_middle then
                local mx = blt.state(blt.tk_mouse_x)
                local my = blt.state(blt.tk_mouse_y)
                bus.emit("mouse_click", { x = mx, y = my, button = vk })

                local clicked = world.widget_topmost({ x = mx, y = my }, "_clickable")
                if clicked then
                    bus.emit("widget:click", { widget = clicked, x = mx, y = my, button = vk })
                end
            end

            -- State-bound input.
            if game_state.is(game_state.Mode.Menu) then
                if vk == key.tk_return then
                    game_state.set(game_state.Mode.Playing)
                elseif vk == key.tk_escape then
                    bus.emit("quit")
                end
            elseif game_state.is(game_state.Mode.Paused) then
                if vk == key.tk_p then
                    game_state.set(game_state.Mode.Playing)
                elseif vk == key.tk_escape then
                    bus.emit("quit")
                end
            elseif game_state.is(game_state.Mode.Playing) then
                if vk == key.tk_p then
                    game_state.set(game_state.Mode.Paused)
                elseif vk == key.tk_escape then
                    bus.emit("quit")
                elseif vk == key.tk_pageup then
                    world.peek(1)
                elseif vk == key.tk_pagedown then
                    world.peek(-1)
                end
            end

            -- Arrow-key HELD-STATE tracking (universal: runs in any state so
            -- a held key released during pause still clears). The per-frame
            -- `move` emit (aggregated from this set) fires below, only while
            -- Playing. Press (no RELEASED bit) adds; release removes.
            if
                base == key.tk_right
                or base == key.tk_left
                or base == key.tk_up
                or base == key.tk_down
            then
                if released then
                    held[base] = nil
                else
                    held[base] = true
                end
            end
        end

        -- 2. dt since last frame. CLAMPED to the frame budget: when a
        --    frame runs long (the per-frame lighting flood on a large
        --    map can be costly), wall-clock `dt` would spike and feed a
        --    huge step into the semi-implicit Euler integrator -> the
        --    player lurches/overshoots a tap. Capping at FRAME_TIME keeps
        --    the simulation steady and responsive under hitches (yes,
        --    this means we simulate slightly slow on a slow frame rather
        --    than exploding — the lesser evil for a real-time game).
        local now = os.clock()
        local dt = now - last
        last = now
        if dt > FRAME_TIME then
            dt = FRAME_TIME
        end

        -- 3. Advance the simulation only while Playing.
        if game_state.is(game_state.Mode.Playing) then
            -- Per-frame movement from the held arrow-key set (polled
            -- model): one aggregated `move` emit per frame while a key is
            -- held -> the player's `move` handler applies one accel impulse,
            -- every frame -> continuous accel -> real sliding on hold.
            -- Opposite keys cancel; no held keys -> no emit (no impulse,
            -- friction + soft-snap bring the player to rest).
            local dx = (held[key.tk_right] and 1 or 0) - (held[key.tk_left] and 1 or 0)
            local dy = (held[key.tk_down] and 1 or 0) - (held[key.tk_up] and 1 or 0)
            if dx ~= 0 or dy ~= 0 then
                bus.emit("move", dx, dy)
            end
            world.update(dt)
        end

        -- UI widgets always tick (anchors, animations) regardless of state.
        world.update_widgets(dt)

        -- 4. Render + present.
        current_screen:draw()
        if game_state.is(game_state.Mode.Paused) then
            pause_overlay:draw()
        end

        con:refresh()

        -- 5. Cap framerate. BLT doesn't expose vsync control, so we sleep
        --    the remainder of the frame budget. Try luasocket's sleep if
        --    available in the host; if not (embedded host may not ship it),
        --    use BLT's own terminal_delay (portable, ms). Resolved once.
        local elapsed = os.clock() - now
        local remaining = FRAME_TIME - elapsed
        if remaining > 0 then
            if _G._sleep_fn ~= nil then
                _G._sleep_fn(remaining)
            else
                -- Fallback: BLT's portable delay (ms). Coarser than socket.sleep
                -- but always available — avoids a spin. Resolved once below.
                blt.delay(math.floor(remaining * 1000))
            end
        end
        if _G._sleep_tried == nil then
            _G._sleep_tried = true
            local ok, sock = pcall(require, "socket")
            if ok and type(sock.sleep) == "function" then
                _G._sleep_fn = sock.sleep
            end
        end
    end

    con:shutdown()
    blt.close()
    return 0
end

return main()
