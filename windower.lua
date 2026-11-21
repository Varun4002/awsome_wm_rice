--------------------------------------------------------------------------
-- windower.lua — Layer 1 active-window block, Layer 2 window detail,
-- Layer 3 window control surface
--
-- Each screen has its own block.  It shows the window that screen last
-- focused: the focused client on the focused screen, and the last focused
-- client of the other screen (rendered muted).  A block only ever shows a
-- client that still exists, still belongs to that screen, is not minimized
-- and is on a visible tag — no stale window information.
--
-- The control surface always acts on `client.focus` and re-reads it on
-- every client signal while open.  Close / move / minimize validate the
-- client again at click time, so a destroyed or retargeted client can never
-- receive a stale action.  Controls reflect the real client state
-- (maximize vs restore, fullscreen, floating, sticky, on-top).
--------------------------------------------------------------------------

local awful = require("awful")
local gears = require("gears")
local wibox = require("wibox")

local ui      = require("ui")
local popover = require("popover")
local dotws   = require("dotworkspace")

local M = {}

local blocks = {}   -- [screen] = block
local last   = {}   -- [screen] = client (last focused on that screen)
local flushing = false

local FA_PIN   = "\u{f08d}" -- thumb-tack  (sticky)
local FA_UP    = "\u{f062}" -- arrow-up    (always on top)
local FA_MINUS = "\u{f068}"
local FA_SQUARE= "\u{f096}"
local FA_TIMES = "\u{f00d}"

-------------------------------------------------------------------------- state

local function state_of(c)
    if not c or not c.valid then return "Desktop", ui.color.text_faint end
    if c.fullscreen then return "Fullscreen", ui.color.accent end
    if c.maximized then return "Maximized", ui.color.accent end
    if c.floating then return "Floating", ui.color.warn end
    return "Tiled", ui.color.text_faint
end

-- The client a screen's block may display.  Deliberately strict about
-- staleness (destroyed, moved, hidden tag resolves to nil), but minimized
-- clients ARE shown — muted with a Minimized state — so they can be
-- restored with one click instead of vanishing from the desktop.
local function resolve(s)
    local c = last[s]
    if not c or not c.valid then return nil end
    if c.screen ~= s then return nil end
    if not c:isvisible() and not c.minimized then return nil end
    return c
end

-------------------------------------------------------------------------- Layer 1

