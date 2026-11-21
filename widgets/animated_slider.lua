--------------------------------------------------------------------------
-- widgets/animated_slider.lua — the AETHER animated fill slider (base)
--
-- Why this is not built on wibox.widget.slider's paint path: the stock
-- 4.3 slider has three traps, all reproduced live on this machine —
-- its :fit echoes the available size (unconstrained sliders inflate),
-- its :draw fills the bar without setting a source when bar_color is
-- unset (solid garbage blocks), and even an explicitly transparent
-- bar_color still produced garbage in composite stacks.  So the stock
-- slider is NOT used at all here:
--
--   * the visible bar is two wibox.container.background widgets — the
--     track (full width) and the active fill (animated width), both
--     rounded_bar, colours from M.config;
--   * input is a transparent full-area surface with this module's own
--     pointer handling: click jumps to the position, hold-drag scrubs
--     (mousegrabber, horizontal-resize cursor), wheel steps.  This is
--     the same grabber mechanism the bar's volume scrub uses, verified
--     working on this machine ("sb_h_double_arrow");
--   * programmatic updates glide via M.tween (gears.timer, 60 FPS,
--     cubic-out — no external libraries); drags and wheel respond
--     instantly.  is_animating/is_dragging let backend integrations
--     suppress feedback loops, and M.debouncer coalesces their CLI
--     writes while the user scrubs.
--------------------------------------------------------------------------

local wibox = require("wibox")
local gears = require("gears")

local M = {}

-- Single source of truth for every bar in AETHER.
M.config = {
    -- geometry + look
    bar_height     = 6,
    track_color    = "#ffffff2b",
    fill_color     = "#7cc4ee",
    fill_color_alt = "#6c7480",   -- muted/inactive fill
    -- animation engine
    animation_fps  = 60,
    animation_time = 0.18,        -- seconds for programmatic transitions
    -- input
    scroll_step    = 5,           -- percent per wheel notch
    debounce_ms    = 50,          -- backend command coalescing
}

local tweens = {}

function M.tween_stop(tag)
    if tweens[tag] then
        tweens[tag]:stop()
        tweens[tag] = nil
    end
end

--- One live cubic-out interpolation on a gears.timer (60 FPS target).
function M.tween(tag, from, to, duration, on_step, on_done)
    M.tween_stop(tag)
    local dur = duration or M.config.animation_time
    local steps = math.max(1, math.ceil(dur * M.config.animation_fps))
    local i = 0
    local timer
    timer = gears.timer{ timeout = dur / steps, callback = function()
        i = i + 1
        local t = math.min(i / steps, 1)
        local eased = 1 - (1 - t) * (1 - t) * (1 - t) -- cubic-out
        on_step(from + (to - from) * eased)
        if t >= 1 then
            timer:stop()
            tweens[tag] = nil
            if on_done then on_done() end
        end
    end }
    tweens[tag] = timer
    timer:start()
end

--- Trailing-edge debouncer: the last call wins after `ms` of quiet.
function M.debouncer(fn, ms)
    local queued
    local timer = gears.timer{
        timeout = (ms or M.config.debounce_ms) / 1000,
        single_shot = true,
        callback = function()
            local v = queued
            queued = nil
            if v ~= nil then fn(v) end
        end,
    }
    return function(v)
        queued = v
        if not timer.started then timer:start() else timer:again() end
    end
end

--- New animated slider.
-- args: minimum, maximum, value, width, height, track_color, fill_color,
--       muted, on_change(fn(value, is_dragging))
-- The widget reports property::value for every change (animated steps
-- included); is_animating / is_dragging are on the widget.
function M.new(args)
    args = args or {}
    local min = args.minimum or 0
    local max = args.maximum or 100
    local W = args.width
    local H = args.height or 20
    local BH = args.bar_height or M.config.bar_height
    local value = args.value or min
    local muted = args.muted == true

    -- The visible bar: fill (animated width) over the track, both plain
    -- background containers — no custom :draw anywhere.
    local fill = wibox.widget{
        bg = args.fill_color or M.config.fill_color,
        shape = gears.shape.rounded_bar,
        forced_width = math.floor((W or 0) * (value - min) / math.max(1, max - min)),
        forced_height = BH,
        widget = wibox.container.background,
    }
    local bar = wibox.widget{
        { fill, layout = wibox.layout.align.horizontal },
        bg = args.track_color or M.config.track_color,
        shape = gears.shape.rounded_bar,
        forced_width = W, forced_height = BH,
        widget = wibox.container.background,
    }

    local root = wibox.widget{
        { bar, top = (H - BH) / 2, widget = wibox.container.margin },
        bg = "#00000000",
        width = W, height = H,
        widget = wibox.container.background,
    }
    if W then root.forced_width = W end
    root.forced_height = H

    local tag = tostring(root)
    local state = { value = value, dragging = false, animating = false }

    local function paint(v)
        local frac = (v - min) / math.max(1, max - min)
        fill.forced_width = math.floor(W * frac + 0.5)
    end
    local function set_silent(v)
        v = math.max(min, math.min(max, v))
        state.value = v
        paint(v)
        return v
    end
    local function announce(v)
        root:emit_signal("property::value", v)
    end

    function root:set_value(v)          -- instant, announces
        local done = set_silent(v)
        announce(done)
    end
    function root:get_value() return state.value end
    function root:set_muted(m) muted = m == true end
    function root:set_fill_color(c) fill.bg = c end
    function root:set_sensitive(_) end  -- always interactive
    --- Programmatic update: the fill glides to the target.
    function root:set_value_animated(target)
        M.tween(tag, state.value, target, nil, function(v)
            set_silent(v)
            announce(state.value)
        end, function()
            state.animating = false
        end)
        state.animating = true
    end

    -- Input: click jumps, hold-drag scrubs, wheel steps.
    root:connect_signal("button::press", function(_, x, y, id, mods, geo)
        if id == 1 then
            M.tween_stop(tag)
            state.animating = false
            state.dragging = true
            -- x is relative to THIS widget; geo anchors it on screen.
            local geo_ok = geo and geo.width and geo.width > 0
            local v = geo_ok and (min + (x / geo.width) * (max - min)) or state.value
            set_silent(v)
            announce(state.value)
            -- hold-drag: the same grabber the bar's volume scrub uses
            mousegrabber.run(function(m)
                if not state.dragging or not m.buttons[1] then
                    state.dragging = false
                    root:emit_signal("button::release", x, y, 1, mods, geo)
                    return false
                end
                if geo_ok then
                    local px = math.max(0, math.min(geo.width, m.x - geo.x))
                    set_silent(min + (px / geo.width) * (max - min))
                    announce(state.value)
                end
                return true
            end, "sb_h_double_arrow")
        elseif id == 4 or id == 5 then
            local step = (id == 4) and M.config.scroll_step
                                       or -M.config.scroll_step
            set_silent(state.value + step * (max - min) / 100)
            announce(state.value)
        end
    end)
    root:connect_signal("button::release", function()
        state.dragging = false
    end)

    if args.on_change then
        root:connect_signal("property::value", function(_, v)
            args.on_change(v, state.dragging)
        end)
    end

    root.is_dragging  = function() return state.dragging end
    root.is_animating = function() return state.animating end
    return root
end

return M
