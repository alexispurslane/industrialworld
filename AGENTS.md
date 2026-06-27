# industrialworld — agent notes

## Architecture

A single-process LuaJIT host that statically links BearLibTerminal
(BLT). The C side (`src/main.c`) is intentionally thin: it preloads every
compiled Lua module into `package.preload` and then runs the `main`
module. BLT owns the window; the Lua side's real-time loop drives
rendering + input via BLT's immediate-mode API (there is no blocking
event loop — `terminal_open()` returns immediately after the non-modal
Cocoa patch, and the loop calls `refresh()`/`has_input()`/`read()` per
frame).

## Vendored dependencies

- `vendor/luajit` — vendored LuaJIT, built once into `libluajit.a` + the
  `luajit` bytecode-compiler tool.
- `vendor/bearlibterminal` — shallow clone of the BearLibTerminal repo.
  Built as a static library via CMake; BLT ships its own FreeType +
  PicoPNG + NanoJPEG in-tree (under `Terminal/Dependencies/`), so there
  are NO external git deps — only macOS frameworks (OpenGL + Cocoa).
- `vendor/fonts` — DejaVu TTFs (Sans, SansMono, Serif). SansMono is the
  base tileset (anti-aliased ASCII + box-drawing + block-element glyphs);
  Sans is loaded at the Private Use Area (0xE000+) for the messages
  panel. BLT's global codespace resolves per-cell by codepoint, so both
  fonts coexist on screen simultaneously.

## Build flow (see `justfile`)

1. `build-luajit` — `make` in `vendor/luajit`.
2. `compile-bytecode` — `luajit -b` per `.lua` → `build/bytecode_*.h`,
   plus generated `includes.inc` / `modules.inc`.
3. `compile-blt` — `cmake -S vendor/bearlibterminal -B build/bearlibterminal`
   with `BUILD_SHARED_LIBS=OFF`, then `cmake --build`.
4. `compile-binary` — clang links `src/main.c` + `libluajit.a` +
   `libBearLibTerminal.a` + `libfreetype2.a` + `libpicopng.a` with
   `-Wl,-export_dynamic`.

The `-export_dynamic` link flag is what lets `ffi.C` resolve BLT symbols
(`terminal_put`, `terminal_set8`, etc.): it exports the executable's
symbols into the dynamic symbol table so LuaJIT's dlsym-based lookup
finds them.

### Required BLT patch

BLT's `CocoaWindow::Construct()` calls `[NSApp run]`, a modal run loop
that blocks until the app terminates — incompatible with a Lua host that
owns the main thread. The vendored source is patched to call
`[NSApp finishLaunching]` + `activateIgnoringOtherApps:` instead; BLT's
`PumpEvents()` (called from `refresh()`/`read()`) drives the run loop
iteratively, as it does on Linux/Windows.

## OOP convention

Game entities use the OOP DSL in `src/classes.lua`, wired as globals
`class`, `mixin`, and `enum` by `main.lua` (whitelisted in
`.luarc.json`).

**Globals policy**: ONLY the external DSL keywords (`class`, `mixin`,
`enum`) are global. Everything else — the world (`world`), the event
bus (`bus`), `allocate`/`destroy`, the renderers, and engine-object
classes like `Map` — is reached via `require` (e.g.
`local world = require("world")`, `local bus = require("event")`). These
modules are singletons (Lua's module cache returns the same table on
every require), so all callers share one world and one bus. Don't add
new `_G.x = ...` exports; require instead.

### Laws

1. **Mixins define all specific capabilities — state AND methods.**
   A mixin bundles the state and the methods for one narrow capability
   ("can be hurt" -> `hp`, `is_dead`, `damage`). Leaf mixins are narrow,
   orthogonal, and know nothing about other mixins or classes.
   Capabilities come from mixins, never from the base class or subclasses.

