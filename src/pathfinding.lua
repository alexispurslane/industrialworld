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
--   budget = N                      -- cap nodes expanded (safety)
--
-- The queries (raycast/line_of_sight/within_radius/within_sphere) take a
-- slimmer opts; see each module. FOV/lighting is intentionally NOT here
-- — see FUTURE_WORK #1; a future src/fov.lua will reuse
-- pathfinding.raycast + the Opaque flag.

local M = {}

M.find_path = require("pathfinding.find_path").run
M.distance_field = require("pathfinding.distance_field").run
M.descent_field = require("pathfinding.descent_field").run
M.descent_step = require("pathfinding.descent_field").step
M.flood = require("pathfinding.flood").run
M.raycast = require("pathfinding.raycast").run
M.line_of_sight = require("pathfinding.line_of_sight").run
M.within_radius = require("pathfinding.shapes").within_radius
M.within_sphere = require("pathfinding.shapes").within_sphere

-- Exposed for callers building custom transition policies (ladders,
-- flight, portals). grid.default_transition reads map.types against the
-- engine TileType; pass your own function to opts.transition to override.
M.default_transition = require("pathfinding.grid").default_transition

return M
