--------------------------------------------------------------------------
-- dragtransfer.lua — Super+Tab: screen-local switching, or an
-- intelligent cross-monitor transfer while a window is being dragged.
--
-- Every AETHER window drag (Mod4+click on the body, plain click on the
-- glass titlebar) runs through one engine: awful.mouse.client.move ->
-- awful.mouse.resize with the "mouse.move" context, which exposes
-- enter/move/leave callbacks.  Hooking those gives the full drag lifecycle
-- (which client, source screen, source tag, commit state) without touching
-- awful internals — no custom grabber, no post-hoc window shuffling.
--
-- Grab interactions, verified on this machine (awesome 4.3, X11): root
-- keybindings keep firing while awful's mousegrabber holds the pointer
-- (Mod4+Tab switched tags mid-drag in a live test), so the plain global
-- binding stays the single entry point.  Maximized and fullscreen clients
-- never enter a drag at all: awful.mouse.client.move refuses them.
--
-- Behaviour:
--   * no drag        -> screen-local tag cycle on the focused screen,
--                       forward through the tag array:
--                       ". -> 1 -> 2 -> ... -> 9 -> ." (wraps).
--   * first press    -> commit the dragged window to the next monitor
--                       (cyclic screen order).  Destination workspace is
--                       that screen's currently selected tag, except the
--                       dot, which routes to workspace 1.  Floating
--                       geometry is clamped into the destination workarea
--                       and the pointer is warped onto the window's grab
--                       point so the drag continues on the new monitor;
--                       tiled clients re-arrange under the destination
--                       layout.  Only the dragged window moves.
--   * later presses  -> the transfer is already committed; presses now
--                       carry the window along the destination screen's
--                       tag cycle, so it stays under the pointer.  Rapid
--                       repeats inside the cooldown are absorbed.
--------------------------------------------------------------------------

local awful = require("awful")
local capi  = { mouse = mouse }

local resize = require("awful.mouse.resize")
local dotws  = require("dotworkspace")

local M = {}

M.config = {
    cooldown = 0.25, -- seconds; absorbs rapid repeated Super+Tab
}

-- Drag state machine.
local state = {
    active         = false, -- a "mouse.move" drag is in progress
    client         = nil,   -- the client being dragged
    source_screen  = nil,   -- screen the drag started on
    source_tag     = nil,   -- tag the drag started on
    transferred    = false, -- a transfer was committed during this drag
    grab_offset    = nil,   -- pointer offset inside a floating window
}

local last_commit = 0

--- The next monitor in cyclic screen order (nil with a single monitor).
local function other_screen(src)
    local n = screen.count()
    if n < 2 then return nil end
    local dst = screen[(src.index % n) + 1]
    if dst and dst.valid and dst ~= src then return dst end
    for s in screen do
        if s ~= src and s.valid then return s end
    end
end

local function clamp(v, lo, hi)
    if hi < lo then return lo end
    return math.max(lo, math.min(hi, v))
end

--- Commit the dragged client to the other monitor.  Only this client
-- moves; nothing on the source workspace is touched.
local function transfer()
    local c = state.client
    if not c or not c.valid then return false end
    local src = c.screen
    local dst = other_screen(src)
    if not dst then return false end -- no second monitor: keep dragging

    local tag = dst.selected_tag
    if not tag or dotws.is_dot(tag) then
        tag = dotws.first_numbered(dst) -- never strand a window on the dot
    end
    if not tag or not tag.valid then return false end

    -- Snapshot for geometry re-anchoring (floating only: tiled clients are
    -- re-arranged by the destination layout; maximized/fullscreen state is
    -- client-level and survives the retag).
    local floating = c.floating and not (c.maximized or c.fullscreen)
    local geo = floating and
        { x = c.x, y = c.y, width = c.width, height = c.height } or nil

    state.transferred = true
    last_commit = os.clock()

    tag:view_only()     -- screen-local switch of the destination only
    c:move_to_tag(tag)  -- retags (and re-screens) exactly this client
    if not c.valid then return true end -- closed during the move

    if floating and geo then
        -- Adapt the geometry to the destination workarea, then warp the
        -- pointer onto the same grab point so the drag continues there.
        local wa = dst.workarea
        local wx = clamp(geo.x, wa.x, wa.x + math.max(0, wa.width - geo.width))
        local wy = clamp(geo.y, wa.y, wa.y + math.max(0, wa.height - geo.height))
        c:geometry{ x = wx, y = wy }
        capi.mouse.coords({
            x = clamp(wx + state.grab_offset.x, wa.x, wa.x + wa.width - 1),
            y = clamp(wy + state.grab_offset.y, wa.y, wa.y + wa.height - 1),
        }, true) -- true: suppress the enter/leave event storm
    else
        -- Tiled: land the pointer on the destination so the drag feels
        -- continuous; the layout keeps the client under it.
        local wa = dst.workarea
        capi.mouse.coords({
            x = wa.x + math.floor(wa.width / 2),
            y = wa.y + math.floor(wa.height / 2),
        }, true)
    end
    c:emit_signal("request::activate", "drag_transfer", { raise = true })
    return true
end

--- The Mod4+Tab entry point (called from the global binding).  Returns
-- true when the press belongs to the drag handler; false = the caller
-- performs the normal screen-local tag switch.
function M.on_super_tab()
    if not state.active then return false end
    if os.clock() - last_commit < M.config.cooldown then
        return true -- absorb rapid repeats mid-gesture
    end
    if state.transferred then
        -- Already on the other monitor: cycle the destination's workspaces
        -- and carry the window along, so it stays under the pointer.  A
        -- window landing on the dot is routed to workspace 1 by policy.
        local c = state.client
        if c and c.valid then
            awful.tag.viewnext(c.screen)
            if c.valid and c.screen.selected_tag then
                c:move_to_tag(c.screen.selected_tag)
            end
            return true
        end
        return false
    end
    return transfer() or false
end

--- Hook the drag lifecycle.  Safe to call more than once.
function M.install()
    if M._installed then return end
    M._installed = true

    resize.add_enter_callback(function(c)
        if not c or not c.valid then return end
        state.active = true
        state.client = c
        state.source_screen = c.screen
        state.source_tag = c.first_tag
        state.transferred = false
        local m = capi.mouse.coords()
        state.grab_offset = { x = m.x - c.x, y = m.y - c.y }
    end, "mouse.move")

    resize.add_leave_callback(function()
        -- Drag over (or the client died mid-drag): drop everything.
        state.active = false
        state.client = nil
        state.source_screen = nil
        state.source_tag = nil
        state.transferred = false
        state.grab_offset = nil
    end, "mouse.move")

    -- Dragged floating windows never slide under the top bar: a titlebar
    -- hidden by the wibar makes the close/minimize controls unreachable.
    -- The callback runs before the drag's geometry is applied, so clamping
    -- the computed geometry keeps every motion in bounds.
    resize.add_move_callback(function(c, geo)
        if not (c and c.valid and geo and geo.y) then return end
        if not c.floating or c.maximized or c.fullscreen then return end
        local wa = c.screen.workarea
        if geo.y < wa.y then
            geo.y = wa.y
            return geo
        end
    end, "mouse.move")
end

return M