2. **Cross-capability orchestration lives in composed mixins.**
   `mixin({}, Flammable, Soakable)` builds a new mixin whose methods are
   *flat-copied* from its leaves (first-wins; a composed mixin overrides a
   leaf by redefining the method on itself). A composed mixin is itself a
   mixin — pass it to `class(...):mixin(...)` or to another
   `mixin({}, ...))` and composition recurses (so a class that mixes Burning
   gets Flammable + Soakable + Burning's overrides in one go). Emergent
   behavior that only exists at a particular intersection of capabilities
   (burning + wet -> don't ignite) is *reusable across archetypes* (Torch,
   Wizard, Campfire all burn) and *coordinates multiple* mixins — so it
   belongs as an override on a composed mixin: read/write sibling-leaf state,
   delegate to named leaves (`Flammable.light(self)`). If you find
   orchestration creeping into a subclass, it is reusable and belongs in a
   mixin. (This is the substitute for an intra-entity message bus / full ECS;
   we deliberately don't have one.)

   *How flat copy works (implications to know):*
   - **No late binding.** Methods are copied at composition time. Define
     leaves fully before composing; re-compose if a leaf changes.
   - **No MRO / no diamond / no `super` across mixins.** Delegation to a
     leaf is by *naming the leaf table* explicitly: `Flammable.light(self)`.
     There is no chain to walk, so `super` is never used for mixins.
   - **Name collisions are first-wins, silently.** If two leaves define the
     same method, the earlier-mixed one wins; the later is dropped unless
     the composed mixin overrides. Override on the composed mixin to merge
     (and call both leaves by name).
   - **`self` is one flat table.** All mixin state (leaf or composed) lives
     un-namespaced on the instance (law 5); a composed mixin reads
     sibling-leaf state directly (`self.wet`). There are no per-mixin
     subtables or scopes.

3. **Subclasses are archetypes; only game-entity archetypes descend
   from `Entity`.** There are two kinds of class, and the distinction
   matters:
   - *Game entities* (Goblin, Torch, Player) participate in the world and
     the update loop. They subclass `Entity` (+ mixins) and are the only
     things law 4's "one base class" rule applies to.
   - *Engine objects* (Map, Scheduler, EventBus, RNG) are not entities:
     they don't tick, aren't in the world, have no position. They are
     plain `class "Foo"` / `class("Foo", Parent)` with no `Entity` parent.
     Use them for containers, systems, and data structures.

   Either way, a subclass is a named, instantiable *kind of thing* — a
   preset bundle of base + mixins under one name. It carries
   *identity-specific* behavior and state (Goblin's loot table vs Orc's;
   `FastZombie`'s faster `move`). Identity-specific overrides extend the
   parent archetype via `super.method(self, ...)` (single inheritance;
   `super` = the one parent). A subclass does NOT do cross-capability
   orchestration — that is a composed mixin (law 2). Decision test: if the
   behavior is reusable across archetypes OR coordinates multiple
   capabilities, it's a mixin; if it is specific to this one kind, it's a
   subclass.

4. **One base class for game entities: `Entity`.** It carries SOLELY the update-loop
   protocol: a single `:update(dt)` hook the game loop calls per frame
   per entity (plus a no-op `init` so archetypes can unconditionally
   delegate `super.init(self)` without nil-guarding). Every capability —
   position, rendering, health, movement, input, etc. — is a mixin
   layered onto the one base, never the base itself, per law 1. Keep
   subclass hierarchies shallow (aim for <=2 levels under `Entity`).

5. **Mixin state is NOT namespaced.** Write `self.hp`, not
   `self.Health.hp`. State is owned by its mixin (which sets/reads it)
   and may be read, intentionally, by composed-mixin orchestration and
   by an archetype's identity code. There are no per-mixin subtables;
   `self` is flat (see law 2), which is exactly why this is safe.

### Mechanics

- Single inheritance only. `class("Name", Parent)` returns `(cls, parent)`;
  capture `super = parent` for parent delegation in one line:
  `local Enemy, super = class("Enemy", Entity):mixin(Health, Movable)`.
- `super` delegates to the PARENT only. Two legitimate uses: (a) parent
  `init` (`super.init(self, x, y)`) and (b) identity-specific
  override-and-extend on the parent archetype
  (`function FastZombie:move(...) super.move(self, ...); ... end`). It is
  NOT for mixin orchestration — command mixins directly via the named
  leaf: `Flammable.init(self)` / `Flammable.light(self)`. `super` stays
  unambiguous because there is exactly one parent.
- The `:` colon form for delegation is WRONG on a parent/mixin table — it
  passes that table as `self`, not the instance, silently mutating the
  class. Always use `Parent.method(self, ...)` / `Mixin.method(self, ...)`.
- `class("Name", Parent):mixin(M1, M2)` copies mixin methods into the
  class (first-wins: class > earlier mixin > later mixin). A mixin's
  `init`/`included` are never copied — call them explicitly from
  `Class:init`. There is no auto-`super`; all chaining is explicit.
- Constructors: `Class(...)` and `Class:new(...)` both set the metatable
  then call `init`. `__call` dispatches through `cls.new` (not the DSL
  upvalue), so a parent's `new` override is inherited by subclasses.
- **`init` takes a table when args are many or same-typed.** Any `init`
  (or `M.init(self, ...)`) with **>4 args**, OR **≥3 args of the same
  type** (e.g. three `number`s like `x,y,z`), takes a single NAMED-FIELD
  options table as its only non-`self` param: `Position.init(self, opts)`
  reads `opts.x`/`opts.y`/`opts.z` (all defaulted). Call sites pass the
  literal table: `PhysicsObject.init(self, { x=x, y=y, z=z, mask=Collision.Solid, obeys_gravity=true, mass=2.0, w=2, h=2 })`.
  The named fields disambiguate same-typed params (which number is `x`
  vs `vx` vs `mass`?) and let call sites omit any defaulted field.
  Inits at/under the threshold (≤4 args, <3 same-typed) stay positional —
  `Renderable.init(self, fg, bg, glyphs)` / `Label.init(self, text, fg)`
  / `ScreenRect.init(self, x, y, w, h)` are fine as-is. (Lua's no-parens
  call sugar `f{...}` only applies to single-arg calls, NOT to
  `Mixin.init(self, opts)` which is two args — so write the parens.)
  The composed-mixin init chain forwards the SAME `opts` table down to
  the leaves it pulls in (`PhysicsObject.init` -> `Collidable.init(self, opts)`
  -> `Position.init(self, opts)`), since the leaves each pick out their
  own named fields; a leaf ignores fields it doesn't own.
- **Game entities are pooled**: `Entity.new` is overridden to call
  `world.allocate`, so `Goblin(x, y)` / `Goblin:new(x, y)` borrow a recycled
  slot from the pool (0 Lua allocs steady-state), set the alive bit, and
  run `init` on it — NOT allocate fresh. Use `e:destroy()`
  (`Entity:destroy` -> `world.destroy`) to return an entity's slot to the
  pool; `world.destroy` runs the mixin teardown chain (see the Event bus
  section) FIRST, then marks the slot dead. Engine-object classes (`Map`,
  `Field` — no `Entity` parent) keep the generic `new` and allocate fresh.
  `world` is REQUIRED (`local world = require("world")`), not global.
- **One class per module**, so module-local `super` is unambiguous
  (captured as an upvalue by every method in the file). Convention,
  not enforced.
- Leaf mixins are plain local tables; composed mixins use
  `mixin({}, A, B)`. Both live under `src/mixins/`.

### Scaffolding

- Scaffold a subclass (archetype):
  `just new-class <Name> --parent=Entity --mixins=M1,M2` (PascalCase;
  require paths derived; existence-checked). Files are flat in `src/`.
  `new-class` wires leaf mixins only; pass composed mixins by name like
  any leaf (the subclass doesn't care that they're composed).
- Mixins under `src/mixins/` are created with `just new-mixin <Name>`:
  - Leaf: `just new-mixin Health`.
  - Composed (law 2/3): `just new-mixin Burning --compose=Flammable,Soakable`
    — scaffolds `mixin({}, Flammable, Soakable)` + an init that wakes each
    leaf; you then edit in the override methods that orchestrate them.

## Enum convention

Integer enums use the DSL in `src/enums.lua`, wired as the global
`enum` by `main.lua` (whitelisted in `.luarc.json`).

- List form auto-increments from 1: `enum("Floor", "Wall", "Door")`.
- Explicit values: `enum { Ok = 0, Warn = 1, Err = 2 }`.
- Bitflags: `enum.flags("Visible", "Solid", "Opaque")` → 1, 2, 4.
- Reverse lookup: `Tile.Wall` → value, `Tile[2]` → `"Wall"`.
- Don't iterate enums (`pairs`/`ipairs`) — index them. Reverse integer
  keys share the table with name keys, so there's nothing useful to loop.

## Logging

A singleton leveled, categorized logger in `src/log.lua`, reached via
`local log = require("log")` (NOT global; same shared instance on every
require, like `bus`). NOT a class — a registry of named loggers is just
shared state with methods, so the class DSL buys nothing here.

- `local L = log.get("player")` — idempotent; one cached logger per name.
- `L:trace/debug/info/warn/error(msg, ...)` — literal `msg` when no extra
  args (no format cost, no stray-`%` crash); `string.format` otherwise.
  The format is pcall-guarded so a bad `%` becomes an error marker and
  NEVER throws (a logger must not tank the game loop).
- `L:<level>_lazy(fn)` — `fn` (returns one string) runs ONLY if the level
  passes. Lua is strict, so call-site args evaluate regardless of filter;
  wrap expensive arg computation in a builder to actually skip the work
  when filtered.
- Filters: `log.set_level("debug")` (global floor, default Info) and
  `log.set_category("ai", "trace")` (per-module override; `nil` to clear,
  falling back to the global floor). Levels come from `log.Level`
  (`Trace`..`Error` = 1..5).
- Sinks: `log.add_sink(function(level, name, msg) ... end)` returns an
  UNSUBSCRIBE fn (same convention as `bus.on`); each sink is pcall-guarded
  so a throwing sink never aborts the emit or starves the others. Default
  sink writes `LEVEL  name: msg` to `io.stderr`.
- Prefer a string format over `tostring()` spam: pass the raw value as a
  format arg (`L:info("x=%d", x)`, not `L:info("x=" .. tostring(x))`) —
  the format only runs when the level passes, so the concat is avoided
  when filtered.

## Event bus

A singleton pub/sub bus in `src/event.lua`, reached via
`local bus = require("event")` (NOT global; same singleton on every
require). Use it for ALL cross-entity / cross-system communication.
If two entities (or an entity and a system) need to talk, they go
through the bus — not by holding references to each other, and not by
reaching into `_G`. Direct method calls are for an entity acting on
itself or its owner delegating down; everything else routes through bus
events.

- **Semantic events** (`"moved"`, `"collision"`, `"damaged"`, `"ignited"`,
  `"quit"`, ...): named for what happened. Subscribers react to
  semantics; the `move` action (`bus.emit("move", dx, dy)`) is translated
  by the Player into an ACCELERATION IMPULSE (`self:accelerate(...)`),
  not a discrete step — see the Physics section below. Use semantic events
  for gameplay reactions — a `Flammable` mixin subscribes to `"damaged"`
  to maybe catch fire. **Collisions**: `PhysicsObject`'s per-axis resolver
  (wall strike / landing) emits a general `"collision"` AND a class-named
  `"collision:<a>:<b>"` (mover first, blocker second),
  e.g. `bus.emit("collision:Player:Wall", player, wall)`. The Stairs
  entity subscribes to `"collision"` to react with a velocity bump.
  Names are each party's `__name` (entities: class name; tile defs: the
  TileType name, set in tile.lua). Subscribe to `"collision:Mover:Blocker"`
  for a specific pairing, or `"collision"` for all.
- **Raw key channel** `"keypress:<vk>"`: emitted by the input loop for
  EVERY keypress (e.g. `"keypress:16"` for right). Subscribe when you
  need ad-hoc raw-key reactions outside the keybind table. Keybinds
  (arrows -> `move`, Esc -> `quit`) emit
  BOTH the semantic action AND the raw `keypress:<vk>`.

- `bus.on(name, cb)` -> returns an UNSUBSCRIBE function (call to remove;
  idempotent). Handlers run in subscribe order; `emit` snapshot-iterates
  so handlers may safely sub/unsub mid-dispatch.
- `bus.subscribe(target, name, cb)` — the mixin convention: subscribe in
  a mixin's `init` (passing `self` as `target`) and the unsub fn is
  appended to `target._unsubs` for bulk teardown. `world.destroy`
  walks `e._unsubs` (newest-first) before marking the slot dead, so a
  destroyed entity stops reacting. Mixins that listen MUST subscribe
  via `bus.subscribe` (not bare `bus.on`) so teardown is tracked.
- Don't emit game events from inside `update(dt)` hot paths every frame
  unless something actually changed — guard on state transitions
  (a `collision` fires on a wall strike / landing, not every tick the
  entity is resting against a surface).

## Physics (the "basic silly physics engine")

Motion is driven ENTIRELY by the semi-implicit Euler integrator in
`Position` — **no direct position writes, no teleporting**. The player,
projectiles, knockback, drift all go through it. Three mixins stack:
- `Position` (leaf): owns `x/y/z`, `vx/vy/vz`, `ax/ay/az`, and the
  integrator. `step_axis(axis, dt)` (semi-implicit Euler: `v += a*dt`
  then `p += v*dt` for ONE axis) is factored out of `update(dt)` so a
  composed mixin can resolve collisions axis-by-axis (sliding /
  per-axis blocking) instead of moving all three at once. `move(dx,dy,dz)`
  still exists (instant offset) for NON-player discrete steps; the player
  does NOT use it.
- `Collidable` (composed: Position + collision): owns the collision
  `mask` + `should_collide` + `emit_collision_with`. Its `move` is the
  discrete collision-guarded tile step (used by non-physics entities,
  NOT the player).
- `PhysicsObject` (composed: Collidable + gravity + integrator): the
  motion pipeline. `init` sets `obeys_gravity` (NO pre-settle — gravity
  lands it on the first update). `update(dt)`: (1) `az = -GRAVITY`
  baseline for gravity-bound entities (overwrites transient vertical
  input each frame; stairs bump `vz` directly, NOT `az`); (2) per-axis
  `step_axis` + `resolve_axis` (x, y, z): if the integration crossed a
  cell and the entered cell is blocked (tile Solid mask OR a collidable
  entity via the occupancy hash), snap to the free cell boundary + zero
  that axis's velocity (so you SLIDE along a wall on a diagonal, and
  gravity LANDS you instead of snapping a z-stack) and emit
  `collision`/`collision:<a>:<b>`; (3) clear `ax`/`ay` (input impulses are
  per-frame, must not persist); (4) friction `vx,vy *= FRICTION^dt`
  (frame-rate-independent damping toward rest); (5) `occ_rehash`.

Tuning lives on `world` (mirrored as module locals in world.lua):
`world.GRAVITY`, `world.STEP_ACCEL` (cells/sec² per arrow-key impulse),
`world.FRICTION` (per-second velocity retention, ~0.02 = 2%/s),
`world.SHUNT_VZ` / `world.SHUNT_VH` (the velocity bump a Stairs imparts).

Input → physics: the Player subscribes to `bus` `"move"` and calls
`self:accelerate(STEP_ACCEL*dx, STEP_ACCEL*dy, 0)` — an impulse, not a
step. Stairs subscribe to `"collision"` and set `mover.vx/vy/vz` directly
(a velocity bump) — the integrator arcs the mover up-and-over, no
`mover:move()` teleport. There is NO `"moved"` event anymore: motion is
continuous, so the camera follows every frame (`GameScreen.draw` syncs
`world.cam` to `world.player` before FOV/render). `fall()` is GONE —
gravity is a constant `az` resolved per-axis, same as horizontal.

## FFI wrapper convention

The BLT wrapper (`industrialworld/blt.lua`) binds the BLT C API via
`industrialworld/blt_ffi.lua` (ffi.cdef of the exported `terminal_*`
symbols; the `static inline` wrappers in BearLibTerminal.h are NOT
dlsym-able, so we bind their underlying `*8` variants and reimplement
the sugar in Lua). Color is a packed `uint32_t ARGB` (via the `bit`
library). The `Console` shim presents a console-buffer-shaped API
(`put_rgb`/`put_char`/`print`/`width`/`height`) over BLT's immediate-mode
scene so call sites stay readable; layered UI (the messages panel)
uses a higher codepoint range (0xE000+) to route glyphs through the
second tileset.

When adding a new BLT binding, add the `ffi.cdef` entry in
`blt_ffi.lua`, then a typed method in `blt.lua`.

## Widgets (UI library)

Immediate-mode-ish UI widgets live in `src/widgets/` (archetypes) and
`src/mixins/ui/` (leaf capability mixins), re-exported/created via
`src/widget.lua`. They are **engine objects, not game entities** — they
have a position and ticks, but it is screen-space, not world-space, and
they never participate in the entity update loop or collision. This is
law 3/4 in action: `Widget` is the UI analogue of `Entity`, carrying
SOLELY the UI lifecycle protocol (`init`/`update(dt)`/`draw`), and every
capability is a mixin layered on top — never on the base.

### Laws applied

1. **`Widget` is a one-base, capa-from-mixins system — the second base
   class.** It is the ONLY base for UI objects (just as `Entity` is the
   only base for game objects). It owns nothing but the lifecycle hooks.
   Screens, buttons, panels, bars are all `Widget` + mixins.
2. **Capabilities are mixins under `src/mixins/ui/`.** Each bundles its
   own state + methods for one narrow UI concern:
   - `ScreenRect` — screen-space bounds (`screen_x/y/w/h`) + `_contains`,
     the hit-test primitive every spatial mixin depends on.
   - `Hoverable` / `Clickable` — reactive state + bus subscriptions.
   - `Label` / `ProgressFill` / `TextPanel` — rendering mixins.
   - `Anchor` — semantic side/alignment positioning against a target rect.
   Mix these onto an archetype; don't reach into `_G` or hold cross-widget
   references — route through `bus` (law/event-bus convention).
3. **`self` is flat (law 5).** A widget's state (`screen_x`, `text`,
   `hovered`, `percent`, `lines`, `scroll`, ...) lives un-namespaced on
   the instance. A composed mixin reads/writes sibling-leaf state directly
   (e.g. `Hoverable` reads nothing extra, but `MessageLog:add_line` reads
   `self.lines`, which `TextPanelMixin` set). No per-mixin subtables.
