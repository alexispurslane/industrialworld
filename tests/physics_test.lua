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
package.preload["industrialworld.blt_ffi"] = function() return {} end

local Map = require("map")
local tile = require("tile")
local Collision = require("collision")
local world = require("world")
local Entity = require("entity")
local PhysicsObject = require("mixins.physics_object")
local Drawable = require("mixins.drawable")

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

print(("\n%d passed, %d failed"):format(pass, fail))
if fail > 0 then
    os.exit(1)
end
