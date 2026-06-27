--- Centralized color palette for industrialworld.
---
--- Derived from the Carrie Blast Furnaces / Homestead steelworks:
--- stormy slate skies, oxidized iron, weathered concrete, soot-black
--- shadows, and the faded yellow of safety railings. All colors are
--- {r,g,b} tables so they pass straight through blt.to_color.
---
--- Keep this module dependency-free and side-effect-free: it is pure
--- data. Other modules `local palette = require("palette")` and read
--- named colors; do not mutate the table at runtime.

local palette = {
    -- Voids and deep shadows ------------------------------------------------
    soot       = { r =  10, g =  10, b =  14 }, -- open-air void / panel bg
    night      = { r =  18, g =  18, b =  22 }, -- unlit corners
    iron       = { r =  30, g =  30, b =  34 }, -- dark iron, stairs bg

    -- Steel and stone -------------------------------------------------------
    slate      = { r =  55, g =  60, b =  68 }, -- storm sky, wall glyph
    graphite   = { r =  70, g =  75, b =  90 }, -- rules / dividers
    steel      = { r = 100, g = 105, b = 110 }, -- bare structural steel
    concrete   = { r = 125, g = 115, b = 105 }, -- weathered wall fill
    silver     = { r = 160, g = 162, b = 160 }, -- "Pittsburgh Steel Gray"
    smoke      = { r = 140, g = 145, b = 150 }, -- exhaust / pipes

    -- Rust and brick --------------------------------------------------------
    rust_dark  = { r =  90, g =  40, b =  25 }, -- deep oxidation
    brick      = { r = 130, g =  60, b =  40 }, -- old furnace brick
    rust       = { r = 160, g =  75, b =  45 }, -- surface rust
    rust_light = { r = 200, g = 130, b =  95 }, -- rust highlights

    -- Earth and grime -------------------------------------------------------
    mud        = { r =  90, g =  75, b =  50 }, -- dirty metal, stains
    grain      = { r = 140, g = 125, b =  90 }, -- floor grid / ramp highlight
    moss       = { r =  70, g =  85, b =  55 }, -- grime/moss on ruins

    -- Accents ---------------------------------------------------------------
    safety_yellow = { r = 210, g = 170, b =  35 }, -- faded caution paint
    forge_orange  = { r = 230, g = 120, b =  40 }, -- hot metal accent

    -- Text / UI -------------------------------------------------------------
    text       = { r = 220, g = 220, b = 225 }, -- main readable text
    text_dim   = { r = 200, g = 200, b = 205 }, -- secondary text
    panel_dim  = { r =  24, g =  26, b =  34 }, -- age-dim target
    cyan       = { r =  80, g = 200, b = 220 }, -- down-stairs marker

    -- Pure tones ------------------------------------------------------------
    black      = { r =   0, g =   0, b =   0 },
    white      = { r = 255, g = 255, b = 255 },
}

-- A few shorthand aliases for the most common tile-material pairings, so
-- map definitions read in vocabulary rather than raw RGB names.
palette.floor_bg = palette.night
palette.floor_fg = palette.grain
palette.wall_bg  = palette.concrete
palette.wall_fg  = palette.slate
palette.stairs   = palette.text

return palette
