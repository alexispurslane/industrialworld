# Project Memory

This file is auto-maintained by the pi-memory extension.
It stores user preferences, key decisions, durable gotchas, and frequently-referenced files
so the agent can pick up context across sessions.

## Key Decisions

- for the pause and main screens, let's use the serif font, not the tile font.
- since we now have a UI layer, we should add clicks and hovers (with {x,y} data) to the event bus, and make a function that will blit in a button, which just consists of rendering some text, and setting up an event...
- let's create a progress bar ui thing, that renders filled boxes (so, we should use bg color), and sets up a listener for an event based on the id provided to it that tells it what percent to fill to next, and also...
- for the tests, a raycast or set of raycasts is probably fine; for the list of tiles/entities, we should probably use a field or something
- alright, now let's make the world default-dark (invisible), put a field of view around the player and only render those tiles (cut off by how many z-layers above the player we are), and make memory also always render,...
- we should still do an x-ray hole in the visible z layers above the player
- alright, now we should remove all direct tile-teleporting used to move or fall the player, and use the implicit euler stuff exclusively, so we get a little basic silly physics engine
- we should add a friction coefficient to physicsobject, and also boost the acceleration the user's movement imparts to the player by a lot
- maybe we should just remove the snapping and do split frictio
- I think we should no longer split the impulse we send based on whether it's an edge in the input

## Gotchas & Errors

- Now: skylight visible, blocker faces visible, cells beyond blockers NOT visible.
- Tested: axis/diagonal/vertical/degenerate/blocked all correct.
- lua`)
- Rays are now **3D** — they climb through layers, blocked by any `Opaque` voxel.
- Validation failed for tool "edit": — Fix: Try it — tapping should give crisp 1-cell steps and holding should slide.
- Let me run it interactively via tmux so I can send a keypress programmatically and capture what `vk` values BLT produces, since I can't easily press a key in the GUI window myself.
- Let me remove the broken TRACE and write a proper standalone BLT key-event logger that I can reason about, then check whether BLT actually delivers keyUp for arrow keys at all.
- Let me also remove the broken TRACE print I left in:

## Heavily Read

- /Users/alexispurslane/Development/industrialworld/src/main.lua (17 reads) — #6 — per-frame camera sync + drop the `moved` event. Main.lua first:
- /Users/alexispurslane/Development/industrialworld/src/world.lua (9 reads) — The friction test case got mangled — let me fix it to do both checks in one play
- /Users/alexispurslane/Development/industrialworld/AGENTS.md (4 reads) — Now let me find the Mechanics section to add a Physics subsection. Let me look a
- /Users/alexispurslane/Development/industrialworld/src/mixins/physics_object.lua (13 reads) — we should add a friction coefficient to physicsobject, and also boost the accele
- /Users/alexispurslane/Development/industrialworld/src/player.lua (6 reads) — Now wire the player to subscribe to `move_release` and call `snap_to_cell`. Let