local function update_block(b)
    local c = resolve(b.screen)
    b.client = c
    b.icon.set(c)

    if not c then
        ui.set_text(b.app, "Desktop", ui.color.text_dim, ui.font.strong)
        ui.set_text(b.title, "No window focused", ui.color.text_faint, ui.font.small)
        ui.set_text(b.state, "", ui.color.text_faint, ui.font.tiny)
        ui.set_text(b.marks, "", ui.color.text_faint, "FontAwesome 8")
        b.root._aether_no_hover = true
        b.root.bg = "#00000000"
        return
    end

    b.root._aether_no_hover = false
    local app = ui.app_name(c)
    local active = (client.focus == c)
    ui.set_text(b.app, ui.truncate(app, 26),
        active and ui.color.text or ui.color.text_dim, ui.font.strong)
    ui.set_text(b.title, c.name and c.name ~= "" and c.name or "(untitled)",
        active and ui.color.text_dim or ui.color.text_faint, ui.font.small)

    local label, color = state_of(c)
    if c.minimized then
        label, color = "Minimized", ui.color.text_faint
    end
    ui.set_text(b.state, label, color, ui.font.tiny)

    local marks = {}
    if c.sticky then marks[#marks + 1] = FA_PIN end
    if c.ontop then marks[#marks + 1] = FA_UP end
    ui.set_text(b.marks, table.concat(marks, " "),
        active and ui.color.text_dim or ui.color.text_faint, "FontAwesome 8")
end

local function update_all()
    for _, b in pairs(blocks) do
        if b.screen.valid then update_block(b) end
    end
end

-- Coalesce bursts (rapid focus switching, tag changes) into one relayout.
local function schedule_update()
    if flushing then return end
    flushing = true
    gears.timer.delayed_call(function()
        flushing = false
        update_all()
    end)
end

-------------------------------------------------------------------------- Layer 2

local function detail_popover(c)
    if not c or not c.valid then return nil end
    local app = ui.app_name(c)
    local label, label_color = state_of(c)
    local tag = c.first_tag
    local layout = tag and awful.layout.getname(awful.layout.get(tag.screen)) or "—"

    local title = ui.text{ font = "Inter SemiBold 11", wrap = "word", width = 292 }
    ui.set_markup(title, ui.span(c.name ~= "" and c.name or "(untitled)",
        ui.color.text, "Inter SemiBold 11"))

    local head = wibox.widget{
        ui.cell(ui.app_icon(c, 20)),
        {
            ui.text{ font = ui.font.strong,
                     markup = ui.span(app, ui.color.text, ui.font.strong) },
            ui.text{ font = ui.font.tiny,
                     markup = ui.span(c.class or "", ui.color.text_faint) },
            layout = wibox.layout.fixed.vertical,
            spacing = 1,
        },
        layout = wibox.layout.fixed.horizontal,
        spacing = 10,
    }

    local body = wibox.layout.fixed.vertical()
    body.spacing = 7
    body:add(head)
    body:add(title)
    body:add(ui.divider())
    body:add(ui.key_value("State", label, { fg = label_color }))
    body:add(ui.key_value("Workspace", tag and (tag.name or tostring(tag.index)) or "—"))
    body:add(ui.key_value("Monitor", "Screen " .. c.screen.index))
    body:add(ui.key_value("Layout", layout))
    body:add(ui.text{ font = ui.font.tiny,
        markup = ui.span("Click for window controls", ui.color.text_faint) })

    return {
        content = body,
        width = 320,
    }
end

-------------------------------------------------------------------------- Layer 3

local TILING_LAYOUTS = {
    [awful.layout.suit.tile] = true,
    [awful.layout.suit.tile.left] = true,
    [awful.layout.suit.tile.bottom] = true,
    [awful.layout.suit.tile.top] = true,
    [awful.layout.suit.fair] = true,
    [awful.layout.suit.fair.horizontal] = true,
    [awful.layout.suit.spiral] = true,
    [awful.layout.suit.spiral.dwindle] = true,
}

local function tiling_ok(c)
    if not c or not c.valid then return false end
    if c.floating or c.fullscreen then return false end
    local layout = c.first_tag and awful.layout.get(c.first_tag.screen)
    return layout ~= nil and TILING_LAYOUTS[layout] == true
end

--- Build the control surface.  Every callback re-reads client.focus and
-- revalidates it: the surface can never fire an action into a dead client.
local function build_controls()
    local icon = ui.icon_slot(22)
    local app = ui.text{ font = "Inter SemiBold 11", width = 236, ellipsize = "end" }
    local title = ui.text{ font = ui.font.small, width = 300, ellipsize = "end" }
    local meta = ui.text{ font = ui.font.tiny, width = 300, ellipsize = "end" }
    local marks = ui.text{ font = ui.font.tiny, align = "right" }

    local render -- forward declaration: the action closures call it

    local function act(fn, close_after)
        return function()
            local c = client.focus
            if not c or not c.valid then
                popover.close("stale")
                return
            end
            fn(c)
            if close_after then
                popover.close("action")
            else
                render()
            end
        end
    end

    local btn_min = ui.chip{ glyph = FA_MINUS, label = "Minimize",
        onclick = act(function(c) c.minimized = true end, true) }
    local btn_max = ui.chip{ glyph = FA_SQUARE, label = "Maximize",
        onclick = act(function(c) c.maximized = not c.maximized; c:raise() end) }
    local btn_close = ui.chip{ glyph = FA_TIMES, label = "Close", danger = true,
        onclick = act(function(c) c:kill() end, true) }

    local t_floating = ui.chip{ label = "Floating",
        onclick = act(function(c) c.floating = not c.floating end) }
    local t_fullscreen = ui.chip{ label = "Fullscreen",
        onclick = act(function(c) c.fullscreen = not c.fullscreen; c:raise() end) }
    local t_sticky = ui.chip{ label = "Sticky",
        onclick = act(function(c) c.sticky = not c.sticky end) }
    local t_ontop = ui.chip{ label = "On top",
        onclick = act(function(c) c.ontop = not c.ontop end) }

    -- Workspace and monitor targets are resolved at click time from the
    -- focused client, so a screen change cannot leave a stale destination.
    -- Numbered workspaces are looked up by NAME: the leading "." tag
    -- shifts positional indexes (dotworkspace.lua).
    local ws_chips = {}
    for i = 1, 9 do
        ws_chips[i] = ui.chip{
            label = tostring(i), width = 30, height = 24,
            onclick = function()
                local c = client.focus
                if not c or not c.valid then popover.close("stale") return end
                local tag = dotws.numbered(c.screen, i)
                if tag then
                    c:move_to_tag(tag)
                    popover.close("action")
                end
            end,
        }
    end

    local mon_chips = {}
    for i = 1, screen.count() do
        mon_chips[i] = ui.chip{
            label = "Screen " .. i, height = 24,
            onclick = function()
                local c = client.focus
                if not c or not c.valid then popover.close("stale") return end
                local target = screen[i]
                if target and target ~= c.screen then
                    c:move_to_screen(target)
                    popover.close("action")
                end
            end,
        }
    end

    local btn_master = ui.chip{ label = "Master",
        onclick = act(function(c)
            local master = awful.client.getmaster(c.screen)
            if master and master ~= c then c:swap(master) end
        end) }
    local btn_prev = ui.chip{ glyph = "\u{f060}", label = "Prev",
        onclick = act(function(c) awful.client.swap.byidx(-1, c) end) }
    local btn_next = ui.chip{ glyph = "\u{f061}", label = "Next",
        onclick = act(function(c) awful.client.swap.byidx(1, c) end) }

    local function row(children, spacing)
        children.layout = wibox.layout.fixed.horizontal
        children.spacing = spacing or 4
        return wibox.widget(children)
    end

    local sections = {
        layout = wibox.layout.fixed.vertical,
        spacing = 8,
        wibox.widget{
            ui.cell(icon.widget),
            {
                wibox.widget{
                    app, nil, marks,
                    layout = wibox.layout.align.horizontal,
                    forced_width = 300,
                },
                title,
                meta,
                layout = wibox.layout.fixed.vertical,
                spacing = 1,
            },
            layout = wibox.layout.fixed.horizontal,
            spacing = 10,
        },
        ui.divider(),
        row{ btn_min, btn_max, btn_close },
        row{ t_floating, t_fullscreen, t_sticky, t_ontop },
        ui.text{ font = ui.font.tiny,
                 markup = ui.span("MOVE TO WORKSPACE", ui.color.text_faint, ui.font.tiny) },
        row(ws_chips, 4),
    }
    if #mon_chips > 1 then
        sections[#sections + 1] = ui.text{
            font = ui.font.tiny,
            markup = ui.span("MOVE TO MONITOR", ui.color.text_faint, ui.font.tiny),
        }
        sections[#sections + 1] = row(mon_chips, 4)
    end
    sections[#sections + 1] = ui.text{
        font = ui.font.tiny,
        markup = ui.span("TILING", ui.color.text_faint, ui.font.tiny),
    }
    sections[#sections + 1] = row{ btn_master, btn_prev, btn_next }

    local root = wibox.widget(sections)

    render = function()
        local c = client.focus
        if not c or not c.valid then
            popover.close("no-focus")
            return
        end
        icon.set(c)
        ui.set_text(app, ui.app_name(c), ui.color.text, "Inter SemiBold 11")
        ui.set_text(title, c.name ~= "" and c.name or "(untitled)",
            ui.color.text_dim, ui.font.small)
        local tag = c.first_tag
        ui.set_text(meta, string.format("%s · Screen %d · %s",
            tag and ("Workspace " .. (tag.name or tag.index)) or "No workspace",
            c.screen.index, state_of(c)), ui.color.text_faint, ui.font.tiny)

        local mark = {}
        if c.floating then mark[#mark + 1] = "floating" end
        if c.sticky then mark[#mark + 1] = "sticky" end
        if c.ontop then mark[#mark + 1] = "on top" end
        ui.set_text(marks, table.concat(mark, " · "),
            ui.color.text_faint, ui.font.tiny)

        btn_max:set_label(c.maximized and "Restore" or "Maximize")
        btn_max:set_glyph(c.maximized and "\u{f065}" or FA_SQUARE)
        t_floating:set_state{ active = c.floating }
        t_fullscreen:set_state{ active = c.fullscreen }
        t_sticky:set_state{ active = c.sticky }
        t_ontop:set_state{ active = c.ontop == true }

        local can_tile = tiling_ok(c)
        btn_master:set_state{ enabled = can_tile }
        btn_prev:set_state{ enabled = can_tile }
        btn_next:set_state{ enabled = can_tile }

        for i, chip in ipairs(ws_chips) do
            chip:set_state{ active = tag ~= nil and tag.name == tostring(i) }
        end
        for i, chip in ipairs(mon_chips) do
            chip:set_state{ active = c.screen.index == i }
        end
    end

    local watched = {}
    local function watch(sig, fn)
        client.connect_signal(sig, fn)
        watched[#watched + 1] = { sig, fn }
    end

    local function connect()
        watch("focus", render)
        watch("unmanage", render)
        watch("manage", render)
        for _, prop in ipairs{
            "name", "icon", "floating", "fullscreen", "maximized",
            "maximized_horizontal", "maximized_vertical", "sticky", "ontop",
            "minimized", "screen",
        } do
            watch("property::" .. prop, render)
        end
        watch("tagged", render)
        watch("untagged", render)
        tag.connect_signal("property::selected", render)
        tag.connect_signal("property::layout", render)
    end

    local connected = false
    local function disconnect()
        if not connected then return end
        connected = false
        for _, w in ipairs(watched) do
            client.disconnect_signal(w[1], w[2])
        end
        watched = {}
        tag.disconnect_signal("property::selected", render)
        tag.disconnect_signal("property::layout", render)
    end

    local function do_connect()
        if connected then return end
        connected = true
        connect()
    end

    return {
        widget = root,
        render = render,
        connect = do_connect,
        disconnect = disconnect,
    }
end

local function open_controls()
    local c = client.focus
    if not c or not c.valid then return end
    if popover.is_open("win-controls") then popover.close("reopen") end
    local surface = build_controls()
    popover.show{
        id = "win-controls",
        content = surface.widget,
        width = 344,
        modal = true,
        on_open = surface.connect,
        on_close = function()
            surface.disconnect()
        end,
        refresh = surface.render,
    }
    surface.render()
end
M.open_controls = open_controls

local function activate_and_open(b)
    local c = b.client
    if not c or not c.valid then return end
    -- A minimized app restores instead of opening controls on nothing.
    if c.minimized then
        c.minimized = false
        c:emit_signal("request::activate", "aether_bar", { raise = true })
        return
    end
    if c ~= client.focus then
        c:emit_signal("request::activate", "aether_bar", { raise = true })
    end
    -- Only open when activation really moved focus to that client; the
    -- controls must target the actual focused client, never a stale one.
    if client.focus == c then open_controls() end
end

-------------------------------------------------------------------------- public

--- Active-window block for a screen's bar.
function M.widget(s)
    local b = { screen = s }
    b.icon = ui.icon_slot(16)
    b.app = ui.text{ font = ui.font.strong, width = 230, ellipsize = "end" }
    b.title = ui.text{ font = ui.font.small, width = 300, ellipsize = "end" }
    b.state = ui.text{ font = ui.font.tiny, align = "right" }
    b.marks = ui.text{ font = ui.font.tiny, align = "right" }

    local column = wibox.widget{
        layout = wibox.layout.fixed.vertical,
        spacing = 0,
        wibox.widget{
            b.app, nil, b.state,
            layout = wibox.layout.align.horizontal,
            forced_width = 300,
        },
        wibox.widget{
            b.title, nil, b.marks,
            layout = wibox.layout.align.horizontal,
            forced_width = 300,
        },
    }

    local row = wibox.widget{
        ui.cell(b.icon.widget),
        { column, left = 9, widget = wibox.container.margin },
        layout = wibox.layout.fixed.horizontal,
    }

    local root = wibox.container.background()
    root.shape = gears.shape.rounded_rect
    root.bg = "#00000000"
    local place = wibox.container.place(ui.pad(row, 10, 10, 0, 0))
    place.valign = "center"
    place.halign = "left"
    root.widget = place
    root.forced_width = 340
    root.forced_height = 28

    ui.hover(root, function() return "#00000000" end, function()
        return b.client and ui.color.hover or "#00000000"
    end)

    root:buttons(gears.table.join(
        awful.button({}, 1, function()
            activate_and_open(b)
        end),
        -- Preserves the old tasklist's right-click: the full client list.
        awful.button({}, 3, function()
            awful.menu.client_list({ theme = { width = 250 } })
        end)))

    popover.hover(root, "win-detail", function()
        local c = b.client
        if not c then return nil end
        return detail_popover(c)
    end)

    b.root = root
    blocks[s] = b

    -- Initial paint (bar construction happens before the first focus event).
    if s.valid then update_block(b) end
    return root
end

-------------------------------------------------------------------------- signals

client.connect_signal("focus", function(c)
    last[c.screen] = c
    schedule_update()
end)
client.connect_signal("unmanage", function(c)
    for s, tracked in pairs(last) do
        if tracked == c then last[s] = nil end
    end
    schedule_update()
end)
for _, sig in ipairs{
    "manage", "tagged", "untagged",
    "property::name", "property::icon", "property::floating", "property::fullscreen",
    "property::maximized", "property::maximized_horizontal",
    "property::maximized_vertical", "property::sticky", "property::ontop",
    "property::minimized", "property::screen",
} do
    client.connect_signal(sig, schedule_update)
end
tag.connect_signal("property::selected", schedule_update)
screen.connect_signal("removed", function(s)
    blocks[s] = nil
    last[s] = nil
end)

-- Adopt the focus that already exists after an awesome restart.
if client.focus then last[client.focus.screen] = client.focus end

return M
