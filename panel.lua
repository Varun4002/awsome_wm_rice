--------------------------------------------------------------------------
-- panel.lua — Layer 4 expanded intelligence panel
--
-- One temporary surface that brings together what would otherwise need four
-- separate widgets: OpenCode, the open windows, the workspaces of the
-- screen it was opened on, system status, and time.  It is not a control
-- center: Wi-Fi/Bluetooth/brightness remain owned by control_center.lua and
-- the panel only reports their state and offers one explicit "Open controls"
-- action.
--
-- Dismissal: Escape (rc.lua takes the grab while a modal surface is open),
-- pointer leave, or the AETHER mark again.  Opening it does not create a
-- second bar or duplicate any listener: everything is built once per open
-- and disposed on close.
--------------------------------------------------------------------------

local awful = require("awful")
local gears = require("gears")
local wibox = require("wibox")

local ui          = require("ui")
local popover     = require("popover")
local workspaces  = require("workspaces")
local opencode    = require("opencode")
local opencode_ui = require("opencode_ui")
local clock       = require("clock")

local M = {}

local WIDTH = 396

-------------------------------------------------------------------------- system

local function read_system(cb)
    awful.spawn.easy_async_with_shell(
        "echo \"W $(nmcli -t -f WIFI radio 2>/dev/null || echo unavailable)\"; " ..
        "echo \"S $(nmcli --escape=no -t -f NAME,TYPE connection show --active 2>/dev/null " ..
        "| grep 802-11-wireless | cut -d: -f1 | head -1)\"; " ..
        "echo \"B $(bluetoothctl show 2>/dev/null | grep -m1 Powered: | grep -oE 'yes|no')\"; " ..
        "echo \"L $(brightnessctl -m 2>/dev/null | cut -d, -f4)\"; " ..
        "echo \"V $(wpctl get-volume @DEFAULT_AUDIO_SINK@ 2>/dev/null || echo unavailable)\"",
        function(out)
            local data = {}
            for line in (out or ""):gmatch("[^\n]+") do
                local k, v = line:match("^(%u) (.*)$")
                if k then data[k] = v:gsub("%s+$", "") end
            end
            cb(data)
        end)
end

local function system_rows(data)
    local d = data or {}
    local loading = data == nil
    local rows = wibox.layout.fixed.vertical()
    rows.spacing = 0

    local wifi_on = d.W and d.W:find("enabled") ~= nil
    local wifi = "unavailable"
    if d.W and d.W:find("enabled") then
        wifi = (d.S and d.S ~= "") and d.S or "not connected"
    elseif d.W and d.W:find("disabled") then
        wifi = "off"
    end

    local bt = "unavailable"
    if d.B == "yes" then bt = "on" elseif d.B == "no" then bt = "off" end

    local bright = "unavailable"
    if d.L and d.L:match("%d") then bright = d.L end

    local audio = "unavailable"
    if d.V then
        local vol = d.V:match("Volume:%s*([%d%.]+)")
        if vol then
            audio = string.format("%d%%", math.floor(tonumber(vol) * 100 + 0.5))
            if d.V:find("MUTED", 1, true) then audio = audio .. " · muted" end
        end
    end

    -- S1: before the probe returns, a row says it is being read.  "unavailable"
    -- is an answer, not a loading state, and the panel used to show it for the
    -- first ~200 ms of every open.
    local function row(key, value, unavailable)
        if loading then value = "checking…" end
        return ui.key_value(key, value, {
            fg = (loading or unavailable) and ui.color.text_faint
                 or ui.color.text_dim,
            key_width = 86,
            height = 20,
        })
    end
    rows:add(row("Wi-Fi", wifi, wifi == "unavailable"))
    rows:add(row("Bluetooth", bt, bt == "unavailable"))
    rows:add(row("Display", bright, bright == "unavailable"))
    rows:add(row("Audio", audio, audio == "unavailable"))
    return rows
end

-------------------------------------------------------------------------- windows

