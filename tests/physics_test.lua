-- Headless physics test: gravity landing, impulse+friction, wall slide,
-- stairs bump. No window — runs the integrator + per-axis resolver in a
-- stubbed map and asserts the outputs. Uses REALISTIC 60fps frame dts
-- (NOT substepping): substepping would break the per-frame ax-consumption
-- (PhysicsObject.update clears ax each call) and the gravity baseline.
package.path = "src/?.lua;" .. package.path

_G.class = require("classes")
_G.mixin = require("classes").mixin
_G.enum = require("enums")

-- Stubs so the engine modules load without BLT / the full main bootstrap.
package.preload["industrialworld.blt"] = function()
    return { LAYER_ENTITY = 1 }
end
package.preload["industrialworld.blt_ffi"] = function()
    return {}
end

local Map = require("map")
local tile = require("tile")
local Collision = require("collision")
local world = require("world")
local Entity = require("entity")
local PhysicsObject = require("mixins.physics_object")
local Drawable = require("mixins.drawable")
local Stairs = require("stairs")

-- A tiny map: Solid Floor at z=0 (ground), Open air at z=1..2. A Wall at
-- (4,2,1) blocks +x travel for the slide test.
local W, H, D = 8, 8, 3
world.map = Map(W, H, D)
world.cam = { x = 0, y = 0, z = 0 }
world.player = nil
do
    local TT = tile.TileType
    for x = 0, W - 1 do
        for y = 0, H - 1 do
            world.map.types:set(x, y, 0, TT.Floor)
            world.map.types:set(x, y, 1, TT.Open)
            world.map.types:set(x, y, 2, TT.Open)
        end
    end
    -- A vertical wall line at x=4 spanning ALL y, z=1..2, for the slide
    -- test (full span so the player can't run off the wall's end).
    for y = 0, H - 1 do
        world.map.types:set(4, y, 1, TT.Wall)
        world.map.types:set(4, y, 2, TT.Wall)
    end
end

local Player, super = _G.class("Player", Entity):mixin(PhysicsObject, Drawable)
function Player:init(x, y, z)
    super.init(self)
    PhysicsObject.init(self, x, y, z, Collision.Solid, true)
    Drawable.init(self, x, y, z, { r = 255, g = 255, b = 255 }, nil, "@")
end

-- A heavier body (mass 4) to exercise mass-aware impulse: same impulse ->
-- 1/4 the Δv of the mass-1 player.
local Crate, crate_super = _G.class("Crate", Entity):mixin(PhysicsObject, Drawable)
function Crate:init(x, y, z, mass)
    crate_super.init(self)
    PhysicsObject.init(self, x, y, z, Collision.Solid, true, nil, mass or 4.0)
    Drawable.init(self, x, y, z, { r = 200, g = 130, b = 95 }, nil, "#")
end

local FRAME = 1 / 60

-- Run `frames` frames at 60fps. If `per_frame` is given, call it each frame
-- before update (e.g. to apply a held impulse).
local function run(e, frames, per_frame)
    for _ = 1, frames do
        if per_frame then
            per_frame(e)
        end
        e:update(FRAME)
    end
end

local pass, fail = 0, 0
local function check(name, cond, val)
    if cond then
        pass = pass + 1
        print(("  ok   %s"):format(name))
    else
        fail = fail + 1
        print(("  FAIL %s (got %s)"):format(name, tostring(val)))
    end
end

----------------------------------------------------------------
print("[1] gravity landing: player spawned in z=1 air falls & rests on z=0 floor")
----------------------------------------------------------------
do
    local p = Player(2, 2, 2) -- top of the 3-layer map; falls to z=1.
    run(p, 120) -- 2s: plenty to land
    check("rested on floor (z ~= 1)", math.abs(p.z - 1) < 0.01, p.z)
    check("didn't fall through (z >= 0)", p.z >= 0, p.z)
    -- At rest vz is small (gravity re-applies each frame, resolver zeroes).
    check("not sinking (|vz| small)", math.abs(p.vz) < 0.5, p.vz)
    p:destroy()
