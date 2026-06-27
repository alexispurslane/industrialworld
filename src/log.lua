--- A leveled, categorized logger.
--
-- Singleton engine module (NOT a class): `local log = require("log")`.
-- Lua's module cache makes every require return one shared registry, so
-- all callers share the global level + sinks — the same shape as the
-- event bus (`bus`). There's nothing to subclass or pool, so the class
-- DSL buys nothing here; a registry of named loggers is just shared state
-- with methods.
--
-- Two filter layers:
--   1. GLOBAL floor via `log.set_level("debug")` or
--      `log.set_level(log.Level.Debug)`. Records below it are dropped
--      before any formatting. Default: Info.
--   2. PER-CATEGORY override via `log.set_category("ai", "trace")` to
--      crank ONE module up/down independent of the global; pass `nil` to
--      clear it (falls back to the global floor).
--
-- Named loggers: `local L = log.get("player"); L:info("moved %d,%d", x, y)`.
-- `log.get` is idempotent (one cached logger per name). A record is run
-- through `string.format` ONLY when there are extra args — a bare
-- `L:info("hi")` is emitted as-is (no format, no stray-% crash). The
-- format itself is pcall-guarded so a bad `%` can never tank the sim: a
-- malformed record is replaced by an error marker and the loop runs on.
--
-- Lazy variant for EXPENSIVE args. Lua is strict — call-site args are
-- evaluated regardless of filter, so to actually skip the work when
-- filtered, wrap it: `L:debug_lazy(function() return dump(world) end)`.
-- The builder runs ONLY if the level passes, and returns a single string.
--
-- Sinks: `log.add_sink(function(level, name, msg) ... end)` returns an
-- UNSUBSCRIBE function (same convention as `bus.on`). The default sink
-- writes `[LEVEL] name: msg` to io.stderr. Each sink is pcall-guarded so
-- one sink throwing never kills the emit or the others.

local enum = require("enums")

local Level = enum({
    Trace = 1,
    Debug = 2,
    Info = 3,
    Warn = 4,
    Error = 5,
})

