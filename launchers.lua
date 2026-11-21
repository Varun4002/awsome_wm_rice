--------------------------------------------------------------------------
-- launchers.lua — placement authority for the GTK launchers
--
-- Starlight (Alt+Space) and Launchpad (Mod4+e) are GTK4 toplevels. GTK maps
-- them at a preliminary size and then resizes them with a ConfigureRequest
-- that also carries position (0,0); Awesome honours that position for floating
-- clients. Rule-time placement therefore always loses (docs/03-defects.md, D1).
--
-- This module is the single placement authority:
--   * records the screen a keybinding fired on (the window rule reads it),
--   * keeps the window transparent until it sits in its final place,
--   * waits for the post-map size to stabilise, centres once using that
--     screen's work area, restores opacity, and detaches.
--
-- No rule callbacks and no repeated placement.
--------------------------------------------------------------------------

local awful = require("awful")
local gears = require("gears")

local M = {}

local CLASSES = { starlight = true, launchpad = true }

-- Hide a launcher until it is centred: GTK's first frames are at the wrong
-- size/position and would otherwise be visible as a jump.
local HIDE_UNTIL_PLACED = true

-- A remembered screen stays valid for this long after the keybinding.
local SCREEN_TTL = 2

local SETTLE_DELAY = 0.02 -- let a second ConfigureRequest land
local HINT_WAIT    = 0.35 -- first chance to place once size hints are final
local HARD_TIMEOUT = 1.2  -- place regardless of hints

-- [class] = { screen = <screen>, at = <epoch seconds> }
local target = {}

--- Spawn a launcher on the screen the pointer is on right now.
function M.spawn(class)
    target[class] = { screen = mouse.screen, at = os.time() }
    awful.spawn(class)
end

--- Screen index for the window rule; falls back to the pointer's screen.
function M.screen_for(class)
    local t = target[class]
    if t and (os.time() - t.at) <= SCREEN_TTL then
        return t.screen.index
    end
    return mouse.screen.index
end

local function center(c, scr)
    local wa = scr.workarea
    c:geometry {
        x = wa.x + math.floor((wa.width - c.width) / 2),
        y = wa.y + math.floor((wa.height - c.height) / 2),
    }
end

--- True when the client is at the size its own hints declare as final.
--  These launchers are non-resizable, so GTK publishes min == max; matching it
--  is a reliable signal that no further ConfigureRequest is coming.
local function at_final_size(c)
    local sh = c.size_hints
    return sh and sh.max_width and sh.max_height
        and c.width == sh.max_width and c.height == sh.max_height
end

local function place_when_ready(c, scr)
    local placed = false
    local on_geometry

    local function place()
        if placed or not c.valid then
            return
        end
        if c.width <= 1 or c.height <= 1 then
            return
        end
        placed = true
        c:disconnect_signal("property::geometry", on_geometry)

        -- The client's own (0,0) ConfigureRequest can move it across monitors,
        -- and awesome then re-homes it to the screen under that position.
        -- Undo that: the screen chosen when the keybinding fired wins.
        if c.screen ~= scr then
            c.screen = scr
        end

        center(c, scr)
        c.opacity = 1
    end

    on_geometry = function()
        if placed or not c.valid then
            return
        end
        gears.timer.start_new(SETTLE_DELAY, function ()
            if at_final_size(c) then
                place()
            end
            return false
        end)
    end

    c:connect_signal("property::geometry", on_geometry)

    gears.timer.start_new(HINT_WAIT, function ()
        if at_final_size(c) then
            place()
        end
        return false
    end)

    gears.timer.start_new(HARD_TIMEOUT, function ()
        place()
        return false
    end)
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
        -- Capture the screen the rule chose before GTK's post-map request can
        -- move the client into a different monitor (see place()).
        local scr = c.screen
        if HIDE_UNTIL_PLACED then
            c.opacity = 0
        end
        place_when_ready(c, scr)
    end)
end

return M
