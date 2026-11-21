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
-- Also builds the bar's data widgets (shared across screens, macOS
-- styling, Inter Medium 10): M.song (playerctl), M.volume (wpctl) and
-- M.usage (opencode stats). All polling is async; the main loop never
-- blocks.
--------------------------------------------------------------------------

local wibox = require("wibox")
local awful = require("awful")
local gears = require("gears")
local base  = require("wibox.widget.base")
local lgi   = require("lgi")
local GLib  = lgi.GLib
local cairo = lgi.cairo
local lfs   = require("lfs")

local cycler = require("wallpaper_cycler")
local anim   = require("anim") -- popover fades (see the media popover below)

local M = {}

local CACHE_DIR = os.getenv("HOME") .. "/.cache/awesome-wallpaper-bar"

-- magick does not create the output directory; without it every strip
-- build fails silently and the bar stays on the solid fallback.
pcall(function() require("gears.filesystem").make_directories(CACHE_DIR) end)

-- Look & feel
local TINT_ALPHA       = 0.38
local HAIRLINE_ALPHA   = 0.10
local HIGHLIGHT_ALPHA  = 0.05
local FALLBACK         = { 14 / 255, 14 / 255, 16 / 255 } -- #0e0e10
local FG_MAIN          = "#f2f2f7"
local FG_MUTED         = "#9a9aa0"
local FONT_MAIN        = "Inter Medium 10"

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
                length = nil, position = nil }

-- Media popover hooks (defined below). Forward declarations because the
-- poll needs them: it opens nothing itself but must close the popover if
-- the player goes away while it is open, and refresh it on every poll.
local media_open = false
local media_popup -- forward declaration (close_media guards on it)
local toggle_media, close_media, refresh_media_ui, focus_player, open_media

local song_text = wibox.widget.textbox()
song_text.font = FONT_MAIN
song_text.ellipsize = "end"
song_text.wrap = "char"
song_text.visible = false

M.song = spaced(song_text, 8, 8)

-- Cap the composed text: a pango layout with a positive height inside a
-- 30px bar could wrap to 2 lines; a character cap keeps it to one line.
local SONG_MAX = 44
local function cap(s)
    local n = utf8.len(s)
    if not n or n <= SONG_MAX then return s end
    local ok, off = pcall(utf8.offset, s, SONG_MAX)
    if ok and off then
        return s:sub(1, off - 1) .. "…"
    end
    return s:sub(1, SONG_MAX) .. "…"
end

local function set_song(markup)
    if song_text._private.frost_markup == markup then return end
    song_text._private.frost_markup = markup
    song_text:set_markup_silently(markup)
end

local function set_song_visible(b)
    if song_text.visible ~= b then
        song_text.visible = b
        M.song.visible = b -- collapse the margins entirely when hidden
    end
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
            if not has then
                set_song_visible(false) -- no player / empty metadata
                if media_open then close_media() end
                return
            end
            local glyph = (media.status == "Playing") and "▶" or "❚❚"
            local text = cap((media.artist ~= "" and media.artist .. " — " or "")
                             .. media.title)
            set_song(string.format(
                '<span foreground="%s">%s</span> <span foreground="%s">%s</span> ' ..
                '<span foreground="%s">%s</span>',
                FG_MUTED, esc(pretty_app(media.player) or "Now Playing"),
                FG_MUTED, glyph, FG_MAIN, esc(text)))
            set_song_visible(true)
            if media_open then refresh_media_ui() end
        end)
end

-- click = open the media popover (seekbar + controls); scrolling on the
-- text still skips tracks without opening anything.
song_text:buttons(gears.table.join(
    awful.button({}, 1, function() toggle_media() end),
    awful.button({}, 4, function() awful.spawn.with_shell("playerctl next") end),
    awful.button({}, 5, function() awful.spawn.with_shell("playerctl previous") end)
))

gears.timer{ timeout = 3, autostart = true, call_now = true, callback = poll_song }