4. **Archetypes are `src/widgets/*.lua` — identity-specific presets.**
   `Button`, `TextPanel`, `MessageLog`, `ProgressBar` subclass `Widget`
   (+ mixins) and carry ONLY identity behavior (`MessageLog`'s dedup,
   age-dimming, and rule line; `Button`'s hover-color swap + click
   dispatch). Cross-capability orchestration that is reusable across
   archetypes still belongs in a mixin, not a subclass (law 2).
5. **Subclassing lifts via hooks, not overrides, for rendering.**
   `TextPanelMixin:draw` calls `self:line_text(entry, row, h)` and
   `self:line_color(...)` per visible row — default impls return the
   stored text/future. A subclass overrides THOSE hooks (not `draw`) to
   customize rendering (`MessageLog` stamps `xN` repeat counters and
   dims by age). This keeps the layout/scrolling logic in one place.

### Mechanics (lifecycle + init order)

- **Pooled, like entities.** `Widget.new` routes through
  `world.allocate_widget` (which assigns a recycled slot, an alive bit,
  and a monotonic `_z` for topmost ordering); `Widget:destroy` routes
  through `world.destroy_widget`, which walks `w._unsubs` (newest-first)
  then marks the slot dead — so a destroyed widget stops reacting. The
  pool grows lazily. Allocate via the constructor: `Button(con, x, y,
  text, cb)`, never `Button.new` directly from call sites.