end

----------------------------------------------------------------
print("[2] impulse + friction: held +x impulse reaches speed; released -> rests")
----------------------------------------------------------------
do
    local p = Player(2, 2, 1)
    run(p, 30) -- settle on ground
    -- Hold +x impulse for a few frames (BEFORE reaching the wall at x=4):
    -- check cruise speed mid-flight, not after wall contact.
    run(p, 8, function(e)
        e:accelerate(world.STEP_ACCEL, 0, 0)
    end)
    check("reached cruise speed (vx > 0.5)", p.vx > 0.5, p.vx)
    check("moved +x (x > 2.3)", p.x > 2.3, p.x)
    -- Release: friction decays vx to ~0.
    run(p, 180) -- 3s of no input
    check("coasted to rest (vx ~ 0)", math.abs(p.vx) < 0.05, p.vx)
    p:destroy()
end

----------------------------------------------------------------
print("[3] wall slide: diagonal into wall(4,2,1) zeroes vx, leaves vy (slide)")
----------------------------------------------------------------
do
    local p = Player(3, 2, 1)
    run(p, 30) -- settle
    -- Hold +x + +y (diagonal at wall). +x blocked, +y carries along face.
    run(p, 30, function(e)
        e:accelerate(world.STEP_ACCEL, world.STEP_ACCEL, 0)
    end)
    check("stopped at wall (x < 4)", p.x < 4, p.x)
    check("slid in +y (y > 2.3)", p.y > 2.3, p.y)
    check("vx zeroed (hit wall)", math.abs(p.vx) < 0.1, p.vx)
    p:destroy()
end

----------------------------------------------------------------
print("[4] vertical impulse + gravity: vz set arcs player up, then lands")
----------------------------------------------------------------
-- (Stairs no longer use a vz bump — they teleport via move(). This
-- instead exercises the integrator's vertical path directly: a direct vz
-- set, gravity arcs it up, gravity + landing resolver bring it back down.)
do
    local p = Player(2, 2, 1)
    run(p, 30) -- settle
    check("grounded before impulse (z ~= 1)", math.abs(p.z - 1) < 0.01, p.z)
    -- Direct vertical impulse (vx=0) so the player lands back in its own
    -- clear column at (2,2), not on top of the wall at x=4.
    p.vx = 0
    p.vz = world.SHUNT_VZ
    run(p, 6) -- 0.1s: airborne, going up
    check("got airborne (z > 1.1)", p.z > 1.1, p.z)
    run(p, 120) -- 2s: gravity arcs it back down
    check("settled back near ground (z < 1.01)", p.z < 1.01, p.z)
    check("didn't fall through (z >= 0)", p.z >= 0, p.z)
    p:destroy()
end

print("")
----------------------------------------------------------------
print("[5] apply_impulse: Δv = J / mass (mass-aware impulse)")
----------------------------------------------------------------
do
    local p = Player(2, 2, 1)
    run(p, 30) -- settle
    -- mass 1.0 (default): impulse J=10 -> Δv=10. apply_impulse writes vx
    -- directly (pre-friction), so check BEFORE the next update runs.
    p:apply_impulse(10, 0, 0)
    check("mass 1.0: Δv = J/m = 10", math.abs(p.vx - 10) < 0.01, p.vx)
    local c = Crate(3, 3, 1, 4.0) -- mass 4
    run(c, 30) -- settle
    c:apply_impulse(10, 0, 0)
    check("mass 4.0: Δv = J/m = 2.5", math.abs(c.vx - 2.5) < 0.01, c.vx)
    p:destroy()
    c:destroy()
end

