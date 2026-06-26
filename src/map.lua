--- Map: a layered (z-major) 3D grid of tiles, stored SoA — one FFI array
--- per tile property, all in tight linear memory.
---
--- An *engine object*, not a game entity: Map (and Field) do not descend
--- from `Entity` (no position, doesn't tick). They are plain `class "X"`
--- — law 3's "engine object" case.
---
--- Layout (z-major, so a single Z-layer is contiguous in memory):
---
---     idx = ((z * H) + y) * W + x        -- 0-based; x fastest, then y, then z
---
--- This makes "stream one layer" (render, FOV) a linear scan and keeps
--- vertical queries (same x,y, +/-1 z) a constant stride of W*H apart.
---
--- Storage is schema-driven (see src/tile.lua). For each property, an
--- FFI array of the ctype that fits the field kind is allocated and
--- wrapped in a Field instance (one shared class, so `map.types.index`
--- and `map.flags.index` are the same function). `ffi.new` zero-fills,
--- and 0 is the null value for every field by convention, so a new map
--- is already initialized — no tile-init loop.
---
--- Access (field wrappers — `map.types` / `map.flags` / ...):
---   local t = map.types:index(x, y, z)   -- read one field at a tile
---   map.flags:set(x, y, z, TileFlags.Opaque)
---   map.types.index == map.flags.index   -- true: one shared function
---   map.types.cdata[i]                   -- raw cdata for hot loops
---
--- Whole-tile read:
---   local cell = map:index(x, y, z)      -- { types = ..., flags = ... }
---
--- Hot layer scans (bypass the wrapper for speed):
---   local lo, hi = map:layer_range(z)
---   for i = lo, hi do ... map.fields.types.cdata[i] ... end

local ffi = require("ffi")
local class = require("classes")
local tile = require("tile")

local FieldKind = tile.FieldKind

-- The FieldKind enum comes in as a table where integer keys ARE the values
-- (name<->value both ways). Pull the raw integer constants once so field
-- wrappers compare against numbers, not table lookups, in their hot methods.
local KIND_ENUM, KIND_INTEGER, KIND_DOUBLE, KIND_STRING =
    FieldKind.Enum, FieldKind.Integer, FieldKind.Double, FieldKind.String

--- Z-major linear index for (x, y, z) in a w*x h * d grid. 0-based; x
--- fastest, then y, then z. One formula used by Field.index/set and
--- Map:idx alike, so the layout lives in exactly one place.
---@param w integer
---@param h integer
---@param x integer
---@param y integer
---@param z integer
---@return integer
local function idx(w, h, x, y, z)
    return ((z * h) + y) * w + x
end

----------------------------------------------------------------------------------------------------
-- Field: a wrapper around one z-major FFI array for a single tile property.
-- All Field instances share the class table (so `map.types.index` and
-- `map.flags.index` are the same function); each instance carries its own
-- cdata, ctype, kind, and back-reference to its owning Map.
----------------------------------------------------------------------------------------------------

local Field = class("Field")

--- Construct a Field wrapping `count`-cell `ctype` array, bound to the
--- owning `map` (for string interning back-references).
---@param ctype string      e.g. "uint8_t", "int16_t", "const char*".
---@param kind integer      A FieldKind.* value.
---@param w integer
---@param h integer
---@param d integer
---@param map table         The owning Map (for String-field interning).
function Field:init(ctype, kind, w, h, d, map)
    self.ctype = ctype
    self.kind = kind
    self.w = w
    self.h = h
    self.d = d
    self.map = map
    self.cdata = ffi.new(ctype .. "[?]", w * h * d) -- zero-filled
end

--- Read this field's value at (x, y, z). String fields return the Lua
--- string (or nil for a null slot); numeric/enum fields return a number.
---@param x integer
---@param y integer
---@param z integer
---@return integer|number|string|nil
function Field:index(x, y, z)
    local i = idx(self.w, self.h, x, y, z)
    local v = self.cdata[i]
    if self.kind == KIND_STRING then
        -- A null const char* cdata compares == nil in LuaJIT.
        if v == nil then
            return nil
        end
        return ffi.string(v)
    end
    return v
end

--- Write `v` at (x, y, z). For String fields, `v` is interned into a
--- pinned char[] buffer (the bare pointer would dangle once the Lua
--- string is collected); the same content reuses one buffer.
---@param x integer
---@param y integer
---@param z integer
---@param v integer|number|string|nil
function Field:set(x, y, z, v)
    local i = idx(self.w, self.h, x, y, z)
    if self.kind == KIND_STRING then
        self.cdata[i] = self.map:intern(v)
    else
        self.cdata[i] = v
    end
end

----------------------------------------------------------------------------------------------------
-- Map class
----------------------------------------------------------------------------------------------------

local Map = class("Map")

--- Find the maximum integer value in an enum table.
--- Enum tables map name->value AND value->name; integer keys ARE the
--- values (game code shouldn't iterate enums, but this is infra).
---@param e table  An enum table.
---@return integer
local function enum_max_value(e)
    local max = 0
    for k in pairs(e) do
        if type(k) == "number" and k > max then
            max = k
        end
    end
    return max
end

--- Pick the narrowest unsigned ctype that fits an enum's max value.
---@param e table  An enum table.
---@return string ctype  e.g. "uint8_t", "uint16_t".
local function ctype_for_enum(e)
    local m = enum_max_value(e)
    if m <= 0xFF then
        return "uint8_t"
    elseif m <= 0xFFFF then
        return "uint16_t"
    elseif m <= 0xFFFFFFFF then
        return "uint32_t"
    else
        return "uint64_t"
    end
end

--- Pick the FFI ctype for a field spec.
---@param spec table  `{ kind = FieldKind.X, enum? = ..., bytes? = ... }`.
---@return string ctype
local function ctype_for_field(spec)
    local kind = spec.kind
    if kind == KIND_ENUM then
        return ctype_for_enum(spec.enum)
    elseif kind == KIND_INTEGER then
        return ("int%d_t"):format((spec.bytes or 4) * 8)
    elseif kind == KIND_DOUBLE then
        return "double"
    elseif kind == KIND_STRING then
        return "const char*"
    end
    error("Map: unknown field kind: " .. tostring(kind), 2)
end

--- Construct a layered map of size W x H x D.
--- Defaults to the engine tile schema (src/tile.lua); pass an explicit
--- `schema` only to swap schemas (e.g. for tests).
---@param w integer  Width (x).
---@param h integer  Height (y).
---@param d integer  Depth (z, number of layers).
---@param schema? table  Property name -> field spec (default: tile.schema).
function Map:init(w, h, d, schema)
    self.w = w
    self.h = h
    self.d = d
    self.count = w * h * d
    self.schema = schema or tile.schema
    self._strings = {} -- interned char[] buffers, pinned by this table

    -- One Field instance per property; all share the Field class table, so
    -- `map.types.index` and `map.flags.index` are the same function. The
    -- Field owns its z-major cdata array (zero-filled in Field:init).
    self.fields = {}
    for name, spec in pairs(self.schema) do
        local ct = ctype_for_field(spec)
        local f = Field(ct, spec.kind, w, h, d, self)
        self.fields[name] = f
        self[name] = f
    end
end

--- Linear index for (x, y, z). 0-based; x fastest, then y, then z.
---@param x integer
---@param y integer
---@param z integer
---@return integer idx
function Map:idx(x, y, z)
    return idx(self.w, self.h, x, y, z)
end

--- True if (x, y, z) is inside the map.
---@param x integer
---@param y integer
---@param z integer
---@return boolean
function Map:in_bounds(x, y, z)
    return x >= 0 and x < self.w and y >= 0 and y < self.h and z >= 0 and z < self.d
end

--- Inclusive index range [lo, hi] covering one whole Z-layer.
--- Use for cache-friendly linear scans:
---   local lo, hi = map:layer_range(z)
---   for i = lo, hi do ... map.fields.types.cdata[i] ... end
---@param z integer
---@return integer lo
---@return integer hi
function Map:layer_range(z)
    local lo = z * self.w * self.h
    return lo, lo + self.w * self.h - 1
end

--- Read every field at (x, y, z) into a fresh table, keyed by property
--- name: `{ types = ..., flags = ... }`. Allocates a table per call, so
--- prefer the field wrappers (`map.types:index(x,y,z)`) on hot paths.
---@param x integer
---@param y integer
---@param z integer
---@return table
function Map:index(x, y, z)
    local i = idx(self.w, self.h, x, y, z)
    local out = {}
    for name, f in pairs(self.fields) do
        out[name] = f:index(x, y, z)
    end
    return out
end

--- Intern a Lua string into a pinned `char[N+1]` buffer and return its
--- `const char*` (stable for the Map's lifetime; identical content reuses
--- one buffer). Storing a bare `const char*` in the SoA array would
--- dangle once the source Lua string is collected, so writes of String
--- fields go through here.
---@param s string
---@return any cdata  A `const char*` into a Map-owned buffer.
function Map:intern(s)
    local buf = self._strings[s]
    if buf == nil then
        buf = ffi.new("char[?]", #s + 1)
        ffi.copy(buf, s, #s)
        self._strings[s] = buf
    end
    return buf
end

return Map
