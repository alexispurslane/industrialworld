--- Binary min-heap keyed by priority.
--
-- INTERNAL helper for the searchers in this subpackage; not re-exported
-- from `init.lua`. Stores arbitrary integer `item` payloads (the searchers
-- feed it linear cell indices) ordered by an `int32` priority (g-score
-- for Dijkstra, f-score for A*). Plain Lua array storage is plenty fast
-- here: the heap is per-search transient state, not per-frame hot path,
-- and LuaJIT compiles the array ops to native anyway.
--
-- This is a Classic array-backed binary heap:
--   • children of index i live at 2i, 2i+1; parent at floor(i/2).
--   • `_h` holds [prio,item] pairs flat: prio at odd indices, item at even.
--   • push/pop are O(log n); the stored item is the SMALLEST prio.

local heap = {}

--- Construct an empty min-heap.
---@return table h  A heap object with :push/:pop/:peek/:empty.
function heap.new()
    return { _h = {}, _n = 0 }
end

local function swap(h, i, j)
    local a = h._h
    local pi, it = a[i], a[i + 1]
    a[i], a[i + 1] = a[j], a[j + 1]
    a[j], a[j + 1] = pi, it
end

--- Insert `item` with integer `prio`. Duplicates allowed (FIFO-unstable
--- on tie; searchers treat equal-prio cells as commensurate).
---@param h table   A heap from heap.new.
---@param prio integer
---@param item integer
function heap.push(h, prio, item)
    local a = h._h
    local i = h._n * 2 + 1
    h._n = h._n + 1
    a[i], a[i + 1] = prio, item
    -- sift up
    while i > 1 do
        local parent = math.floor((i - 1) / 2) * 2 + 1
        if a[i] < a[parent] then
            swap(h, i, parent)
            i = parent
        else
            break
        end
    end
end

--- Remove and return the lowest-priority item, or nil if empty.
---@param h table
---@return integer|nil item
---@return integer|nil prio
function heap.pop(h)
    local n = h._n
    if n == 0 then
        return nil, nil
    end
    local a = h._h
    local top_item = a[2]
    local top_prio = a[1]
    -- move last to root
    local last = (n - 1) * 2 + 1
    a[1], a[2] = a[last], a[last + 1]
    a[last], a[last + 1] = nil, nil
    h._n = n - 1
    -- sift down
    local i = 1
    n = h._n
    while true do
        local l = i * 2 + 1
        if l > n * 2 then
            break
        end
        local r = l + 2
        local smallest = i
        if l <= n * 2 and a[l] < a[smallest] then
            smallest = l
        end
        if r <= n * 2 and a[r] < a[smallest] then
            smallest = r
        end
        if smallest == i then
            break
        end
        swap(h, i, smallest)
        i = smallest
    end
    return top_item, top_prio
end

return heap
