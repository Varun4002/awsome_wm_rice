--------------------------------------------------------------------------
-- widgets/seekbar.lua — media position via playerctl -F (event-driven)
--
-- A single `playerctl -F` follower (with_line_callback, respawned on
-- exit) streams status/length/position changes; a 1-second gears.timer
-- advances the bar ONLY while the status is Playing and is stopped the
-- moment the player pauses or stops.  Widgets bind through
-- M.subscribe(fn): fn(status, position_us, length_us) on every change.
--
-- API:
--   M.state              { status, position, length }  (µs)
--   M.subscribe(fn)      returns an unsubscribe fn
--   M.seek(seconds)      playerctl position <s> (click/drag commit)
--   M.new_widget(args)   an animated_slider (0..1000) bound to the state:
--                        animated syncs, drag-locked, seek on release
--   M.start()            start the follower (rc.lua)
--------------------------------------------------------------------------

local awful = require("awful")
local gears = require("gears")

local animated_slider = require("widgets.animated_slider")

local M = {}

M.config = {
    follow_cmd   = "playerctl -F metadata --format "
        .. "'{{status}}\\t{{mpris:length}}\\t{{position}}' 2>/dev/null",
    respawn_delay = 2,
    tick_seconds  = 1, -- advance cadence while Playing
}

M.state = { status = "Stopped", position = 0, length = 0 }

local listeners = {}

function M.subscribe(fn)
    listeners[#listeners + 1] = fn
    pcall(fn, M.state.status, M.state.position, M.state.length)
    return function()
        for i = #listeners, 1, -1 do
            if listeners[i] == fn then table.remove(listeners, i) end
        end
    end
end

local function publish()
    for _, fn in ipairs(listeners) do
        pcall(fn, M.state.status, M.state.position, M.state.length)
    end
end

function M.seek(seconds)
    awful.spawn.with_shell(
        string.format("playerctl position %d", math.floor(seconds + 0.5)))
end

-- The 1s timer lives only while the player reports Playing.
local tick_timer = nil

local function ensure_tick()
    local playing = M.state.status == "Playing"
    if playing and not tick_timer then
        tick_timer = gears.timer{
            timeout = M.config.tick_seconds,
            callback = function()
                if M.state.status ~= "Playing" then return end
                -- advance locally; the -F stream corrects drift
                M.state.position = (M.state.position or 0) + 1e6
                if M.state.length and M.state.length > 0
                    and M.state.position > M.state.length then
                    M.state.position = M.state.length
                end
                publish()
            end,
        }
        tick_timer:start()
    elseif not playing and tick_timer then
        tick_timer:stop()
        tick_timer = nil
    end
end

local function start_events()
    awful.spawn.with_line_callback(M.config.follow_cmd, {
        stdout = function(line)
            local status, length, pos =
                line:match("^(%a+)%s*(%d*)%s+(%d+)%s*$")
            if not status then
                -- streams without a length: "Paused  " (two fields only)
                status = line:match("^(%a+)%s*(%d*)%s*$")
                if status and status ~= "" then length, pos = nil, length end
                if not status then return end
            end
            if status ~= "" then M.state.status = status end
            M.state.length = length and tonumber(length) or 0
            M.state.position = tonumber(pos) or M.state.position or 0
            ensure_tick()
            publish()
        end,
        stderr = function() end,
        exit = function(_)
            gears.timer.start_new(M.config.respawn_delay, function()
                start_events()
                return false
            end)
        end,
    })
end

--- An animated 0..1000 slider bound to the playback state.
-- args: width, height, fill_color, handle_color
function M.new_widget(args)
    args = args or {}
    local slider = animated_slider.new{
        minimum = 0, maximum = 1000, value = 0,
        width = args.width or 210, height = args.height or 20,
        fill_color = args.fill_color, handle_color = args.handle_color,
    }
    local interacting = false
    slider:connect_signal("button::press", function(_, _, _, id)
        if id == 1 then interacting = true end
    end)
    slider:connect_signal("button::release", function(_, _, _, id)
        if id ~= 1 then return end
        interacting = false
        if M.state.length and M.state.length > 0 then
            M.seek(M.state.length * slider:get_value() / 1000)
        end
    end)
    M.subscribe(function(status, position, length)
        slider:set_sensitive((length or 0) > 0)
        if interacting or slider.is_dragging then return end
        if (length or 0) <= 0 then return end
        local target = math.floor((position or 0) / length * 1000 + 0.5)
        if math.abs(slider:get_value() - target) > 2 then
            slider:set_value_animated(target)
        end
    end)
    return slider
end

function M.start()
    start_events()
end

return M