-------------------------------------------------------------------------- volume widget

local FA_NORMAL = "\u{f028}" -- FontAwesome volume-up
local FA_MUTED  = "\u{f026}" -- FontAwesome volume-off

local volume_text = wibox.widget.textbox()
volume_text.font = FONT_MAIN
volume_text.visible = false

M.volume = spaced(volume_text, 4, 10)

local vol_state = { pct = nil, muted = false }

local function set_volume(pct, muted)
    if vol_state.pct == pct and vol_state.muted == muted then return end
    vol_state.pct, vol_state.muted = pct, muted
    local glyph = muted and FA_MUTED or FA_NORMAL
    local fg = muted and FG_MUTED or FG_MAIN
    volume_text:set_markup_silently(string.format(
        '<span font="FontAwesome 10" foreground="%s">%s</span>' ..
        '<span font="Inter Medium 10" foreground="%s">  %d%%</span>',
        fg, glyph, fg, pct))
    volume_text.visible = true
end

-- wpctl: "Volume: 0.65" possibly + " [MUTED]"
local function poll_volume()
    awful.spawn.easy_async_with_shell(
        "wpctl get-volume @DEFAULT_AUDIO_SINK@ 2>/dev/null || true",
        function(out)
            local v = out:match("Volume:%s*([%d%.]+)")
            if not v then
                volume_text.visible = false
                return
            end
            set_volume(math.floor(tonumber(v) * 100 + 0.5),
                       out:find("MUTED", 1, true) ~= nil)
        end)
end

local function volume_change(cmd)
    awful.spawn.with_shell(cmd) -- async, never blocks the main loop
    -- re-read shortly after so the widget reflects the action immediately
    gears.timer.start_new(0.25, function()
        poll_volume()
        return false
    end)
end

-- click = raise the window that owns the player (the browser tab playing
-- audio, a media app, etc.); scroll up = +5%, scroll down = -5%.
volume_text:buttons(gears.table.join(
    awful.button({}, 1, function() focus_player() end),
    awful.button({}, 4, function() volume_change("wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%+") end),
    awful.button({}, 5, function() volume_change("wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%-") end)
))

gears.timer{ timeout = 2, autostart = true, call_now = true, callback = poll_volume }

-------------------------------------------------------------------------- opencode usage widget

-- Meaningful figure = tokens.input + output + reasoning (cache.read is
-- an order of magnitude larger and not real usage). Cost is always 0 on
-- this provider. Measured runtime: ~0.14s, so 60s polling is cheap.
local usage_text = wibox.widget.textbox()
usage_text.font = FONT_MAIN
usage_text.visible = false

M.usage = spaced(usage_text, 4, 10)

local usage_markup = nil

