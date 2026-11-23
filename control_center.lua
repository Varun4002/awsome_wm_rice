--------------------------------------------------------------------------
-- control_center.lua — the system control surface of the AETHER bar
--
-- A pill button in the right cluster opens one glass popover with the
-- toggles that should be one gesture away:
--
--   * Wi-Fi:            on/off (nmcli) + the active network name
--   * Bluetooth:        on/off (bluetoothctl) + the paired devices, each
--                       clickable to connect / disconnect
--   * (No dark-mode switch: AETHER's palette is fixed, so a switch that only
--      recoloured GTK apps named something it did not do — design-qa F8.)
--   * Brightness:       hardware backlight slider (brightnessctl via
--                       passwordless sudo, see docs/03-defects.md D8)
--   * Volume:           default sink slider + mute (wpctl)
--
-- Every read is one async fork of a single shell probe; the main loop never
-- blocks.  Toggles animate optimistically and are re-synced from the tools'
-- real state.  While the popover is open a 2.5 s refresh keeps devices and
-- values honest; it stops on close.
--------------------------------------------------------------------------

local wibox = require("wibox")
local awful = require("awful")
local gears = require("gears")
local anim  = require("anim")
local ui    = require("ui")
local popover_mgr = require("popover")

local M = {}

local FA_WIFI     = "\u{f1eb}"
local FA_BT       = "\u{f293}"
local FA_SUN      = "\u{f185}"
local FA_SLIDERS  = "\u{f1de}"
local FA_VOL      = "\u{f028}"
local FA_PANEL    = "\u{f108}"

local FA_VOL_MUTE = "\u{f026}"

local PROBE = [[
echo "W $(nmcli -t -f WIFI radio 2>/dev/null || echo unavailable)"
echo "S $(nmcli --escape=no -t -f NAME,TYPE connection show --active 2>/dev/null | grep 802-11-wireless | cut -d: -f1 | head -1)"
echo "B $(bluetoothctl show 2>/dev/null | grep -m1 Powered: | grep -oE 'yes|no')"
echo "L $(brightnessctl -m 2>/dev/null | cut -d, -f4)"
echo "V $(wpctl get-volume @DEFAULT_AUDIO_SINK@ 2>/dev/null || echo unavailable)"
bluetoothctl devices Paired 2>/dev/null | sed 's/^Device \([^ ]*\) /P\t\1\t/'
bluetoothctl devices Connected 2>/dev/null | sed 's/^Device \([^ ]*\) /C\t\1\t/'
]]

local state = {
    wifi_on   = false,
    wifi_name = nil,
    wifi_available = true,
    bt_on     = false,
    bt_available = true,
    devices   = {},          -- { mac, name, connected }
    bright    = nil,         -- percent
    volume    = nil,         -- percent
    muted     = false,
}

local refresh_timer -- 2.5 s while open (declared below)

-------------------------------------------------------------------------- primitives

local function set_markup(widget, str)
    if widget._private.cc_markup == str then return end
    widget._private.cc_markup = str
    widget:set_markup_silently(str)
end

--- macOS-style switch: rounded pill, knob slides with an ease-out tween.
local function make_switch(id, on_toggle)
    local checked = false
    -- Every level is wrapped in a place: a fixed/align layout hands a child
    -- the whole row height and ignores forced sizes, so an unwrapped knob is
    -- painted as a stretched ellipse instead of a 16 px circle.
    local knob = wibox.container.background()
    knob.shape = gears.shape.circle
    knob.bg = ui.color.text_strong
    knob.forced_width = 16
    knob.forced_height = 16
    knob.widget = wibox.widget.textbox()

    local knob_slot = wibox.container.place(knob)
    knob_slot.halign = "center"
    knob_slot.valign = "center"

    local slide = wibox.widget{
        knob_slot, left = 4, right = 22, widget = wibox.container.margin,
    }
    local pill = wibox.container.background()
    pill.shape = gears.shape.rounded_bar
    pill.bg = ui.color.track
    pill.forced_width = 42
    pill.forced_height = 24
    pill.widget = wibox.container.place(slide)

    local function set_knob(on)
        anim.tween{ tag = "cc_switch_" .. id, duration = 0.16,
            step = function(t)
                slide.left  = on and 4 + 18 * t or 22 - 18 * t
                slide.right = on and 22 - 18 * t or 4 + 18 * t
            end }
    end

    function pill:set_checked(b)
        local changed = checked ~= b
        checked = b
        pill.bg = b and ui.color.accent_bg_hi or ui.color.track
        if changed then set_knob(b) end
        return changed
    end
    function pill:get_checked() return checked end

    pill:buttons(gears.table.join(awful.button({}, 1, function()
        checked = not checked
        pill.bg = checked and ui.color.accent_bg_hi or ui.color.track
        set_knob(checked)
        if on_toggle then on_toggle(checked) end
    end)))

    return pill
