--------------------------------------------------------------------------
-- frostbar.lua — macOS-style frosted-glass backdrop for the top wibar
--
-- wrap(wibar, s) returns a container widget (modeled on
-- wibox/container/background.lua) to be set as the wibar's widget. Its
-- :draw paints, underneath the wibar's regular widgets (children are
-- drawn after the parent by the hierarchy):
--   1. the blurred top strip of the live wallpaper,
--   2. a dark tint rgba(0,0,0,0.38),
--   3. a 1px bottom hairline rgba(255,255,255,0.10) and a 1px top
--      highlight rgba(255,255,255,0.05).
-- If no strip is available yet it paints solid #0e0e10 so the bar never
-- renders garbage.
--
-- Strips are baked by magick OFF the WM thread into
-- ~/.cache/awesome-wallpaper-bar/ and crossfade in sync with the
-- wallpaper cycler (subscribe/frames): strip(current) first, then
-- strip(incoming) with paint_with_alpha(smoothstep(t)). Every cycler
-- frame emits "widget::redraw_needed" on the frost widget — required by
-- the dirty-area rule (wibox/drawable.lua repaints only what a widget
-- marks dirty). When idle nothing repaints: zero idle cost.
--
-- Also builds the bar's data widgets (macOS styling, Inter Medium 10):
-- per-screen now-playing and volume widgets (M.new_song / M.new_volume)
-- driven by shared polled state.  All polling is async; the main loop never
-- blocks.
--------------------------------------------------------------------------

AETHER_FROSTBAR = "v2-cursor"

local wibox = require("wibox")
local awful = require("awful")
local gears = require("gears")
local base  = require("wibox.widget.base")
local lgi   = require("lgi")
local GLib  = lgi.GLib
local cairo = lgi.cairo
local lfs   = require("lfs")

local cycler = require("wallpaper_cycler")
local anim   = require("anim") -- switch/slider tweens
local ui     = require("ui")
local popover_mgr = require("popover")

local M = {}

local CACHE_DIR = os.getenv("HOME") .. "/.cache/awesome-wallpaper-bar"

-- magick does not create the output directory; without it every strip
-- build fails silently and the bar stays on the solid fallback.
pcall(function() require("gears.filesystem").make_directories(CACHE_DIR) end)

-- Look & feel.  Foregrounds/fonts come from the ui token palette so the
-- bar's media/volume text matches every popover; FALLBACK is the pre-frost
-- paint color, and is also the wibar bg rc.lua shows under the systray.
local TINT_ALPHA       = 0.60 -- graphite scrim over the blur: at 0.38 a bright
                              -- wallpaper left #7c8490 text at ~2.5:1
local HAIRLINE_ALPHA   = 0.10
local HIGHLIGHT_ALPHA  = 0.05
local FALLBACK         = { 14 / 255, 14 / 255, 16 / 255 } -- #0e0e10
M.fallback_bg          = ui.color.bg_bar
local FG_MAIN          = ui.color.text
local FG_MUTED         = ui.color.text_dim
local FONT_MAIN        = ui.font.body

-------------------------------------------------------------------------- helpers

-- Single-quote for shell (filenames contain spaces and parentheses).
local function shquote(s)
    return "'" .. s:gsub("'", "'\\''") .. "'"
end

local function is_file(path)
    return path and lfs.attributes(path, "mode") == "file"
end

-- GLib.Checksum object API (GLib.compute_checksum is absent from this lgi
-- build; same approach as wallpaper_cycler.lua, verified on this machine).
local function md5(key)
    local ok, digest = pcall(function()
        local cs = GLib.Checksum.new(GLib.ChecksumType.MD5)
        cs:update(key)
        return cs:get_string()
    end)
    if ok then return digest end
    return key
end

