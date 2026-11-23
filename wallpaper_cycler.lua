--------------------------------------------------------------------------
-- wallpaper_cycler.lua — native awesome 4.3 wallpaper cycler
--
-- One fullscreen wibox per screen (ontop=false, type="desktop",
-- input_passthrough=true) painted by a custom widget. Every screen shows
-- the SAME wallpaper, chosen randomly from cfg.directory, and all screens
-- transition to the next one together: the transition is one timer, one
-- progress value and one style shared by all screens, so the change is
-- seamless.  The style itself is random per switch (crossfade, settle,
-- bloom, drift, push — never the same twice running) with a randomised
-- magnitude, direction and duration, so consecutive transitions never
-- look choreographed the same way.
--
-- Screen-sized copies are pre-baked by ImageMagick in a background process
-- into ~/.cache/awesome-wallpaper/ so switches never stall the WM thread.
--
-- The painter must be a real widget, not a bare bgimage: awesome's drawable
-- only repaints what a widget marks dirty and returns early otherwise
-- (wibox/drawable.lua, do_redraw: "if self._dirty_area:is_empty() then
-- return end").
--
-- API: setup{directory=, interval=1800, fade=2.0, tick=0.016, cache_dir=}
--      stop(), next(), status()
--------------------------------------------------------------------------

local wibox = require("wibox")
local awful = require("awful")
local gears = require("gears")
local gfs   = require("gears.filesystem")
local wallpaper = require("gears.wallpaper")
local base  = require("wibox.widget.base")
local lgi   = require("lgi")
local GLib  = lgi.GLib
local cairo = lgi.cairo
local lfs   = require("lfs")
local anim  = require("anim") -- reduced-motion preference (gsettings poll)

local screen = screen

local M = {}

local cfg = {
    directory = nil,
    interval  = 1800,                                  -- seconds between switches
    fade      = 2.0,                                   -- base transition duration
    tick      = 0.016,                                 -- animation frame interval
    cache_dir = os.getenv("HOME") .. "/.cache/awesome-wallpaper",
}

-- Transition styles. paint_frame interpolates a spec with:
--   zoom    incoming scale offset at t=0; positive settles down (starts
--           larger), negative blooms up (starts smaller)
--   slide   incoming offset at t=0 as a fraction of the screen axis
--   dir     which edge a slide enters from ({x=±1,y=0} or {x=0,y=±1})
--   counter outgoing counter-drift amplitude (fraction of the axis)
-- Every offset is 0 at t=1, so the committed 1:1 frame never snaps.
local STYLES = { "crossfade", "settle", "bloom", "drift", "push" }
local last_style = nil

local function pick_transition()
    local style = last_style
    while style == last_style and #STYLES > 1 do
        style = STYLES[math.random(#STYLES)]
    end
    last_style = style
    local spec = { style = style }
    if style == "settle" then
        spec.zoom = 0.03 + math.random() * 0.03            -- 1.03 .. 1.06
    elseif style == "bloom" then
        spec.zoom = -(0.03 + math.random() * 0.03)         -- 0.97 .. 0.94
    elseif style == "drift" or style == "push" then
        local axis, sign = math.random(2), (math.random(2) == 1) and 1 or -1
        spec.dir = (axis == 1) and { x = sign, y = 0 } or { x = 0, y = sign }
        spec.slide = (style == "drift") and (0.05 + math.random() * 0.04)
                                            or (0.11 + math.random() * 0.05)
        -- Push adds a gentle give on the outgoing image: it drifts a little
        -- against the incoming slide and returns (sin, zero at both ends).
        if style == "push" then spec.counter = 0.02 + math.random() * 0.01 end
    end
    return spec
end

local started       = false
local bag           = {}    -- paths still awaiting their turn (shuffle bag)
local seen          = {}    -- every path that has ever entered the bag
local current_path  = nil    -- the wallpaper every screen is showing
local pending_path  = nil    -- pre-picked next wallpaper (cache building)
local outgoing_path = nil    -- path being faded OUT (nil when idle)
local screens       = {}    -- [screen] = per-screen state table
local fade_timer, switch_timer, attach_fn
local building      = {}    -- cache files currently being built by magick
local fading        = false
local t             = 0     -- transition progress, shared by all screens
local fade_dur      = nil   -- duration of the running transition (jittered)
local tx            = nil   -- the running transition spec (pick_transition)
local incoming_path = nil    -- path being faded in (nil when idle)
local subscribers   = {}    -- callbacks notified on every frame change
local state_file    = nil    -- remembers the current path across restarts

local IMAGE_EXT = { jpg = true, jpeg = true, png = true, bmp = true, tga = true }

-------------------------------------------------------------------------- helpers

-- Single-quote for shell: closes the quote around each embedded '.
local function shquote(s)
    return "'" .. s:gsub("'", "'\\''") .. "'"
end

local function is_file(path)
    return path and lfs.attributes(path, "mode") == "file"
end

-- Remember the current wallpaper across awesome restarts.  The root pixmap is
-- switched to it as well (sync_root), because during a restart the root window
-- is exposed for a moment before the cycler's wiboxes map: without this the
-- stock theme wallpaper (the awesome logo) flashes on every reload.
local function remember(path)
    if not (state_file and path) then return end
    local f = io.open(state_file, "w")
    if not f then return end
    f:write(path, "\n")
    f:close()
end

local function remembered()
    if not state_file then return nil end
    local f = io.open(state_file, "r")
    if not f then return nil end
    local path = f:read("*l")
    f:close()
    if is_file(path) then return path end
    return nil
end

-- Keep the X root background equal to what the cycler is painting, so the
-- root never exposes the theme wallpaper between a restart and the first
-- painted frame.  st.cur is already a screen-sized surface, so this is a
-- blit, not a decode.
local function sync_root()
    for s, st in pairs(screens) do
        if st.cur then
            pcall(wallpaper.maximized, st.cur, s, true)
        end
    end
end

-- MD5 of a key string. GLib.compute_checksum is absent from this lgi build,
-- so the Checksum object API is used directly (verified on this machine).
local function md5(key)
    local ok, digest = pcall(function()
        local cs = GLib.Checksum.new(GLib.ChecksumType.MD5)
        cs:update(key)
        return cs:get_string()
    end)
    if ok then return digest end
    return key  -- plain string fallback, still a valid unique cache key
end

-- Cache file name includes source path, mtime and target size: any change
-- to those invalidates the entry automatically.
local function cache_path(src, w, h)
    local mtime = lfs.attributes(src, "modification") or 0
    return cfg.cache_dir .. "/" ..
        md5(string.format("%s|%s|%dx%d", src, tostring(mtime), w, h)) .. ".jpg"
end

-- Non-recursive scan of the wallpaper directory.
local function scan_files()
    local out = {}
    if not cfg.directory then return out end
    for f in lfs.dir(cfg.directory) do
        local p = cfg.directory .. "/" .. f
        if is_file(p) then
            local ext = f:lower():match("%.(%w+)$")
            if IMAGE_EXT[ext or ""] then out[#out + 1] = p end
        end
    end
    table.sort(out)
    return out
end

-- Pop the next image. One bag for the whole session so every screen shows
-- the same image; every image gets a turn before repeats.
local function pick()
    local files = scan_files()
    if #files == 0 then return nil end

    local present = {}
    for _, f in ipairs(files) do present[f] = true end
    for i = #bag, 1, -1 do
        if not present[bag[i]] then table.remove(bag, i) end
    end

    for _, f in ipairs(files) do
        if not seen[f] then
            table.insert(bag, math.random(#bag + 1), f) -- random position
            seen[f] = true
        end
    end

    if #bag == 0 then
        for _, f in ipairs(files) do seen[f] = true end
        for i = #files, 2, -1 do -- Fisher-Yates
            local j = math.random(i)
            files[i], files[j] = files[j], files[i]
        end
        bag = files
        -- Never show the current image again right after a reshuffle.
        if #bag > 1 and bag[#bag] == current_path then
            bag[#bag], bag[1] = bag[1], bag[#bag]
        end
    end

    return table.remove(bag)
end

-------------------------------------------------------------------------- images

-- Bake a screen-sized cover-fit surface in-thread (fallback path, costs a
-- decode of the source image). Same transform pattern as
-- gears.wallpaper.maximized (gears/wallpaper.lua).
local function bake(src, w, h)
    local src_surf = gears.surface.load(src)
    if not src_surf then return nil end
    local sw, sh = gears.surface.get_size(src_surf)
    local out = cairo.ImageSurface(cairo.Format.RGB24, w, h)
    local ocr = cairo.Context(out)
    local scale = math.max(w / sw, h / sh)
    ocr:scale(scale, scale)
    ocr:translate((w / scale - sw) / 2, (h / scale - sh) / 2)
    ocr:set_source_surface(src_surf, 0, 0)
    ocr.operator = cairo.Operator.SOURCE
    ocr:paint()
    return out
end

-- Build the cache file asynchronously so magick never runs on the WM thread.
local function build_async(src, w, h, dst)
    if building[dst] then return end
    building[dst] = true
    local cmd = string.format(
        "magick %s -resize %dx%d^ -gravity center -extent %dx%d -strip -quality 95 %s",
        shquote(src), w, h, w, h, shquote(dst))
    awful.spawn.easy_async_with_shell(cmd, function() building[dst] = nil end)
end

-- Get a ready-to-paint screen-sized surface for src: load the cached file
-- when it exists, otherwise bake in-thread right now (and queue the cache
-- build for next time).
local function prepare(src, geom)
    local dst = cache_path(src, geom.width, geom.height)
    if is_file(dst) then
        local surf = gears.surface.load(dst)
        if surf then return surf end
    end
    print("wallpaper_cycler: cache miss, baking in-thread: " .. src)
    build_async(src, geom.width, geom.height, dst)
    return bake(src, geom.width, geom.height)
end

-------------------------------------------------------------------------- painting

-- Paint the current frame (or the running transition) onto a cairo context.
local function paint_frame(st, cr, w, h)
    local cur, nxt = st.cur, st.nxt
    if not cur then
        cr:set_source_rgb(0, 0, 0)
        cr:paint()
        return
    end
    if not nxt then
        -- Committed frame: exact 1:1 blit, no transform at all.
        cr:set_source_surface(cur, 0, 0)
        cr.operator = cairo.Operator.SOURCE
        cr:paint()
        return
    end
    local spec = tx or {}

    -- Alpha: smoothstep, the same symmetric curve a crossfade wants.  All
    -- movement below eases out (decelerates into place) so surfaces settle,
    -- matching the ease-out convention of the UI motion layer.
    local alpha = t * t * (3 - 2 * t)                    -- smoothstep
    local e_out = 1 - (1 - t) * (1 - t) * (1 - t)        -- ease-out-cubic

    -- Outgoing counter-drift (push only): a gentle give against the incoming
    -- slide, sin() so it is 0 with zero velocity at both ends — the committed
    -- 1:1 frame therefore never snaps.
    local counter = spec.counter or 0
    if counter > 0 then
        local cx = counter * math.sin(math.pi * t) * w * -(spec.dir and spec.dir.x or 0)
        local cy = counter * math.sin(math.pi * t) * h * -(spec.dir and spec.dir.y or 0)
        cr:translate(cx, cy)
        cr:set_source_surface(cur, 0, 0)
        cr.operator = cairo.Operator.SOURCE
        cr:paint()
        cr:translate(-cx, -cy)
    else
        cr:set_source_surface(cur, 0, 0)
        cr.operator = cairo.Operator.SOURCE
        cr:paint()
    end

    -- Incoming: optional scale (zoom) and offset (slide from an edge), both
    -- interpolating to identity at t=1.
    local zoom = 1 + (spec.zoom or 0) * (1 - e_out)
    local ox = (spec.slide or 0) * (1 - e_out) * w * (spec.dir and spec.dir.x or 0)
    local oy = (spec.slide or 0) * (1 - e_out) * h * (spec.dir and spec.dir.y or 0)
    cr:translate(w / 2 + ox, h / 2 + oy)
    cr:scale(zoom, zoom)
    cr:translate(-w / 2, -h / 2)
    cr:set_source_surface(nxt, 0, 0)
    cr.operator = cairo.Operator.OVER
    cr:paint_with_alpha(alpha)
end

-- The painter must be a real widget, not a bare bgimage: awesome's drawable
-- only repaints the area a widget marks dirty and returns early otherwise
-- (wibox/drawable.lua, do_redraw: "if self._dirty_area:is_empty() then
-- return end"). Emitting "widget::redraw_needed" on this widget per
-- animation tick marks the full screen dirty and drives the crossfade.
local function make_painter(st)
    local widget = base.make_widget(nil, nil, {enable_properties = true})
    function widget:fit(_, width, height)
        return width, height
    end
    function widget:draw(_, cr, width, height)
        paint_frame(st, cr, width, height)
    end
    return widget
end

-- One animation tick: ask for a repaint of the whole wibox.
local function repaint(st)
    st.widget:emit_signal("widget::redraw_needed")
end

-- Tell subscribers (e.g. the top bar's blur) that the wallpaper state moved.
local function notify()
    for _, fn in ipairs(subscribers) do pcall(fn) end
end

-------------------------------------------------------------------------- lifecycle

-- Pick the next image and make sure its screen-sized cache files are being
-- built, so the next switch can load them instantly.
local function precache()
    pending_path = pick()
    if not pending_path then return end
    for s in pairs(screens) do
        local g = s.geometry
        local dst = cache_path(pending_path, g.width, g.height)
        if not is_file(dst) then
            build_async(pending_path, g.width, g.height, dst)
        end
    end
end

local function commit_all()
    for _, st in pairs(screens) do
        if st.nxt then
            st.cur = st.nxt
            st.nxt = nil
            repaint(st) -- final frame painted at exactly 1:1
        end
    end
    fading = false
    t = 1
    incoming_path = nil
    outgoing_path = nil
    tx, fade_dur = nil, nil
    sync_root() -- root follows the committed image (no theme flash on reload)
    fade_timer:stop() -- idle cost is zero between fades
    notify()
end

local function fade_tick()
    if not fading then
        fade_timer:stop()
        return
    end
    t = t + cfg.tick / (fade_dur or cfg.fade)
    if t >= 1 then
        commit_all()
        precache()
    else
        for _, st in pairs(screens) do repaint(st) end
        notify()
    end
end

local function switch()
    if fading then
        commit_all() -- a switch interrupting a fade commits it first
    end
    local path = pending_path
    pending_path = nil
    if not path or not is_file(path) then path = pick() end
    if not path then return end
    local prev = current_path

    local ready = false
    for s, st in pairs(screens) do
        local surf = prepare(path, s.geometry)
        if surf then
            st.nxt = surf
            ready = true
        end
    end
    if not ready then return end

    current_path = path
    remember(path)

    -- The desktop has animations off (gsettings enable-animations): land the
    -- new wallpaper without a transition, same respect the UI motion layer pays.
    if not anim.animations then
        outgoing_path = nil
        commit_all()
        precache()
        print("wallpaper_cycler: switched to " .. path .. " (reduced motion, instant)")
        return
    end

    outgoing_path = prev -- the bar's blur fades from this one

    -- Unique-feeling transition: a random style (never twice the same) with a
    -- randomised magnitude/direction, over a jittered duration around cfg.fade.
    tx = pick_transition()
    fade_dur = cfg.fade * (0.8 + math.random() * 0.4)
    incoming_path = path
    t = 0
    fading = true
    fade_timer:again()
    notify()
    print("wallpaper_cycler: fading in " .. path .. " (" .. tx.style ..
        ", " .. string.format("%.2f", fade_dur) .. "s)")
end

local function show_initial()
    -- A reload keeps the remembered image instead of picking a new random one,
    -- so an awesome restart never changes the wallpaper by itself.
    local path = remembered() or pick()
    if not path then return end
    current_path = path
    remember(path)
    for s, st in pairs(screens) do
        st.cur = prepare(path, s.geometry)
        repaint(st)
    end
    sync_root()
    precache()
    notify()
    print("wallpaper_cycler: initial wallpaper: " .. path)
end

-------------------------------------------------------------------------- setup API

local function attach(s)
    local g = s.geometry
    local st = {}
    local wb = wibox{
        x = g.x, y = g.y, width = g.width, height = g.height,
        screen = s, visible = true, ontop = false, type = "desktop",
        bg = "#000000", border_width = 0,
    }
    -- Explicitly after creation: from the args table it only applies when
    -- args.screen is set (wibox/init.lua).
    wb.input_passthrough = true
    st.wb = wb
    st.widget = make_painter(st)
    wb:set_widget(st.widget)  -- required: the drawable repaints what a widget marks dirty
    screens[s] = st
    -- attach() runs for screens that appear after setup too (second monitor
    -- enabled at runtime, RandR hotplug).  Such a screen has no frame yet and
    -- paint_frame would fill it black until the next 30 minute switch, so give
    -- it the current wallpaper immediately.  At setup time current_path is
    -- still nil and show_initial() paints every screen itself.
    if current_path then
        st.cur = prepare(current_path, g) or st.cur
        repaint(st)
        sync_root()
    end
end

local function on_removed(s)
    local st = screens[s]
    if not st then return end
    st.wb.visible = false -- no wibox:destroy() in 4.3; drop the reference
    screens[s] = nil
end

local function on_geometry(s)
    local st = screens[s]
    if not st then return end
    st.wb:geometry(s.geometry)
    -- A resolution change mid-fade would leave per-screen surfaces at the old
    -- size; commit what is visible, then rebuild for the new geometry.
    if fading then commit_all() end
    if current_path then
        st.cur = prepare(current_path, s.geometry) or st.cur
        repaint(st)
        sync_root()
    end
end

function M.setup(args)
    -- A hot reload (package.loaded[...] = nil via awesome-client) creates a
    -- fresh module table whose stop() cannot reach instances from earlier
    -- loads; they would keep their timers and wiboxes alive forever. A
    -- global hook survives reloads, so use it to tear the previous instance
    -- down first.
    local previous_stop = rawget(_G, "__wallpaper_cycler_stop")
    if previous_stop then pcall(previous_stop) end
    rawset(_G, "__wallpaper_cycler_stop", M.stop)

    for _, k in ipairs{ "directory", "interval", "fade", "tick", "cache_dir" } do
        if args and args[k] ~= nil then cfg[k] = args[k] end
    end
    state_file = cfg.cache_dir .. "/current"
    gfs.make_directories(cfg.cache_dir)
    math.randomseed(os.time())
    attach_fn = attach
    awful.screen.connect_for_each_screen(attach) -- also runs for existing screens
    screen.connect_signal("removed", on_removed)
    screen.connect_signal("property::geometry", on_geometry)
    show_initial()
    fade_timer = gears.timer{ timeout = cfg.tick, callback = fade_tick }
    switch_timer = gears.timer{
        timeout = cfg.interval,
        callback = switch,
        autostart = true,
    }
    started = true
    print("wallpaper_cycler: started, directory=" .. tostring(cfg.directory) ..
        " interval=" .. tostring(cfg.interval) ..
        "s fade=" .. tostring(cfg.fade) .. "s (styles: " .. table.concat(STYLES, ", ") .. ")")
end

function M.stop()
    -- gears.timer:stop() errors "timer not started" in 4.3, and the hot-reload
    -- teardown legitimately stops idle timers.
    if switch_timer and switch_timer.started then switch_timer:stop() end
    if fade_timer and fade_timer.started then fade_timer:stop() end
    for _, st in pairs(screens) do
        st.wb.visible = false
    end
    screens, bag, seen = {}, {}, {}
    current_path, pending_path = nil, nil
    incoming_path, fading, t = nil, false, 0
    fade_dur, tx, last_style = nil, nil, nil
    outgoing_path = nil
    subscribers = {}
    if attach_fn then awful.screen.disconnect_for_each_screen(attach_fn) end
    screen.disconnect_signal("removed", on_removed)
    screen.disconnect_signal("property::geometry", on_geometry)
    switch_timer, fade_timer, attach_fn = nil, nil, nil
    started = false
    if rawget(_G, "__wallpaper_cycler_stop") == M.stop then
        rawset(_G, "__wallpaper_cycler_stop", nil)
    end
    print("wallpaper_cycler: stopped")
end

function M.next()
    if not started then return end
    switch()
    switch_timer:again() -- restart the interval from now
end

-- Raise the wallpaper above the clients for `seconds` so a transition can be
-- watched on demand, then drop it back behind everything:
--   awesome-client 'require("wallpaper_cycler").preview(4)'
function M.preview(seconds)
    if not started then return end
    for _, st in pairs(screens) do st.wb.ontop = true end
    M.next()
    gears.timer.start_new(seconds or 4, function()
        for _, st in pairs(screens) do st.wb.ontop = false end
        return false
    end)
end

function M.status()
    local count = 0
    for _ in pairs(screens) do count = count + 1 end
    return {
        running = started,
        current = current_path,
        pending = pending_path,
        fading  = fading,
        t       = t,
        style   = tx and tx.style or nil,
        screens = count,
    }
end

-- What a dependent (the top bar's blur) needs to paint in sync: while idle
-- the wallpaper every screen shows; while transitioning, the path being
-- faded OUT (outgoing), the one being faded IN (incoming), the shared
-- progress and the running style.
-- NOTE: during a transition current_path already points at the incoming path.
function M.frames()
    return {
        current  = current_path,
        incoming = incoming_path,
        outgoing = outgoing_path,
        t        = t,
        fading   = fading,
        style    = tx and tx.style or nil,
    }
end

-- fn is called on every frame change (initial show, each fade tick, commit).
-- Returns an unsubscribe function.
function M.subscribe(fn)
    if type(fn) ~= "function" then return function() end end
    subscribers[#subscribers + 1] = fn
    fn() -- deliver the current state immediately
    return function()
        for i, f in ipairs(subscribers) do
            if f == fn then table.remove(subscribers, i) return end
        end
    end
end

return M
