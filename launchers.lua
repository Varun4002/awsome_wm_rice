--------------------------------------------------------------------------
-- launchers.lua — placement authority for the GTK launchers
--
-- Starlight (Alt+Space) and Launchpad (Mod4+e) are GTK4 toplevels. GTK maps
-- them at a preliminary geometry and then resizes them with a ConfigureRequest
-- that also carries position (0,0); Awesome honours that position for floating
-- clients. Rule-time placement therefore always loses (docs/03-defects.md, D1).
--
-- This module is the single placement authority:
--   * records the screen a keybinding fired on (the window rule reads it),
--   * centres the client at manage time and after every size change,
--   * keeps the client invisible until its size has been stable for a moment,
--     so the first painted frame is already centred,
--   * reveals it once, then detaches. No rule callbacks, no repeated reveal.
--
-- glass.lua must not touch a client's opacity while placement is pending; it
-- checks the _aether_placement_pending marker this module sets (D10).
--
-- The reveal waits for *size* stability, not for size hints: GTK4 only
-- publishes min == max after the WM has already resized the window, so
-- waiting for hints costs a fixed 350 ms (D4, docs/03-defects.md).
--------------------------------------------------------------------------

local awful = require("awful")
local gears = require("gears")
local naughty = require("naughty")

local M = {}

local CLASSES = { starlight = true, launchpad = true }

-- Availability is probed once per class on first use: a binding whose binary is
-- gone must say so instead of doing nothing (user-flow FL1).  `nil` = unknown,
-- true = present, false = missing.
local available = {}
local warned_at = {}
local WARN_INTERVAL = 30 -- seconds between notices for the same class

local function warn_missing(class)
    local now = os.time()
    if warned_at[class] and now - warned_at[class] < WARN_INTERVAL then return end
    warned_at[class] = now
    naughty.notify {
        title = "AETHER",
        text  = "`" .. class .. "` is not installed.\nRebuild it or rebind its key.",
        timeout = 8,
    }
end

-- A remembered screen stays valid this long after the keybinding. It is
-- consumed by the next manage of that class, so the TTL only matters for a
-- launcher started by hand (no keybinding) while a stale entry exists.
local SCREEN_TTL = 5

local SETTLE_DELAY = 0.08 -- reveal once the size has been stable this long
local HARD_TIMEOUT = 0.50 -- ... but never hold a launcher longer than this

-- [class] = { screen = <screen>, at = <os.time()> }
local target = {}

--- Spawn a launcher on the screen the pointer is on right now.
function M.spawn(class)
    target[class] = { screen = mouse.screen, at = os.time() }

    local known = available[class]
    if known == nil then
        -- First press: resolve the binary, then spawn (or explain) in the
        -- callback.  One shell round-trip, off the WM's critical path.
        awful.spawn.easy_async_with_shell(
            "command -v " .. class .. " >/dev/null 2>&1 && echo yes || echo no",
            function(out)
                local present = out:find("yes", 1, true) ~= nil
                available[class] = present
                if present then
                    awful.spawn(class)
                else
                    target[class] = nil
                    warn_missing(class)
                end
            end)
        return
    end

    if not known then
        target[class] = nil
        warn_missing(class)
        return
    end

    awful.spawn(class)
end

--- Searchable launcher (navigation §3.6 / flow FL6).  `mode` is a rofi mode:
-- "drun" for applications, "window" for every open window on every screen.
-- rofi is the interim affordance while the AETHER launchers are missing, so
-- it is probed exactly like them and reports its absence instead of failing
-- silently.
function M.search(mode)
    local binary = "rofi"
    local known = available[binary]
    local function run()
        awful.spawn.with_shell("rofi -show " .. mode)
    end
    if known == nil then
        awful.spawn.easy_async_with_shell(
            "command -v " .. binary .. " >/dev/null 2>&1 && echo yes || echo no",
            function(out)
                local present = out:find("yes", 1, true) ~= nil
                available[binary] = present
                if present then run() else warn_missing(binary) end
            end)
        return
    end
    if not known then warn_missing(binary) return end
    run()
