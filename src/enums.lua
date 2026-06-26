--- A tiny integer-enum DSL.
---
--- Exposes an `enum` function (wired as a global by `main.lua`) for defining
--- integer-backed enums. Three forms:
---
---     -- list (auto-increments from 1):
---     local Tile = enum("Floor", "Wall", "Door")
---     --   Tile.Floor=1, Tile.Wall=2, Tile.Door=3
---
---     -- explicit values (any integers you choose):
---     local Status = enum { Ok = 0, Warn = 1, Err = 2 }
---
---     -- bitflags (1, 2, 4, 8, ...):
---     local Flag = enum.flags("Visible", "Solid", "Opaque")
---     --   Flag.Visible=1, Flag.Solid=2, Flag.Opaque=4
---
--- Reverse lookup works both ways:
---     Tile.Wall    -> 2         (name -> value)
---     Tile[2]      -> "Wall"   (value -> name)
---
--- Don't iterate enums with pairs/ipairs — index them. Reverse-lookup
--- integer keys share the table with name keys, so there's nothing useful
--- to iterate.

--- Build an enum table from an ordered list of names and a value function.
---@param names string[]  Declaration-order names.
---@param value_of fun(name: string): integer  Maps a name to its value.
---@return table e  The enum table (name->value AND value->name).
local function make(names, value_of)
    local e = {}
    for _, name in ipairs(names) do
        local v = value_of(name)
        e[name] = v
        e[v] = name
    end
    return e
end

--- Normalize the args of a list/flags form into an ordered name list.
--- Each vararg arg is a name string.
---@param ... string|table  Names (non-strings are rejected at runtime).
---@return string[] names
local function namelist(...)
    local names = {}
    for _, a in ipairs({ ... }) do
        if type(a) ~= "string" then
            error("enum: names must be strings, got " .. type(a))
        end
        names[#names + 1] = a
    end
    return names
end

--- Define an integer enum.
---   enum("A", "B", "C")          -- auto-increment from 1
---   enum { A = 1, B = 2, C = 4 } -- explicit values
---@param ... string|table  Names, or an explicit table.
---@return table e  The enum table.
local function define(...)
    local args = { ... }
    -- Explicit table form: { Name = value, ... }
    local first = args[1]
    if #args == 1 and type(first) == "table" then
        local spec = first
        local names = {}
        for k in pairs(spec) do
            if type(k) ~= "string" then
                error("enum: explicit form keys must be names (strings)", 2)
            end
            names[#names + 1] = k
        end
        return make(names, function(name)
            return spec[name]
        end)
    end

    -- List form: auto-increment from 1.
    local names = namelist(...)
    local next_v = 1
    return make(names, function()
        local v = next_v
        next_v = next_v + 1
        return v
    end)
end

return setmetatable({
    --- Define a bitflag enum: each name gets 1, 2, 4, 8, ...
    ---   enum.flags("Visible", "Solid", "Opaque")
    ---@param ... string|table  Names (non-strings are rejected at runtime).
    ---@return table e  The enum table.
    flags = function(...)
        local names = namelist(...)
        local bit = 1
        return make(names, function()
            local v = bit
            bit = bit * 2
            return v
        end)
    end,
}, {
    __call = function(_, ...)
        return define(...)
    end,
})
