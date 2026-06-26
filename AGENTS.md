# industrialworld — agent notes

## Architecture

A single-process LuaJIT host that statically links libtcod. The C side
(`src/main.c`) is intentionally thin: it preloads every compiled Lua
module into `package.preload` and then runs the `main` module. libtcod
owns the window and its own event loop, so the host needs no event-pump
plumbing of its own.

## Vendored dependencies

- `vendor/luajit` — vendored LuaJIT, built once into `libluajit.a` + the
  `luajit` bytecode-compiler tool.
- `vendor/libtcod` — shallow clone of the libtcod git repo. Built as a
  static library via CMake; CMake's `FetchContent` pulls SDL3, zlib,
  lodepng, utf8proc, and stb into `build/libtcod/_deps`.

## Build flow (see `justfile`)

1. `build-luajit` — `make` in `vendor/luajit`.
2. `compile-bytecode` — `luajit -b` per `.lua` → `build/bytecode_*.h`,
   plus generated `includes.inc` / `modules.inc`.
3. `compile-libtcod` — `cmake -S vendor/libtcod -B build/libtcod`
   with `BUILD_SHARED_LIBS=OFF`, then `cmake --build`.
4. `compile-binary` — clang links `src/main.c` + `libluajit.a` + every
   `.a` under `build/libtcod` with `-Wl,-export_dynamic`.

The `-export_dynamic` link flag is what lets `ffi.C` resolve libtcod
symbols: it exports the executable's symbols into the dynamic symbol
table so LuaJIT's dlsym-based lookup finds them.

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
  semantics; `bus.emit("moved", player, dx, dy)` lets the subscriber
  decide arg shape. Use these for gameplay reactions — a `Flammable`
  mixin subscribes to `"damaged"` to maybe catch fire, the camera
  subscribes to `"moved"` to follow. **Collisions**: `Collidable:move`
  (blocked step) and `PhysicsObject:fall` (landing) emit a general
  `"collision"` AND a class-named `"collision:<a>:<b>"` (mover first,
  blocker second), e.g. `bus.emit("collision:Player:Wall", player, wall)`.
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
  ("moved" fires when position changes, not every tick).

## FFI wrapper convention

Every typed wrapper (`tcod.lua`) routes resource cleanup through
`gc.wrap_gc` (in `gc.lua`) so there is one consistent RAII protocol.
C functions returning `TCOD_Error` are checked and converted to
`(nil, errmsg)` Lua tuples; the message comes from `TCOD_get_error()`.

When adding a new libtcod binding, follow the existing pattern in
`tcod.lua`: add the `ffi.cdef` entry in `tcod_ffi.lua`, then add a
typed method/class in `tcod.lua` that checks errors and owns the
pointer via `gc.wrap_gc`.
