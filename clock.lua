--------------------------------------------------------------------------
-- clock.lua — Layer 1 clock + Layer 2 contextual time surface
--
-- The ambient clock is two lines (time above, date below).  Hovering reveals
-- the full date and the current month as a calendar; clicking pins the same
-- surface so it can be dismissed with Escape.
--
-- One timer aligned to the next minute drives every clock instance (the bar
-- on each screen and the expanded panel), so the widget never wakes the WM
-- more than once a minute and never shows a stale minute.
--------------------------------------------------------------------------

local awful = require("awful")
local gears = require("gears")
local wibox = require("wibox")

local ui      = require("ui")
local popover = require("popover")

local M = {}

local targets = {}   -- { time = textbox, date = textbox, full = textbox }
local listeners = {}
local last_stamp

local function paint(now)
    now = now or os.time()
    local stamp = os.date("%Y-%m-%d %H:%M", now)
    if stamp ~= last_stamp then
        last_stamp = stamp
        for _, fn in ipairs(listeners) do pcall(fn, now) end
    end
    -- 12-hour clock with meridiem ("9:41 PM").
    local time = ui.time12(now)
    local date = os.date("%a %d %b", now):gsub(" 0", " ")
    local full = os.date("%A, %d %B %Y", now):gsub(", 0", ", ")
    for i = #targets, 1, -1 do
        local t = targets[i]
        ui.set_text(t.time, time, ui.color.text, t.font or ui.font.strong)
        if t.date then ui.set_text(t.date, date, ui.color.text_dim, ui.font.tiny) end
        if t.full then ui.set_text(t.full, full, ui.color.text_dim, ui.font.small) end
    end
end

local function tick()
    paint(os.time())
end

local function schedule()
    local sec = tonumber(os.date("%S")) or 0
    gears.timer.start_new(60 - sec + 0.05, function()
        tick()
        schedule()
        return false
    end)
end

--- Register textboxes that follow the clock.  Returns a detach function.
function M.attach(time_tb, date_tb, full_tb, opts)
    local entry = { time = time_tb, date = date_tb, full = full_tb,
                    font = opts and opts.font }
    targets[#targets + 1] = entry
    paint(os.time())
    return function()
        for i = #targets, 1, -1 do
            if targets[i] == entry then table.remove(targets, i) end
        end
    end
end

--- Called once per minute (expanded panel uses it to stay live).
function M.subscribe(fn)
    listeners[#listeners + 1] = fn
    return function()
        for i = #listeners, 1, -1 do
            if listeners[i] == fn then table.remove(listeners, i) end
        end
    end
end

-------------------------------------------------------------------------- surfaces

local function build_detail()
    local now = os.date("*t")
    local time = ui.text{ font = "Inter SemiBold 20", align = "center" }
    ui.set_text(time, ui.time12(), ui.color.text, "Inter SemiBold 20")

    local date = ui.text{ font = ui.font.body, align = "center" }
    ui.set_text(date, (os.date("%A, %d %B %Y"):gsub(", 0", ", ")), ui.color.text_dim, ui.font.body)

    local month = ui.text{ font = ui.font.strong, align = "center" }
    ui.set_text(month, ui.month_title(now.year, now.month), ui.color.text_dim, ui.font.strong)

    local body = wibox.layout.fixed.vertical()
    body.spacing = 8
    body:add(time)
    body:add(date)
    body:add(ui.divider())
    body:add(month)
    body:add(ui.calendar(now.year, now.month, 30))
    body:add(ui.text{ font = ui.font.tiny,
        markup = ui.span("Click to pin · Escape to dismiss", ui.color.text_faint) })

    return {
        content = body,
        width = 244,
    }
end

-------------------------------------------------------------------------- public

--- Two-line ambient clock for a screen's bar.
function M.widget()
    local time = ui.text{ font = ui.font.strong, align = "right", width = 64 }
    local date = ui.text{ font = ui.font.tiny, align = "right", width = 64 }
    local column = wibox.widget{
        time, date,
        layout = wibox.layout.fixed.vertical,
        spacing = 0,
    }
    local root = wibox.container.background()
    root.shape = gears.shape.rounded_rect
    root.bg = "#00000000"
    root.forced_height = 28
    root.widget = wibox.container.place(ui.pad(column, 6, 8, 0, 0))

    ui.hover(root, function() return "#00000000" end, ui.color.hover)

    root:buttons(gears.table.join(awful.button({}, 1, function()
        if popover.is_open("clock-detail") and popover.any_modal() then
            popover.close("toggle")
            return
        end
        local spec = build_detail()
        spec.id = "clock-detail"
        spec.modal = true
        popover.show(spec)
    end)))

    popover.hover(root, "clock-detail", build_detail)

    M.attach(time, date)
    return root
end

schedule()

return M
