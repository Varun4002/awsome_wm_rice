-- If LuaRocks is installed, make sure that packages installed through it are
-- found (e.g. lgi). If LuaRocks is not installed, do nothing.
pcall(require, "luarocks.loader")

-- Standard awesome library
local gears = require("gears")
local awful = require("awful")
require("awful.autofocus")
-- Widget and layout library
local wibox = require("wibox")
-- Theme handling library
local beautiful = require("beautiful")
-- Notification library
local naughty = require("naughty")
local menubar = require("menubar")
-- macOS frosted top bar (also provides song/volume/usage widgets)
-- AETHER_RC_MARKER identifies the config generation currently loaded, so a
-- reload can be verified from awesome-client (AETHER_RC_MARKER ~= nil).
AETHER_RC_MARKER = "dot-v1"

local frostbar = require("frostbar")
-- Popover tween helper and the control-center popover (wifi/bt/brightness)
local anim           = require("anim")
local control_center = require("control_center")
local hotkeys_popup = require("awful.hotkeys_popup")
-- AETHER five-layer bar: design tokens, surface manager, layer modules and
-- the OpenCode integration state (see docs/06-five-layer-bar.md).
local ui          = require("ui")
local popover     = require("popover")
local workspaces  = require("workspaces")
local windower    = require("windower")
local dotws       = require("dotworkspace")
local dragtransfer = require("dragtransfer")
local clock       = require("clock")
local opencode    = require("opencode")
local opencode_ui = require("opencode_ui")
local panel       = require("panel")
local launchers   = require("launchers")
-- Enable hotkeys help widget for VIM and other apps
-- when client with a matching name is opened:
require("awful.hotkeys_popup.keys")

-- Load Debian menu entries
local debian = require("debian.menu")
local has_fdo, freedesktop = pcall(require, "freedesktop")

-- {{{ Error handling
-- Check if awesome encountered an error during startup and fell back to
-- another config (This code will only ever execute for the fallback config)
if awesome.startup_errors then
    naughty.notify({ preset = naughty.config.presets.critical,
                     title = "Oops, there were errors during startup!",
                     text = awesome.startup_errors })
end

-- Handle runtime errors after startup
do
    local in_error = false
    awesome.connect_signal("debug::error", function (err)
        -- Make sure we don't go into an endless error loop
        if in_error then return end
        in_error = true

        naughty.notify({ preset = naughty.config.presets.critical,
                         title = "Oops, an error happened!",
                         text = tostring(err) })
        in_error = false
    end)
end
-- }}}

-- {{{ Variable definitions
-- Themes define colours, icons, font and wallpapers.
beautiful.init(gears.filesystem.get_themes_dir() .. "default/theme.lua")

-- macOS frosted top bar: Inter for the wibar widgets, white-on-dark
-- colors, transparent item backgrounds so the frosted backdrop stays
-- visible (beautiful.font itself is left untouched).  Foregrounds use the
-- ui token palette so taglist/tasklist text matches bar and popover text.
beautiful.taglist_font = ui.font.body
beautiful.tasklist_font = ui.font.body
beautiful.taglist_bg_normal = ui.color.transparent
beautiful.taglist_bg_focus  = ui.color.transparent
beautiful.taglist_fg_normal = ui.color.text_dim
beautiful.taglist_fg_focus  = ui.color.text
beautiful.tasklist_bg_normal = ui.color.transparent
beautiful.tasklist_bg_focus  = ui.color.active
beautiful.tasklist_fg_normal = ui.color.text_dim
beautiful.tasklist_fg_focus  = ui.color.text

-- Frosted-glass windows: border/menu/notification theme, focus-aware window
-- opacity and the compositor lifecycle (see glass.lua for the tuning knobs).
local glass = require("glass")
glass.setup()

-- This is used later as the default terminal and editor to run.
terminal = "x-terminal-emulator"
editor = os.getenv("EDITOR") or "editor"
editor_cmd = terminal .. " -e " .. editor

-- Default modkey.
-- Usually, Mod4 is the key with a logo between Control and Alt.
-- If you do not like this or do not have such a key,
-- I suggest you to remap Mod4 to another key using xmodmap or other tools.
-- However, you can use another modifier like Mod1, but it may interact with others.
modkey = "Mod4"

-- Table of layouts to cover with awful.layout.inc, order matters.
awful.layout.layouts = {
    awful.layout.suit.floating,
    awful.layout.suit.tile,
    awful.layout.suit.tile.left,
    awful.layout.suit.tile.bottom,
    awful.layout.suit.tile.top,
    awful.layout.suit.fair,
    awful.layout.suit.fair.horizontal,
    awful.layout.suit.spiral,
    awful.layout.suit.spiral.dwindle,
    awful.layout.suit.max,
    awful.layout.suit.max.fullscreen,
    awful.layout.suit.magnifier,
    awful.layout.suit.corner.nw,
    -- awful.layout.suit.corner.ne,
    -- awful.layout.suit.corner.sw,
    -- awful.layout.suit.corner.se,
}
-- }}}

