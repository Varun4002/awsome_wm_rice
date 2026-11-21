--------------------------------------------------------------------------
-- control_center.lua — macOS-style control-center popover for the top bar
--
-- A pill button in the bar's right section opens a popover with:
--   * Wi-Fi: on/off toggle (nmcli) + the current network name
--   * Bluetooth: on/off toggle (bluetoothctl) + power state
--   * Brightness: hardware backlight slider via brightnessctl. Setting
--     needs root, so changes go through `sudo -n` (passwordless on this
--     machine); reads are unprivileged.
--
-- All state reads are async forks — the main loop never blocks. Toggles
-- animate immediately (optimistic) and are re-synced from the tools' real
-- state; a poll that reports "unchanged" does not re-animate the switch.
--------------------------------------------------------------------------

local wibox = require("wibox")
local awful = require("awful")
local gears = require("gears")
local anim  = require("anim")

local M = {}

local FG_MAIN  = "#f2f2f7"
local FG_MUTED = "#9a9aa0"
local POPUP_BG = "#1c1c1f"
local ON_BG    = "#30d158"
local OFF_BG   = "#48484d"

local FA_WIFI    = "\u{f1eb}"
local FA_BT      = "\u{f293}"
local FA_SUN     = "\u{f185}"
local FA_SLIDERS = "\u{f1de}"

