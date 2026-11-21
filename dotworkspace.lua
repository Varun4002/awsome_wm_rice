--------------------------------------------------------------------------
-- dotworkspace.lua — the "." wallpaper showcase workspace
--
-- Each screen's tag table leads with a "." tag (created in rc.lua): a
-- deliberate, uncluttered presentation surface where only the wallpaper
-- shows.  This module is the single authority for everything dot-related:
--
--   * tag lookups: the prepended dot shifts positional indexes, so tags
--     are ALWAYS resolved by name (M.numbered / M.first_numbered), never
--     by raw index;
--   * routing policy: any ordinary client that ends up tagged on the dot
--     is moved to workspace "1" of its screen, which is then selected.
--     One policy table, one signal handler — no per-app rules scattered
--     around the config.  Exemptions: the sticky overlay launchers
--     (Starlight, Launchpad — reliable class metadata, never title
--     matching), dialogs (they follow their transient parent), and
--     notification/dock/desktop/splash windows;
--   * accent(): a pastel accent derived from the current wallpaper
--     (one async 1x1 magick average per wallpaper change, cached),
--     used by the bar's dot pill.  Falls back to the AETHER accent.
--------------------------------------------------------------------------

local awful = require("awful")
local gears = require("gears")
local lfs   = require("lfs")

local ui     = require("ui")
local cycler = require("wallpaper_cycler")

local M = {}

M.config = {
    dot_name    = ".",
    destination = "1",    -- ordinary windows land here, never on dot
    -- Overlay launchers: sticky, never routed, usable over the dot.
    overlay_classes = { starlight = true, launchpad = true },
    route_enabled   = true,
}

-- Pastel wallpaper-derived accent; the AETHER accent until the first
-- wallpaper sample lands.
M.accent_color = ui.color.accent

local subscribers = {}
local accent_cache = {}   -- [src path] = "#rrggbb"
local accent_jobs = {}    -- magick jobs in flight
local last_src

