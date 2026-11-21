--------------------------------------------------------------------------
-- glass.lua — frosted-glass window treatment for AwesomeWM
--
-- Awesome has no compositor of its own: window transparency here means
-- _NET_WM_WINDOW_OPACITY on the WM frame (set by `client.opacity`) plus
-- picom, which actually composites and blurs the desktop behind the window.
-- This module owns both halves that belong to Awesome:
--
--   * theme: 1px-equivalent muted borders, dark translucent menus/popups and
--     notifications, so the non-client surfaces share the glass look;
--   * opacity: focused / unfocused / floating / maximized / fullscreen
--     all get their own level, applied on every relevant client signal;
--   * compositor: one picom instance, started only if none is running and
--     respawned by a watchdog if it dies.  Without picom the opacity
--     property is simply ignored by X, so a dead compositor degrades to
--     opaque windows rather than a broken desktop.
--
-- Tune the values below; they are read once in setup().  After changing the
-- picom config, apply it without touching the WM:
--     awesome-client 'require("glass").restart_compositor()'
--
-- To re-enable titlebars (they are disabled in rc.lua's rules), set the
-- rules' titlebars_enabled back to true: the theme keys for them are set
-- below as well.
--------------------------------------------------------------------------

local awful     = require("awful")
local beautiful = require("beautiful")
local gears     = require("gears")
local wibox     = require("wibox")
local gstring   = require("gears.string")
local gsurface = require("gears.surface")

local M = {}

M.config = {
    -- Window opacity.  Text stays readable because the terminal itself keeps
    -- a nearly opaque background (kitty: background_opacity in kitty.conf);
    -- these values fade the whole window on top of that.
    focused_opacity            = 0.94,
    unfocused_opacity          = 0.88,
    floating_focused_opacity   = 0.92,
    floating_unfocused_opacity = 0.86,
    maximized_opacity          = 0.97,
    fullscreen_opacity         = 1.00,

    -- A 1px border disappears on busy wallpapers; 2px stays visible without
    -- becoming an outline.  Alpha in client border colours is ignored by
    -- Awesome (verified: #ffffff80 renders solid white), so these are muted
    -- opaque equivalents of "low-opacity white".
    border_width  = 2,
    border_focus  = "#9aa7b8",
    border_normal = "#3a414d",

    -- Clients that paint their own alpha (launchers/HUDs) must keep full
    -- window opacity, otherwise their own translucency is multiplied down.
    opacity_exclude = { starlight = true, launchpad = true },

    picom_config = os.getenv("HOME") .. "/.config/picom/picom.conf",
    compositor_watchdog  = true,
    watchdog_interval    = 15,

    -- macOS-style glass titlebar (see M.titlebar).  The bar is a translucent
    -- wibox over the panel's top strip, so picom blurs the wallpaper behind
    -- it.  It is shaped with only the top corners rounded to match the
    -- panel's picom-rounded outline; picom must therefore not round awesome
    -- wiboxes itself (see rounded-corners-exclude in picom.conf).
    titlebar_height    = 28,
    titlebar_bg_normal = "#0a0c10b8",
    titlebar_bg_focus  = "#0d1117cc",
    titlebar_font      = "Inter SemiBold 10",
    titlebar_meta_font = "Inter Medium 9",
    titlebar_fg_normal = "#9aa0aa",
    titlebar_fg_focus  = "#f2f4f8",
    titlebar_meta_fg   = "#7f8792",
    corner_radius      = 12,
}

local cfg = M.config
local started = false
local watchdog
local get_compositor_state  -- forward declaration

-------------------------------------------------------------------------- theme

local function apply_theme()
    beautiful.border_width  = cfg.border_width
    beautiful.border_focus  = cfg.border_focus
    beautiful.border_normal = cfg.border_normal
    beautiful.border_marked = "#c9a227"

    -- Non-client surfaces.  bg_normal/bg_focus are the fallbacks menus,
    -- tooltips and titlebars read; the explicit keys override them per
    -- widget class.  Alpha here is in the wibox/drawin path (cairo), which
    -- does honour it.
    beautiful.bg_normal = "#0e1014e6"
    beautiful.bg_focus  = "#1a2029f2"
    beautiful.bg_urgent = "#8c2f2f"
    beautiful.bg_minimize = "#2a2f38"
    beautiful.fg_normal = "#c9ccd4"
    beautiful.fg_focus  = "#f5f7fa"
    beautiful.fg_urgent = "#ffffff"
    beautiful.fg_minimize = "#f5f7fa"

    beautiful.menu_bg_normal = "#0e1014e6"
    beautiful.menu_bg_focus  = "#26303deb"
    beautiful.menu_fg_normal = "#c9ccd4"
    beautiful.menu_fg_focus  = "#ffffff"
    beautiful.menu_border_color = "#ffffff1f"
    beautiful.menu_border_width = 1
    beautiful.menu_font = "Inter Medium 10"

    beautiful.notification_bg = "#0e1014e6"
    beautiful.notification_fg = "#e6e8ee"
    beautiful.notification_border_color = "#ffffff1f"
    beautiful.notification_border_width = 1
    beautiful.notification_shape = function(cr, w, h)
        gears.shape.rounded_rect(cr, w, h, 12)
    end
    beautiful.notification_font = "Inter Medium 10"

    beautiful.tooltip_bg_color = "#0e1014e6"
    beautiful.tooltip_fg_color = "#e6e8ee"
    beautiful.tooltip_font = "Inter Medium 9"

    -- Only used if titlebars are re-enabled in rc.lua.
    beautiful.titlebar_bg_normal = "#0e1014d9"
    beautiful.titlebar_bg_focus  = "#161c25e6"
    beautiful.titlebar_fg_normal = "#9aa0aa"
    beautiful.titlebar_fg_focus  = "#f5f7fa"
end

-------------------------------------------------------------------------- opacity

local function tiled_opacity(c)
    if client.focus == c then return cfg.focused_opacity end
    return cfg.unfocused_opacity
end

local function floating_opacity(c)
    if client.focus == c then return cfg.floating_focused_opacity end
    return cfg.floating_unfocused_opacity
end

local function target_opacity(c)
    if c.fullscreen then return cfg.fullscreen_opacity end
    if c.maximized then return cfg.maximized_opacity end
    if c.floating then return floating_opacity(c) end
    return tiled_opacity(c)
end

local function apply_opacity(c)
    if not c.valid then return end
    if cfg.opacity_exclude[c.class] then
        c.opacity = 1.0
        return
    end
    c.opacity = target_opacity(c)
end

local function connect_client_signals()
    client.connect_signal("manage", apply_opacity)
    client.connect_signal("focus", apply_opacity)
    client.connect_signal("unfocus", apply_opacity)

    -- Everything that changes which tier the window belongs to.
    for _, prop in ipairs{
        "floating", "fullscreen", "maximized",
        "maximized_horizontal", "maximized_vertical",
    } do
        client.connect_signal("property::" .. prop, apply_opacity)
    end
end

-------------------------------------------------------------------------- compositor

-- True when picom is installed and running.  `command -v` first so a missing
-- binary does not make the watchdog spawn-fail every interval.
get_compositor_state = function(callback)
    awful.spawn.easy_async_with_shell(
        "command -v picom >/dev/null 2>&1 && pgrep -x picom >/dev/null 2>&1",
        function(_, _, _, code) callback(code == 0) end)
end

local function spawn_compositor()
    awful.spawn("picom --config " .. cfg.picom_config .. " --daemon")
    print("glass: started picom")
end

function M.start_compositor()
    get_compositor_state(function(running)
        if running then
            print("glass: picom already running, leaving it alone")
        else
            spawn_compositor()
        end
    end)

    if cfg.compositor_watchdog and not watchdog then
        watchdog = gears.timer{
            timeout = cfg.watchdog_interval,
            autostart = true,
            callback = function()
                get_compositor_state(function(running)
                    if not running then
                        spawn_compositor()
                    end
                end)
            end,
        }
    end
end

-- pkill + start, for config tweaks without restarting Awesome.
function M.restart_compositor()
    awful.spawn.easy_async_with_shell("pkill -x picom", function()
        M.start_compositor()
    end)
end

-------------------------------------------------------------------------- titlebar

-- macOS-style control: a filled circle.  Clicks go to the margin around it so
-- the hit target is bigger than the 13 px dot.
local function traffic_dot(c, normal, hover, action)
    local dot = wibox.container.background()
    dot.shape = gears.shape.circle
    dot.bg = normal
    dot.forced_width = 13
    dot.forced_height = 13
    -- container.background paints its background only when it has a child.
    dot.widget = wibox.widget.textbox()

    local hit = wibox.container.margin(dot, 5, 5, 0, 0)
    hit:buttons(gears.table.join(awful.button({}, 1, function()
        c:emit_signal("request::activate", "titlebar", {raise = true})
        action(c)
    end)))
    hit:connect_signal("mouse::enter", function() dot.bg = hover end)
    hit:connect_signal("mouse::leave", function() dot.bg = normal end)
    return hit
end

local function window_state(c)
    if c.fullscreen then return "fullscreen" end
    if c.maximized then return "maximized" end
    if c.floating then return "floating" end
    return "tiled"
end

-- Rounded top corners only: the bar sits on top of the panel, whose top
-- corners picom rounds, so a square bar would paint over that curve.
local function shape_titlebar(tb)
    local ok, err = pcall(function()
        local g = tb.drawable:geometry()
        if not g or g.width <= 0 or g.height <= 0 then return end
        gsurface.apply_shape_bounding(tb.drawable,
            gears.shape.partially_rounded_rect,
            true, true, false, false, cfg.corner_radius)
    end)
    if not ok then
        print("glass: titlebar shape failed: " .. tostring(err))
    end
end

--- Build the glass titlebar for a client.  Call from `request::titlebars`.
function M.titlebar(c)
    local tb = awful.titlebar(c, {
        size      = cfg.titlebar_height,
        bg_normal = cfg.titlebar_bg_normal,
        bg_focus  = cfg.titlebar_bg_focus,
        fg_normal = cfg.titlebar_fg_normal,
        fg_focus  = cfg.titlebar_fg_focus,
    })

    local buttons = gears.table.join(
        awful.button({}, 1, function()
            c:emit_signal("request::activate", "titlebar", {raise = true})
            awful.mouse.client.move(c)
        end),
        awful.button({}, 3, function()
            c:emit_signal("request::activate", "titlebar", {raise = true})
            awful.mouse.client.resize(c)
        end))

    -- Application identity (left).
    local icon = awful.titlebar.widget.iconwidget(c)
    icon.forced_width = 16
    icon.forced_height = 16
    icon.resize = true

    local app = wibox.widget.textbox()
    app.font = cfg.titlebar_meta_font
    app.markup = string.format('<span foreground="%s">%s</span>',
        cfg.titlebar_meta_fg, gstring.xml_escape(c.class or ""))

    -- Window title (centre).  Recoloured on focus so the active panel reads
    -- as foreground without needing a second bar style.
    local title = wibox.widget.textbox()
    title.font = cfg.titlebar_font
    title.align = "center"
    title.ellipsize = "end"
    local function refresh_title()
        local fg = (client.focus == c) and cfg.titlebar_fg_focus or cfg.titlebar_fg_normal
        title.markup = string.format('<span foreground="%s">%s</span>',
            fg, gstring.xml_escape(c.name or ""))
    end
    c:connect_signal("property::name", refresh_title)
    c:connect_signal("focus", refresh_title)
    c:connect_signal("unfocus", refresh_title)
    refresh_title()

    -- Window state (right), a cheap per-window stat.
    local state = wibox.widget.textbox()
    state.font = cfg.titlebar_meta_font
    local function refresh_state()
        state.markup = string.format('<span foreground="%s">%s</span>',
            cfg.titlebar_meta_fg, window_state(c))
    end
    for _, prop in ipairs{
        "floating", "fullscreen", "maximized",
        "maximized_horizontal", "maximized_vertical",
    } do
        c:connect_signal("property::" .. prop, refresh_state)
    end
    refresh_state()

    tb:setup {
        {
            layout = wibox.layout.fixed.horizontal,
            spacing = 8,
            { widget = icon, valign = "center", buttons = buttons },
            { widget = app,  valign = "center", buttons = buttons },
        },
        { align = "center", widget = title, buttons = buttons },
        {
            layout = wibox.layout.fixed.horizontal,
            spacing = 8,
            { widget = state, valign = "center", buttons = buttons },
            {
                layout = wibox.layout.fixed.horizontal,
                spacing = 0,
                traffic_dot(c, "#ff5f57", "#ff7b74", function(cl) cl:kill() end),
                traffic_dot(c, "#febc2e", "#ffd058", function(cl) cl.minimized = true end),
                traffic_dot(c, "#28c840", "#4ade68", function(cl)
                    cl.maximized = not cl.maximized
                    cl:raise()
                end),
            },
        },
        layout = wibox.layout.align.horizontal,
    }

    -- The bar spans the client width; keep its rounded shape in sync.  The
    -- drawable's own geometry signal runs after its resize, so the shape is
    -- never applied at a stale width (which would clip the right end).
    tb.drawable:connect_signal("property::geometry", function()
        shape_titlebar(tb)
    end)
    gears.timer.start_new(0.05, function()
        shape_titlebar(tb)
        return false
    end)
end

-------------------------------------------------------------------------- setup

function M.setup()
    if started then return end
    started = true
    apply_theme()
    connect_client_signals()
    -- On an Awesome restart the existing clients are re-managed, but apply
    -- once here as well so the look is correct immediately either way.
    for _, c in ipairs(client.get()) do
        apply_opacity(c)
    end
end

return M
