--- Pooled per-cell scratch buffers reused across searches.
--
-- INTERNAL helper; not re-exported from `init.lua`. The searchers need,
-- per cell: a g-score (best cost-to-reach found so far) and a parent
-- index (for path reconstruction). These are allocated as FFI cdata so
-- zero-fill + tight integer writes JIT cleanly, and POOLED by cell count
-- so a stream of searches over the same map size is allocation-free
-- steady state (same memory discipline as the world's entity pool).
--
-- NON-REENTRANT: a Scratch is reused across searches. Do NOT run two
-- searches with the same Scratch concurrently — the turn model almost
-- certainly never interleaves them, and reentrancy would force a fresh
-- buffer per search, defeating the pool.

local ffi = require("ffi")

local scratch = {}

--- Pool of Scratch instances keyed by cell count.
local pool = {}

--- State per cell. 0 = unseen, 1 = open (in frontier), 2 = closed.
local UNSEEN, OPEN, CLOSED = 0, 1, 2
scratch.UNSEEN, scratch.OPEN, scratch.CLOSED = UNSEEN, OPEN, CLOSED

local function make(count)
    return {
        count = count,
        gscore = ffi.new("int32_t[?]", count), -- best known cost-to-reach (init 0; unseen guarded by state)
        parent = ffi.new("int32_t[?]", count), -- parent cell index (-1 via marks below; we lazily set)
        state = ffi.new("uint8_t[?]", count), -- 0 = unseen (the ffi.new zero-fill handles reset)
        _version = 0, -- bumped on reset; cells carry their own version stamp? no — full mem reset below
    }
end

--- Borrow a Scratch sized for `count` cells, zeroed and ready.
--- Returns a pooled instance if one of the right size exists; creates
--- one otherwise. Caller MUST return it via `scratch.release(s)`.
---@param count integer  w*h*d of the search space.
---@return table s
function scratch.get(count)
    local s = pool[count]
    if s == nil then
        s = make(count)
        pool[count] = s
    end
    -- ffi.fill zeroes the whole array in one memset; cheap enough.
    ffi.fill(s.state, count, 0)
    return s
end

--- Like `get`, but zero ONLY the cells inside a 3D sub-box of the state
--- array instead of the full `count`-cell arena. For budget-bounded searches
--- that stay within a box around the source (e.g. light floods of radius R
--- on a 2000×2000×10 map), this turns a full-map memset (here ~40 MB) into a
--- tiny box-sized one (a few thousand cells). The pooled arrays may carry
--- stale `CLOSED` state OUTSIDE the box from prior searches, but a
--- budget-bounded search never reads a cell outside its box (every neighbor
--- it opens is within radius R ⊂ box of the source), so a partial zero is
--- safe — see `distance_field`'s `box` option, which pairs this with a
--- `visited` list so the caller never scans the stale region either.
---
--- `box` is {minx, miny, minz, maxx, maxy, maxz} in global cell coords.
---@param count integer  w*h*d of the FULL search space (arena size, for pooling).
---@param w integer  grid width.
---@param h integer  grid height.
---@param box table  {minx, miny, minz, maxx, maxy, maxz}.
---@return table s
function scratch.get_box(count, w, h, box)
    local s = pool[count]
    if s == nil then
        s = make(count)
        pool[count] = s
    end
    local minx, miny, minz = box[1], box[2], box[3]
    local maxx, maxy, maxz = box[4], box[5], box[6]
    local bw = maxx - minx + 1
    for z = minz, maxz do
        local zbase = (z * h) * w
        for y = miny, maxy do
            ffi.fill(s.state + zbase + y * w + minx, bw, 0)
        end
    end
    return s
end

return scratch
