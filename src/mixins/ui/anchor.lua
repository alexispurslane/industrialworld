--- Semantic side-anchor mixin for UI widgets.
---
--- Assumes ScreenRect (needs screen_w/screen_h to size itself). Positions a
--- widget flush against one side of a target rect, aligned along that side:
---
---     -- sit below `btn`, centered horizontally:
---     panel:mixin(Anchor)
---     Anchor.init(panel, btn, "bottom", "center")
---
--- `target` may be any table exposing screen_x/screen_y/screen_w/screen_h
--- (any widget), a function returning such a table (resolved lazily,
--- so you can anchor to something created later), or the string
--- `"screen"` to anchor to the owning console's bounds. A screen target
--- places the widget INSIDE the named edge (a bottom-centered panel hugs
--- the bottom of the screen); a widget target places it on the OUTSIDE of
--- the side. The position is recomputed every frame in update(), so the
--- anchor follows a moving or resizing target.
---
--- Side semantics (anchored widget sits on the outside of the named side):
---   top    -> above the target (its bottom edge touches the target's top)
---   bottom -> below the target
---   left   -> to the left of the target
---   right  -> to the right of the target
---
--- Alignment (`start`/`center`/`end`) positions the widget along the side:
---   start  -> flush with the target's leading edge
---   center -> centered over the side
---   end    -> flush with the target's trailing edge
---
--- This mixin owns screen_x/screen_y (set in update); screen_w/screen_h
--- are owned by ScreenRect.

local Anchor = {}

--- @param target table|string|fun():table  a rect (widget or table), a
---        function returning one, or "screen" to anchor to the console.
--- @param side string "top"|"bottom"|"left"|"right"
--- @param alignment string "start"|"center"|"end"
function Anchor:init(target, side, alignment)
    assert(
        side == "top" or side == "bottom" or side == "left" or side == "right",
        "Anchor.init: side must be top/bottom/left/right"
    )
    assert(
        alignment == "start" or alignment == "center" or alignment == "end",
        "Anchor.init: alignment must be start/center/end"
    )
    self.anchor_target = target
    self.anchor_side = side
    self.anchor_alignment = alignment
end

--- Resolve the target rect. May be:
---   * a table exposing screen_x/screen_y/screen_w/screen_h (any widget),
---   * a function returning such a table (resolved lazily), or
---   * the string "screen" -> the owning console's full bounds.
---@return table|nil
function Anchor:resolve_target()
    local t = self.anchor_target
    if t == "screen" then
        local con = self.con
        if con == nil then
            return nil
        end
        return {
            screen_x = 0,
            screen_y = 0,
            screen_w = con:width(),
            screen_h = con:height(),
        }
    end
    if type(t) == "function" then
        t = t()
    end
    ---@cast t table
    return t
end

--- Recompute screen_x/screen_y from the current target rect. Called every
--- frame by world.update_widgets. If the target is nil, leave position
--- unchanged.
---
--- For a widget target the anchored widget sits on the OUTSIDE of the
--- named side (flush against it). For the "screen" target it sits INSIDE
--- the named edge (so a bottom-centered panel hugs the bottom of the
--- screen instead of sitting below it).
---@param dt number  unused; anchors don't need dt.
function Anchor:update(dt)
    local t = self:resolve_target()
    if t == nil then
        return
    end
    local tx, ty = t.screen_x, t.screen_y
    local tw, th = t.screen_w, t.screen_h
    local trx = tx + tw - 1
    local try = ty + th - 1
    local w, h = self.screen_w, self.screen_h
    local side = self.anchor_side
    local align = self.anchor_alignment
    local inside = (self.anchor_target == "screen")

    -- Along-side alignment helpers (shared by every side).
    local function align_h() -- horizontal alignment over the target span
        if align == "start" then
            return tx
        elseif align == "center" then
            return tx + math.floor((tw - w) / 2)
        else -- end
            return trx - w + 1
        end
    end
    local function align_v() -- vertical alignment over the target span
        if align == "start" then
            return ty
        elseif align == "center" then
            return ty + math.floor((th - h) / 2)
        else -- end
            return try - h + 1
        end
    end

    if side == "top" then
        -- outside: widget above the target (bottom edge touches target top)
        -- inside: widget flush with the top edge of the rect
        self.screen_y = inside and ty or (ty - h)
        self.screen_x = align_h()
    elseif side == "bottom" then
        self.screen_y = inside and (try - h + 1) or (try + 1)
        self.screen_x = align_h()
    elseif side == "left" then
        self.screen_x = inside and tx or (tx - w)
        self.screen_y = align_v()
    else -- right
        self.screen_x = inside and (trx - w + 1) or (trx + 1)
        self.screen_y = align_v()
    end
end

return Anchor