-- {{{ Menu
-- Create a launcher widget and a main menu
myawesomemenu = {
   { "hotkeys", function() hotkeys_popup.show_help(nil, awful.screen.focused()) end },
   { "manual", terminal .. " -e man awesome" },
   { "edit config", editor_cmd .. " " .. awesome.conffile },
   { "restart", awesome.restart },
   { "quit", function() awesome.quit() end },
}

local menu_awesome = { "awesome", myawesomemenu, beautiful.awesome_icon }
local menu_terminal = { "open terminal", terminal }
local menu_wallpaper = { "Change wallpaper", function() require("wallpaper_cycler").next() end }

if has_fdo then
    mymainmenu = freedesktop.menu.build({
        before = { menu_awesome },
        after =  { menu_terminal, menu_wallpaper }
    })
else
    mymainmenu = awful.menu({
        items = {
                  menu_awesome,
                  { "Debian", debian.menu.Debian_menu.Debian },
                  menu_terminal,
                  menu_wallpaper,
                }
    })
end


-- The AETHER mark in the bar replaces the old awesome-icon launcher: left
-- click opens the expanded panel, right click still opens this menu.

-- Menubar configuration
menubar.utils.terminal = terminal -- Set the terminal for applications that require it
-- }}}

-- {{{ Wibar
-- AETHER's five-layer bar.  Layer 1 (the ambient bar) is assembled here;
-- layers 2-4 are owned by their modules and anchored to these widgets;
-- layer 5 is the signal wiring (windower/opencode subscriptions plus the
-- autohide rule below).  Every widget that holds state is created once per
-- screen: a wibox widget cannot belong to two bar hierarchies.

local function aether_mark()
    local label = ui.text{ font = ui.font.mark }
    ui.set_text(label, "AETHER", ui.color.text, ui.font.mark)

    local root = wibox.container.background()
    root.shape = ui.radius_shape.chip
    root.bg = ui.color.transparent
    root.forced_height = ui.block_h
    root.widget = wibox.container.place(ui.pad(wibox.widget{
        { ui.dot(ui.color.accent, 5), right = 8, widget = wibox.container.margin },
        label,
        layout = wibox.layout.fixed.horizontal,
    }, 8, 8, 0, 0))

    ui.hover(root, function() return ui.color.transparent end, ui.color.hover,
        function() ui.set_text(label, "AETHER", ui.color.text_strong, ui.font.mark) end,
        function() ui.set_text(label, "AETHER", ui.color.text, ui.font.mark) end)

    -- Left click: the expanded intelligence panel (layer 4).  Right click:
    -- the existing main menu, so the awesome menu is still one gesture away.
    root:buttons(gears.table.join(
        awful.button({}, 1, function() panel.toggle() end),
        awful.button({}, 3, function() mymainmenu:toggle() end)))
    return root
end

local function set_wallpaper(s)
    -- Wallpaper
    if beautiful.wallpaper then
        local wallpaper = beautiful.wallpaper
        -- If wallpaper is a function, call it with the screen
        if type(wallpaper) == "function" then
            wallpaper = wallpaper(s)
        end
        gears.wallpaper.maximized(wallpaper, s, true)
    end
end

-- Re-set wallpaper when a screen's geometry changes (e.g. different resolution)
screen.connect_signal("property::geometry", set_wallpaper)

awful.screen.connect_for_each_screen(function(s)
    -- Wallpaper
    set_wallpaper(s)

    -- Each screen has its own tag table, led by the "." wallpaper showcase
    -- (see dotworkspace.lua).  The prepended dot shifts positional indexes,
    -- so tags are resolved BY NAME everywhere (dotws.numbered), never by
    -- raw index.  ensure_tags is idempotent: the setup callback can re-run
    -- for a re-enumerated screen and awful.tag only appends.
    local fresh = #s.tags == 0
    dotws.ensure_tags(s)
    -- A fresh screen boots onto the ordinary desktop; the dot is a
    -- deliberate destination, never a startup default.
    if fresh or #s.selected_tags == 0 then
        local boot = dotws.numbered(s, 1)
        if boot then boot:view_only() end
    end

    -- Create a promptbox for each screen
    s.mypromptbox = awful.widget.prompt()
    -- Create the layout indicator: a token-coloured cairo glyph instead of
    -- the stock layoutbox PNGs (U1).  Same buttons — it is still the layout
    -- switch.
    s.mylayoutbox = ui.layout_indicator(s)
    s.mylayoutbox:buttons(gears.table.join(
                           awful.button({ }, 1, function () awful.layout.inc( 1) end),
                           awful.button({ }, 3, function () awful.layout.inc(-1) end),
                           awful.button({ }, 4, function () awful.layout.inc( 1) end),
                           awful.button({ }, 5, function () awful.layout.inc(-1) end)))

    -- Keyboard layout indicator: one instance per bar (a widget cannot be
    -- shared between two hierarchies).
    local keyboardlayout = awful.widget.keyboardlayout()

    -- Systray: awesome 4.3 has a single tray instance and no client count, and
    -- it *fits icons to the available cell*: a fixed 22 px cell shrank two
    -- icons to 11 px each (illegible).  Fix the icon size and let the cell size
    -- itself to its content instead (bar-aesthetic Q2).
    local tray = wibox.widget.systray()
    tray:set_base_size(20)

    -- Create the wibox
    -- height must be passed in the constructor: the wibar's attached
    -- placement reverts later runtime height changes.
    -- ontop: awesome stacks ontop drawins after every client layer
    -- (fullscreen and _NET_WM_STATE_ABOVE included), so the bar cannot be
    -- covered by clients or by the cycler's desktop wibox (stack.c:
    -- stack_refresh).
    s.mywibox = awful.wibar({ position = "top", screen = s, height = ui.bar_height, ontop = true })
    -- Matches the frost fallback color; the frost widget paints over the
    -- bar background, but the systray's embedded X window uses this color.
    s.mywibox.bg = frostbar.fallback_bg

    -- Layer 1 assembly.  The centre slot of align.horizontal is centred on
    -- the whole bar width, so the active-window block stays optically
    -- centred while the side clusters grow and shrink.
    --
    -- Each cluster is wrapped in one `place` with valign="center": a fixed
    -- layout hands its children the full bar height, so every block used to
    -- centre itself independently and the bar carried two ink baselines 2 px
    -- apart (continuity K1).  One place per cluster gives all three one centre.
    local space = ui.space
    local left = wibox.widget{
        layout = wibox.layout.fixed.horizontal,
        aether_mark(),
        workspaces.widget(s),
        { workspaces.other_screen(s), left = space.s, widget = wibox.container.margin },
        s.mypromptbox,
    }
    local right = wibox.widget{
        layout = wibox.layout.fixed.horizontal,
        frostbar.new_song(s),
        opencode_ui.bar_widget(s),
        ui.pad(ui.vrule(ui.space.l), space.m, space.m, 0, 0),
        frostbar.new_volume(),
        ui.pad(ui.vrule(ui.space.l), space.m, space.m, 0, 0),
        ui.pad(keyboardlayout, 0, space.xs, 0, 0),
        -- The layout indicator draws its own 16x12 diagram; left unwrapped in
        -- a fixed row it was stretched to the full bar height and became the
        -- bar's largest graphic again (U1 regression).
        ui.cell(ui.pad(s.mylayoutbox, 0, space.xs, 0, 0)),
        -- Tray as a designed sunken cell: 4.3 has one systray and no client
        -- count, so screen 2 would otherwise show an unexplained gap.  The
        -- cell sizes itself to its icons (no forced width: a fixed one
        -- squeezed two 20 px icons into 22 px total).
        -- NOT wrapped in ui.cell: a place fits the systray, and when that fit
        -- is 0 the tray's draw divides by zero entries and the C call rejects
        -- the size (systray.lua:72).  A margin container passes the row
        -- height through instead, which is what the tray wants.
        wibox.widget{
            {
                tray,
                margins = 2,
                widget  = wibox.container.margin,
            },
            bg = ui.color.bg_sunken,
            shape = ui.radius_shape.chip,
            widget = wibox.container.background,
        },
        ui.pad(ui.vrule(ui.space.l), space.m, space.m, 0, 0),
        control_center.new_button(),
        ui.pad(ui.vrule(ui.space.l), space.m, space.m, 0, 0),
        clock.widget(s),
    }
    s.mywibox:setup {
        layout = wibox.layout.align.horizontal,
        { -- Left: identity, workspaces, other screen, prompt
            layout = wibox.container.place,
            halign = "left", valign = "center",
            left,
        },
        { -- Centre: the screen's active window (layer 1-3 anchor)
            layout = wibox.container.place,
            windower.widget(s),
            halign = "center",
            valign = "center",
        },
        { -- Right: media · OpenCode | audio | keyboard · layout · tray |
          -- controls | clock.  Thin rules separate the functional groups so
          -- the cluster reads as one interface instead of a pile of glyphs.
            layout = wibox.container.place,
            halign = "right", valign = "center",
            right,
        },
    }

    -- Frosted-glass backdrop painted underneath all of the above.
    s.mywibox:set_widget(frostbar.wrap(s.mywibox, s))

    -- Autohide interplay: when the bar was hidden by the fullscreen rule
    -- and revealed at the top edge, leaving it puts it away again.
    s.mywibox:connect_signal("mouse::leave", function()
        if s._bar_hidden then
            s._bar_revealed = false
            s.mywibox.visible = false
            s.mywibox.opacity = 1
        end
    end)
end)
-- }}}

