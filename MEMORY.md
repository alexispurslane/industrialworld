# Project Memory

This file is auto-maintained by the pi-memory extension.
It stores user preferences, key decisions, durable gotchas, and frequently-referenced files
so the agent can pick up context across sessions.

## Key Decisions

- alright, now let's make the world default-dark (invisible), put a field of view around the player and only render those tiles (cut off by how many z-layers above the player we are), and make memory also always render,...
- we should still do an x-ray hole in the visible z layers above the player
- alright, now we should remove all direct tile-teleporting used to move or fall the player, and use the implicit euler stuff exclusively, so we get a little basic silly physics engine
- we should add a friction coefficient to physicsobject, and also boost the acceleration the user's movement imparts to the player by a lot
- maybe we should just remove the snapping and do split frictio
- I think we should no longer split the impulse we send based on whether it's an edge in the input
- basically, I want the friction coefficient to come from whatever tile is under the player when the friction is currently being applied (so we should add a simple stationary physics body mixin to the tile types).
- like, on PhysicsObject:update(dt), we need to look at the whole path from where we were last to where we will end up now, and if one is not reachable from the other, we need to stop at the last place that was.
- I think, for one thing, to differentiate them, we should have the player's FOV not be limited in distance (except to stop at the viewport), only blocked by solid things, not falloff, just like our eyes aren't limited.
- _flags` that I never set in the opts table.

## Gotchas & Errors

- You were exactly right: the heavy dummy gets shoved, the soft-snap sees it wants to re-grid into the stairs cell, the stairs is a blocker — and soft-snap drops it on the floor instead of triggering...
- Let me fix soft-snap: when the target cell is blocked, it should emit a collision there (so stairs shunts, knockback fires) before zeroing v — exactly like the swept march does.
- Now fix `soft_snap_axis`: when the target cell is blocked, emit a collision there (resting at the near boundary) instead of silently arresting.
- When the target cell is blocked: rest at the near boundary, emit a collision (so stairs shunt / knockback fire), and zero v.
- 5, below the old soft-snap threshold) shunts on a single shove, because soft-snap now emits a collision when it wants to re-grid into the blocked stairs cell, instead of silently arresting.
- Factored the collision-emit logic (collision event + momentum capture + knockback) into a shared **`hit_blocker(axis, blk, mv)`** — both the swept march and soft-snap call it, so they can't drift...
- The earlier "FAIL" was just a test-setup artifact (walls placed at distance 8–10 against a radius-8 light sit at the falloff edge).
- (no output)

## Heavily Read

- /Users/alexispurslane/Development/industrialworld/src/world.lua (6 reads) — The user just wants the file fixed. Let me read the current state of the file ar
- /Users/alexispurslane/Development/industrialworld/src/fov.lua (6 reads)
- /Users/alexispurslane/Development/industrialworld/src/pathfinding/grid.lua (3 reads)