function M.subscribe(fn)
    subscribers[#subscribers + 1] = fn
    return function()
        for i = #subscribers, 1, -1 do
            if subscribers[i] == fn then table.remove(subscribers, i) end
        end
    end
end

local function notify()
    for _, fn in ipairs(subscribers) do pcall(fn) end
end

-------------------------------------------------------------------------- colors

local function hex_ok(h)
    return type(h) == "string" and #h == 7 and h:sub(1, 1) == "#"
        and h:sub(2):match("^%x+$") ~= nil
end

--- Linear mix: fraction f of b into a.
function M.mix(a, b, f)
    if not (hex_ok(a) and hex_ok(b)) then return a end
    local r1, g1, b1 = tonumber(a:sub(2, 3), 16), tonumber(a:sub(4, 5), 16),
                       tonumber(a:sub(6, 7), 16)
    local r2, g2, b2 = tonumber(b:sub(2, 3), 16), tonumber(b:sub(4, 5), 16),
                       tonumber(b:sub(6, 7), 16)
    local mix = function(x, y)
        return math.floor(x + (y - x) * f + 0.5)
    end
    return string.format("#%02x%02x%02x",
        mix(r1, r2), mix(g1, g2), mix(b1, b2))
end

local function shquote(s)
    return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

local function is_file(path)
    return path and lfs.attributes(path, "mode") == "file"
end

-- One async magick call per wallpaper change; the result is blended toward
-- white into a pastel so it stays legible on the dark frosted bar.
local function compute_accent(src)
    if not is_file(src) then return end
    local cached = accent_cache[src]
    if cached then
        if cached ~= M.accent_color then
            M.accent_color = cached
            notify()
        end
        return
    end
    if accent_jobs[src] then return end
    accent_jobs[src] = true
    awful.spawn.easy_async_with_shell(
        "magick " .. shquote(src) .. " -resize 1x1! -depth 8 txt:- 2>/dev/null",
        function(out)
            accent_jobs[src] = nil
            local r, g, b = (out or ""):match("#(%x%x)(%x%x)(%x%x)")
            if not r then return end
            local pastel = M.mix("#" .. r .. g .. b, "#ffffff", 0.55)
            local n = 0
            for _ in pairs(accent_cache) do n = n + 1 end
            if n > 16 then accent_cache = {} end -- tiny table; still bound it
            accent_cache[src] = pastel
            if pastel ~= M.accent_color then
                M.accent_color = pastel
                notify()
            end
        end)
end

cycler.subscribe(function()
    -- Same cycler semantics as frostbar: while fading, the incoming
    -- wallpaper is the one being shown.
    local f = cycler.frames()
    local want = f.fading and f.incoming or f.current
    if want and want ~= last_src then
        last_src = want
        compute_accent(want)
    end
end)

-------------------------------------------------------------------------- tag lookups

function M.is_dot(tag)
    return tag ~= nil and tag.valid and tag.name == M.config.dot_name
end

local function by_name(s, name)
    for _, t in ipairs(s.tags) do
        if t.name == name then return t end
    end
end

--- Tag named "." on a screen (nil when the screen has no dot yet).
function M.dot_tag(s)
    return by_name(s, M.config.dot_name)
end

--- Numbered workspace i (1-9) on a screen, by name.
function M.numbered(s, i)
    return by_name(s, tostring(i))
end

--- First ordinary workspace ("1"); falls back to the first tag.
function M.first_numbered(s)
    return M.numbered(s, 1) or (s.tags and s.tags[1])
end

--------------------------------------------------------------------------
-- tag reconciliation

local CANONICAL = { M.config.dot_name, "1", "2", "3", "4", "5",
                    "6", "7", "8", "9" }

--- Enforce each screen's exact tag set, in canonical order (dot first).
--
-- awful.tag always APPENDS, and the per-screen setup callback can run more
-- than once for a screen object (observed across awesome restarts, when
-- Xinerama re-detects screens mid-restart).  A naive call therefore
-- duplicates or shifts the set.  This rebuilds the set in canonical order,
-- carrying clients over to the same-named tag before the old one is
-- deleted.  Returns true when a rebuild happened.
function M.ensure_tags(s)
    local fast = #s.tags == #CANONICAL
    if fast then
        for i, name in ipairs(CANONICAL) do
            if not s.tags[i] or s.tags[i].name ~= name then
                fast = false
                break
            end
        end
    end
    if fast then return false end

    local old = {}
    for _, t in ipairs(s.tags) do old[#old + 1] = t end
    for _, name in ipairs(CANONICAL) do
        awful.tag.add(name, { screen = s, layout = awful.layout.layouts[1] })
    end
    local fresh = {}
    for i = #old + 1, #s.tags do fresh[#fresh + 1] = s.tags[i] end

    for _, t in ipairs(old) do
        local target
        for _, f in ipairs(fresh) do
            if f.name == t.name then target = f break end
        end
        target = target or M.first_numbered(s) or fresh[1]
        if target then
            for _, c in ipairs(t:clients()) do c:move_to_tag(target) end
        end
        t:delete() -- empty now; refuses (harmlessly) if a client snuck in
    end

    if #s.selected_tags == 0 then
        local boot = M.first_numbered(s)
        if boot then boot:view_only() end
    end
    return true
end

-------------------------------------------------------------------------- routing

-- nil = leave the client alone; a tag = dialogs follow their parent;
-- "workspace1" = route to the ordinary destination workspace.
local function routable(c)
    if not M.config.route_enabled then return nil end
    if not c or not c.valid then return nil end
    if M.config.overlay_classes[(c.class or ""):lower()] then return nil end
    if c.sticky or c.skip_taskbar then return nil end
    if c.type ~= "normal" and c.type ~= "dialog" then return nil end
    -- Only a client whose ONLY tag is the dot is "accidentally" there.  A
    -- window toggled onto the dot alongside its real workspace stays: the
    -- user explicitly asked for it to be visible over the showcase.
    local tags = c:tags()
    if #tags ~= 1 or not M.is_dot(tags[1]) then return nil end
    if c.transient_for and c.transient_for.valid then
        local p = c.transient_for.first_tag
        if p and p.valid and not M.is_dot(p) then return p end
    end
    return "workspace1"
end

--- Move an ordinary client off the dot.  No focus change: the client is
-- brand-new or was just tagged, and awful.autofocus handles activation.
-- Re-entrancy is safe without a flag: the retag to a numbered workspace
-- emits "tagged" for a non-dot tag, which never re-enters routing.
local function route(c)
    local what = routable(c)
    if not what then return false end
    local target = (what == "workspace1") and M.first_numbered(c.screen) or what
    if not target or not target.valid then return false end
    target:view_only()   -- screen-local: the showcase gives way to workspace 1
    c:move_to_tag(target)
    return true
end

--- Install the routing signal.  Safe to call more than once.
function M.install()
    if M._installed then return end
    M._installed = true

    -- Covers every path that can put a client on the dot: launching while
    -- the dot is selected, Mod4+click on the dot pill, workspace actions,
    -- late-async window maps, multi-window applications.  The guard flag
    -- keeps the move_to_tag re-tag from re-entering (no switching loops).
    client.connect_signal("tagged", function(c, tag)
        if M.is_dot(tag) then route(c) end
    end)
end

return M
