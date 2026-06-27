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

return scratch