local function poll_usage()
    -- awesome's PATH lacks ~/.opencode/bin where the opencode binary lives
    awful.spawn.easy_async_with_shell(
        'PATH="$HOME/.opencode/bin:$PATH" opencode stats --days 0 --json 2>/dev/null | ' ..
        "jq -r '[(.tokens.input + .tokens.output + .tokens.reasoning), .sessions] | @tsv' " ..
        "2>/dev/null || true",
        function(out)
            local nums = {}
            for n in out:gmatch("%d+") do
                nums[#nums + 1] = tonumber(n)
                if #nums == 2 then break end
            end
            if #nums == 2 and nums[1] > 0 then
                local markup = string.format(
                    '<span foreground="%s">opencode</span> <span foreground="%s">%s</span>' ..
                    '<span foreground="%s"> · %ds</span>',
                    FG_MUTED, FG_MAIN, human(nums[1]), FG_MUTED, nums[2])
                if markup ~= usage_markup then
                    usage_markup = markup
                    usage_text:set_markup_silently(markup)
                    usage_text.visible = true
                end
            else
                usage_text.visible = false -- error / no jq / empty stats
            end
        end)
end

gears.timer{ timeout = 60, autostart = true, call_now = true, callback = poll_usage }

-------------------------------------------------------------------------- media popover

-- Clicking the now-playing text opens an opaque card anchored under the
-- bar: app name, track info, a draggable seekbar (drag = seek, release =
-- jump) and transport + volume controls. It follows the bar it was opened
-- from; moving the pointer out of it fades it away.

local FA_PREV, FA_PLAY, FA_PAUSE, FA_NEXT = "\u{f048}", "\u{f04b}", "\u{f04c}", "\u{f051}"

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

local function glyph_button(glyph, size, color)
    local b = wibox.widget.textbox()
    b.font = "FontAwesome " .. (size or 12)
    b:set_markup_silently(string.format('<span foreground="%s">%s</span>', color or FG_MAIN, glyph))
    return b
end

local mp_app = wibox.widget.textbox()
mp_app.font = "Inter Medium 9"
mp_app.ellipsize = "end"
mp_app.forced_width = 276

local mp_title = wibox.widget.textbox()
mp_title.font = "Inter SemiBold 13"
mp_title.ellipsize = "end"
mp_title.wrap = "char"
mp_title.forced_width = 276

local mp_artist = wibox.widget.textbox()
mp_artist.font = "Inter Medium 10"
mp_artist.ellipsize = "end"
mp_artist.forced_width = 276

local seek = wibox.widget.slider{
    minimum = 0, maximum = 1000, value = 0,
    bar_shape    = gears.shape.rounded_rect, bar_height = 4,
    bar_color    = "#4a4a4f",
    handle_shape = gears.shape.circle, handle_width = 12,
    handle_color = "#f2f2f7",
}
-- 4.3's slider:fit returns the *available* height ("use with a constraint
-- widget"), which would blow the popover up to its 9999px cap.
seek.forced_height = 20
local time_cur = wibox.widget.textbox()
time_cur.font = "Inter Medium 9"
local time_tot = wibox.widget.textbox()
time_tot.font = "Inter Medium 9"

local btn_prev = glyph_button(FA_PREV, 12, FG_MUTED)
local btn_play = glyph_button(FA_PLAY, 17)
local btn_next = glyph_button(FA_NEXT, 12, FG_MUTED)
btn_prev:buttons(gears.table.join(awful.button({}, 1, function()
    awful.spawn.with_shell("playerctl previous") end)))
btn_play:buttons(gears.table.join(awful.button({}, 1, function()
    awful.spawn.with_shell("playerctl play-pause") end)))
btn_next:buttons(gears.table.join(awful.button({}, 1, function()
    awful.spawn.with_shell("playerctl next") end)))

-- Volume inside the popover: speaker glyph = mute toggle, slider = the
-- system sink volume (same wpctl path as the bar's volume widget).
local FA_VOLUP, FA_VOLMUTE = FA_NORMAL, FA_MUTED
local vol = wibox.widget.slider{
    minimum = 0, maximum = 100, value = 0,
    bar_shape    = gears.shape.rounded_rect, bar_height = 4,
    bar_color    = "#4a4a4f",
    handle_shape = gears.shape.circle, handle_width = 10,
    handle_color = "#f2f2f7",
}
vol.forced_width = 210
vol.forced_height = 20 -- see seek: slider:fit echoes the available height
local vol_pct = wibox.widget.textbox()
vol_pct.font = "Inter Medium 9"
local btn_mute = glyph_button(FA_VOLUP, 12, FG_MUTED)
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

seek:connect_signal("property::value", function()
    if media_syncing or not media.length then return end
    pending_seek = media.length * seek.value / 1000
    schedule(seek_timer)
end)
seek:connect_signal("button::press",   function() seek_dragging = true end)
seek:connect_signal("button::release", function()
    seek_dragging = false
    apply_pending_seek()
end)

vol:connect_signal("property::value", function()
    if vol_syncing then return end
    set_markup_now(vol_pct, string.format('<span font="Inter Medium 9" foreground="%s">%d%%</span>',
        FG_MUTED, math.floor(vol.value + 0.5)))
    pending_vol = vol.value
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

function refresh_media_ui()
    if not media_popup then return end
    local state = (media.status == "Playing") and "playing" or "paused"
    set_markup_now(mp_app, string.format(
        '<span font="Inter Medium 9" foreground="%s">%s</span>', FG_MUTED,
        esc(string.format("%s  ·  %s", pretty_app(media.player) or "Now Playing", state))))
    set_markup_now(mp_title, string.format(
        '<span font="Inter SemiBold 13" foreground="%s">%s</span>',
        FG_MAIN, esc(media.title or "")))
    set_markup_now(mp_artist, string.format(
        '<span font="Inter Medium 10" foreground="%s">%s</span>',
        FG_MUTED, esc(media.artist or "")))
    set_markup_now(btn_play, string.format(
        '<span font="FontAwesome 17" foreground="%s">%s</span>', FG_MAIN,
        media.status == "Playing" and FA_PAUSE or FA_PLAY))
    set_markup_now(btn_mute, string.format(
        '<span font="FontAwesome 12" foreground="%s">%s</span>', FG_MUTED,
        vol_state.muted and FA_VOLMUTE or FA_VOLUP))
    set_markup_now(vol_pct, string.format(
        '<span font="Inter Medium 9" foreground="%s">%d%%</span>',
        FG_MUTED, vol_state.pct or 0))
    local len = media.length or 0
    seek.sensitive = len > 0 -- no mpris:length (streams): no seeking
    if len > 0 then
        if not seek_dragging and GLib.get_monotonic_time() / 1000 >= seek_hold_until then
            media_syncing = true
            seek:set_value(math.floor((media.position or 0) / len * 1000 + 0.5))
            media_syncing = nil
        end
        set_markup_now(time_cur, string.format(
            '<span font="Inter Medium 9" foreground="%s">%s</span>',
            FG_MUTED, fmt_us(media.position)))
        set_markup_now(time_tot, string.format(
            '<span font="Inter Medium 9" foreground="%s">%s</span>',
            FG_MUTED, fmt_us(len)))
    end
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

media_popup = awful.popup{
    widget = media_content,
    ontop  = true,
    type   = "dock",
    visible = false,
    bg     = "#1c1c1f",
    shape  = gears.shape.rounded_rect,
    border_width = 0,
    preferred_positions = "bottom",
    preferred_anchors  = "middle", -- centred under the bar
}
media_popup:connect_signal("mouse::leave", function() close_media() end)

function close_media()
    if not media_open then return end
    media_open = false
    if pos_timer.started then pos_timer:stop() end
    anim.tween{ tag = "media_popup", duration = 0.12, step = function(t)
        media_popup.opacity = 1 - t
    end, done = function()
        if media_popup and not media_open then
            media_popup.visible = false
            media_popup.opacity = 1
        end
    end }
end

function toggle_media()
    if media_open then close_media() else open_media() end
end

function open_media()
    if not song_text.visible then return end -- nothing playing, nothing to control
    -- One popover at a time (lazy require: control_center requires
    -- frostbar's exports, so a top-level require would be a cycle).
    pcall(function() require("control_center").close() end)
    refresh_media_ui()
    poll_song() -- fresh position/length right away
    -- Anchor to the bar on the screen under the pointer (the one that was
    -- clicked), not the focused client's screen.
    local s = mouse.screen or awful.screen.focused()
    if not s then return end
    media_popup:move_next_to(s.mywibox)
    media_open = true
    if not pos_timer.started then pos_timer:start() end
    anim.tween{ tag = "media_popup", duration = 0.18, step = function(t)
        media_popup.opacity = t
    end }
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
                    c:jump_to() -- switches to its tag, raises and focuses it
                    return
                end
            end
        end)
end

-- Used by rc.lua's autohide: the bar going away takes its popover with it.
function M.close_media()
    close_media()
end

return M