- **Explicit, ordered init chain.** There is no auto-`super`; every
  `init` is called by name from the subclass `init`, in dependency order:
  screen-space mixins BEFORE reactive/rendering ones (ScreenRect sets
  `screen_x/y`, which `Hoverable`/`Clickable`/`Label`/`ProgressFill`/
  `TextPanel` all assert on). Then set `self.con` (the `Console` shim)
  before `draw` runs. A working `init` looks like:
  ```lua
  function Button:init(con, x, y, text, cb, fg, fg_hover)
      self.con = con
      super.init(self)            -- one-level parent no-op
      ScreenRect.init(self, x, y, #text, 1)
      Label.init(self, text, fg or palette.text)
      Hoverable.init(self)
      Clickable.init(self)
      ...
  end
  ```
  Forgetting to call a mixin init leaves its state nil and the assertions
  in the next mixin down the chain catch it — that is the intended fast
  failure, do not weaken the asserts.
- **Mouse input is centralized, NOT per-widget.** Widgets do not touch raw
  mouse coords. `main.lua` polls the cursor, calls
  `world.widget_topmost({x,y}, flag)` (flag = `"_clickable"` /
  `"_hoverable"`) to find the topmost living widget at that position with
  that capability (using `ScreenRect._contains`), and emits a TARGETED
  event carrying identity + coords:
  `bus.emit("widget:click", { widget=clicked, x=mx, y=my, button=vk })`
  and the matching `widget:hover` with `state`.
  `Clickable`/`Hoverable` subscribe to those events (via `bus.subscribe`
  so teardown is tracked), filter on `p.widget == self`, and dispatch to
  `self:on_click(x,y,button)` / `self:on_hover` / `self:on_hover_changed`.
  Want a clickable widget? Mix `Clickable` (and a bounds mixin) — never
  subscribe to a raw mouse channel from a widget.