-- {{{ Autohide: fullscreen content gets the whole screen; the bar steps
-- aside and is revealed by moving the pointer close to the top edge.
local function fullscreen_busy(s)
    if awful.layout.get(s) == awful.layout.suit.max.fullscreen then
        return true -- every client covers the bar in this layout
    end
    for _, c in ipairs(client.get()) do
        if c.screen == s and c.fullscreen and c:isvisible() then
            return true
        end
    end
    return false
end

-- Declared before the constructor: inside the callback `reveal_timer` must
-- refer to this local. With a single `local reveal_timer = gears.timer{...}`
-- the initializer cannot see the local, so the callback resolved the name to
-- a global (nil) and raised an error every 80 ms.
local reveal_timer
reveal_timer = gears.timer{ timeout = 0.08, callback = function()
    local any_hidden = false
    local mc = mouse.coords()
    for s in screen do
        if s._bar_hidden then
            any_hidden = true
            local g = s.geometry
            if mc.y <= 6 and mc.x >= g.x and mc.x < g.x + g.width then
                s._bar_revealed = true
                local b = s.mywibox
                if not b.visible then
                    b.visible = true
                    b.opacity = 0
                    anim.tween{ tag = "bar_reveal_" .. tostring(s.index), duration = 0.15,
                        step = function(t) b.opacity = t end,
                        done = function() b.opacity = 1 end }
                end
            end
        end
    end
    if not any_hidden then reveal_timer:stop() end
end }

local function update_bars()
    for s in screen do
        local b = s.mywibox
        if not b then goto continue end
        if fullscreen_busy(s) then
            if b.visible then
                -- Every AETHER layer (contextual reveals, control surface,
                -- panel, OpenCode, control center, media) is owned by the
                -- surface manager, so one call takes the whole bar UI away.
                popover.close_all()
                b.visible = false
                b.opacity = 1
                s._bar_hidden = true
                s._bar_revealed = false
                if not reveal_timer.started then reveal_timer:start() end
            end
        elseif not b.visible then
            s._bar_hidden = false
            s._bar_revealed = false
            b.visible = true
            b.opacity = 1
        end
        ::continue::
    end
end

client.connect_signal("property::fullscreen", update_bars)
client.connect_signal("manage", update_bars)
client.connect_signal("unmanage", update_bars)
tag.connect_signal("property::selected", update_bars)
tag.connect_signal("property::layout", update_bars)
screen.connect_signal("property::geometry", update_bars)
-- }}}

