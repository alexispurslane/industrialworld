--- Drawable mixin (composed: Position + Renderable).
---
--- An entity that draws itself in camera space. Composes `Position`
--- (spatial state + movement + physics integrator) and `Renderable`
--- (appearance). `draw(console, cam)` transforms the entity's world
--- position to screen coords via `cam` and delegates to the Renderable
--- leaf's `draw(console, sx, sy)` (which takes screen coords as params,
--- pure leaf). Reading Position's state is lawful orchestration (law 5:
--- flat `self`, no scopes).
---
--- Camera is a PARAMETER (not read off a global), so the mixin stays
--- capability-pure — no coupling to `world`. The caller (the render loop)
--- owns which camera the entity renders against. For position-independent
--- appearance (a tile-type registry entry with no position), use the
--- `Renderable` leaf directly.

local Position = require("mixins.position")
local Renderable = require("mixins.renderable")

local Drawable = mixin({}, Position, Renderable)

--- Initialize position (Position leaf) then appearance (Renderable leaf).
--- Takes a NAMED-FIELD table: appearance fields (fg/bg/glyphs) plus the
--- spatial fields that flow through to Position.init (x,y,z,w,h). Defaults:
--- white-on-black, single "?" glyph. `w,h` (default 1,1) declare the tile
--- footprint so a multi-tile drawable can be sized at construction.
---@param opts? table  {x=,y=,z=,fg=,bg=,glyphs=,w=,h=,vx=,vy=,vz=} (all optional).
function Drawable:init(opts)
    opts = opts or {}
    Position.init(self, opts)
    Renderable.init(self, opts.fg, opts.bg, opts.glyphs)
end

--- Render this entity in camera space onto `console`. Translates world
--- `self.x`/`self.y` to screen coords using `cam` (the cell at the
--- viewport center) + the console size, then delegates to the Renderable
--- leaf. Off-screen entities are skipped (anchor outside the console,
--- with a 1-cell slack for multi-tile glyphs at the edge).
---@param console iw.Console
---@param cam table  `{x=,y=,z=}` — the camera (center cell + z layer).
function Drawable:draw(console, cam)
    local cols = console:width()
    local rows = cam.view_rows or console:height()
    local sx = math.floor(self.x) - cam.x + math.floor(cols / 2)
    local sy = math.floor(self.y) - cam.y + math.floor(rows / 2)
    if sx < -1 or sx > cols or sy < -1 or sy > rows then
        return
    end
    Renderable.draw(self, console, sx, sy)
end

return Drawable