local function window_signature()
    local parts = {}
    for _, c in ipairs(client.get()) do
        parts[#parts + 1] = tostring(c.window) .. ":" .. tostring(c.name) ..
            ":" .. tostring(c.screen and c.screen.index) ..
            ":" .. tostring(c.first_tag and c.first_tag.index) ..
            ":" .. tostring(c.minimized) .. ":" .. tostring(c == client.focus)
    end
    table.sort(parts)
    return table.concat(parts, "|")
end

local function window_rows(on_pick)
    local clients = client.get()
    table.sort(clients, function(a, b)
        if (a == client.focus) ~= (b == client.focus) then return a == client.focus end
        if (a.screen and a.screen.index or 0) ~= (b.screen and b.screen.index or 0) then
            return (a.screen and a.screen.index or 0) < (b.screen and b.screen.index or 0)
        end
        return (a.name or "") < (b.name or "")
    end)

    local list = wibox.layout.fixed.vertical()
    list.spacing = ui.space.xs
    local shown = 0
    for _, c in ipairs(clients) do
        if shown >= 4 then break end
        shown = shown + 1
        local focused = (c == client.focus)
        local dot = ui.dot(focused and ui.color.accent or ui.color.idle_dot, 4)
        local title = ui.text{ font = ui.font.small, ellipsize = "end", width = 214 }
        ui.set_text(title, c.name ~= "" and c.name or "(untitled)",
            focused and ui.color.text or ui.color.text_dim)
        local tag = c.first_tag
        local meta = ui.text{ font = ui.font.tiny, align = "right", width = 96 }
        ui.set_text(meta, string.format("%s · S%d%s",
            tag and (tag.name or "?") or "?", c.screen and c.screen.index or 0,
            c.minimized and " · min" or ""), ui.color.text_faint)

        local row = wibox.container.background()
        row.shape = ui.radius_shape.card
        row.bg = focused and ui.color.occupied or ui.color.transparent
        row.forced_height = 24
        -- No inner inset: the row starts on the surface's content axis, like
        -- the section heading above it (continuity K3).
        row.widget = wibox.widget{
            wibox.widget{
                { dot, right = ui.space.s, widget = wibox.container.margin },
                ui.cell(ui.app_icon(c, 16)),
                { title, left = ui.space.s, widget = wibox.container.margin },
                layout = wibox.layout.fixed.horizontal,
            },
            nil,
            meta,
            layout = wibox.layout.align.horizontal,
        }
        ui.hover(row, function()
            return focused and ui.color.occupied or ui.color.transparent
        end, ui.color.hover)
        row:buttons(gears.table.join(awful.button({}, 1, function()
            if not c.valid then return end
            if c.minimized then c.minimized = false end
            c:emit_signal("request::activate", "aether_panel", { raise = true })
            c:jump_to()
            if on_pick then on_pick(c) end
        end)))
        list:add(row)
    end

    if shown == 0 then
        list:add(ui.text{ font = ui.font.small,
            markup = ui.span("No open windows", ui.color.text_faint) })
    end
    return list
end

-------------------------------------------------------------------------- panel

local function build(s)
    local alive = true
    local root = wibox.layout.fixed.vertical()
    -- Two interruption magnitudes only (continuity K4): 4 px inside a section
    -- (heading → content, row → row) and 12 px above every section heading.
    -- The single divider that used to separate the header from OpenCode read
    -- as a stronger boundary than five section breaks.
    root.spacing = ui.space.xs

    -- header -------------------------------------------------------------
    local mark = ui.text{ font = ui.font.title }
    ui.set_markup(mark, ui.span("AETHER", ui.color.text, ui.font.title))
    local time = ui.text{ font = ui.font.strong, align = "right", width = 140 }
    local date = ui.text{ font = ui.font.tiny, align = "right", width = 140 }
    local detach_clock = clock.attach(time, date)
    -- Pending work is the one thing on this surface that asks for an action,
    -- so it sits in the header: attention first, orientation below.
    local pending = ui.text{ font = ui.font.small, align = "center" }

    root:add(wibox.widget{
        mark,
        pending,
        wibox.widget{
            time, date,
            layout = wibox.layout.fixed.vertical,
            spacing = 0,
        },
        layout = wibox.layout.align.horizontal,
    })

    -- Workspaces ---------------------------------------------------------
    root:add(ui.section("Workspaces", { spacing_before = ui.space.m }))
    local ws_holder = wibox.container.background()
    ws_holder.widget = workspaces.panel_rows(s, function(tag)
        tag:view_only()
        M.close()
    end, { width = WIDTH - 2 * ui.surface_pad_h })
    root:add(ws_holder)

    -- Windows ------------------------------------------------------------
    root:add(ui.section("Windows", { spacing_before = ui.space.m }))
    local windows_holder = wibox.container.background()
    windows_holder.widget = window_rows(function() M.close() end)
    root:add(windows_holder)

    -- OpenCode -----------------------------------------------------------
    root:add(ui.section("OpenCode", { spacing_before = ui.space.m }))
    local oc_section = opencode_ui.panel_section(function() M.close() end)
    root:add(oc_section)

    -- System -------------------------------------------------------------
    root:add(ui.section("System", { spacing_before = ui.space.m }))
    local sys_holder = wibox.container.background()
    sys_holder.widget = system_rows(nil)
    root:add(sys_holder)
    root:add(wibox.widget{
        ui.chip{
            label = "Open controls", glyph = "\u{f1de}",
            onclick = function()
                M.close()
                require("control_center").toggle()
            end,
        },
        layout = wibox.layout.fixed.horizontal,
    })

    -- Time ---------------------------------------------------------------
    local now = os.date("*t")
    root:add(ui.section("Time", { spacing_before = ui.space.m }))
    local month = ui.text{ font = ui.font.strong }
    ui.set_text(month, ui.month_title(now.year, now.month), ui.color.text_dim,
        ui.font.strong)
    root:add(month)
    root:add(ui.calendar(now.year, now.month, 28))
    root:add(ui.text{ font = ui.font.tiny,
        markup = ui.span("Escape or click outside to dismiss", ui.color.text_faint) })

    read_system(function(data)
        if alive then sys_holder.widget = system_rows(data) end
    end)

    ---------------------------------------------------------------- refresh
    local ws_sig, win_sig, pending_n
    local function paint_pending()
        local st = opencode.state
        local n = st.pending and st.pending.total or 0
        if n == pending_n then return end
        pending_n = n
        if n > 0 then
            ui.set_markup(pending, ui.span(string.format("! %d pending", n),
                                          ui.color.warn, ui.font.small))
        else
            ui.set_markup(pending, "")
        end
    end
    paint_pending()
    local detach_pending = opencode.subscribe(paint_pending)

    ---------------------------------------------------------------- refresh
    local ws_sig, win_sig
    local function refresh()
        if not alive then return end
        local sig = window_signature()
        if sig ~= win_sig then
            win_sig = sig
            windows_holder.widget = window_rows(function() M.close() end)
        end
        local wparts = { s.index, tostring(client.focus and client.focus.window) }
        for _, t in ipairs(s.tags) do
            wparts[#wparts + 1] = tostring(t.index) .. (t.selected and "*" or "") ..
                (#t:clients())
        end
        local wsg = table.concat(wparts, ",")
        if wsg ~= ws_sig then
            ws_sig = wsg
            ws_holder.widget = workspaces.panel_rows(s, function(tag)
                tag:view_only()
                M.close()
            end, { width = WIDTH - 2 * ui.surface_pad_h })
        end
    end

    local watched = {}
    local function watch(sig_name, fn)
        client.connect_signal(sig_name, fn)
        watched[#watched + 1] = { sig_name, fn }
    end
    local function schedule()
        gears.timer.delayed_call(refresh)
    end
    watch("focus", schedule)
    watch("manage", schedule)
    watch("unmanage", schedule)
    watch("tagged", schedule)
    watch("untagged", schedule)
    for _, prop in ipairs{ "name", "minimized", "screen", "floating", "icon" } do
        watch("property::" .. prop, schedule)
    end
    tag.connect_signal("property::selected", schedule)

    local function dispose()
        alive = false
        detach_clock()
        if detach_pending then detach_pending() end
        for _, w in ipairs(watched) do
            client.disconnect_signal(w[1], w[2])
        end
        watched = {}
        tag.disconnect_signal("property::selected", schedule)
        if oc_section.dispose then oc_section.dispose() end
    end

    return root, dispose
end

-------------------------------------------------------------------------- public

function M.close()
    popover.close("panel")
end

--- Open the panel (idempotent).  A named opener rather than only a toggle:
-- the popover back-stack rebuilds a previous surface through its opener
-- (navigation N8), and `toggle` must stay a toggle for the click target.
function M.open(s)
    s = s or mouse.screen or awful.screen.focused()
    if not s then return end
    local content, dispose = build(s)
    popover.show{
        id = "panel",
        content = content,
        width = WIDTH,
        modal = true,
        screen = s,
        reopen = function() M.open(s) end,
        on_close = function() dispose() end,
    }
end

function M.toggle()
    if popover.is_open("panel") then
        M.close()
        return
    end
    M.open()
end

return M
