--------------------------------------------------------------------------
-- widgets/volume.lua — default sink volume, event-driven (no polling)
--
-- wpctl is the read/write CLI; pw-mon (PipeWire's monitor) is the change
-- feed: every sink/volume/mutation streams lines, bursts are coalesced
-- for M.config.debounce_ms and collapsed into ONE wpctl read that
-- publishes the truth to subscribers.  The monitor is respawned if it
-- ever exits.  (pactl is not installed on this machine; pw-mon ships
-- with pipewire-bin, which is already a hard dependency via wpctl.)
--
-- API:
--   M.state                  { pct, muted } — the published truth
--   M.subscribe(fn)          fn(pct, muted); returns an unsubscribe fn
--   M.set(pct)               write (debouncing is the caller's job);
--                            unmutes so the change is audible
--   M.toggle_mute()
--   M.start()                initial read + event monitor (rc.lua)
--------------------------------------------------------------------------

local awful = require("awful")
local gears = require("gears")

local M = {}

M.config = {
    sink          = "@DEFAULT_AUDIO_SINK@",
    debounce_ms   = 50,   -- coalesce pw-mon bursts before one read
    respawn_delay = 2,    -- pw-mon died: restart after this many seconds
    unmute_on_set = true,
}

M.state = { pct = nil, muted = false }

local listeners = {}

function M.subscribe(fn)
    listeners[#listeners + 1] = fn
    if M.state.pct then pcall(fn, M.state.pct, M.state.muted) end
    return function()
        for i = #listeners, 1, -1 do
            if listeners[i] == fn then table.remove(listeners, i) end
        end
    end
end

local function publish()
    for _, fn in ipairs(listeners) do
        pcall(fn, M.state.pct, M.state.muted)
    end
end

local function refresh()
    awful.spawn.easy_async_with_shell(
        "wpctl get-volume " .. M.config.sink .. " 2>/dev/null || true",
        function(out)
            local v = out and out:match("Volume:%s*([%d%.]+)")
            if not v then
                M.state.pct = nil
                publish()
                return
            end
            M.state.pct = math.floor(tonumber(v) * 100 + 0.5)
            M.state.muted = out:find("MUTED", 1, true) ~= nil
            publish()
        end)
end

-- Event storms collapse into one read, and only one read runs at a time.
local refresh_timer
local refresh_inflight = false

local function refresh_soon()
    if refresh_inflight then return end
    if not refresh_timer then
        refresh_timer = gears.timer{
            timeout = M.config.debounce_ms / 1000,
            single_shot = true,
            callback = function()
                refresh_inflight = true
                awful.spawn.easy_async_with_shell(
                    "wpctl get-volume " .. M.config.sink .. " 2>/dev/null || true",
                    function(out)
                        refresh_inflight = false
                        local v = out and out:match("Volume:%s*([%d%.]+)")
                        M.state.pct = v and math.floor(tonumber(v) * 100 + 0.5) or nil
                        M.state.muted = (out and out:find("MUTED", 1, true)) ~= nil
                        publish()
                        refresh_soon() -- a burst may have queued behind it
                    end)
            end,
        }
    end
    if not refresh_timer.started then refresh_timer:start() else refresh_timer:again() end
end

local function start_events()
    awful.spawn.with_line_callback("pw-mon", {
        stdout = function(_) refresh_soon() end,
        stderr = function() end,
        exit = function(_)
            gears.timer.start_new(M.config.respawn_delay, function()
                start_events()
                return false
            end)
        end,
    })
end

--- Write the sink volume (0-100).  Unmutes so the change is audible;
-- the pw-mon event then publishes the confirmed truth.  Same-value writes
-- are skipped so an animated external sync cannot loop through the
-- monitor feed.
function M.set(pct)
    pct = math.max(0, math.min(100, math.floor(pct + 0.5)))
    if M.state.pct and math.abs(M.state.pct - pct) < 1 and not M.state.muted then
        return
    end
    local cmds = { string.format("wpctl set-volume %s %d%%",
                                 M.config.sink, pct) }
    if M.config.unmute_on_set and M.state.muted then
        table.insert(cmds, 1, "wpctl set-mute " .. M.config.sink .. " 0")
    end
    awful.spawn.with_shell(table.concat(cmds, " && "))
    -- Optimistic publish so the UI is instant; the monitor confirms.
    M.state.pct = pct
    M.state.muted = false
    publish()
end

function M.toggle_mute()
    awful.spawn.with_shell("wpctl set-mute " .. M.config.sink .. " toggle")
    refresh_soon()
end

function M.start()
    refresh()
    start_events()
end

return M