----------------------------------------------------------------
print("[6] knockback: collision transfers MOVER MOMENTUM (J = m*v)")
----------------------------------------------------------------
-- Mover (mass 1, v=10) hits adjacent crate (mass 4). Collision zeroes
-- the mover's v and emits knockback impulse J = m_mover * v = 10. The
-- crate's apply_impulse converts to Δv = J / m_crate = 10/4 = 2.5.
do
    local p = Player(2, 2, 1)
    local c = Crate(3, 2, 1, 4.0) -- directly in +x path
    run(p, 30)
    run(c, 30) -- settle crate at (3,2,1)
    -- Place mover just shy of the cell boundary so ONE frame crosses into
    -- the crate's cell 3, with a known velocity (no input accel this frame
    -- so ax=0 and friction hasn't damped vx yet at resolve time).
    p.x = 2.9
    p.vx = 10
    p:update(FRAME)
    check("mover stopped by block (vx ~ 0)", math.abs(p.vx) < 0.1, p.vx)
    check("crate gained Δv = (m_mover*v)/m_crate = 2.5", math.abs(c.vx - 2.5) < 0.05, c.vx)
    p:destroy()
    c:destroy()
end

print("")
----------------------------------------------------------------
print("[7] swept collision: fast mover (v > 1 cell/frame) cannot tunnel through a thin wall")
----------------------------------------------------------------
-- Place a wall at x=4 spanning all y/z (from the map setup). A mover at
-- x=2.x with vx=10 cells/s moves 0.167 cells/frame — calm. So set vx
-- huge (50 cells/s = 0.83 cells/frame, multi-frame) AND start close so
-- the integrated target clears the wall + lands beyond it in ONE frame.
-- Old destination-only resolver would skip the wall; swept must catch it.
do
    local p = Player(2, 2, 1)
    run(p, 30) -- settle on the floor
    -- Start at x=3.5 so target = 3.5 + 50*dt... we want a velocity that
    -- in ONE frame jumps from inside cell 3 to inside cell 6+ (past the
    -- wall at cell 4 and the cell 5 behind it). vx=300 cells/s, dt=1/60:
    -- displacement = 5 cells -> from 3.5 to 8.5, skipping cells 4 (wall).
    p.vx = 300
    p:update(FRAME)
    check("stopped at the wall (x < 4)", p.x < 4, p.x)
    check("didn't tunnel past (x >= 3)", p.x >= 3, p.x)
    check("vx zeroed by block", math.abs(p.vx) < 0.1, p.vx)
    p:destroy()
end

print("")
----------------------------------------------------------------
print("[8] soft-snap into a blocked cell emits a collision (stairs shunt on a shoved heavy body)")
----------------------------------------------------------------
-- Regression for the "shoved body stuck on the doorstep" bug: a knock
-- that leaves v < SOFT_SNAP_V wants to re-grid INTO the stairs cell.
-- Old soft-snap silently arrested it there (no collision -> no shunt).
-- Fixed soft-snap emits a collision at the blocked target cell, so the
-- stairs' shunt handler fires and the body is teleported up.
-- Map: floor z=0, open z=1. Place an up-stairs at (2,0,1) so a dummy
-- shoved -x from (3,0,1) re-grids into cell 2 and should shunt to z=2.
-- (Cell 2 is Open at z=1, so the stairs occupies it; the z=2 landing is
-- Open air — fine: we just assert z increased, the shunt happened.)
do
    -- Clear the wall at (4,*,1) path is irrelevant; we use the left edge.
    world.map.types:set(2, 0, 1, tile.TileType.Open) -- ensure stairs cell is open
    local s = Stairs(2, 0, 1, "up")
    local c = Crate(3, 0, 1, 4.0) -- mass 4: Δv from J=38 is 9.5 (<SOFT_SNAP_V)
    run(c, 30) -- settle
    -- Faithful knock: player mass 1 at cruise v=38 -> J=38. Δv = 38/4 = 9.5.
    c:apply_impulse(-38, 0, 0) -- shove toward the stairs at -x
    run(c, 6)
    check("heavy body shoved into stairs shunted up (z > 1.5)", c.z > 1.5, c.z)
    c:destroy()
    s:destroy()
end

print(("\n%d passed, %d failed"):format(pass, fail))
if fail > 0 then
    os.exit(1)
end
