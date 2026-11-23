--------------------------------------------------------------------------
-- popover.lua — the one popover surface of the AETHER bar
--
-- Every layer above the ambient bar (contextual reveal, control surface,
-- expanded panel) is a popover owned by this module:
--
--   * exactly one popover exists at a time — opening another replaces it,
--     and every surface of the bar (control center, media, panel, reveals)
--     is a managed one;
--   * placement is deterministic: centred under the widget that triggered
--     it (mouse.current_widget_geometry, in screen coordinates), below the
--     bar, clamped into the screen with an 8 px margin.  A popover can never
--     be rendered off-screen;
--   * hover popovers are delayed and their close is cancellable, so sliding
--     the pointer across workspaces updates one surface instead of blinking
--     nine of them;
--   * only "modal" surfaces (a click-engaged surface) ask rc.lua to take the
--     Escape grab.  Read-only hover reveals never steal keyboard input.
--------------------------------------------------------------------------

local awful = require("awful")
local gears = require("gears")
local wibox = require("wibox")

local ui  = require("ui")

local M = {}

local popup
local current          -- { id, spec, modal }
local listeners = {}
local hover_close = {} -- id -> timer
local hover_open  = {} -- id -> timer
local generation = 0

-- Back-stack (navigation N8 / flow FL4): opening a modal surface over another
-- modal surface used to destroy the first one, so there was no way back to it.
-- Entries hold the *opener*, not the content: a surface is rebuilt on return,
-- which keeps its timers and subscriptions living exactly as long as it is
-- visible, and makes the stack a list of destinations rather than of widgets.
local back_stack = {}
local backing = false
local BACK_DEPTH = 2

-- Hover pacing comes from the motion scale, so the wait before a reveal and
-- the grace before it closes move at the same pace as the surfaces themselves.
local HOVER_DELAY = ui.motion.base
local HOVER_CLOSE = ui.motion.fast