- **Game-semantic input still goes through `bus` for data-driven feed.**
  `TextPanelMixin` subscribes to a named event (`event_name` passed at
  init) for appended lines; `ProgressBar` subscribes to
  `progress:<id>` / `progress:<id>:destroy`. This keeps the feed decoupled
  from the producer — emit `bus.emit("message", text, fg)` and any
  `MessageLog` listening on `"message"` picks it up.

### Adding a widget

- **New capability?** Add a leaf mixin in `src/mixins/ui/<name>.lua` as a
  plain local table `{}`; `init(self, ...)` its state onto the flat `self`
  (with the asserts that encode its prerequisites), and any `(self, ...)`
  methods. If it listens to the bus, subscribe via `bus.subscribe(self,
  ...)` for teardown.
- **New archetype?** `src/widgets/<name>.lua` subclassing `Widget`
  (`local Foo, super = class("Foo", Widget):mixin(M1, M2, ...)`).
  Call `super.init(self)` then each mixin's init in dependency order, set
  `self.con`, and implement identity-specific overrides (or the
  `line_text`/`line_color` style hooks for `TextPanel` subclasses). Render
  by delegating: `function Foo:draw() Label.draw(self) end` (or compose).
- **Want it to render a new glyph/style?** Add the typed method to
  `blt.lua` (FFI wrapper convention) and call it from the widget's `draw`.