-- {{{ Mouse bindings
root.buttons(gears.table.join(
    awful.button({ }, 3, function () mymainmenu:toggle() end),
    awful.button({ }, 4, awful.tag.viewnext),
    awful.button({ }, 5, awful.tag.viewprev)
))
-- }}}

-- {{{ Key bindings
-- Brave (Mod4+b): the pointer's screen at keypress is remembered and consumed
-- by the Brave window rule.
local brave_screen

-- FL3: pending close arming { win = <window id>, at = <os.time()> }.
local armed_close

globalkeys = gears.table.join(
    awful.key({ modkey,           }, "s",      hotkeys_popup.show_help,
              {description="show help", group="awesome"}),
    -- Expanded AETHER panel (layer 4); the AETHER mark in the bar toggles
    -- the same surface on the screen under the pointer.
    awful.key({ modkey,           }, "a", function() panel.toggle() end,
              {description="toggle AETHER panel", group="awesome"}),
    awful.key({ modkey,           }, "Left",   awful.tag.viewprev,
              {description = "view previous", group = "tag"}),
    awful.key({ modkey,           }, "Right",  awful.tag.viewnext,
              {description = "view next", group = "tag"}),
    awful.key({ modkey,           }, "Escape", awful.tag.history.restore,
              {description = "go back", group = "tag"}),

    -- Super+D: the dot wallpaper showcase ("show desktop"), screen-local.
    -- A second press returns to the workspace you came from — before this it
    -- was one-way and pressing the key again did nothing (flow 5 feedback).
    awful.key({ modkey,           }, "d",
        function ()
            local s = awful.screen.focused()
            local dot = dotws.dot_tag(s)
            if not dot then return end
            if dot.selected then
                local back = s._aether_showcase_return
                if back and back.valid then
                    back:view_only()
                else
                    dotws.numbered(s, 1):view_only()
                end
                s._aether_showcase_return = nil
            else
                s._aether_showcase_return = s.selected_tag
                dot:view_only()
            end
        end,
        {description = "dot wallpaper showcase (toggle)", group = "tag"}),

    awful.key({ modkey,           }, "j",
        function ()
            awful.client.focus.byidx( 1)
        end,
        {description = "focus next by index", group = "client"}
    ),
    awful.key({ modkey,           }, "k",
        function ()
            awful.client.focus.byidx(-1)
        end,
        {description = "focus previous by index", group = "client"}
    ),
    awful.key({ modkey,           }, "w", function () mymainmenu:show() end,
              {description = "show main menu", group = "awesome"}),

    -- Mod4+e was bound to Launchpad, which is not installed: the key did
    -- nothing and a launcher was two dead bindings away (user-flow FL1,
    -- navigation §3.6).  rofi is the interim searchable launcher until
    -- Starlight/Launchpad come back; Mod4+Shift+O searches open windows
    -- (flow FL6: one "where is it?" entry).  Both are registered with the
    -- rest of the global keys: a deferred re-grab is not reliable after a
    -- restart (the binding appeared in root.keys() yet never fired).
    awful.key({ modkey }, "e", function() launchers.search("drun") end,
              {description = "search applications (rofi)", group = "launcher"}),
    awful.key({ modkey, "Shift" }, "o", function() launchers.search("window") end,
              {description = "search open windows (rofi)", group = "launcher"}),
    awful.key({ modkey }, "b", function ()
                  brave_screen = mouse.screen
                  awful.spawn("brave-browser")
              end,
              {description = "open brave on screen under pointer", group = "launcher"}),

    -- Layout manipulation
    awful.key({ modkey, "Shift"   }, "j", function () awful.client.swap.byidx(  1)    end,
              {description = "swap with next client by index", group = "client"}),
    awful.key({ modkey, "Shift"   }, "k", function () awful.client.swap.byidx( -1)    end,
              {description = "swap with previous client by index", group = "client"}),
    awful.key({ modkey, "Control" }, "j", function () awful.screen.focus_relative( 1) end,
              {description = "focus the next screen", group = "screen"}),
    awful.key({ modkey, "Control" }, "k", function () awful.screen.focus_relative(-1) end,
              {description = "focus the previous screen", group = "screen"}),
    awful.key({ modkey,           }, "u", awful.client.urgent.jumpto,
              {description = "jump to urgent client", group = "client"}),
    -- Tags are per-screen in awesome, so this cycles the focused monitor
    -- only.  During a window drag the press is consumed by the drag
    -- handler instead: the dragged window transfers to the other monitor
    -- (dragtransfer.lua).  Cycle order is forward through the tag array:
    -- ". -> 1 -> ... -> 9 -> ."
    awful.key({ modkey,           }, "Tab",
        function ()
            if not dragtransfer.on_super_tab() then
                awful.tag.viewnext(awful.screen.focused())
            end
        end,
        {description = "next tag on this screen / transfer dragged window", group = "tag"}),

    -- Standard program
    awful.key({ modkey,           }, "Return", function () awful.spawn(terminal) end,
              {description = "open a terminal", group = "launcher"}),
    awful.key({ modkey, "Control" }, "r", awesome.restart,
              {description = "reload awesome", group = "awesome"}),
    awful.key({ modkey, "Shift"   }, "q", awesome.quit,
              {description = "quit awesome", group = "awesome"}),
    -- Close the focused application (Mod4+Shift+Q above quits the WM itself).
    -- Guarded: focus can differ from the window under the pointer (pointer on
    -- the bar, or focus moved by a keyboard tag switch), so a blind close can
    -- kill the wrong window.  First press arms and names the target; a second
    -- press within 3 s closes it (user-flow FL3).
    awful.key({ modkey }, "q",
        function ()
            local c = client.focus
            if not c then return end
            local mc = mouse.coords()
            local pointer_over = mc.x >= c.x and mc.x < c.x + c.width
                             and mc.y >= c.y and mc.y < c.y + c.height
            if pointer_over then c:kill() return end
            if armed_close and armed_close.win == c.window
               and os.time() - armed_close.at <= 3 then
                armed_close = nil
                c:kill()
                return
            end
            armed_close = { win = c.window, at = os.time() }
            naughty.notify {
                title   = "Close this window?",
                text    = (c.name or c.class or "window") ..
                          "\nPress Mod4+Q again within 3 s.",
                timeout = 3,
            }
        end,
        {description = "close focused app", group = "client"}),

    -- Keyboard route to layer 3: the window-controls surface for the focused
    -- client, previously reachable only by clicking its bar block (U5).
    awful.key({ modkey }, "i", windower.open_controls,
              {description = "focused window controls", group = "client"}),

    -- Windows by index (navigation N1).  Mod4+Tab cycles *workspaces* on this
    -- desktop by design, so window switching lives on the convention every
    -- other desktop uses: Alt+Tab.  Symmetric pair, no hidden steps.
    awful.key({ "Mod1" }, "Tab",
              function () awful.client.focus.byidx(1) end,
              {description = "next window", group = "client"}),
    awful.key({ "Mod1", "Shift" }, "Tab",
              function () awful.client.focus.byidx(-1) end,
              {description = "previous window", group = "client"}),

    -- One key to the other monitor (navigation N2): with two screens,
    -- "focus the other one" is the whole gesture; Mod4+Ctrl+j/k stay for
    -- setups with more than two.
    awful.key({ modkey }, "grave",
              function () awful.screen.focus_relative(1) end,
              {description = "focus the other screen", group = "screen"}),

    -- Hardware keys (navigation N3): a laptop user reaches for these before
    -- the bar.  They drive the same commands the widgets already use.
    awful.key({}, "XF86AudioRaiseVolume",
              function () awful.spawn.with_shell("wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%+") end,
              {description = "volume up", group = "media"}),
    awful.key({}, "XF86AudioLowerVolume",
              function () awful.spawn.with_shell("wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%-") end,
              {description = "volume down", group = "media"}),
    awful.key({}, "XF86AudioMute",
              function () awful.spawn.with_shell("wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle") end,
              {description = "mute audio", group = "media"}),
    awful.key({}, "XF86AudioMicMute",
              function () awful.spawn.with_shell("wpctl set-mute @DEFAULT_AUDIO_SOURCE@ toggle") end,
              {description = "mute microphone", group = "media"}),
    awful.key({}, "XF86AudioPlay",
              function () awful.spawn.with_shell("playerctl play-pause") end,
              {description = "play/pause", group = "media"}),
    awful.key({}, "XF86AudioNext",
              function () awful.spawn.with_shell("playerctl next") end,
              {description = "next track", group = "media"}),
    awful.key({}, "XF86AudioPrev",
              function () awful.spawn.with_shell("playerctl previous") end,
              {description = "previous track", group = "media"}),
    awful.key({}, "XF86MonBrightnessUp",
              function () awful.spawn.with_shell("brightnessctl -q set +10%") end,
              {description = "brightness up", group = "media"}),
    awful.key({}, "XF86MonBrightnessDown",
              function () awful.spawn.with_shell("brightnessctl -q set 10%-") end,
              {description = "brightness down", group = "media"}),


    -- Print saves a full-screen PNG into ~/Pictures/Screenshots.
    awful.key({ }, "Print",
        function ()
            local dir = os.getenv("HOME") .. "/Pictures/Screenshots"
            awful.spawn.with_shell("mkdir -p " .. dir ..
                " && import -window root " .. dir .. "/screenshot-$(date +%Y%m%d-%H%M%S).png")
        end,
        {description = "take screenshot", group = "launcher"}),

    -- Alt+F4 closes the focused app (Mod4+q does the same).
    awful.key({ "Mod1" }, "F4",
        function ()
            if client.focus then client.focus:kill() end
        end,
        {description = "close focused app", group = "client"}),

    -- Win+L locks the session; master-width resizing moves to Alt+L/Alt+H.
    awful.key({ modkey,           }, "l",     function () awful.spawn("xsecurelock") end,
              {description = "lock screen", group = "awesome"}),
    awful.key({ "Mod1",           }, "l",     function () awful.tag.incmwfact( 0.05)          end,
              {description = "increase master width factor", group = "layout"}),
    awful.key({ "Mod1",           }, "h",     function () awful.tag.incmwfact(-0.05)          end,
              {description = "decrease master width factor", group = "layout"}),
    awful.key({ modkey, "Shift"   }, "h",     function () awful.tag.incnmaster( 1, nil, true) end,
              {description = "increase the number of master clients", group = "layout"}),
    awful.key({ modkey, "Shift"   }, "l",     function () awful.tag.incnmaster(-1, nil, true) end,
              {description = "decrease the number of master clients", group = "layout"}),
    awful.key({ modkey, "Control" }, "h",     function () awful.tag.incncol( 1, nil, true)    end,
              {description = "increase the number of columns", group = "layout"}),
    awful.key({ modkey, "Control" }, "l",     function () awful.tag.incncol(-1, nil, true)    end,
              {description = "decrease the number of columns", group = "layout"}),
    awful.key({ modkey,           }, "space", function () awful.layout.inc( 1)                end,
              {description = "select next", group = "layout"}),
    awful.key({ modkey, "Shift"   }, "space", function () awful.layout.inc(-1)                end,
              {description = "select previous", group = "layout"}),

    awful.key({ modkey, "Control" }, "n",
              function ()
                  local c = awful.client.restore()
                  -- Focus restored client
                  if c then
                    c:emit_signal(
                        "request::activate", "key.unminimize", {raise = true}
                    )
                  end
              end,
              {description = "restore minimized", group = "client"}),

    -- Prompt
    awful.key({ modkey },            "r",     function () awful.screen.focused().mypromptbox:run() end,
              {description = "run prompt", group = "launcher"}),

    awful.key({ modkey }, "x",
              function ()
                  awful.prompt.run {
                    prompt       = "Run Lua code: ",
                    textbox      = awful.screen.focused().mypromptbox.widget,
                    exe_callback = awful.util.eval,
                    history_path = awful.util.get_cache_dir() .. "/history_eval"
                  }
              end,
              {description = "lua execute prompt", group = "awesome"}),
    -- Menubar
    awful.key({ modkey }, "p", function() menubar.show() end,
              {description = "show the menubar", group = "launcher"})
)

clientkeys = gears.table.join(
    awful.key({ modkey,           }, "f",
        function (c)
            c.fullscreen = not c.fullscreen
            c:raise()
        end,
        {description = "toggle fullscreen", group = "client"}),
    awful.key({ modkey, "Shift"   }, "c",      function (c) c:kill()                         end,
              {description = "close", group = "client"}),
    awful.key({ modkey, "Control" }, "space",  awful.client.floating.toggle                     ,
              {description = "toggle floating", group = "client"}),
    awful.key({ modkey, "Control" }, "Return", function (c) c:swap(awful.client.getmaster()) end,
              {description = "move to master", group = "client"}),
    awful.key({ modkey,           }, "o",      function (c) c:move_to_screen()               end,
              {description = "move to screen", group = "client"}),
    awful.key({ modkey,           }, "t",      function (c) c.ontop = not c.ontop            end,
              {description = "toggle keep on top", group = "client"}),
    awful.key({ modkey,           }, "n",
        function (c)
            -- The client currently has the input focus, so it cannot be
            -- minimized, since minimized clients can't have the focus.
            c.minimized = true
        end ,
        {description = "minimize", group = "client"}),
    awful.key({ modkey,           }, "m",
        function (c)
            c.maximized = not c.maximized
            c:raise()
        end ,
        {description = "(un)maximize", group = "client"}),
    awful.key({ modkey, "Control" }, "m",
        function (c)
            c.maximized_vertical = not c.maximized_vertical
            c:raise()
        end ,
        {description = "(un)maximize vertically", group = "client"}),
    awful.key({ modkey, "Shift"   }, "m",
        function (c)
            c.maximized_horizontal = not c.maximized_horizontal
            c:raise()
        end ,
        {description = "(un)maximize horizontally", group = "client"})
)

-- Bind all key numbers to tags.
-- Be careful: we use keycodes to make it work on any keyboard layout.
-- This should map on the top row of your keyboard, usually 1 to 9.
-- Tags are resolved by name (dotworkspace.numbered): the leading "." tag
-- shifts positional indexes, and these bindings must keep meaning the
-- NUMBERED workspaces.
local function numbered_tag(scr, i)
    return dotws.numbered(scr, i)
end

for i = 1, 9 do
    globalkeys = gears.table.join(globalkeys,
        -- View tag only.
        awful.key({ modkey }, "#" .. i + 9,
                  function ()
                        local screen = awful.screen.focused()
                        local tag = numbered_tag(screen, i)
                        if tag then
                           tag:view_only()
                        end
                  end,
                  {description = "view tag #"..i, group = "tag"}),
        -- Toggle tag display.
        awful.key({ modkey, "Control" }, "#" .. i + 9,
                  function ()
                      local screen = awful.screen.focused()
                      local tag = numbered_tag(screen, i)
                      if tag then
                         awful.tag.viewtoggle(tag)
                      end
                  end,
                  {description = "toggle tag #" .. i, group = "tag"}),
        -- Move client to tag.
        awful.key({ modkey, "Shift" }, "#" .. i + 9,
                  function ()
                      if client.focus then
                          local tag = numbered_tag(client.focus.screen, i)
                          if tag then
                              client.focus:move_to_tag(tag)
                          end
                     end
                  end,
                  {description = "move focused client to tag #"..i, group = "tag"}),
        -- Toggle tag on focused client.
        awful.key({ modkey, "Control", "Shift" }, "#" .. i + 9,
                  function ()
                      if client.focus then
                          local tag = numbered_tag(client.focus.screen, i)
                          if tag then
                              client.focus:toggle_tag(tag)
                          end
                      end
                  end,
                  {description = "toggle focused client on tag #" .. i, group = "tag"})
    )
end

clientbuttons = gears.table.join(
    awful.button({ }, 1, function (c)
        c:emit_signal("request::activate", "mouse_click", {raise = true})
    end),
    awful.button({ modkey }, 1, function (c)
        c:emit_signal("request::activate", "mouse_click", {raise = true})
        awful.mouse.client.move(c)
    end),
    awful.button({ modkey }, 3, function (c)
        c:emit_signal("request::activate", "mouse_click", {raise = true})
        awful.mouse.client.resize(c)
    end)
)

-- Set keys
root.keys(globalkeys)

-- Escape dismisses the active AETHER surface (panel, window controls,
-- OpenCode, clock, control center, media).  The key is grabbed *only* while
-- a modal surface is open: plain Escape must keep reaching applications,
-- so it is never a permanent global binding.  The grab table is captured at
-- open time, which preserves the late-registered launcher bindings.
local modal_escape = awful.key({}, "Escape", function()
    popover.close_all()
end, {description="dismiss AETHER surface", group="awesome"})

-- BackSpace goes up one layer before it dismisses: the layer stack is the
-- product's main idea, and without a back action navigating *between* layers
-- destroyed the previous one (navigation N8 / flow FL4).  With nothing to go
-- back to it behaves like Escape, so it is never a dead key.
local modal_back = awful.key({}, "BackSpace", function()
    if not popover.back() then popover.close_all() end
end, {description="back to the previous surface", group="awesome"})

local keys_before_modal
popover.subscribe(function(_, modal)
    if modal and not keys_before_modal then
        keys_before_modal = root.keys()
        root.keys(gears.table.join(keys_before_modal, modal_escape, modal_back))
    elseif not modal and keys_before_modal then
        root.keys(keys_before_modal)
        keys_before_modal = nil
    end
end)

-- Launchers: Starlight search (Alt+Space) and Launchpad. Placement is owned by
-- launchers.lua — the GTK clients map at a preliminary size and send a
-- ConfigureRequest at (0,0), so rule-time placement cannot work
-- (docs/03-defects.md, D1).
local function starlight_toggle()
    launchers.spawn("starlight")
end

-- Mod4+b / Mod4+e / Mod4+Shift+O now live in globalkeys above: a deferred
-- re-grab at 0.5 s could silently fail after a restart (the binding showed up
-- in root.keys() but never fired), which is exactly how the launcher keys got
-- lost before.  Alt+Space stays deferred because its GTK client needs the
-- placement authority installed first (launchers.install below).
gears.timer.start_new(0.5, function ()
    root.keys(gears.table.join(root.keys(),
        awful.key({ "Mod1" }, "space", starlight_toggle,
                  {description = "starlight search", group = "launcher"})))
    return false
end)
-- }}}

