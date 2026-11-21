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
local frostbar = require("frostbar")
-- Popover tween helper and the control-center popover (wifi/bt/brightness)
local anim           = require("anim")
local control_center = require("control_center")
local hotkeys_popup = require("awful.hotkeys_popup")
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
-- visible (beautiful.font itself is left untouched).
beautiful.taglist_font = "Inter Medium 10"
beautiful.tasklist_font = "Inter Medium 10"
beautiful.taglist_bg_normal = "#00000000"
beautiful.taglist_bg_focus  = "#00000000"
beautiful.taglist_fg_normal = "#9a9aa0"
beautiful.taglist_fg_focus  = "#f2f2f7"
beautiful.tasklist_bg_normal = "#00000000"
beautiful.tasklist_bg_focus  = "#3a3a3c60"
beautiful.tasklist_fg_normal = "#9a9aa0"
beautiful.tasklist_fg_focus  = "#f2f2f7"

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


mylauncher = awful.widget.launcher({ image = beautiful.awesome_icon,
                                     menu = mymainmenu })

-- Menubar configuration
menubar.utils.terminal = terminal -- Set the terminal for applications that require it
-- }}}

-- Keyboard map indicator and switcher
mykeyboardlayout = awful.widget.keyboardlayout()

-- {{{ Wibar
-- Create a textclock widget
mytextclock = wibox.widget.textclock()
mytextclock.font = "Inter Medium 10"

-- Create a wibox for each screen and add it
local taglist_buttons = gears.table.join(
                    awful.button({ }, 1, function(t) t:view_only() end),
                    awful.button({ modkey }, 1, function(t)
                                              if client.focus then
                                                  client.focus:move_to_tag(t)
                                              end
                                          end),
                    awful.button({ }, 3, awful.tag.viewtoggle),
                    awful.button({ modkey }, 3, function(t)
                                              if client.focus then
                                                  client.focus:toggle_tag(t)
                                              end
                                          end),
                    awful.button({ }, 4, function(t) awful.tag.viewnext(t.screen) end),
                    awful.button({ }, 5, function(t) awful.tag.viewprev(t.screen) end)
                )

local tasklist_buttons = gears.table.join(
                     awful.button({ }, 1, function (c)
                                              if c == client.focus then
                                                  c.minimized = true
                                              else
                                                  c:emit_signal(
                                                      "request::activate",
                                                      "tasklist",
                                                      {raise = true}
                                                  )
                                              end
                                          end),
                     awful.button({ }, 3, function()
                                              awful.menu.client_list({ theme = { width = 250 } })
                                          end),
                     awful.button({ }, 4, function ()
                                              awful.client.focus.byidx(1)
                                          end),
                     awful.button({ }, 5, function ()
                                              awful.client.focus.byidx(-1)
                                          end))

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

    -- Each screen has its own tag table.
    awful.tag({ "1", "2", "3", "4", "5", "6", "7", "8", "9" }, s, awful.layout.layouts[1])

    -- Create a promptbox for each screen
    s.mypromptbox = awful.widget.prompt()
    -- Create an imagebox widget which will contain an icon indicating which layout we're using.
    -- We need one layoutbox per screen.
    s.mylayoutbox = awful.widget.layoutbox(s)
    s.mylayoutbox:buttons(gears.table.join(
                           awful.button({ }, 1, function () awful.layout.inc( 1) end),
                           awful.button({ }, 3, function () awful.layout.inc(-1) end),
                           awful.button({ }, 4, function () awful.layout.inc( 1) end),
                           awful.button({ }, 5, function () awful.layout.inc(-1) end)))
    -- Create a taglist widget
    s.mytaglist = awful.widget.taglist {
        screen  = s,
        filter  = awful.widget.taglist.filter.all,
        buttons = taglist_buttons
    }

    -- Create a tasklist widget
    s.mytasklist = awful.widget.tasklist {
        screen  = s,
        filter  = awful.widget.tasklist.filter.currenttags,
        buttons = tasklist_buttons
    }

    -- Create the wibox
    -- height must be passed in the constructor: the wibar's attached
    -- placement reverts later runtime height changes.
    -- ontop: awesome stacks ontop drawins after every client layer
    -- (fullscreen and _NET_WM_STATE_ABOVE included), so the bar cannot be
    -- covered by clients or by the cycler's desktop wibox (stack.c:
    -- stack_refresh).
    s.mywibox = awful.wibar({ position = "top", screen = s, height = 30, ontop = true })
    -- Matches the frost fallback color; the frost widget paints over the
    -- bar background, but the systray's embedded X window uses this color.
    s.mywibox.bg = "#0e0e10"

    -- Add widgets to the wibox
    s.mywibox:setup {
        layout = wibox.layout.align.horizontal,
        { -- Left widgets
            layout = wibox.layout.fixed.horizontal,
            mylauncher,
            s.mytaglist,
            s.mypromptbox,
        },
        { -- Middle: now-playing centered (macOS style), tasklist beside it
            layout = wibox.layout.align.horizontal,
            nil,
            frostbar.song,
            s.mytasklist,
        },
        { -- Right widgets
            layout = wibox.layout.fixed.horizontal,
            frostbar.volume,
            frostbar.usage,
            mykeyboardlayout,
            wibox.widget.systray(),
            control_center.button,
            mytextclock,
            s.mylayoutbox,
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
                control_center.close()
                frostbar.close_media()
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

globalkeys = gears.table.join(
    awful.key({ modkey,           }, "s",      hotkeys_popup.show_help,
              {description="show help", group="awesome"}),
    awful.key({ modkey,           }, "Left",   awful.tag.viewprev,
              {description = "view previous", group = "tag"}),
    awful.key({ modkey,           }, "Right",  awful.tag.viewnext,
              {description = "view next", group = "tag"}),
    awful.key({ modkey,           }, "Escape", awful.tag.history.restore,
              {description = "go back", group = "tag"}),

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
    -- Tags are per-screen in awesome, so this cycles the focused monitor only.
    awful.key({ modkey,           }, "Tab",
        function ()
            awful.tag.viewnext(awful.screen.focused())
        end,
        {description = "next tag on this screen", group = "tag"}),

    -- Standard program
    awful.key({ modkey,           }, "Return", function () awful.spawn(terminal) end,
              {description = "open a terminal", group = "launcher"}),
    awful.key({ modkey, "Control" }, "r", awesome.restart,
              {description = "reload awesome", group = "awesome"}),
    awful.key({ modkey, "Shift"   }, "q", awesome.quit,
              {description = "quit awesome", group = "awesome"}),
    -- Close the focused application (Mod4+Shift+Q above quits the WM itself).
    awful.key({ modkey }, "q",
        function ()
            if client.focus then client.focus:kill() end
        end,
        {description = "close focused app", group = "client"}),

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
for i = 1, 9 do
    globalkeys = gears.table.join(globalkeys,
        -- View tag only.
        awful.key({ modkey }, "#" .. i + 9,
                  function ()
                        local screen = awful.screen.focused()
                        local tag = screen.tags[i]
                        if tag then
                           tag:view_only()
                        end
                  end,
                  {description = "view tag #"..i, group = "tag"}),
        -- Toggle tag display.
        awful.key({ modkey, "Control" }, "#" .. i + 9,
                  function ()
                      local screen = awful.screen.focused()
                      local tag = screen.tags[i]
                      if tag then
                         awful.tag.viewtoggle(tag)
                      end
                  end,
                  {description = "toggle tag #" .. i, group = "tag"}),
        -- Move client to tag.
        awful.key({ modkey, "Shift" }, "#" .. i + 9,
                  function ()
                      if client.focus then
                          local tag = client.focus.screen.tags[i]
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
                          local tag = client.focus.screen.tags[i]
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

-- Launchers: Starlight search (Alt+Space) and Launchpad (Mod4+e). Placement is
-- owned by launchers.lua — the GTK clients map at a preliminary size and send a
-- ConfigureRequest at (0,0), so rule-time placement cannot work
-- (docs/03-defects.md, D1).
local launchers = require("launchers")

local function starlight_toggle()
    launchers.spawn("starlight")
end

local function launchpad_toggle()
    launchers.spawn("launchpad")
end

-- Alt+Space (starlight) and Mod4+b (brave) are grabbed once the main loop is
-- running rather than at load.  A grab attempted while rc.lua loads (notably
-- during an awesome restart) can fail silently, and awesome then caches the
-- combination as "grabbed" and never retries it — the binding shows up in
-- root.keys() but never fires.
gears.timer.start_new(0.5, function ()
    root.keys(gears.table.join(root.keys(),
        awful.key({ "Mod1" }, "space", starlight_toggle,
                  {description = "starlight search", group = "launcher"}),
        awful.key({ modkey }, "e", launchpad_toggle,
                  {description = "launchpad app grid", group = "launcher"}),
        awful.key({ modkey }, "b", function ()
                      brave_screen = mouse.screen
                      awful.spawn("brave-browser")
                  end,
                  {description = "open brave on screen under pointer", group = "launcher"})))
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