end

-- Row geometry: every row is [glyph][label][spacer][control] inside one
-- fixed.horizontal, with the spacer computed from the popover's own width.
-- align.horizontal shrinks its outer widgets to whatever is left, which
-- squeezed switches into vertical slivers and clipped the value columns.
local CONTENT_W = 316 - 2 * ui.surface_pad_h        -- card width
local ROW_W     = CONTENT_W - 2 * ui.space.s        -- row content width

local function line(lead, lead_w, trail, trail_w)
    local box = wibox.widget{ layout = wibox.layout.fixed.horizontal }
    lead.forced_width = lead_w
    box:add(lead)
    box:add(ui.spacer(math.max(0, ROW_W - lead_w - (trail_w or 0)), 1))
    if trail then
        if trail_w then trail.forced_width = trail_w end
        box:add(trail)
    end
    return box
end

--- A full-width switch row: glyph, label (+ optional sub line), switch.
local function switch_row(icon_glyph, label, sub, id, on_toggle)
    local icon = ui.icon(icon_glyph, ui.glyph.m, ui.color.text_dim)
    local main = ui.text{ font = ui.font.body, width = 166, ellipsize = "end" }
    local subline = ui.text{ font = ui.font.tiny, width = 166, ellipsize = "end" }

    local switch = make_switch(id, on_toggle)
    local switch_slot = wibox.container.place(switch)
    switch_slot.halign = "left"
    switch_slot.valign = "center"

    local texts = wibox.layout.fixed.vertical()
    texts.spacing = 0
    texts:add(main)
    texts:add(subline)

    local lead = wibox.widget{
        { icon, left = 2, right = 12, widget = wibox.container.margin },
        texts,
        layout = wibox.layout.fixed.horizontal,
    }

    local row = wibox.container.background()
    row.shape = ui.radius_shape.card
    row.bg = ui.color.transparent
    row.forced_height = sub and 40 or 32
    row.widget = ui.pad(line(lead, 194, switch_slot, 42),
        ui.space.s, ui.space.s, ui.space.xs, ui.space.xs)

    ui.hover(row, function() return ui.color.transparent end, ui.color.hover)

    function row:set(main_text, sub_text, on)
        ui.set_text(main, main_text, on and ui.color.text or ui.color.text_dim)
        ui.set_text(subline, sub_text or "", ui.color.text_faint)
        switch:set_checked(on)
    end

    row:set(label, sub, false)
    return row
end

--- Icon + label + trailing widget (slider rows, device rows).
local function row(icon_glyph, label, trailing, height, on_hover)
    local icon = ui.icon(icon_glyph, ui.glyph.m, ui.color.text_dim)
    local main = ui.text{ font = ui.font.body, ellipsize = "end" }
    ui.set_text(main, label, ui.color.text_dim)

    local lead = wibox.widget{
        { icon, left = 2, right = 12, widget = wibox.container.margin },
        main,
        layout = wibox.layout.fixed.horizontal,
    }

    local r = wibox.container.background()
    r.shape = ui.radius_shape.chip
    r.bg = ui.color.transparent
    r.forced_height = height or 32
    r.widget = ui.pad(line(lead, 96, trailing, trailing and 160 or 0),
        ui.space.s, ui.space.s, ui.space.xs, ui.space.xs)
    if on_hover then
        ui.hover(r, function() return ui.color.transparent end, ui.color.hover)
    end
    r.label = main
    r.icon = icon
    return r
end

local function slider(min, max)
    -- macOS-style composite: visible track + accent fill + round handle
    -- (the stock 4.3 slider has no value fill and an invisible track).
    return ui.slider{
        minimum = min, maximum = max,
        width = 112, height = 20, bar_height = 4,
    }
end

-------------------------------------------------------------------------- rows

