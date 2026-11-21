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

local M = {}

local active = {}

M.ease = {
    linear    = function(t) return t end,
    out_cubic = function(t) return 1 - (1 - t) * (1 - t) * (1 - t) end,
    -- macOS pop-in: slight overshoot on the way to the target.
    out_back  = function(t)
        local c1, c3 = 1.70158, 2.70158
        t = t - 1
        return 1 + c3 * t * t * t + c1 * t * t
    end,
}

function M.tween(args)
    local tag   = args.tag or tostring(args.step)
    local dur   = args.duration or 0.15
    local steps = math.max(1, math.ceil(dur * 60))
    local ease  = args.ease or M.ease.out_cubic
    local i     = 0

    if active[tag] then active[tag]:stop() end
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

return M