-- {{{ Rules
-- Rules to apply to new clients (through the "manage" signal).
awful.rules.rules = {
    -- All clients will match this rule.
    { rule = { },
      properties = { border_width = beautiful.border_width,
                     border_color = beautiful.border_normal,
                     focus = awful.client.focus.filter,
                     raise = true,
                     keys = clientkeys,
                     buttons = clientbuttons,
                     screen = awful.screen.preferred,
                     placement = awful.placement.no_overlap+awful.placement.no_offscreen
     }
    },

    -- Floating clients.
    { rule_any = {
        instance = {
          "DTA",  -- Firefox addon DownThemAll.
          "copyq",  -- Includes session name in class.
          "pinentry",
        },
        class = {
          "Arandr",
          "Blueman-manager",
          "Gpick",
          "Kruler",
          "MessageWin",  -- kalarm.
          "Sxiv",
          "Tor Browser", -- Needs a fixed window size to avoid fingerprinting by screen size.
          "Wpa_gui",
          "veromix",
          "xtightvncviewer"},

        -- Note that the name property shown in xprop might be set slightly after creation of the client
        -- and the name shown there might not match defined rules here.
        name = {
          "Event Tester",  -- xev.
        },
        role = {
          "AlarmWindow",  -- Thunderbird's calendar.
          "ConfigManager",  -- Thunderbird's about:config.
          "pop-up",       -- e.g. Google Chrome's (detached) Developer Tools.
        }
      }, properties = { floating = true }},

    -- Every normal window gets the macOS-style glass bar: app icon + class on
    -- the left, window title centred, state + traffic-light controls on the
    -- right (glass.titlebar builds it).  Starlight below opts out.
    { rule_any = {type = { "normal", "dialog" }
      }, properties = { titlebars_enabled = true }
    },

    -- Starlight Search (Alt+Space). wlr-layer-shell does not exist under X11,
    -- so the GTK client is a normal window; this rule gives it the
    -- layer-surface behaviour: borderless, floating, always-on-top, on the
    -- pointer's monitor, dismissed by the launcher itself on blur.
    -- Position and the final centring are owned by launchers.lua: the client
    -- maps at a preliminary size and sends a ConfigureRequest at (0,0), so
    -- neither placement nor a rule callback can produce a correct result.
    { rule = { class = "starlight" },
      properties = {
          floating = true,
          ontop = true,
          sticky = true,
          skip_taskbar = true,
          border_width = 0,
          titlebars_enabled = false,
          focus = true,
          raise = true,
          screen = function ()
              return launchers.screen_for("starlight")
          end,
      } },

    -- Launchpad (Mod4+e): the application grid, same contract as Starlight.
    { rule = { class = "launchpad" },
      properties = {
          floating = true,
          ontop = true,
          sticky = true,
          skip_taskbar = true,
          border_width = 0,
          titlebars_enabled = false,
          focus = true,
          raise = true,
          screen = function ()
              return launchers.screen_for("launchpad")
          end,
      } },

    -- Brave: open on the monitor under the pointer (see Mod4+b above). The
    -- remembered screen is consumed on first use, so Brave windows opened by
    -- other means keep the default placement.
    { rule = { class = "Brave-browser" },
      properties = {
          screen = function ()
              local s = brave_screen
              brave_screen = nil
              return (s or mouse.screen).index
          end,
      } },

    -- Set Firefox to always map on the tag named "2" on screen 1.
    -- { rule = { class = "Firefox" },
    --   properties = { screen = 1, tag = "2" } },
}
-- }}}

