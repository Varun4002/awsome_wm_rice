--------------------------------------------------------------------------
-- widgets/brightness.lua — hardware backlight via brightnessctl
--
-- No polling: the truth is read once at start, after every write, and
-- whenever something else emits the custom signal
--   awesome.connect_signal("signal::brightness", pct)
-- Hardware keybinds in rc.lua call M.step(delta) (or emit the signal
-- themselves), so the bar's fill animates immediately on keypress.
--
-- API:
--   M.state             { pct } — the published truth
--   M.subscribe(fn)     fn(pct); returns an unsubscribe fn
--   M.set(pct)          write (debouncing is the caller's job)
--   M.step(delta)       +1 / -1 steps for keybinds
--   M.refresh()         re-read and publish
--   M.start()           initial read (rc.lua)
--------------------------------------------------------------------------

local awful = require("awful")
local awesome = awesome

local M = {}

M.config = {
    cli        = "brightnessctl",
    min        = 5,    -- never go fully dark from the slider
}

M.state = { pct = nil }

local listeners = {}

function M.subscribe(fn)
    listeners[#listeners + 1] = fn
    if M.state.pct then pcall(fn, M.state.pct) end
    return function()
        for i = #listeners, 1, -1 do
            if listeners[i] == fn then table.remove(listeners, i) end
        end
    end
end

local function publish()
    for _, fn in ipairs(listeners) do
        pcall(fn, M.state.pct)
    end
    if M.state.pct then
        awesome.emit_signal("signal::brightness", M.state.pct)
    end
end

function M.refresh()
    awful.spawn.easy_async_with_shell(
        M.config.cli .. " -m 2>/dev/null || true",
        function(out)
            local pct = out and out:match(",(%d+)%%,")
            if pct then
                M.state.pct = math.min(100, math.max(0, tonumber(pct)))
                publish()
            end
        end)
end

function M.set(pct)
    pct = math.max(M.config.min, math.min(100, math.floor(pct + 0.5)))
    if M.state.pct and M.state.pct == pct then return end
    awful.spawn.with_shell(
        string.format("%s -q set %d%%", M.config.cli, pct))
    -- Optimistic publish; the follow-up read confirms the hardware value.
    M.state.pct = pct
    publish()
    awful.spawn.easy_async_with_shell(
        string.format("sleep 0.3 && %s -m", M.config.cli), function(out)
            local real = out and out:match(",(%d+)%%,")
            if real and tonumber(real) ~= M.state.pct then
                M.state.pct = tonumber(real)
                publish()
            end
        end)
end

function M.step(delta)
    M.set((M.state.pct or 50) + delta * 5)
end

function M.start()
    M.refresh()
end

return M
