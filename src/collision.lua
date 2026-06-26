--- Collision category bitflags.
--
-- Bitflag enum via the engine's `enum.flags` DSL (wired as a global by
-- main.lua): each name gets 1, 2, 4, 8, ... OR them for a composite mask
-- (`Collision.Solid | Collision.Local`). Add new categories by appending
-- (don't renumber existing ones — masks persist on entities and in the
-- tile-collidable registry). 0 = no categories set (collides with nothing).
--
-- Shared between `mixins/collidable.lua` (entity masks) and `tile.lua`
-- (the per-tile-type fixed collidable registry) so both reference one
-- source of truth. Kept in its own module so the tile registry can take
-- the flags without pulling in the Collidable mixin (and the mixin can
-- take the tile registry without a back edge).
local collision = enum.flags("Solid")

return collision