-- Launcher placement must be installed after the rules: awesome connects its
-- own manage handler when awful.rules loads, so rules run first and the
-- client already belongs to the right screen when the settle timer starts.
launchers.install()

-- The dot workspace's routing policy and the drag-aware Super+Tab both hook
-- client/tag signals; installing after the rules keeps them behind the
-- launcher placement authority in the manage chain.
dotws.install()
dragtransfer.install()

-- Restart races: the screen setup callback can fire again mid-restart after
-- Xinerama re-detects, appending a stray tag set after the clean one above.
-- One deferred pass enforces the canonical set again once clients have
-- re-managed (fast no-op when nothing raced).
gears.timer.start_new(2.5, function()
    for s in screen do
        if s.valid then dotws.ensure_tags(s) end
    end
    -- Re-grab once the main loop has settled.  A grab requested during config
    -- load can lose the race (X answers AlreadyGrabbed and awesome caches the
    -- combination as grabbed): Mod4+e showed up in root.keys() yet never fired
    -- until an explicit re-registration.  Idempotent, and skipped while a modal
    -- surface holds the scoped Escape/BackSpace grab.
    if not popover.any_modal() then root.keys(root.keys()) end
    return false
end)

-- {{{ Signals
-- Signal function to execute when a new client appears.
client.connect_signal("manage", function (c)
    -- Set the windows at the slave,
    -- i.e. put it at the end of others instead of setting it master.
    -- if not awesome.startup then awful.client.setslave(c) end

    if awesome.startup
      and not c.size_hints.user_position
      and not c.size_hints.program_position then
        -- Prevent clients from being unreachable after screen count changes.
        awful.placement.no_offscreen(c)
    end
end)

-- Add a titlebar if titlebars_enabled is set to true in the rules.
client.connect_signal("request::titlebars", function(c)
    glass.titlebar(c)
end)

-- Enable sloppy focus, so that focus follows mouse. The launchers are modal
-- overlays: while one is open, crossing events caused by its own resize must
-- not hand focus to a client underneath it (the GTK app would dismiss itself).
client.connect_signal("mouse::enter", function(c)
    if launchers.has_open_launcher() then return end
    c:emit_signal("request::activate", "mouse_enter", {raise = false})
end)

client.connect_signal("focus", function(c) c.border_color = beautiful.border_focus end)
client.connect_signal("unfocus", function(c) c.border_color = beautiful.border_normal end)
-- }}}
-- Wallpaper cycler: 30 minute interval, 2s crossfade (see wallpaper_cycler.lua).
local wallpaper_cycler = require("wallpaper_cycler")
wallpaper_cycler.setup{ directory = os.getenv("HOME") .. "/wallpapers" }

-- Compositor: transparency is only honoured with a compositor, and picom
-- supplies the background blur and shadows too.  glass.lua starts it once
-- (never a second instance) and respawns it if it crashes.
glass.start_compositor()

-- OpenCode integration: capability probe then the first poll.  Nothing
-- blocks; a service that starts after awesome is picked up by the adaptive
-- poll, and a service that restarts is re-discovered from its service file
-- on the next tick without an AwesomeWM restart.
opencode.start()
