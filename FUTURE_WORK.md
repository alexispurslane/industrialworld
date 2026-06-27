# Future Work

This is a ranked list of the biggest engine gaps to fill before (or
alongside) gameplay work. Items near the top give the most design freedom
for the effort.

## 1. Field of View / Sight / Lighting

Right now the map renderer draws everything. A roguelike engine needs a
visibility system so the player (and eventually NPCs) only see what they
can see.

- DONE: 2D or 3D FOV from the camera/player position.
- "Explored but not currently visible" rendering.
- Optional dynamic light sources (torches, forges, windows).
- Should feed into the existing render_map depth/ceiling pass, not fight
  it.

## 2. Save / Load / Serialization

Map SoA data, entity state, world state, bus listeners, and config all
live in memory only.

- Serialize the Map's tile fields to a binary or compact format.
- Serialize living entities (flat `self` tables make this tractable but
  need a schema per archetype).
- Restore event subscriptions after load.
- Autosave slots and a user-writable save directory.

## 3. Richer UI Toolkit

Buttons and progress bars are a good start, but a real game needs more.

- DONE: Panel/frame primitive with borders and background fill.
- DONE: Clipped / scrolling text areas (the message log already wants this).
- DONE: Layout helpers so screens stop hand-computing `centered_x`.
- Focus management and tab order for keyboard-driven UI.
- DONE: Z-ordered widget layers and modal overlays.
- DONE: A simple settings menu to prove the toolkit works end-to-end.

## 4. Pathfinding and Spatial Queries

Collision and occupancy exist, but there's no route-finding.

- DONE: A* on the map grid, respecting z-levels, stairs, and ramps where
  appropriate.
- DONE: Radius/circle queries for explosions, shouts, area effects.
- DONE: Raycast for line-of-sight, projectiles, and ranged targeting.
- DONE: Filter by collision mask / faction.

## 5. Audio

No sound yet.

- SFX event channel (e.g. `bus.emit("sfx", "clang")`).
- Background music switching by game state / area.
- Volume categories and muting.

## 6. Config, Keybindings, and Save Directory

Input and logging are hardcoded or env-var driven.

- Load keybindings from a user config file.
- Window/fullscreen, volume, and accessibility settings.
- Use a proper OS save directory instead of the repo root.

## 7. Turn Scheduling / Action Economy

The main loop is purely real-time `update(dt)`. A turn-based or hybrid
system will need a scheduler.

- Energy / action-point system for actors.
- Real-time vs. turn-based mode switch (or a hybrid pause-on-input
  model).
- Animations that play during turns without breaking scheduling.

## 8. Error Boundaries and Debugging Tools

A throwing handler currently aborts the real-time loop or bus dispatch.

- Top-level pcall that logs and continues in dev mode.
- In-game debug overlay (FPS, entity count, recent log lines).
- Frame-stepping and slow-motion for debugging movement/collision.

---

Resolving the items above keeps the engine "game-ready" regardless of
which specific game you build on top of it.