local wifi_row, bt_row
local bright_slider, bright_pct
local vol_slider, vol_pct, vol_icon
local device_list
local last_device_sig -- device-list signature: rows only rebuild on change

local dragging, syncing = false, false
local pending_bright, pending_vol
local throttle = gears.timer{ timeout = 0.25, single_shot = true, callback = function()
    if pending_bright then
        awful.spawn.with_shell(
            string.format("sudo -n brightnessctl -q set %d%%", math.floor(pending_bright + 0.5)))
        pending_bright = nil
    end
    if pending_vol then
        awful.spawn.with_shell(
            string.format("wpctl set-volume @DEFAULT_AUDIO_SINK@ %d%%", math.floor(pending_vol + 0.5)))
        pending_vol = nil
    end
end }

local function queue(field, value)
    if field == "bright" then pending_bright = value else pending_vol = value end
    if not throttle.started then throttle:start() else throttle:again() end
end

local refresh -- forward declaration (toggles and the timer call it)

local function resync_soon(delay)
    gears.timer.start_new(delay or 1.0, function()
        if refresh_timer and refresh_timer.started then refresh() end
        return false
    end)
end

-------------------------------------------------------------------------- refresh

function refresh()
    awful.spawn.easy_async_with_shell(PROBE, function(out)
        local d = {}
        for line in (out or ""):gmatch("[^\n]+") do
            local kind, a, b = line:match("^(%u)[ \t](.*)$")
            if kind == "P" or kind == "C" then
                local mac, name = a:match("^([%x:]+)\t(.+)$")
                if mac then
                    local dev = d.devices and d.devices[mac]
                    if not dev then
                        dev = { mac = mac, name = name, connected = false }
                        d.devices = d.devices or {}
                        d.devices[mac] = dev
                    end
                    if kind == "C" then dev.connected = true; dev.cname = name end
                end
            elseif kind then
                d[kind] = a
            end
        end

        -- Wi-Fi
        state.wifi_available = not (d.W == "unavailable" or d.W == nil)
        state.wifi_on = state.wifi_available and d.W:find("enabled") ~= nil
        state.wifi_name = (d.S and d.S ~= "") and d.S or nil
        if wifi_row then
            wifi_row:set(
                state.wifi_on and (state.wifi_name or "Wi-Fi") or "Wi-Fi",
                state.wifi_available and (state.wifi_on and "connected" or "off") or "unavailable",
                state.wifi_on)
        end

        -- Bluetooth + paired devices
        state.bt_available = (d.B ~= nil and d.B ~= "")
        state.bt_on = d.B == "yes"
        if bt_row then
            bt_row:set("Bluetooth",
                state.bt_available and (state.bt_on and "on" or "off") or "unavailable",
                state.bt_on)
        end
        if device_list then
            -- Rebuild the device rows only when the list actually changed:
            -- the 2.5 s refresh used to tear down and rebuild every row on
            -- each tick, flickering the open popover for identical data.
            local devices = {}
            for _, dev in pairs(d.devices or {}) do devices[#devices + 1] = dev end
            table.sort(devices, function(a, b)
                if a.connected ~= b.connected then return a.connected end
                return a.name < b.name
            end)
            local sig = {}
            for i = 1, math.min(#devices, 3) do
                sig[#sig + 1] = devices[i].mac .. (devices[i].connected and "+" or "-")
            end
            sig = table.concat(sig, ",") .. "|" .. tostring(state.bt_available)
                .. tostring(state.bt_on)
            if sig ~= last_device_sig then
                last_device_sig = sig
                device_list:reset()
                local shown = 0
                for _, dev in ipairs(devices) do
                    if shown >= 3 then break end
                    shown = shown + 1
                    local dot = ui.dot(dev.connected and ui.color.ok or ui.color.idle_dot, 5)
                    local name = ui.text{ font = ui.font.small, ellipsize = "end", width = 158 }
                    ui.set_text(name, dev.name, dev.connected and ui.color.text or ui.color.text_dim)
                    local st = ui.text{ font = ui.font.tiny, align = "right", width = 66 }
                    ui.set_text(st, dev.connected and "connected" or "paired", ui.color.text_faint)
                    local r = wibox.container.background()
                    r.shape = ui.radius_shape.card
                    r.bg = ui.color.transparent
                    r.forced_height = 24
                    r.widget = ui.pad(wibox.widget{
                        wibox.widget{
                            { dot, left = 6, right = 8, widget = wibox.container.margin },
                            name,
                            layout = wibox.layout.fixed.horizontal,
                        },
                        nil,
                        st,
                        layout = wibox.layout.align.horizontal,
                    }, 2, 2, 0, 0)
                    ui.hover(r, function() return ui.color.transparent end, ui.color.hover)
                    r:buttons(gears.table.join(awful.button({}, 1, function()
                        awful.spawn.with_shell("bluetoothctl " ..
                            (dev.connected and "disconnect " or "connect ") .. dev.mac)
                        resync_soon(1.5)
                    end)))
                    device_list:add(r)
                end
                if shown == 0 then
                    local empty = ui.text{ font = ui.font.tiny }
                    ui.set_text(empty, state.bt_available and state.bt_on
                        and "No paired devices" or "Bluetooth is off",
                        ui.color.text_faint, ui.font.tiny)
                    device_list:add(empty)
                end
            end
        end

        -- Brightness
        local pct = tonumber(d.L and d.L:match("(%d+)%%") or nil)
        if pct then
            ui.set_text(bright_pct, pct .. "%", ui.color.text, ui.font.body)
            if not dragging then
                syncing = true
                bright_slider:set_value(pct)
                syncing = nil
            end
        end

        -- Volume
        local vol = d.V and d.V:match("Volume:%s*([%d%.]+)")
        if vol then
            state.volume = math.floor(tonumber(vol) * 100 + 0.5)
            state.muted = d.V:find("MUTED", 1, true) ~= nil
            ui.set_text(vol_pct, (state.muted and "muted" or state.volume .. "%"),
                state.muted and ui.color.text_faint or ui.color.text, ui.font.body)
            ui.set_icon(vol_icon, state.muted and FA_VOL_MUTE or FA_VOL, ui.glyph.m,
                state.muted and ui.color.text_faint or ui.color.text_dim)
            if not dragging then
                syncing = true
                vol_slider:set_value(state.volume)
                syncing = nil
            end
        end
    end)
end

-------------------------------------------------------------------------- content

local function build_content()
    wifi_row = switch_row(FA_WIFI, "Wi-Fi", nil, "wifi", function(on)
        awful.spawn.with_shell("nmcli radio wifi " .. (on and "on" or "off"))
        resync_soon()
    end)

    bt_row = switch_row(FA_BT, "Bluetooth", nil, "bt", function(on)
        awful.spawn.with_shell("bluetoothctl power " .. (on and "on" or "off"))
        resync_soon()
    end)

    device_list = wibox.layout.fixed.vertical()
    device_list.spacing = 0

    bright_pct = ui.text{ font = ui.font.body, width = 40, align = "right" }
    bright_slider = slider(5, 100)
    bright_slider:connect_signal("button::press", function() dragging = true end)
    bright_slider:connect_signal("button::release", function()
        dragging = false
        queue("bright", bright_slider:get_value())
    end)
    bright_slider:connect_signal("property::value", function()
        if syncing then return end
        ui.set_text(bright_pct, math.floor(bright_slider:get_value()) .. "%",
            ui.color.text, ui.font.body)
        queue("bright", bright_slider:get_value())
    end)

    vol_pct = ui.text{ font = ui.font.body, width = 40, align = "right" }
    vol_slider = slider(0, 100)
    vol_icon = ui.icon(FA_VOL, ui.glyph.m, ui.color.text_dim)
    vol_icon:buttons(gears.table.join(awful.button({}, 1, function()
        awful.spawn.with_shell("wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle")
        resync_soon(0.5)
    end)))
    vol_slider:connect_signal("button::press", function() dragging = true end)
    vol_slider:connect_signal("button::release", function()
        dragging = false
        queue("vol", vol_slider:get_value())
    end)
    vol_slider:connect_signal("property::value", function()
        if syncing then return end
        ui.set_text(vol_pct, math.floor(vol_slider:get_value()) .. "%",
            state.muted and ui.color.text_faint or ui.color.text, ui.font.body)
        queue("vol", vol_slider:get_value())
    end)

    local bright_group = wibox.widget{
        bright_slider, { bright_pct, left = ui.space.s, widget = wibox.container.margin },
        layout = wibox.layout.fixed.horizontal,
    }
    local bright_row = row(FA_SUN, "Brightness", bright_group)
    local vol_group = wibox.widget{
        vol_slider, { vol_pct, left = ui.space.s, widget = wibox.container.margin },
        layout = wibox.layout.fixed.horizontal,
    }
    local vol_row = row(FA_VOL, "Volume", vol_group)

    local open_panel = row(FA_PANEL, "Open AETHER panel", nil, 26, true)
    open_panel:buttons(gears.table.join(awful.button({}, 1, function()
        M.close()
        require("panel").toggle()
    end)))
    open_panel.label:set_markup_silently(
        string.format('<span font="%s" foreground="%s">%s</span>',
            ui.font.body, ui.color.accent_hi, "Open AETHER panel"))

    local card = function(children)
        local box = wibox.container.background()
        box.shape = ui.radius_shape.card
        box.bg = ui.color.card_bg
        box.shape_border_width = 1
        box.shape_border_color = ui.color.border
        box.widget = wibox.layout.fixed.vertical()
        for _, child in ipairs(children) do box.widget:add(child) end
        return box
    end

    local content = wibox.layout.fixed.vertical()
    content.spacing = ui.space.xs
    content:add(ui.section("Connectivity"))
    content:add(card{ wifi_row, ui.divider(), bt_row, device_list })
    content:add(ui.section("Display & sound", { spacing_before = ui.space.m }))
    content:add(card{ bright_row, ui.divider(), vol_row })
    content:add(ui.divider())
    content:add(open_panel)

    -- S1: the first probe takes ~200 ms; until it returns the rows say they
    -- are being read instead of showing a blank sub-line and a switch that
    -- looks switched off.
    wifi_row:set("Wi-Fi", "checking…", false)
    bt_row:set("Bluetooth", "checking…", false)

    -- No ui.surface here: popover.apply already pads every spec.content by
    -- surface_pad_h/v, and wrapping twice cost 32 px per side — the row content
    -- box was 252 px wide while the rows were laid out for 268 (the switch was
    -- squeezed to a sliver and the value columns were clipped).
    return content
end

-------------------------------------------------------------------------- popup

local cc_open = false
local cc_popup -- the current content widget (built per open)

local function close_cc()
    if not cc_open then return end
    cc_open = false
    if refresh_timer then refresh_timer:stop() end
    popover_mgr.close("cc")
end

local function open_cc()
    -- One surface at a time across the whole bar; the media popover, the
    -- AETHER panel and any contextual reveal yield to it.  Placement,
    -- animation and dismissal are owned by the shared surface manager.
    cc_popup = build_content()
    popover_mgr.show{
        id = "cc",
        content = cc_popup,
        width = 316,
        modal = true,
        reopen = open_cc,
        on_open = function()
            cc_open = true
            if not refresh_timer then
                refresh_timer = gears.timer{ timeout = 2.5, callback = function() refresh() end }
            end
            if not refresh_timer.started then refresh_timer:start() end
        end,
        on_close = function()
            cc_open = false
            if refresh_timer then refresh_timer:stop() end
        end,
    }
    refresh()
end

function M.toggle()
    if cc_open then close_cc() else open_cc() end
end

function M.close()
    close_cc()
end

--------------------------------------------------------------------------
-- Bar button: a clear, hoverable pill in the right cluster.
--------------------------------------------------------------------------

function M.new_button()
    -- 16 px: the control glyph reads at the icon size of the scale.  At 10 px
    -- the sliders glyph is three specks and does not say "controls" (Q4).
    local glyph = ui.icon(FA_SLIDERS, ui.glyph.l, ui.color.text_dim)
    local root = wibox.container.background()
    root.shape = ui.radius_shape.card
    root.bg = ui.color.transparent
    root.forced_width = 28
    root.forced_height = 24
    root.widget = wibox.container.place(ui.pad(glyph, ui.space.xs, ui.space.xs, 0, 0))
    ui.hover(root, function() return ui.color.transparent end, ui.color.hover,
        function() ui.set_icon(glyph, FA_SLIDERS, ui.glyph.l, ui.color.text) end,
        function() ui.set_icon(glyph, FA_SLIDERS, ui.glyph.l, ui.color.text_dim) end)
    root:buttons(gears.table.join(awful.button({}, 1, function() M.toggle() end)))
    return root
end

return M