-- While a bar-level drag is in progress the pointer sweeps across other
-- widgets; hovering must not pop cards open underneath it. Set by the
-- drag owner (frostbar's volume scrub), cleared when it ends.
M.suppressed = false

local function stop_timer(t)
    if t and t.started then t:stop() end
end

local function cancel_hover_close(id)
    stop_timer(hover_close[id])
    hover_close[id] = nil
end

local function cancel_hover_open(id)
    stop_timer(hover_open[id])
    hover_open[id] = nil
end

local function cancel_hover_id(id)
    cancel_hover_close(id)
    cancel_hover_open(id)
end

local function notify()
    local modal = M.any_modal()
    local open = M.any_open()
    for _, fn in ipairs(listeners) do
        pcall(fn, open, modal)
    end
end

local function make_popup()
    -- A plain wibox: awful.popup adds its own asynchronous sizing and
    -- `next_to` placement, which would fight the manager's explicit
    -- geometry (the surface would jump to the widget under the pointer at
    -- some later tick instead of the element that opened it).
    local p = wibox{
        ontop = true,
        visible = false,
        type = "menu",           -- picom: blur + shadow + 12 px corners
        bg = ui.color.bg_popup,
        shape = gears.shape.rounded_rect,
        border_width = 1,
        border_color = ui.color.border,
        opacity = 1,
    }
    -- Hovering away is the universal "click outside": a pointer cannot
    -- leave the surface without crossing this edge first.
    p:connect_signal("mouse::leave", function()
        if current and not current.spec.keep_on_leave then M.close("leave") end
    end)
    return p
end

local function screen_for(anchor)
    if anchor then
        -- getbycoord returns the screen *index*; the manager needs the object.
        local idx = awful.screen.getbycoord(anchor.x, anchor.y)
        return (idx and screen[idx]) or mouse.screen or awful.screen.focused()
    end
    return mouse.screen or awful.screen.focused()
end

-- The widget under the pointer at call time, in screen coordinates.  This is
-- what makes a surface appear *under the element that triggered it* instead
-- of floating centred: it is read synchronously in M.show, not from the
-- popup's unrealised geometry, and is clamped by place().
local function live_anchor()
    local g = mouse.current_widget_geometry
    if g and g.width and g.width > 0 and g.height and g.height > 0 then
        return { x = g.x, y = g.y, width = g.width, height = g.height }
    end
    return nil
end

local function preferred_size(widget, s)
    -- textbox:fit needs a real context (dpi), so build the same shape the
    -- drawable's layout engine provides instead of an empty table.  A raw
    -- `widget:fit` bypasses forced sizes (base.fit_widget applies them), so
    -- the width is taken from the surface's own forced_width and the height
    -- is fitted at that width — wrapping text then measures correctly.
    local dpi = (s.dpi ~= nil and s.dpi) or require("beautiful").xresources.get_dpi()
    local ctx = { screen = s, dpi = dpi }
    local ok, nw = pcall(function()
        return select(1, widget:fit(ctx, 400, s.geometry.height))
    end)
    local w = widget.forced_width or (ok and nw) or 320
    local ok_h, h = pcall(function()
        return select(2, widget:fit(ctx, w, s.geometry.height))
    end)
    if not ok_h or type(h) ~= "number" then h = 120 end
    return math.max(1, math.floor(w)), math.max(1, math.floor(h))
end

-- Deterministic, clamped placement (no dependency on the popup's unrealised
-- geometry, which awful.placement.next_to would otherwise need).
local function place(s, content, anchor)
    local screen_geo = s.geometry
    local bar_h = (s.mywibox and s.mywibox.height) or ui.bar_height
    local w, h = preferred_size(content, s)
    if w <= 0 then w = 320 end
    if h <= 0 then h = 80 end

    local x
    if anchor and anchor.width and anchor.width > 0 then
        x = anchor.x + math.floor((anchor.width - w) / 2)
    else
        x = screen_geo.x + math.floor((screen_geo.width - w) / 2)
    end
    local y = screen_geo.y + bar_h + 6

    local margin = 8
    x = math.max(screen_geo.x + margin,
                 math.min(x, screen_geo.x + screen_geo.width - w - margin))
    local max_y = screen_geo.y + screen_geo.height - h - margin
    if y > max_y then y = math.max(screen_geo.y + bar_h + 6, max_y) end

    popup:geometry{ x = math.floor(x), y = math.floor(y),
                    width = math.floor(w), height = math.floor(h) }
end

local function apply(spec, s, anchor)
    local body = ui.surface(spec.content, spec.width)
    popup.widget = body
    place(s, body, anchor)
    -- Opaque before the map. The entrance is animated GPU-side by picom (the
    -- window_type 'menu' rule in picom.conf), not here: a WM-thread tween on
    -- a blurred, shadowed wibox costs a full repaint plus a blur re-composite
    -- per frame, which reads as lag. With picom dead this is simply instant.
    popup.opacity = 1
    popup.visible = true
end

function M.active()
    if current then return current.id end
end

function M.is_open(id)
    return current ~= nil and (id == nil or current.id == id)
end

function M.any_open()
    return current ~= nil
end

function M.any_modal()
    return (current ~= nil and current.modal == true)
end

function M.subscribe(fn)
    listeners[#listeners + 1] = fn
    return function()
        for i = #listeners, 1, -1 do
            if listeners[i] == fn then table.remove(listeners, i) end
        end
    end
end

-------------------------------------------------------------------------- open / close

--- Show (or update in place) a popover.
-- spec = {
--   id       = string,
--   content  = widget,
--   width    = number,
--   screen   = screen (default: screen under the pointer),
--   geometry = anchor rect (default: widget under the pointer),
--   modal    = boolean,
--   refresh  = function() -- called by M.refresh()
--   on_close = function(reason),
--   keep_on_leave = boolean,
-- }
function M.show(spec)
    if not spec or not spec.content then return end

    generation = generation + 1
    local my_gen = generation

    -- A stale hover timer must never fire over a newly opened surface.
    cancel_hover_id(spec.id)
    if spec.modal then
        for id in pairs(hover_open) do cancel_hover_open(id) end
        for id in pairs(hover_close) do cancel_hover_close(id) end
    end

    local anchor = spec.geometry or live_anchor()
    local s = spec.screen or screen_for(anchor)
    if type(s) == "number" then s = screen[s] end -- tolerate index arguments
    if not s or not s.valid then return end

    if not popup then popup = make_popup() end

    if current and current.id ~= spec.id then
        -- Remember where we came from before the old surface is disposed, so
        -- BackSpace/Back can rebuild it (only modal→modal is a real layer
        -- transition; a hover reveal is not a destination).
        if not backing and spec.modal and current.modal and current.spec.reopen then
            back_stack[#back_stack + 1] = { id = current.id, reopen = current.spec.reopen }
            while #back_stack > BACK_DEPTH do table.remove(back_stack, 1) end
        end
        local old = current
        current = nil
        if old.spec.on_close then pcall(old.spec.on_close, "replace") end
    end
    if current and current.id == spec.id then
        -- same surface, new data (sliding across workspaces, live rerender).
        -- Swap the content in place: no re-anchor (the surface must not jump
        -- under the pointer mid-read) and no re-fade (a 0.14 s blink on every
        -- state change read as a glitch).  Call sites that only need a data
        -- poke without a rebuild use spec.refresh instead (media card).
        if current.spec.on_close then pcall(current.spec.on_close, "update") end
        current = { id = spec.id, spec = spec, modal = spec.modal == true }
        popup.widget = ui.surface(spec.content, spec.width)
        notify()
        return
    end

    current = { id = spec.id, spec = spec, modal = spec.modal == true }
    apply(spec, s, anchor)
    if generation == my_gen and spec.on_open then pcall(spec.on_open) end
    notify()
end

function M.refresh()
    if current and current.spec.refresh then
        pcall(current.spec.refresh)
    end
end

function M.close(reason)
    if not current then return end
    back_stack = {}
    local old = current
    current = nil
    if old.spec.on_close then pcall(old.spec.on_close, reason or "close") end
    if popup and popup.visible then
        -- Instant unmap; picom's disappear script (window_type 'menu') draws
        -- the exit GPU-side. Keeping the WM thread out of the per-frame loop
        -- is the whole point; see apply().
        popup.visible = false
    end
    notify()
end

function M.close_all()
    M.close("close_all")
end

--- Up one layer: rebuild the modal surface this one replaced.  Returns true if
-- there was somewhere to go.  Surfaces opt in by setting `spec.reopen` to their
-- own opener; a surface that does not set it simply has no parent layer.
function M.back()
    local entry = table.remove(back_stack)
    if not entry or not entry.reopen then return false end
    backing = true
    local ok = pcall(entry.reopen)
    backing = false
    return ok
end

function M.can_back()
    return #back_stack > 0
end

--- The live popover's content widget, for QA probes (tree walks).
function M.content()
    return popup and popup.widget
end

--- Geometry of the live popover, for QA probes and tools/qa.sh --live.
function M.geometry()
    if not popup or not popup.visible then return nil end
    return { x = popup.x, y = popup.y, width = popup.width, height = popup.height }
end

-------------------------------------------------------------------------- hover helper

--- Hover-to-reveal for a widget.  `build` returns a spec table (M.show
-- arguments) or nil when there is nothing to reveal.
function M.hover(widget, id, build, opts)
    opts = opts or {}
    widget:connect_signal("mouse::enter", function()
        cancel_hover_close(id)
        if M.any_modal() then return end
        cancel_hover_open(id)
        hover_open[id] = gears.timer.start_new(opts.delay or HOVER_DELAY, function()
            hover_open[id] = nil
            if not widget.visible then return false end
            if M.any_modal() then return false end
            if M.suppressed then return false end
            local spec = build()
            if not spec then return false end
            spec.id = id
            spec.modal = false
            spec.keep_on_leave = true
            M.show(spec)
            return false
        end)
    end)
    widget:connect_signal("mouse::leave", function()
        cancel_hover_open(id)
        cancel_hover_close(id)
        if M.active() ~= id then return end
        hover_close[id] = gears.timer.start_new(opts.close_delay or HOVER_CLOSE,
            function()
                hover_close[id] = nil
                if M.active() == id then M.close("hover_leave") end
                return false
            end)
    end)
end

-------------------------------------------------------------------------- lifecycle

screen.connect_signal("removed", function()
    M.close_all()
end)
screen.connect_signal("property::geometry", function()
    if current then M.close("geometry") end
end)

return M
