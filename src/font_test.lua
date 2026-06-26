--- Font charmap diagnostic.
--- Renders a known string with each of the three charmaps and saves a
--- screenshot per charmap into the working dir so we can eyeball which
--- layout matches terminal.png.
local tcod = require("industrialworld.tcod")

local function put_str(con, x, y, str, fg)
    for i = 1, #str do
        con:put_char(
            x + (i - 1),
            y,
            string.byte(str, i),
            fg or tcod.colors.white,
            tcod.colors.black
        )
    end
end

local function try(label, charmap)
    local cols, rows = 48, 6
    local tileset
    if charmap == "identity" then
        tileset = tcod.Tileset.load_font("terminal.png", 32, 8, nil)
    else
        tileset = tcod.Tileset.load_font(
            "terminal.png",
            32,
            8,
            charmap == "tcod" and tcod.charmap_tcod or tcod.charmap_cp437
        )
    end
    if not tileset then
        io.stderr:write(("charmap=%s: failed to load tileset\n"):format(label))
        return
    end
    local ctx = tcod.Context.new({
        columns = cols,
        rows = rows,
        window_title = label,
        renderer = tcod.renderer_sdl2,
        tileset = tileset,
    })
    if not ctx then
        io.stderr:write(("charmap=%s: no ctx\n"):format(label))
        return
    end
    local con = tcod.Console.new(cols, rows)
    if not con then
        io.stderr:write(("charmap=%s: no console\n"):format(label))
        ctx:shutdown()
        return
    end
    con:clear()
    put_str(con, 1, 1, "ABCDEFG abcde 0123 #")
    put_str(con, 1, 2, "The quick brown fox")
    put_str(con, 1, 3, "industrialworld")
    ctx:present(con)
    local out = ("font_test_%s.png"):format(label)
    ctx:screenshot(out)
    io.stderr:write(("charmap=%s: saved %s\n"):format(label, out))
    -- brief sleep so SDL flushes the framebuffer/screenshot before teardown
    os.execute("sleep 0.4")
    con:shutdown()
    ctx:shutdown()
end

try("identity", "identity")
try("cp437", "cp437")
try("tcod", "tcod")
return 0