local function esc(s)
    return (tostring(s):gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"))
end

-- Markup-setter that skips no-op writes (a textbox relayout for the same
-- string is wasted work in a widget that refreshes every few seconds).
local function set_markup(widget, str)
    if widget._private.cc_markup == str then return end
    widget._private.cc_markup = str
    widget:set_markup_silently(str)
end

local function markup(text, color, font)
    return string.format('<span font="%s" foreground="%s">%s</span>',
        font or "Inter Medium 10", color or FG_MAIN, esc(text))
end

local function icon_widget(glyph, size)
    local i = wibox.widget.textbox()
    i.font = "FontAwesome " .. (size or 11)
    set_markup(i, string.format('<span foreground="%s">%s</span>', FG_MUTED, glyph))
    return i
end

--------------------------------------------------------------------------
-- macOS-style switch: rounded pill, knob slides with an ease-out tween.
--------------------------------------------------------------------------

local function make_switch(id, on_toggle)
    local checked = false
    local knob = wibox.widget{
        bg = "#ffffff", shape = gears.shape.circle,
        forced_width = 18, forced_height = 18,
        widget = wibox.container.background,
    }
    local slide = wibox.widget{
        { knob, layout = wibox.layout.fixed.horizontal },
        left = 2, right = 18, widget = wibox.container.margin,
    }
    local pill = wibox.widget{
        slide, bg = OFF_BG, shape = gears.shape.rounded_bar,
        forced_width = 42, forced_height = 22,
        widget = wibox.container.background,
    }

    -- Knob rests: off = margins 2/18, on = 22/2 (slides 20px across).
    local function set_knob(on)
        anim.tween{ tag = "cc_switch_" .. id, duration = 0.16,
            step = function(t)
                slide.left  = on and 2 + 20 * t or 22 - 20 * t
                slide.right = on and 22 - 20 * t or 2 + 20 * t
            end }
    end

    function pill:set_checked(b)
        local changed = checked ~= b
        checked = b
        pill.bg = b and ON_BG or OFF_BG
        if changed then set_knob(b) end
        return changed
    end
    function pill:get_checked() return checked end

    pill:buttons(gears.table.join(awful.button({}, 1, function()
        checked = not checked
        pill.bg = checked and ON_BG or OFF_BG
        set_knob(checked)
        if on_toggle then on_toggle(checked) end
    end)))

    return pill
end

--------------------------------------------------------------------------
-- Rows. State reads are async; resync_soon() re-reads after a toggle so
-- the switch settles on the tool's real state even if the command failed.
--------------------------------------------------------------------------

local wifi_label = wibox.widget.textbox()
local bt_label   = wibox.widget.textbox()
local bright_pct = wibox.widget.textbox()
local resync_soon, refresh -- forward declarations (toggles capture them)

local wifi_switch = make_switch("wifi", function(on)
    awful.spawn.with_shell("nmcli radio wifi " .. (on and "on" or "off"))
    resync_soon()
end)
local bt_switch = make_switch("bt", function(on)
    awful.spawn.with_shell("bluetoothctl power " .. (on and "on" or "off"))
    resync_soon()
end)

-- Brightness slider. Reads are unprivileged; writes need root, so each
-- change is `sudo -n brightnessctl`, throttled so a drag sends one command
-- per 250ms instead of one per frame.
local bright_dragging, bright_syncing = false, false
local pending_bright
local bright_timer = gears.timer{ timeout = 0.25, single_shot = true, callback = function()
    if pending_bright then
        awful.spawn.with_shell(
            string.format("sudo -n brightnessctl -q set %d%%", math.floor(pending_bright + 0.5)))
        pending_bright = nil
    end
end }
local bright = wibox.widget.slider{
    minimum = 5, maximum = 100, value = 73,
    bar_shape    = gears.shape.rounded_rect, bar_height = 4,
    bar_color    = "#4a4a4f",
    handle_shape = gears.shape.circle, handle_width = 12,
    handle_color = "#f2f2f7",
}
-- 4.3's slider:fit returns the *available* height ("use with a constraint
-- widget"), which would blow the popover up to its 9999px cap.
bright.forced_height = 20
bright:connect_signal("button::press",   function() bright_dragging = true end)
bright:connect_signal("button::release", function()
    bright_dragging = false
    pending_bright = bright.value
    if not bright_timer.started then bright_timer:start() else bright_timer:again() end
end)
bright:connect_signal("property::value", function()
    if bright_syncing then return end
    set_markup(bright_pct, markup(tostring(math.floor(bright.value)) .. "%",
        FG_MUTED, "Inter Medium 9"))
    pending_bright = bright.value
    if not bright_timer.started then bright_timer:start() else bright_timer:again() end
end)

function resync_soon()
    gears.timer.start_new(1.0, function() refresh(); return false end)
end

function refresh()
    -- Wi-Fi: radio state, then the active wireless connection's name.
    awful.spawn.easy_async_with_shell(
        "nmcli -t -f WIFI radio 2>/dev/null || true", function(out)
            local on = out:match("enabled") ~= nil
            wifi_switch:set_checked(on)
            if on then
                awful.spawn.easy_async_with_shell(
                    "nmcli --escape=no -t -f NAME,TYPE connection show --active 2>/dev/null | " ..
                    "grep 802-11-wireless | cut -d: -f1 | head -1 || true",
                    function(ssid)
                        ssid = (ssid or ""):gsub("[\r\n]+$", "")
                        set_markup(wifi_label, markup(
                            ssid ~= "" and ssid or "Wi-Fi",
                            ssid ~= "" and FG_MAIN or FG_MUTED))
                    end)
            else
                set_markup(wifi_label, markup("Wi-Fi off", FG_MUTED))
            end
        end)

    -- Bluetooth: controller power state.
    awful.spawn.easy_async_with_shell(
        "bluetoothctl show 2>/dev/null | grep -m1 'Powered:' | grep -oE 'yes|no' || true",
        function(out)
            local on = out:match("yes") ~= nil
            bt_switch:set_checked(on)
            set_markup(bt_label, markup(on and "Bluetooth" or "Bluetooth off",
                on and FG_MAIN or FG_MUTED))
        end)

    -- Brightness: current backlight percentage.
    awful.spawn.easy_async_with_shell("brightnessctl -m 2>/dev/null || true", function(out)
        local pct = tonumber(out:match(",(%d+)%%,"))
        if pct then
            set_markup(bright_pct, markup(tostring(pct) .. "%", FG_MUTED, "Inter Medium 9"))
            if not bright_dragging then
                bright_syncing = true
                bright:set_value(pct)
                bright_syncing = nil
            end
        end
    end)
end

-- Row = icon + label on the left, control pinned to the right.
local function row(icon, label, trailing)
    return wibox.widget{
        {
            icon,
            { label, left = 10, widget = wibox.container.margin },
            layout = wibox.layout.fixed.horizontal,
        },
        trailing,
        layout = wibox.layout.align.horizontal,
    }
end

local content = wibox.widget{
    {
        layout = wibox.layout.fixed.vertical,
        spacing = 14,
        row(icon_widget(FA_WIFI), wifi_label, wifi_switch),
        row(icon_widget(FA_BT),   bt_label,   bt_switch),
        {
            {
                icon_widget(FA_SUN),
                { bright_pct, left = 10, widget = wibox.container.margin },
                layout = wibox.layout.fixed.horizontal,
            },
            { bright, left = 14, right = 4, widget = wibox.container.margin },
            layout = wibox.layout.align.horizontal,
        },
    },
    margins = 16,
    widget  = wibox.container.margin,
}

-- Fixed width so long SSIDs ellipsize instead of resizing the popover.
content.forced_width = 300
wifi_label.ellipsize = "end"
bt_label.ellipsize   = "end"

local cc_popup = awful.popup{
    widget = content,
    ontop  = true,
    type   = "dock",
    visible = false,
    bg     = POPUP_BG,
    shape  = gears.shape.rounded_rect,
    border_width = 0,
    preferred_positions = "bottom",
    preferred_anchors   = "back", -- hug the right edge, under the button
}
cc_popup:connect_signal("mouse::leave", function() M.close() end)

local cc_open = false

local function close_cc()
    if not cc_open then return end
    cc_open = false
    anim.tween{ tag = "cc_popup", duration = 0.12, step = function(t)
        cc_popup.opacity = 1 - t
    end, done = function()
        if cc_popup and not cc_open then
            cc_popup.visible = false
            cc_popup.opacity = 1
        end
    end }
end

local function open_cc()
    -- One popover at a time: the media popover yields (lazy require keeps
    -- control_center <-> frostbar from being a require cycle).
    pcall(function() require("frostbar").close_media() end)
    refresh()
    -- Anchor to the bar on the screen under the pointer (the one the user
    -- clicked), not the focused client's screen.
    local s = mouse.screen or awful.screen.focused()
    if not s then return end
    cc_popup:move_next_to(s.mywibox)
    cc_open = true
    anim.tween{ tag = "cc_popup", duration = 0.18, step = function(t)
        cc_popup.opacity = t
    end }
end

function M.toggle()
    if cc_open then close_cc() else open_cc() end
end

function M.close()
    close_cc()
end

--------------------------------------------------------------------------
-- Bar button (sliders glyph, macOS control-center style)
--------------------------------------------------------------------------

local cc_button = wibox.widget.textbox()
cc_button.font = "FontAwesome 10"
set_markup(cc_button, string.format('<span foreground="%s">%s</span>', FG_MUTED, FA_SLIDERS))
cc_button:buttons(gears.table.join(awful.button({}, 1, function() M.toggle() end)))
cc_button:connect_signal("mouse::enter", function()
    set_markup(cc_button, string.format('<span foreground="%s">%s</span>', FG_MAIN, FA_SLIDERS))
end)
cc_button:connect_signal("mouse::leave", function()
    set_markup(cc_button, string.format('<span foreground="%s">%s</span>', FG_MUTED, FA_SLIDERS))
end)

M.button = cc_button

return M
