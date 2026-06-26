package = "industrialworld"
version = "dev-1"

source = {
    url = ".",
}

description = {
    summary = "A standalone LuaJIT + libtcod wrapper project",
    detailed = "Standalone LuaJIT binary with ahead-of-time bytecode compilation, statically linking vendored libtcod and exposing it to Lua via safe FFI wrappers.",
    homepage = "https://github.com/example/industrialworld",
    license = "MIT",
}

dependencies = {
    "lua == 5.1",
}

build = {
    type = "builtin",
    modules = {
        industrialworld = "src/main.lua",
    },
}
