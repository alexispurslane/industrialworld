--- Pathfinding + spatial query subpackage.
--
-- Purpose-named routing & reach primitives over the engine's z-major
-- grid. Reach via `local pf = require("pathfinding")`. Each function
-- below has a "WHEN TO USE THIS" docstring; consult those to pick the
-- right one — the names describe the use case, not the algorithm.
--
-- All searchers (find_path, distance_field, descent_field, flood) take
-- an `opts` table with at minimum:
--   dims      = {w, h, d}            -- grid extent (matches Map)
--   passable  = function(x,y,z)->bool -- e.g. TileFlags.Walkable test
--   source/start/goal = {x,y,z}       -- per function
-- Optional, shared across searchers:
--   cost(x,y,z, bx,by,bz)->number   -- per-step cost (default uniform 1)
--   occupied(x,y,z)->bool          -- dynamic blocker (live entities)
--   transition(x,y,z,opts)->iter   -- z-edges; default reads TileType stairs/ramp
--   diagonal = true                 -- 8-dir (octile, no corner cutting)
--   budget = N                      -- COST cap: max path-cost expanded
--                                   -- (``reach radius''; nil => unbounded).
--                                   -- Uniform across ALL searchers
--                                   -- (flood/distance_field/find_path): a
--                                   -- cell whose cost-to-reach exceeds it
--                                   -- is not expanded/returned. A separate
--                                   -- always-on runaway-safety NODE cap is
--                                   -- applied internally (not caller-set).
--
-- The queries (raycast/within_radius/within_sphere) take a slimmer opts;
-- see each module. SIGHT is not here — it lives in `fov`
-- (`require("fov")`; `fov.line_of_sight` is the single-pair boolean,
-- `fov.visible_*`/`fov.can_see` are the many-at-once forms), reusing
-- `pathfinding.raycast` + the map's Opaque flag.

local M = {}

M.find_path = require("pathfinding.find_path").run
M.distance_field = require("pathfinding.distance_field").run
M.descent_field = require("pathfinding.descent_field").run
M.descent_step = require("pathfinding.descent_field").step
M.flood = require("pathfinding.flood").run
M.raycast = require("pathfinding.raycast").run
M.raycast3d = require("pathfinding.raycast3d").run
M.within_radius = require("pathfinding.shapes").within_radius
M.within_sphere = require("pathfinding.shapes").within_sphere

-- Exposed for callers building custom transition policies (ladders,
-- flight, portals). grid.default_transition reads map.types against the
-- engine TileType; pass your own function to opts.transition to override.
M.default_transition = require("pathfinding.grid").default_transition

return M