end

--- Screen index for the window rule; falls back to the pointer's screen.
function M.screen_for(class)
    local t = target[class]
    if t and (os.time() - t.at) <= SCREEN_TTL then
        return t.screen.index
    end
    return mouse.screen.index
end

-- Consume the remembered screen for a class. Called from the manage handler,
-- after rules have read it, so a later manual launch cannot inherit it.
local function take_screen(class)
    local t = target[class]
    target[class] = nil
    if t and (os.time() - t.at) <= SCREEN_TTL then
        return t.screen
    end
    return nil
end

local function target_position(c, scr)
    local wa = scr.workarea
    return wa.x + math.floor((wa.width - c.width) / 2),
           wa.y + math.floor((wa.height - c.height) / 2)
end

local function center(c, scr)
    if c.width <= 1 or c.height <= 1 then
        return
    end
    local x, y = target_position(c, scr)
    if c.x ~= x or c.y ~= y then
        c:geometry{ x = x, y = y }
    end
end

local function place_when_ready(c, scr)
    local placed = false
    local applying = false -- ignore geometry events caused by our own move
    local last_w, last_h = c.width, c.height
    local finish, on_geometry -- forward declarations

    local reveal_timer = gears.timer{
        timeout = SETTLE_DELAY,
        single_shot = true,
        callback = function()
            finish()
        end,
    }

    finish = function()
        if placed or not c.valid then
            return
        end
        placed = true
        reveal_timer:stop()

        -- The client's own (0,0) ConfigureRequest can move it across
        -- monitors and awesome then re-homes it to the screen under that
        -- position. Undo that: the screen chosen at spawn time wins.
        if c.screen ~= scr then
            c.screen = scr
        end
        applying = true
        center(c, scr)
        applying = false

        c._aether_placement_pending = nil
        c.opacity = 1
    end

    -- Kept connected for the client's lifetime: GTK can send another
    -- ConfigureRequest after the reveal (late async results, theme changes),
    -- and a launcher must never end up off-centre. Position-only requests are
    -- corrected immediately; size changes only schedule the one-time reveal.
    on_geometry = function()
        if applying or not c.valid then
            return
        end
        -- A ConfigureRequest can arrive without a size change (GTK sends
        -- (0,0)); keep the window centred regardless of who moved it.
        applying = true
        center(c, scr)
        applying = false

        if placed then
            return
        end
        if c.width ~= last_w or c.height ~= last_h then
            last_w, last_h = c.width, c.height
            -- Restart the single timer: a burst of resizes results in one
            -- reveal, 80 ms after the last size change.
            reveal_timer:stop()
            reveal_timer:start()
        end
    end

    -- Hide before the first frame is painted. glass.lua leaves the opacity
    -- alone while the placement marker is set.
    c._aether_placement_pending = true
    c.opacity = 0

    c:connect_signal("property::geometry", on_geometry)

    -- Centre immediately with the size GTK mapped with. Launchpad's window
    -- already maps at its final size, so its first visible frame is centred.
    applying = true
    center(c, scr)
    applying = false

    reveal_timer:start()

    gears.timer.start_new(HARD_TIMEOUT, function()
        finish()
        return false
    end)
end

--- True while a launcher is managed on screen (including while it is still
-- being placed). The launchers are modal overlays: the pointer must not move
-- focus to a client underneath them, or the GTK app sees a blur and dismisses
-- itself (D5).
function M.has_open_launcher()
    for _, c in ipairs(client.get()) do
        if CLASSES[c.class] and c._aether_launcher_open and c:isvisible() then
            return true
        end
    end
    return false
end

--- Install the single manage handler. Safe to call more than once.
function M.install()
    if M._installed then
        return
    end
    M._installed = true

    client.connect_signal("manage", function (c)
        if not CLASSES[c.class] then
            return
        end
        c._aether_launcher_open = true
        local scr = take_screen(c.class) or c.screen
        place_when_ready(c, scr)
    end)

    client.connect_signal("unmanage", function (c)
        c._aether_launcher_open = nil
    end)
end

return M
