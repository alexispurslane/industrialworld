# Project Memory

This file is auto-maintained by the pi-memory extension.
It stores user preferences, key decisions, durable gotchas, and frequently-referenced files
so the agent can pick up context across sessions.

## Key Decisions

- let's create a progress bar ui thing, that renders filled boxes (so, we should use bg color), and sets up a listener for an event based on the id provided to it that tells it what percent to fill to next, and also...
- for the tests, a raycast or set of raycasts is probably fine; for the list of tiles/entities, we should probably use a field or something
- alright, now let's make the world default-dark (invisible), put a field of view around the player and only render those tiles (cut off by how many z-layers above the player we are), and make memory also always render,...
- we should still do an x-ray hole in the visible z layers above the player
- alright, now we should remove all direct tile-teleporting used to move or fall the player, and use the implicit euler stuff exclusively, so we get a little basic silly physics engine
- we should add a friction coefficient to physicsobject, and also boost the acceleration the user's movement imparts to the player by a lot
- maybe we should just remove the snapping and do split frictio
- I think we should no longer split the impulse we send based on whether it's an edge in the input
- basically, I want the friction coefficient to come from whatever tile is under the player when the friction is currently being applied (so we should add a simple stationary physics body mixin to the tile types).
- like, on PhysicsObject:update(dt), we need to look at the whole path from where we were last to where we will end up now, and if one is not reachable from the other, we need to stop at the last place that was.

## Gotchas & Errors

- The soft-snap **does** test the snap target cell for a blocker — but it does nothing on a successful snap.
- Soft-snap finds a blocked target cell and just...
- You were exactly right: the heavy dummy gets shoved, the soft-snap sees it wants to re-grid into the stairs cell, the stairs is a blocker — and soft-snap drops it on the floor instead of triggering...
- Let me fix soft-snap: when the target cell is blocked, it should emit a collision there (so stairs shunts, knockback fires) before zeroing v — exactly like the swept march does.
- Now fix `soft_snap_axis`: when the target cell is blocked, emit a collision there (resting at the near boundary) instead of silently arresting.
- When the target cell is blocked: rest at the near boundary, emit a collision (so stairs shunt / knockback fire), and zero v.
- 5, below the old soft-snap threshold) shunts on a single shove, because soft-snap now emits a collision when it wants to re-grid into the blocked stairs cell, instead of silently arresting.
- Factored the collision-emit logic (collision event + momentum capture + knockback) into a shared **`hit_blocker(axis, blk, mv)`** — both the swept march and soft-snap call it, so they can't drift...

## Heavily Read

- /Users/alexispurslane/Development/industrialworld/src/mixins/physics_object.lua (7 reads) — Let me check for the now-unused snapshot in `swept_move_axis`:
- /Users/alexispurslane/Development/industrialworld/src/world.lua (4 reads) — Now the load-bearing change — task #6, the occupancy hash in world.lua. Let me r
