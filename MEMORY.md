# Project Memory

This file is auto-maintained by the pi-memory extension.
It stores user preferences, key decisions, durable gotchas, and frequently-referenced files
so the agent can pick up context across sessions.

## Key Decisions

- we should use manual compositing with the colors on the lower layers for the bg, if what you say is true that BLT doesn't layer bgs; but use BLT's layering to composite the two *symbols* together
- for the pause and main screens, let's use the serif font, not the tile font.
- since we now have a UI layer, we should add clicks and hovers (with {x,y} data) to the event bus, and make a function that will blit in a button, which just consists of rendering some text, and setting up an event...
- let's create a progress bar ui thing, that renders filled boxes (so, we should use bg color), and sets up a listener for an event based on the id provided to it that tells it what percent to fill to next, and also...
- for the tests, a raycast or set of raycasts is probably fine; for the list of tiles/entities, we should probably use a field or something
- alright, now let's make the world default-dark (invisible), put a field of view around the player and only render those tiles (cut off by how many z-layers above the player we are), and make memory also always render,...
- we should still do an x-ray hole in the visible z layers above the player

## Gotchas & Errors

- `can_reach` returning `false` when the blocker sits on the only path is **correct** behavior.
- So the test data was just contrived badly — `skip-target` correctly allows you to reach an entity standing *on a non-bottleneck cell*; it doesn't help when an unrelated blocker sits on the only bridge.
- Let me confirm skip-target actually works with a blocker that's NOT on the bottleneck:
- Confirmed working: `can_reach` reaches the target with an off-path blocker present (`true`), proving skip-target works correctly — the earlier `false` was because the barrel sat on the only path...
- That's wrong: a blocker cell blocks ALL rays through it, even if it's already been seen.
- Now: skylight visible, blocker faces visible, cells beyond blockers NOT visible.
- Tested: axis/diagonal/vertical/degenerate/blocked all correct.
- lua`)
- Rays are now **3D** — they climb through layers, blocked by any `Opaque` voxel.

## Heavily Read

- /Users/alexispurslane/Development/industrialworld/src/main.lua (4 reads) — Let me explore the rendering setup, world, player, and map to understand the cur
- /Users/alexispurslane/Development/industrialworld/src/world.lua (18 reads) — Now let me look at `world.render_map` and `draw_entities` closely, plus the came
- /Users/alexispurslane/Development/industrialworld/src/fov.lua (3 reads) — Now task #2: rewrite fov natively 3D. Let me read the rest of the current fov.lu
