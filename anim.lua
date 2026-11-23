--------------------------------------------------------------------------
-- anim.lua — tiny tween helper for bar/popover animations
--
-- M.tween{ tag=, duration=, ease=, step=function(t 0..1), done=function() }
-- drives `step` at ~60fps for `duration` seconds. One live tween per tag:
-- re-triggering a tag cancels the previous tween of that tag, so a widget
-- can never be animated by two competing timers (e.g. spam-clicking the
-- control-center button).
--------------------------------------------------------------------------

local gears = require("gears")
-- ui.motion is the one duration scale (ui.lua does not require anim, so the
-- dependency is one-way: anim → ui).
local ui = require("ui")

local M = {}

local active = {}

-- Reduced motion (design-qa S4): respect the desktop's animation preference.
-- Read once at load and refreshed every 60 s, so toggling the setting takes
-- effect without reloading the WM.  When animations are off, a tween jumps
-- straight to its final frame instead of stepping.
M.animations = true

local function read_pref(out)
    M.animations = (out or ""):find("false", 1, true) == nil
end

gears.timer {
    timeout   = 60,
    autostart = true,
    call_now  = true,
    callback  = function()
        gears.timer.start_new(0, function()
            require("awful").spawn.easy_async_with_shell(
                "gsettings get org.gnome.desktop.interface enable-animations 2>/dev/null || true",
                read_pref)
            return false
        end)
    end,
}

M.ease = {
    linear    = function(t) return t end,
    out_cubic = function(t) return 1 - (1 - t) * (1 - t) * (1 - t) end,
    -- Symmetric ease for movement (slides): zero velocity at both ends so a
    -- surface settles instead of stopping dead. Opacity keeps out_cubic.
    in_out_cubic = function(t)
        if t < 0.5 then return 4 * t * t * t end
        return 1 - ((-2 * t + 2) ^ 3) / 2
    end,
    -- macOS pop-in: slight overshoot on the way to the target.
    out_back  = function(t)
        local c1, c3 = 1.70158, 2.70158
        t = t - 1
        return 1 + c3 * t * t * t + c1 * t * t
    end,
}

function M.tween(args)
    local tag   = args.tag or tostring(args.step)
    local dur   = args.duration or ui.motion.base
    local steps = math.max(1, math.ceil(dur * 60))
    local ease  = args.ease or M.ease.out_cubic
    local i     = 0

    if active[tag] then active[tag]:stop() end

    -- Reduced motion: land on the final frame immediately (S4).
    if not M.animations then
        if args.step then pcall(args.step, ease(1)) end
        if args.done then pcall(args.done) end
        return nil
    end

    -- Declare first so the callback's upvalue refers to this local, not to
    -- the global gears.timer function.
    local timer
    timer = gears.timer{ timeout = dur / steps, callback = function()
        i = i + 1
        if args.step then pcall(args.step, ease(math.min(i / steps, 1))) end
        if i >= steps then
            timer:stop()
            if active[tag] == timer then active[tag] = nil end
            if args.done then pcall(args.done) end
        end
    end }
    active[tag] = timer
    timer:start()
    return timer
end

function M.stop(tag)
    if active[tag] then active[tag]:stop(); active[tag] = nil end
end

--- Fade a wibox/widget opacity from `from` to `to`. Returns the tween.
function M.opacity(w, from, to, tag, dur)
    w.opacity = from
    return M.tween{ tag = tag, duration = dur, step = function(t)
        w.opacity = from + (to - from) * t
    end }
end

return M