- **Don't** add a second base class for UI (law 4: one base, `Widget`),
  **don't** put cross-capability orchestration in a subclass (use a
  mixin), and **don't** give a widget a world position or make it tick in
  the entity loop — widgets tick in `world.update_widgets(dt)` only.

## Pathfinding & spatial queries

Routing and reach primitives over the engine's z-major grid live in
`src/pathfinding/` (re-exported by `src/pathfinding.lua` — reach via
`local pf = require("pathfinding")`). Functions are **purpose-named, not
algorithm-named** so you can tell when to reach for them: `find_path`
(one A→B route), `distance_field` (cost from one cell to all reachable),
`descent_field` / `descent_step` (one search feeding many NPCs to one
target), `flood` (connectivity / wall-respecting radius), `raycast`,
`within_radius` / `within_sphere` (pure-geometric extents). Each module
carries a `WHEN TO USE THIS` / `WHEN NOT TO` docstring — **consult those
to pick the right function**; this note is only a pointer. **SIGHT lives
elsewhere**: `src/fov.lua` (`local fov = require("fov")`) — `fov.line_of_sight`
(the single-pair boolean), `fov.visible_tiles`/`fov.visible_entities`/
`fov.visible_from_set`/`fov.can_see`/`fov.can_see_from_set` — NATIVELY 3D
(Amanatides-&-Woo voxel DDA via `pf.raycast3d`), so rays climb through
layers and are blocked by any `Opaque` voxel; a solid ceiling cuts off
upper layers except where it's `Open` (a skylight). The world wires this
up each frame: `world.update_fov()` recomputes `TileFlags.Visible` from
the camera (player) cell (constant-radius 3D sphere, `world.VISION_RANGE`/
`VISION_SHAPE`) and ORs `TileFlags.Explored` (memory = ever-seen union).
`world.render_map` is DEFAULT-DARK: cells with neither flag render
nothing; Visible cells render full-shaded; Explored-but-not-Visible render
dimmed (`MEMORY_BRIGHTNESS` × the depth/height shade). Visible above-
layer cells (z > cam.z) additionally get an x-ray hole
(`xray_alpha` rings) carved around the player. `world.draw_entities` only
draws entities on Visible cells (memory shows NO entities). Set `Opaque`
on Wall terrain (main.lua does a linear pass). **WALKING-REACH ergonomics**
(mirroring the FOV API shape) live in `src/reach.lua`
(`local reach = require("reach")`) over `pf.flood` + `pf.find_path`.