-- Module state (file-local upvalues, like event.lua's `listeners`).
local floor = Level.Info -- global floor; records below dropped pre-format
local cats = {} -- name -> level int (per-category override; absent => floor)
local loggers = {} -- name -> cached logger (so log.get is shared/idempotent)
local sinks = {} -- ordered sink fns(level, name, msg); called per record

-- Short tag per level for the default stderr sink.
local LEVEL_TAG = {
    [Level.Trace] = "TRACE",
    [Level.Debug] = "DEBUG",
    [Level.Info] = "INFO",
    [Level.Warn] = "WARN",
    [Level.Error] = "ERROR",
}

local log = { Level = Level }

--- Normalize a level given as a name ("info" / "Info" / "INFO") or int (3).
--- Returns the int, or nil if the input names no level.
---@param x string|integer
---@return integer|nil
local function level_of(x)
    if type(x) == "string" then
        -- Case-insensitive: "trace"/"Trace"/"TRACE" -> "Trace".
        local cap = x:sub(1, 1):upper() .. x:sub(2):lower()
        return Level[cap]
    end
    if type(x) == "number" then
        -- Only 1..5 are real levels (Level[int] is the reverse-lookup name).
        return Level[x] and x or nil
    end
    return nil
end

--- Effective floor for a named logger: the per-category override if set,
--- else the global floor.
---@param name string
---@return integer
local function effective_level(name)
    local c = cats[name]
    if c ~= nil then
        return c
    end
    return floor
end

--- Format a record: literal `msg` when no extra args (sidesteps the
--- stray-% crash and the format cost), else `string.format`. pcall the
--- format so a malformed `%` becomes an error marker, never a throw.
---@param msg string
---@param ... any
---@return string
local function format_record(msg, ...)
    if select("#", ...) == 0 then
        return msg
    end
    local ok, s = pcall(string.format, msg, ...)
    if ok then
        return s
    end
    return ("(log format error: %s | fmt=%q)"):format(tostring(s), tostring(msg))
end

--- Dispatch one formatted record to every sink (pcall-guarded per sink so
--- a throwing sink never aborts the emit or starves the others).
---@param level integer
---@param name string
---@param msg string
local function dispatch(level, name, msg)
    for i = 1, #sinks do
        local ok, err = pcall(sinks[i], level, name, msg)
        if not ok then
            -- The failing sink can't be trusted with this; write the
            -- meta-error straight to stderr as the fallback of last resort.
            io.stderr:write(("log: sink %d threw: %s\n"):format(i, tostring(err)))
        end
    end
end

--- Emit a record at `level` for logger `name` if the filter passes.
---@param name string
---@param level integer
---@param msg string
---@param ... any
local function emit(name, level, msg, ...)
    if effective_level(name) > level then
        return
    end
    dispatch(level, name, format_record(msg, ...))
end

--- Emit via a builder fn, ONLY if the filter passes (real laziness: the
--- builder isn't called when filtered). Builder returns a single string.
---@param name string
---@param level integer
---@param builder fun():string
local function emit_lazy(name, level, builder)
    if effective_level(name) > level then
        return
    end
    local ok, s = pcall(builder)
    if ok then
        dispatch(level, name, s)
    else
        dispatch(level, name, ("(log builder error: %s)"):format(tostring(s)))
    end
end

-- The named-logger method table. An instance holds only `name`; methods
-- close over the shared emit/emit_lazy helpers + the Level constants.
local Logger = {}

function Logger:trace(msg, ...)
    emit(self.name, Level.Trace, msg, ...)
end

function Logger:debug(msg, ...)
    emit(self.name, Level.Debug, msg, ...)
end

function Logger:info(msg, ...)
    emit(self.name, Level.Info, msg, ...)
end

function Logger:warn(msg, ...)
    emit(self.name, Level.Warn, msg, ...)
end

function Logger:error(msg, ...)
    emit(self.name, Level.Error, msg, ...)
end

--- Lazy (builder) variants. The builder runs ONLY if the level passes, so
--- expensive arg computation is skipped when filtered out. Returns a
--- single string.
function Logger:trace_lazy(builder)
    emit_lazy(self.name, Level.Trace, builder)
end

function Logger:debug_lazy(builder)
    emit_lazy(self.name, Level.Debug, builder)
end

function Logger:info_lazy(builder)
    emit_lazy(self.name, Level.Info, builder)
end

function Logger:warn_lazy(builder)
    emit_lazy(self.name, Level.Warn, builder)
end

function Logger:error_lazy(builder)
    emit_lazy(self.name, Level.Error, builder)
end

--- Get (or create) the shared logger for `name`. Idempotent: the same name
--- returns the same cached logger table across all requires.
---@param name string  Category/module name (e.g. "player", "world", "ai").
---@return table logger  Has :trace/:debug/:info/:warn/:error + _lazy variants.
function log.get(name)
    local L = loggers[name]
    if L == nil then
        L = setmetatable({ name = name }, { __index = Logger })
        loggers[name] = L
    end
    return L
end

--- Set the global floor (records below dropped before formatting). Accepts
--- a level name ("debug") or int (`log.Level.Debug`). Unknown input is a
--- no-op (never throws).
---@param lvl string|integer
function log.set_level(lvl)
    local v = level_of(lvl)
    if v ~= nil then
        floor = v
    end
end

--- Set a per-category override (independent of the global floor), or clear
--- it by passing `nil`. Accepts a level name or int.
---@param name string
---@param lvl string|integer|nil
function log.set_category(name, lvl)
    if lvl == nil then
        cats[name] = nil
        return
    end
    local v = level_of(lvl)
    if v ~= nil then
        cats[name] = v
    end
end

--- Register a sink: `fn(level, name, msg)` is called for every emitted
--- record (post-filter, post-format), in add order. Returns an UNSUBSCRIBE
--- function (call to remove; idempotent) — same convention as `bus.on`.
---@param fn fun(level: integer, name: string, msg: string)
---@return function unsubscribe
function log.add_sink(fn)
    sinks[#sinks + 1] = fn
    local removed = false
    return function()
        if removed then
            return
        end
        removed = true
        for i = 1, #sinks do
            if sinks[i] == fn then
                table.remove(sinks, i)
                break
            end
        end
    end
end

--- The current global floor (read-only accessor; useful for tests/UI).
---@return integer
function log.level()
    return floor
end

-- Default sink: one line per record to stderr (`INFO  player: moved 23,10`).
log.add_sink(function(level, name, msg)
    io.stderr:write(("%-5s %s: %s\n"):format(LEVEL_TAG[level] or ("L" .. level), name, msg))
end)

return log
