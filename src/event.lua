--- A tiny pub/sub event bus.
---
--- Engine object (NOT a class — no instances; a module with a shared
--- registry). Use for cross-system signaling: a Health mixin emits
--- "damaged"; a Flammable mixin subscribed to it can react; the render
--- loop subscribes to "player_moved" to refocus the camera.
---
--- Subscribe with `bus.on(name, cb)` — returns an UNSUBSCRIBE function:
--- call it to remove the handler (no handle IDs to track). Items are
--- removed by filtering the listener array (small N per event, fine).
---
--- Emit with `bus.emit(name, ...)` — the vararg tail is the payload,
--- passed to each handler. `bus.emit("moved", player, dx, dy)` lets the
--- subscriber decide arg shape; no forced payload-table allocation.
---
--- `emit` iterates a SNAPSHOT of the current listeners (copied via
--- `{...}`), so a handler that subscribes/unsubscribes during dispatch
--- doesn't corrupt iteration. Handlers run in subscribe order; no
--- priority system (keep it predictable).

local bus = {}

local log = require("log")
local L = log.get("bus")

-- listeners[name] = { cb, cb, ... }  (ordered; subscribe order preserved)
local listeners = {}

--- Subscribe to `name`. Returns a function that, when called, removes
--- this subscription. Calling the returned function more than once is a
--- safe no-op after the first.
---@param name string  Event name.
---@param cb function  Handler: `cb(...)` receives emit's payload.
---@return function unsubscribe  Call to remove this subscription.
function bus.on(name, cb)
    L:trace("on %s", name)
    local list = listeners[name]
    if list == nil then
        list = {}
        listeners[name] = list
    end
    list[#list + 1] = cb
    local removed = false
    return function()
        if removed then
            return
        end
        removed = true
        local cur = listeners[name]
        if cur ~= nil then
            for i = 1, #cur do
                if cur[i] == cb then
                    table.remove(cur, i)
                    break
                end
            end
        end
    end
end

--- Emit `name`, calling every current subscriber with `...` as args.
--- Iterates a snapshot so handlers may safely subscribe/unsubscribe
--- during dispatch. A handler erroring aborts the dispatch (re-raises);
--- guard inside handlers if you want isolated failures.
---@param name string  Event name.
---@param ... any       Payload forwarded to each handler.
function bus.emit(name, ...)
    local list = listeners[name]
    if list == nil then
        return
    end
    L:trace("emit %s (%d subs)", name, #list)
    -- Snapshot: a handler may unsubscribe itself (or add a new sub) mid-
    -- dispatch. The snapshot freezes the set for THIS emit; the live list
    -- is what future emits see. Built with a loop (not table.unpack):
    -- LuaJIT exposes `unpack` as a global, not table.unpack, and a loop
    -- sidesteps the 5.1/5.2 portability split.
    local n = #list
    local snap = {}
    for i = 1, n do
        snap[i] = list[i]
    end
    for i = 1, n do
        snap[i](...)
    end
end

--- Subscribe to `name` and register the unsubscribe fn on `target`'s
--- teardown list (`target._unsubs`). Mixins call this from their `init`
--- (passing the instance as `target`) so subscriptions are tracked for
--- bulk teardown on Entity:destroy (world.destroy walks `target._unsubs`).
--- The instance owns one flat `_unsubs` list shared across all its mixins
--- (law 5: flat self); multiple mixins append to the same list.
---@param target table  The instance (the mixin's `self`).
---@param name string   Event name.
---@param cb function   Handler: `cb(...)` receives emit's payload.
function bus.subscribe(target, name, cb)
    local unsubs = rawget(target, "_unsubs")
    if unsubs == nil then
        unsubs = {}
        target._unsubs = unsubs
    end
    unsubs[#unsubs + 1] = bus.on(name, cb)
end

return bus