local function esc(s)
    return (tostring(s):gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"))
end

-- Compact human number: 2419423 -> 2.4M, 35500 -> 35K.
local function human(n)
    if n >= 1000000 then
        local s = string.format("%.1f", n / 1000000):gsub("%.0$", "")
        return s .. "M"
    elseif n >= 1000 then
        return string.format("%.0f", n / 1000) .. "K"
    end
    return tostring(n)
end

-------------------------------------------------------------------------- frost widget

local instances = {}   -- one per screen
local unsub      = nil -- wallpaper cycler subscription (module-wide)

-- strip = blurred wallpaper's TOP bar-height region scaled to (screenW x barH)
local function strip_path(src, sw, sh, barh)
    local mtime = lfs.attributes(src, "modification") or 0
    -- screenH included: the cover-crop of the top region depends on it too
    return CACHE_DIR .. "/" ..
        md5(string.format("%s|%s|%dx%d|%dx%d", src, tostring(mtime), sw, sh, sw, barh)) .. ".jpg"
end

local building = {}    -- dst -> true, magick jobs in flight
local inst_update      -- forward declaration (build_strip calls it)

-- Bake a strip asynchronously; never on the WM thread (~0.8s at 1080p).
local function build_strip(src, sw, sh, barh, dst)
    if building[dst] then return end
    building[dst] = true
    local cmd = string.format(
        "magick %s -resize %dx%d^ -gravity center -extent %dx%d -blur 0x14 " ..
        "-crop %dx%d+0+0 +repage -quality 95 %s",
        shquote(src), sw, sh, sw, sh, sw, barh, shquote(dst))
    awful.spawn.easy_async_with_shell(cmd, function()
        building[dst] = nil
        for _, inst in ipairs(instances) do inst_update(inst) end
    end)
end

-- Ready-to-paint strip surface for a wallpaper path on this screen's
-- state: memory cache first, then the baked file, else kick a build and
-- return nil (the caller paints the previous strip / solid fallback).
local function get_strip(st, path)
    if not path then return nil end
    local surf = st.surf_cache[path]
    if surf then return surf end
    local g = st.screen.geometry
    local dst = strip_path(path, g.width, g.height, st.barh)
    if is_file(dst) then
        surf = gears.surface.load(dst)
        if surf then
            local n = 0
            for _ in pairs(st.surf_cache) do n = n + 1 end
            if n > 12 then st.surf_cache = {} end -- tiny strips; still bound memory
            st.surf_cache[path] = surf
            return surf
        end
    end
    build_strip(path, g.width, g.height, st.barh, dst)
    return nil
end

-- Called on every cycler notify (each fade tick ~60/s while fading, plus
-- commit/initial): update this screen's strip surfaces and repaint.
-- Cycler semantics: while idle, frames.current is the shown wallpaper;
-- while fading, frames.outgoing is the strip painted underneath and
-- frames.incoming the one fading in (frames.current == frames.incoming
-- during a fade — do not use it for the idle path).
function inst_update(st)
    if not st.screen.valid then return end
    local f = cycler.frames()
    local changed = false

    if not f.fading then
        local cur = f.current
        if cur ~= st.cur_path then
            st.cur_path = cur
            st.cur_surf = cur and get_strip(st, cur) or nil
            changed = true
        elseif cur and not st.cur_surf then
            local s = get_strip(st, cur) -- cache build finished since last frame
            changed = changed or s ~= nil
            st.cur_surf = s
        end
        -- Warm the strip of the cycler's pending wallpaper so the next
        -- fade blends from t=0 instead of waiting for the magick build.
        local pending = cycler.status().pending
        if pending and pending ~= cur then get_strip(st, pending) end
        if st.fading then changed = true end
        st.fading = false
        st.nxt_path, st.nxt_surf = nil, nil
        st.t = 0
    else
        st.t = f.t
        if f.outgoing ~= st.cur_path then
            st.cur_path = f.outgoing
            st.cur_surf = f.outgoing and get_strip(st, f.outgoing) or nil
            changed = true
        end
        if f.incoming ~= st.nxt_path then
            st.nxt_path = f.incoming
            st.nxt_surf = f.incoming and get_strip(st, f.incoming) or nil
            changed = true
        elseif f.incoming and not st.nxt_surf then
            local s = get_strip(st, f.incoming) -- build may have just finished
            changed = changed or s ~= nil
            st.nxt_surf = s
        end
        if not st.fading then changed = true end
        st.fading = true
    end

    if changed or st.fading then
        st.widget:emit_signal("widget::redraw_needed")
    end
end

-- Paint the backdrop. Draw signature: exactly 3 formals after self.
local function paint_frost(st, cr, width, height)
    if st.cur_surf then
        cr:set_source_surface(st.cur_surf, 0, 0)
        cr.operator = cairo.Operator.SOURCE
        cr:paint()
        if st.fading and st.nxt_surf then
            local a = st.t
            if a < 0 then a = 0 elseif a > 1 then a = 1 end
            a = a * a * (3 - 2 * a) -- smoothstep, same easing as the cycler
            cr:set_source_surface(st.nxt_surf, 0, 0)
            cr.operator = cairo.Operator.OVER
            cr:paint_with_alpha(a)
        end
    else
        cr:set_source_rgb(FALLBACK[1], FALLBACK[2], FALLBACK[3])
        cr.operator = cairo.Operator.SOURCE
        cr:paint()
    end
    cr.operator = cairo.Operator.OVER
    cr:set_source_rgba(0, 0, 0, TINT_ALPHA)
    cr:paint()
    cr:set_source_rgba(1, 1, 1, HAIRLINE_ALPHA)
    cr:rectangle(0, height - 1, width, 1)
    cr:fill()
    cr:set_source_rgba(1, 1, 1, HIGHLIGHT_ALPHA)
    cr:rectangle(0, 0, width, 1)
    cr:fill()
end

-- Container modeled on wibox/container/background.lua: ONE child, custom
-- :layout/:fit/:draw; the child is drawn after the parent, so the backdrop
-- painted in :draw lands underneath the child widgets.
local function make_frost(st)
    local w = base.make_widget(nil, "frostbar", { enable_properties = true })

    function w:set_widget(child)
        if child then base.check_widget(child) end
        self._private.widget = child
        self:emit_signal("widget::layout_changed")
    end
    function w:get_widget()
        return self._private.widget
    end
    function w:get_children()
        return { self._private.widget }
    end
    function w:set_children(children)
        self:set_widget(children and children[1])
    end

    function w:layout(_, width, height)
        if self._private.widget then
            return { base.place_widget_at(self._private.widget, 0, 0, width, height) }
        end
    end
    function w:fit(context, width, height)
        if not self._private.widget then return 0, 0 end
        return base.fit_widget(self, context, self._private.widget, width, height)
    end
    function w:draw(_, cr, width, height)
        paint_frost(st, cr, width, height)
    end

    st.widget = w
    return w
end

local function on_frames()
    for i = #instances, 1, -1 do
        local st = instances[i]
        if st.screen.valid then
            inst_update(st)
        else
            table.remove(instances, i)
        end
    end
end

local function ensure_subscribed()
    if unsub then return end
    unsub = cycler.subscribe(on_frames)
end

-- Re-raise the wibar above the cycler's desktop wibox. Not needed: the wibar
-- is created with ontop = true, and awesome stacks ontop drawins last
-- (stack.c: stack_refresh), regardless of map order.

screen.connect_signal("removed", function(sc)
    for i = #instances, 1, -1 do
        if instances[i].screen == sc then
            table.remove(instances, i) -- drop per-screen state & surfaces
        end
    end
end)

--- Wrap a wibar: take its current widget as the frost container's child
-- and install the container as the wibar's widget. Call AFTER :setup.
function M.wrap(wibar, s)
    local st = {
        screen = s,
        wibar = wibar,
        barh = wibar.height,
        surf_cache = {},
        cur_path = nil, cur_surf = nil,
        nxt_path = nil, nxt_surf = nil,
        t = 0, fading = false,
    }
    local w = make_frost(st)
    w:set_widget(wibar.widget)
    wibar:set_widget(w)
    instances[#instances + 1] = st

    -- Resolution change: strips are size-dependent; drop and rebuild.
    s:connect_signal("property::geometry", function()
        st.surf_cache = {}
        st.cur_path, st.cur_surf = nil, nil
        st.nxt_path, st.nxt_surf = nil, nil
        inst_update(st)
    end)
    wibar:connect_signal("property::height", function()
        st.barh = wibar.height
        st.surf_cache = {}
        st.cur_path, st.cur_surf = nil, nil
        inst_update(st)
    end)

    ensure_subscribed()
    inst_update(st)
    return w
end

-- poll/player widgets -----------------------------------------------------

-- Wrap a widget in small horizontal margins (macOS breathing room).
local function spaced(w, l, r)
    return wibox.container.margin(w, l or 0, r or 0, 0, 0)
end

-- playerctl polling (3s, async forks). Polling chosen over `playerctl -F`
-- follow mode: a dead player just shows up as empty output on the next
-- poll and the widget hides — no watcher to babysit.
--
-- Friendly display names for MPRIS players (playerctl reports the lower
-- case service id, e.g. "org.mpris.MediaPlayer2.brave" -> "brave").
local APP_NAMES = {
    spotify = "Spotify", brave = "Brave", chromium = "Chromium",
    ["google-chrome"] = "Chrome", firefox = "Firefox", mpv = "mpv",
    vlc = "VLC", lollypop = "Lollypop", rhythmbox = "Rhythmbox",
    celluloid = "Celluloid", audacious = "Audacious",
    strawberry = "Strawberry", cmus = "cmus", totem = "Videos",
    elisa = "Elisa", sayonara = "Sayonara",
    kdeconnect = "KDE Connect", kdeconnectd = "KDE Connect",
}

local function pretty_app(name)
    if not name or name == "" then return nil end
    return APP_NAMES[name:lower()] or name:sub(1, 1):upper() .. name:sub(2)
end

-- Shared media state: written by the 3s metadata poll, read by the bar
-- text and the media popover (defined below). length/position are
-- microseconds ({{mpris:length}} / {{position}}).
local media = { player = nil, status = nil, title = nil, artist = nil,
                length = nil, position = nil, has = false }

-- Media popover hooks (defined below). Forward declarations because the
-- poll needs them: it opens nothing itself but must close the popover if
-- the player goes away while it is open, and refresh it on every poll.
local media_open = false
local toggle_media, close_media, refresh_media_ui, focus_player, open_media

-- One widget set per screen: a widget cannot belong to two bar hierarchies,
-- so the song text and the volume glyph are created per bar and every
-- instance is driven from the same polled state.
local song_widgets = {}
local cap -- forward declaration (render_song uses it)

-- Transport glyphs shared by the bar's mini-player and the media card.
local FA_PREV, FA_PLAY, FA_PAUSE, FA_NEXT = "\u{f048}", "\u{f04b}", "\u{f04c}", "\u{f051}"

-- Seek plumbing lives in the media section below; the bar's mini-player
-- needs it at construction/poll time (both run after the module loads).
local attach_seek, sync_seek

local function render_song()
    local visible = media.has == true
    for _, w in ipairs(song_widgets) do
        local markup
        if visible then
            local glyph = (media.status == "Playing") and "▶" or "❚❚"
            -- The title cap comes from the bar's width budget, so the 1680
            -- monitor drops characters instead of overflowing (layout-grid G7).
            local limit = w.budget and w.budget.song or SONG_MAX
            local text = cap((media.artist ~= nil and media.artist .. " — " or "")
                             .. (media.title or ""), limit)
            local app = pretty_app(media.player) or "Now Playing"
            markup = limit > 0 and string.format(
                '<span foreground="%s">%s</span> <span foreground="%s">%s</span> ' ..
                '<span foreground="%s">%s</span>',
                FG_MUTED, esc(app),
                FG_MUTED, glyph, FG_MAIN, esc(text))
                or esc(app)
        end
        if markup and w.text._private.frost_markup ~= markup then
            w.text._private.frost_markup = markup
            w.text:set_markup_silently(markup)
        end
        if w.play then
            local pglyph = (media.status == "Playing") and FA_PAUSE or FA_PLAY
            local pmark = string.format(
                '<span foreground="%s">%s</span>', FG_MAIN, pglyph)
            if w.play._private.frost_markup ~= pmark then
                w.play._private.frost_markup = pmark
                w.play:set_markup_silently(pmark)
            end
        end
        if w.text.visible ~= visible then
            w.text.visible = visible
            w.box.visible = visible -- collapse the margins entirely when hidden
        end
    end
end

--- New now-playing mini-player for one screen's bar: track, play/pause,
-- elapsed/total time and a seekbar, all inline (the media card keeps the
-- full controls).
function M.new_song(s)
    local text = wibox.widget.textbox()
    text.font = FONT_MAIN
    text.ellipsize = "end"
    text.wrap = "char"
    text.visible = false
    -- click = open the media popover (full controls); scrolling still
    -- skips tracks without opening anything.
    text:buttons(gears.table.join(
        awful.button({}, 1, function() toggle_media() end),
        awful.button({}, 4, function() awful.spawn.with_shell("playerctl next") end),
        awful.button({}, 5, function() awful.spawn.with_shell("playerctl previous") end)
    ))
    local play = wibox.widget.textbox()
    play.font = ui.glyph_font.m
    play.forced_width = 16
    play:buttons(gears.table.join(awful.button({}, 1, function()
        awful.spawn.with_shell("playerctl play-pause") end)))
    local time = wibox.widget.textbox()
    time.font = ui.font.small
    time.visible = false
    local bar = ui.slider{
        minimum = 0, maximum = 1000, value = 0,
        width = 90, height = 18, bar_height = 4,
    }
    attach_seek(bar)
    local row = wibox.widget{
        text, play, time, bar,
        spacing = 6, layout = wibox.layout.fixed.horizontal,
    }
    local box = spaced(row, 8, 8)
    box.visible = false
    song_widgets[#song_widgets + 1] =
        { text = text, play = play, time = time, bar = bar, box = box,
          budget = ui.bar_budget(s and s.geometry and s.geometry.width) }
    render_song()
    return box
end

-- Cap the composed text: a pango layout with a positive height inside a
-- 38px bar could wrap to 2 lines; a character cap keeps it to one line.
-- (Shorter cap now that the mini-player carries the extra controls.)
local SONG_MAX = 26
cap = function(s, limit)
    limit = limit or SONG_MAX
    if limit <= 0 then return "" end
    local n = utf8.len(s)
    if not n or n <= limit then return s end
    local ok, off = pcall(utf8.offset, s, limit)
    if ok and off then
        return s:sub(1, off - 1) .. "…"
    end
    return s:sub(1, limit) .. "…"
end

local function poll_song()
    -- Tab-separated because titles regularly contain "|".
    awful.spawn.easy_async_with_shell(
        "playerctl metadata --format " ..
        "'{{playerName}}\t{{status}}\t{{title}}\t{{artist}}\t{{mpris:length}}\t{{position}}' " ..
        "2>/dev/null || true",
        function(out)
            out = out:gsub("[\r\n]+$", "")
            local player, status, title, artist, length, position =
                out:match("^(.-)\t(.-)\t(.-)\t(.-)\t(.-)\t(.*)$")
            local has = player and (title ~= "" or artist ~= "")
            media.player   = player and player ~= "" and player or nil
            media.status   = status and status ~= "" and status or nil
            media.title    = title ~= "" and title or nil
            media.artist   = artist ~= "" and artist or nil
            media.length   = tonumber(length) or nil
            media.position = tonumber(position) or nil
            media.has      = has == true
            render_song()
            if sync_seek then sync_seek() end
            if not has then
                if media_open then close_media() end
                return
            end
            if media_open then refresh_media_ui() end
        end)
end

gears.timer{ timeout = 3, autostart = true, call_now = true, callback = poll_song }

-------------------------------------------------------------------------- volume widget

local FA_NORMAL = "\u{f028}" -- FontAwesome volume-up
local FA_DOWN   = "\u{f027}" -- FontAwesome volume-down
local FA_MUTED  = "\u{f026}" -- FontAwesome volume-off

local vol_state = { pct = nil, muted = false }
local volume_widgets = {}
local volume_change -- forward declaration (the per-screen widget uses it)
local vol_bar_dragging = false -- a bar drag owns the volume; the poll stands down
local volume_drag_start -- forward declaration (the per-screen widget uses it)

-- Level glyphs for the drag readout: the icon itself tracks the volume.
local function vol_glyph(pct)
    if pct == nil or pct <= 0 then return FA_MUTED end
    if pct < 50 then return FA_DOWN end
    return FA_NORMAL
end

local function render_volume()
    local pct, muted = vol_state.pct, vol_state.muted
    local glyph = muted and FA_MUTED or FA_NORMAL
    local fg = (muted or pct == nil) and FG_MUTED
        or (vol_bar_dragging and ui.color.accent_hi or FG_MAIN)
    local markup
    if pct then
        -- Muted renders as the word, not a lying "0%" (U6).
        local label = muted and "  muted" or string.format("  %d%%", pct)
        markup = string.format(
            '<span font="' .. ui.glyph_font.m .. '" foreground="%s">%s</span>' ..
            '<span font="%s" foreground="%s">%s</span>',
            fg, glyph, ui.font.body, fg, label)
    end
    for _, w in ipairs(volume_widgets) do
        if markup then
            if w.text._private.frost_markup ~= markup then
                w.text._private.frost_markup = markup
                w.text:set_markup_silently(markup)
            end
        end
        if w.text.visible ~= (markup ~= nil) then
            w.text.visible = markup ~= nil
            w.box.visible = markup ~= nil
        end
    end
end

--- New volume indicator for one screen's bar.
function M.new_volume()
    local text = wibox.widget.textbox()
    text.font = FONT_MAIN
    text.visible = false
    -- press-hold-drag = scrub the volume (left decreases, right increases,
    -- release sticks; a press that never moves keeps the old click
    -- behaviour below); scroll up = +5%, scroll down = -5%.
    text:buttons(gears.table.join(
        awful.button({}, 1, function() volume_drag_start() end),
        awful.button({}, 4, function() volume_change("wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%+") end),
        awful.button({}, 5, function() volume_change("wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%-") end)
    ))
    local box = spaced(text, 4, 10)
    box.visible = false
    volume_widgets[#volume_widgets + 1] = { text = text, box = box }
    render_volume()
    return box
end

local function set_volume(pct, muted)
    if vol_state.pct == pct and vol_state.muted == muted then return end
    vol_state.pct, vol_state.muted = pct, muted
    render_volume()
end

-- wpctl: "Volume: 0.65" possibly + " [MUTED]"
local function poll_volume()
    awful.spawn.easy_async_with_shell(
        "wpctl get-volume @DEFAULT_AUDIO_SINK@ 2>/dev/null || true",
        function(out)
            if vol_bar_dragging then return end -- don't fight an active drag
            local v = out:match("Volume:%s*([%d%.]+)")
            if not v then
                vol_state.pct = nil
                render_volume()
                return
            end
            set_volume(math.floor(tonumber(v) * 100 + 0.5),
                       out:find("MUTED", 1, true) ~= nil)
        end)
end

volume_change = function(cmd)
    awful.spawn.with_shell(cmd) -- async, never blocks the main loop
    -- re-read shortly after so the widget reflects the action immediately
    gears.timer.start_new(0.25, function()
        poll_volume()
        return false
    end)
end

-- The 2s poll keeps the widget honest (device changes, other apps
-- adjusting volume); the drag guard inside poll_volume prevents fighting.
gears.timer{ timeout = 2, autostart = true, call_now = true, callback = poll_volume }

-------------------------------------------------------------------------- volume drag

-- Press and hold button 1 on the bar's volume indicator and drag: the
-- pointer delta from the press maps 1:1 to volume (1 px = 1 %) — dragging
-- left decreases, right increases — and every step is applied live so the
-- change is audible while scrubbing. On release the final value is written
-- once more and sticks (the next poll confirms it). A press that never
-- moves keeps the click's old meaning: raise the player's window.

local DRAG_PCT_PER_PX = 1
local DRAG_THRESHOLD  = 3   -- px of pointer movement before it counts as a drag
local APPLY_EVERY_MS  = 120 -- throttle between live wpctl writes

local volume_drag_finish
local drag = nil -- { start_x, start_pct, moved, sent_ms }
local drag_active = false -- the mousegrabber is live for the current press

-- Floating readout under the bar while dragging: level glyph, fill bar and
-- percentage, so direction and magnitude are visible beyond the bar text.
local osd, osd_glyph, osd_bar, osd_pct
local OSD_W, OSD_H = 208, 44

local function make_osd()
    osd_glyph = wibox.widget.textbox()
    osd_glyph.font = ui.glyph_font.m
    osd_glyph.forced_width = 16
    osd_pct = wibox.widget.textbox()
    osd_pct.font = ui.font.clock
    osd_pct.forced_width = 44
    osd_bar = wibox.widget.progressbar()
    -- 4.3 progressbar drops constructor args: assign as properties.
    osd_bar.max_value        = 100
    osd_bar.value            = 0
    osd_bar.color            = ui.color.accent
    osd_bar.background_color = ui.color.track
    osd_bar.shape            = gears.shape.rounded_rect
    osd_bar.bar_shape        = gears.shape.rounded_rect
    osd_bar.forced_width  = 104
    osd_bar.forced_height = 4
    osd = wibox{
        ontop = true, visible = false, type = "menu", -- picom: blur + shadow
        bg = ui.color.bg_popup,
        shape = ui.radius_shape.popup,
        border_width = 1, border_color = ui.color.border,
        opacity = 1,
    }
    osd.widget = wibox.widget{
        { -- the bar sits in a place wrapper: fixed.horizontal hands each
          -- child the row's full height, which would stretch it otherwise
            osd_glyph,
            { osd_bar, layout = wibox.container.place, valign = "center" },
            osd_pct,
            spacing = 10, layout = wibox.layout.fixed.horizontal,
        },
        margins = 12, widget = wibox.container.margin,
    }
end

local function osd_paint(pct)
    osd_bar.value = pct
    local gmark = string.format(
        '<span font="' .. ui.glyph_font.m .. '" foreground="%s">%s</span>',
        FG_MAIN, vol_glyph(pct))
    if osd_glyph._private.frost_markup ~= gmark then
        osd_glyph._private.frost_markup = gmark
        osd_glyph:set_markup_silently(gmark)
    end
    local pmark = string.format(
        '<span font="' .. ui.font.clock .. '" foreground="%s">%d%%</span>',
        FG_MAIN, pct)
    if osd_pct._private.frost_markup ~= pmark then
        osd_pct._private.frost_markup = pmark
        osd_pct:set_markup_silently(pmark)
    end
end

-- Anchored under the pressed widget (screen coordinates, same convention
-- as popover.lua's place), clamped into the screen with an 8 px margin.
local function osd_show(anchor, s)
    if not osd then make_osd() end
    osd_paint(vol_state.pct or 0)
    local g = s.geometry
    local x = g.x + math.floor((g.width - OSD_W) / 2)
    if anchor and anchor.width and anchor.width > 0 then
        x = anchor.x + math.floor((anchor.width - OSD_W) / 2)
    end
    x = math.max(g.x + 8, math.min(x, g.x + g.width - OSD_W - 8))
    osd:geometry{ x = x, y = g.y + ((s.mywibox and s.mywibox.height) or ui.bar_height) + 6,
                  width = OSD_W, height = OSD_H }
    osd.visible = true
    anim.tween{ tag = "frostbar_vol_osd", duration = 0.12, step = function(t)
        osd.opacity = t
    end }
end

local function osd_hide()
    if not (osd and osd.visible) then return end
    anim.tween{ tag = "frostbar_vol_osd", duration = 0.15, step = function(t)
        osd.opacity = 1 - t
    end, done = function()
        if not drag and osd then osd.visible = false end
    end }
end

function volume_drag_finish()
    drag_active = false
    local d = drag
    drag = nil
    vol_bar_dragging = false
    popover_mgr.suppressed = false -- hover reveals may open again
    if not d then return end
    render_volume() -- drop the dragging accent colour
    if d.moved then
        -- One final absolute write pins the exact value shown when the
        -- button came up, even if the last throttled write was skipped.
        volume_change(string.format("wpctl set-volume @DEFAULT_AUDIO_SINK@ %d%%",
                                    vol_state.pct or d.start_pct))
        gears.timer.start_new(0.35, osd_hide) -- let the final value be read
    else
        focus_player() -- a press without movement is still a click
    end
end

function volume_drag_start()
    if drag_active then return end
    if vol_state.pct == nil then focus_player() return end
    local anchor = mouse.current_widget_geometry
    local s = mouse.screen or awful.screen.focused()
    drag = { start_x = mouse.coords().x, start_pct = vol_state.pct, moved = false }
    vol_bar_dragging = true
    drag_active = true
    popover_mgr.suppressed = true -- no hover card may pop open mid-drag
    -- mousegrabber.run returns nothing in this build (not a boolean), so
    -- success cannot be tested from its return value; the callback's own
    -- release/stale checks own the lifecycle instead.
    mousegrabber.run(function(m)
        if not drag_active or not drag then return false end
        if not m.buttons[1] then -- release
            volume_drag_finish()
            return false
        end
        local dx = m.x - drag.start_x
        if not drag.moved then
            if math.abs(dx) < DRAG_THRESHOLD then return true end
            drag.moved = true
            if vol_state.muted then -- scrubbing implies unmuting
                awful.spawn.with_shell("wpctl set-mute @DEFAULT_AUDIO_SINK@ 0")
            end
            osd_show(anchor, s)
        end
        local pct = math.max(0, math.min(100,
            math.floor(drag.start_pct + dx * DRAG_PCT_PER_PX + 0.5)))
        if pct ~= vol_state.pct then
            set_volume(pct, false) -- instant bar update (accent-coloured)
            local now = GLib.get_monotonic_time() / 1000
            if now - (drag.sent_ms or 0) >= APPLY_EVERY_MS then
                drag.sent_ms = now
                awful.spawn.with_shell(
                    string.format("wpctl set-volume @DEFAULT_AUDIO_SINK@ %d%%", pct))
            end
            osd_paint(pct)
        end
        return true
    end, "sb_h_double_arrow")
end

-------------------------------------------------------------------------- media popover

-- Clicking the now-playing text opens an opaque card anchored under the
-- bar: app name, track info, a draggable seekbar (drag = seek, release =
-- jump) and transport + volume controls. It follows the bar it was opened
-- from; moving the pointer out of it fades it away.

-- Drag guards: while the pointer is on a slider handle the poll must not
-- fight the drag, and while the poll syncs a slider it must not seek.
-- (wibox widgets emit button::press/release signals — the slider connects
-- to them internally, so we can watch the same events.)
local seek_dragging, vol_dragging = false, false
local media_syncing, vol_syncing = false, false

-- No-op markup writes skipped: a textbox relayout for an identical string
-- is wasted work at poll frequency.
local function set_markup_now(widget, str)
    if widget._private.frost_markup == str then return end
    widget._private.frost_markup = str
    widget:set_markup_silently(str)
end

local function glyph_button(glyph, font, color)
    local b = wibox.widget.textbox()
    b.font = font or ui.glyph_font.m
    b:set_markup_silently(string.format('<span foreground="%s">%s</span>', color or FG_MAIN, glyph))
    return b
end

local mp_app = wibox.widget.textbox()
mp_app.font = ui.font.small
mp_app.ellipsize = "end"
mp_app.forced_width = 276

local mp_title = wibox.widget.textbox()
mp_title.font = ui.font.title
mp_title.ellipsize = "end"
mp_title.wrap = "char"
mp_title.forced_width = 276

local mp_artist = wibox.widget.textbox()
mp_artist.font = ui.font.body
mp_artist.ellipsize = "end"
mp_artist.forced_width = 276

local seek = ui.slider{
    minimum = 0, maximum = 1000, value = 0,
    width = 210, height = 20, bar_height = 4,
}
local time_cur = wibox.widget.textbox()
time_cur.font = ui.font.small
local time_tot = wibox.widget.textbox()
time_tot.font = ui.font.small

local btn_prev = glyph_button(FA_PREV, ui.glyph_font.m, FG_MUTED)
local btn_play = glyph_button(FA_PLAY, ui.glyph_font.l)
local btn_next = glyph_button(FA_NEXT, ui.glyph_font.m, FG_MUTED)
btn_prev:buttons(gears.table.join(awful.button({}, 1, function()
    awful.spawn.with_shell("playerctl previous") end)))
btn_play:buttons(gears.table.join(awful.button({}, 1, function()
    awful.spawn.with_shell("playerctl play-pause") end)))
btn_next:buttons(gears.table.join(awful.button({}, 1, function()
    awful.spawn.with_shell("playerctl next") end)))

-- Volume inside the popover: speaker glyph = mute toggle, slider = the
-- system sink volume (same wpctl path as the bar's volume widget).
local FA_VOLUP, FA_VOLMUTE = FA_NORMAL, FA_MUTED
local vol = ui.slider{
    minimum = 0, maximum = 100, value = 0,
    width = 210, height = 20, bar_height = 4,
}
local vol_pct = wibox.widget.textbox()
vol_pct.font = ui.font.strong
local btn_mute = glyph_button(FA_VOLUP, ui.glyph_font.m, FG_MUTED)
btn_mute:buttons(gears.table.join(awful.button({}, 1, function()
    volume_change("wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle") end)))

-- Seek: throttle to one MPRIS position command per 250ms; after one lands,
-- hold off the poll's slider sync for 1.2s so a laggy player position
-- report can't yank the handle back while the user is still interacting.
local pending_seek, pending_vol = nil, nil
local seek_hold_until = 0 -- ms, monotonic clock

local function schedule(timer)
    if not timer.started then timer:start() else timer:again() end
end

local function apply_pending_seek()
    if not pending_seek then return end
    local v = pending_seek; pending_seek = nil
    awful.spawn.with_shell(
        string.format("playerctl position %d", math.floor(v / 1e6 + 0.5)))
    seek_hold_until = GLib.get_monotonic_time() / 1000 + 1200
end

local apply_pending_vol -- forward declaration (also used on drag release)

local seek_timer = gears.timer{ timeout = 0.25, single_shot = true,
                                callback = apply_pending_seek }
local vol_timer = gears.timer{ timeout = 0.25, single_shot = true,
                               callback = function() apply_pending_vol() end }

--- Wire one seek slider (the media card's and the bar mini-player's) to
-- the shared throttled seek machinery.
function attach_seek(slider)
    slider:connect_signal("property::value", function()
        if media_syncing or not media.length then return end
        pending_seek = media.length * slider:get_value() / 1000
        schedule(seek_timer)
    end)
    slider:connect_signal("button::press", function() seek_dragging = true end)
    slider:connect_signal("button::release", function()
        seek_dragging = false
        apply_pending_seek()
    end)
end

vol:connect_signal("property::value", function()
    if vol_syncing then return end
    set_markup_now(vol_pct, string.format('<span font="' .. ui.font.strong .. '" foreground="%s">%d%%</span>',
        FG_MAIN, math.floor(vol:get_value() + 0.5)))
    pending_vol = vol:get_value()
    schedule(vol_timer)
end)
vol:connect_signal("button::press",   function() vol_dragging = true end)
vol:connect_signal("button::release", function()
    vol_dragging = false
    apply_pending_vol()
end)

function apply_pending_vol()
    if not pending_vol then return end
    local v = pending_vol; pending_vol = nil
    volume_change(string.format("wpctl set-volume @DEFAULT_AUDIO_SINK@ %d%%",
                                math.floor(v + 0.5)))
end

local function fmt_us(us)
    if not us or us <= 0 then return "0:00" end
    local s = math.floor(us / 1e6 + 0.5)
    return string.format("%d:%02d", math.floor(s / 60), s % 60)
end

--- Sync the card's and the bar's seek sliders + time labels from the
-- polled position, holding off while the user drags or a seek lands.
function sync_seek()
    local len = media.length or 0
    local stamp = GLib.get_monotonic_time() / 1000
    local tmark
    if len > 0 then
        tmark = string.format(
            '<span font="%s" foreground="%s">%s/%s</span>',
            ui.font.small, FG_MUTED, fmt_us(media.position), fmt_us(len))
    else
        tmark = ""
    end
    for _, w in ipairs(song_widgets) do
        set_markup_now(w.time, tmark)
        if w.bar then w.bar.sensitive = len > 0 end
    end
    set_markup_now(time_cur, string.format(
        '<span font="%s" foreground="%s">%s</span>',
        ui.font.small, FG_MUTED, fmt_us(media.position)))
    set_markup_now(time_tot, string.format(
        '<span font="%s" foreground="%s">%s</span>',
        ui.font.small, FG_MUTED, fmt_us(len)))
    if len <= 0 then return end
    if not seek_dragging and stamp >= seek_hold_until then
        local v = math.floor((media.position or 0) / len * 1000 + 0.5)
        media_syncing = true
        seek:set_value(v)
        for _, w in ipairs(song_widgets) do
            if w.bar then w.bar:set_value(v) end
        end
        media_syncing = nil
    end
end

function refresh_media_ui()
    if not media_open then return end -- nothing to repaint while closed
    local state = (media.status == "Playing") and "playing" or "paused"
    set_markup_now(mp_app, string.format(
        '<span font="%s" foreground="%s">%s</span>', ui.font.small, FG_MUTED,
        esc(string.format("%s  ·  %s", pretty_app(media.player) or "Now Playing", state))))
    set_markup_now(mp_title, string.format(
        '<span font="%s" foreground="%s">%s</span>',
        ui.font.title, FG_MAIN, esc(media.title or "")))
    set_markup_now(mp_artist, string.format(
        '<span font="%s" foreground="%s">%s</span>',
        ui.font.body, FG_MUTED, esc(media.artist or "")))
    set_markup_now(btn_play, string.format(
        '<span font="' .. ui.glyph_font.l .. '" foreground="%s">%s</span>', FG_MAIN,
        media.status == "Playing" and FA_PAUSE or FA_PLAY))
    set_markup_now(btn_mute, string.format(
        '<span font="' .. ui.glyph_font.m .. '" foreground="%s">%s</span>', FG_MUTED,
        vol_state.muted and FA_VOLMUTE or FA_VOLUP))
    set_markup_now(vol_pct, string.format(
        '<span font="%s" foreground="%s">%d%%</span>',
        ui.font.strong, FG_MAIN, vol_state.pct or 0))
    local len = media.length or 0
    seek.sensitive = len > 0 -- no mpris:length (streams): no seeking
    sync_seek()
    if not vol_dragging then
        vol_syncing = true
        vol:set_value(vol_state.pct or 0)
        vol_syncing = nil
    end
end

-- Live position while the popover is open: 0.5s poll, idle-free otherwise.
local pos_timer = gears.timer{ timeout = 0.5, callback = function()
    awful.spawn.easy_async_with_shell("playerctl position 2>/dev/null || true", function(out)
        local sec = tonumber(out)
        if sec and media_open then
            media.position = sec * 1e6
            refresh_media_ui()
        end
    end)
end }

local media_content = wibox.widget{
    {
        layout = wibox.layout.fixed.vertical,
        spacing = 10,
        mp_app,
        mp_title,
        mp_artist,
        seek,
        {
            time_cur,
            nil,
            time_tot,
            layout = wibox.layout.align.horizontal,
        },
        { -- transport, centred
            { btn_prev, btn_play, btn_next, spacing = 26,
              layout = wibox.layout.fixed.horizontal },
            widget = wibox.container.place,
        },
        { -- volume row
            btn_mute, vol, vol_pct, spacing = 10,
            layout = wibox.layout.fixed.horizontal,
        },
    },
    margins = 16,
    widget  = wibox.container.margin,
}
media_content.forced_width = 308

function close_media()
    if not media_open then return end
    media_open = false
    popover_mgr.close("media")
    if pos_timer.started then pos_timer:stop() end
end

function toggle_media()
    if media_open then close_media() else open_media() end
end

function open_media()
    if not media.has then return end -- nothing playing, nothing to control
    -- One surface at a time across the whole bar; placement, animation and
    -- dismissal belong to the shared surface manager.
    media_open = true
    popover_mgr.show{
        id = "media",
        content = media_content,
        width = 308,
        modal = true,
        reopen = open_media,
        on_open = function()
            media_open = true
            if not pos_timer.started then pos_timer:start() end
        end,
        on_close = function()
            media_open = false
            if pos_timer.started then pos_timer:stop() end
        end,
        refresh = refresh_media_ui,
    }
    refresh_media_ui()
    poll_song() -- fresh position/length right away
end



-- Clicking the volume indicator raises the window that owns the MPRIS
-- player: the PID owning the D-Bus name matches an awesome client's pid,
-- with a class-name match as fallback (some players run the MPRIS
-- interface in a helper process, e.g. playerctld). KDE Connect has no
-- window to raise, so the match simply finds nothing.
function focus_player()
    if not media.player then return end
    awful.spawn.easy_async_with_shell(
        "busctl --user list --no-legend 2>/dev/null | " ..
        "grep 'org.mpris.MediaPlayer2." .. media.player .. "' | head -1 | awk '{print $2}'",
        function(out)
            local pid = tonumber(out)
            local target = media.player:lower()
            for _, c in ipairs(client.get()) do
                local class = (c.class or ""):lower()
                if (pid and c.pid == pid) or class:find(target, 1, true) then
                    if c.minimized then c.minimized = false end
                    if not c:isvisible() and c.first_tag then
                        c.first_tag:view_only() -- reveal on its own monitor
                    end
                    -- Activate WITHOUT jump_to: jump_to calls screen.focus,
                    -- which warps the pointer to the player's monitor.
                    c:emit_signal("request::activate", "aether_volume",
                                  { raise = true })
                    return
                end
            end
        end)
end

-- Used by rc.lua's autohide: the bar going away takes its popover with it.
function M.close_media()
    close_media()
end

-- Debug/state access for awesome-client diagnostics.
M.poll_debug = function() return vol_bar_dragging, vol_state.pct end

return M
