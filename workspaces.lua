--------------------------------------------------------------------------
-- workspaces.lua — Layer 1 workspace indicator, Layer 2 preview, Layer 3
-- workspace actions
--
-- Layer 1: nine compact pills.  The selected workspace is accent-filled,
-- occupied workspaces carry a subtle surface and an occupancy tick, empty
-- ones stay quiet.  The built-in awful taglist keeps the update logic and
-- the Mod4+click tag semantics intact.
--
-- Layer 2: hovering a pill reveals its window list (icon + title) after a
-- short delay, in the shared popover surface, without stealing keyboard.
--
-- Layer 3: right-click opens the workspace action surface (view, send the
-- focused window here, toggle in view, next layout).  Right-click no longer
-- view-toggles directly: toggle-in-view is the first action of the surface,
-- so the capability is preserved with an explicit affordance.
--------------------------------------------------------------------------

local awful = require("awful")
local gears = require("gears")
local wibox = require("wibox")

local ui      = require("ui")
local popover = require("popover")
local dotws   = require("dotworkspace")

local M = {}

local PILL_W, PILL_H = 24, 20

local FA_CIRCLE = "\u{f111}" -- the dot workspace's indicator glyph

local function client_state(c)
    if c.fullscreen then return "fullscreen" end
    if c.maximized then return "maximized" end
    if c.floating then return "floating" end
    return "tiled"
end

-- Sticky overlays (Starlight, Launchpad) live on every tag; they must never
-- make a workspace — least of all the dot showcase — look occupied.
local function real_clients(t)
    if not dotws.is_dot(t) then return t:clients() end
    local out = {}
    for _, c in ipairs(t:clients()) do
        if not (c.sticky or c.skip_taskbar) then out[#out + 1] = c end
    end
    return out
end

-------------------------------------------------------------------------- preview

local function preview_row(c)
    local app = ui.app_name(c)
    local title = c.name and c.name ~= "" and c.name or app
    local focused = c == client.focus
    local tb = ui.text{ font = ui.font.small, ellipsize = "end", width = 196 }
    ui.set_markup(tb, ui.span(ui.truncate(title, 38) .. (c.minimized and "  ·min" or ""),
        focused and ui.color.text or ui.color.text_dim))
    return wibox.widget{
        ui.cell(ui.app_icon(c, 14)),
        { tb, left = 8, widget = wibox.container.margin },
        layout = wibox.layout.fixed.horizontal,
        forced_height = 20,
    }
end

local function build_preview(t)
    if not t or not t.valid then return nil end
    local clients = real_clients(t)
    local rows = {}
    local shown = 0
    for _, c in ipairs(clients) do
        shown = shown + 1
        if shown <= 5 then rows[#rows + 1] = preview_row(c) end
    end
    if #rows == 0 then
        rows[1] = ui.text{ font = ui.font.small,
                           markup = ui.span("No windows on this workspace",
                                            ui.color.text_faint) }
    elseif shown > #rows then
        rows[#rows + 1] = ui.text{
            font = ui.font.tiny,
            markup = ui.span(string.format("+%d more", shown - #rows),
                             ui.color.text_faint),
        }
    end

    local head = wibox.widget{
        ui.text{ font = ui.font.strong,
                 markup = ui.span("Workspace " .. (t.name or ""), ui.color.text) },
        nil,
        ui.text{ font = ui.font.small, align = "right",
                 markup = ui.span(string.format("%d window%s", #clients,
                     #clients == 1 and "" or "s"), ui.color.text_dim) },
        layout = wibox.layout.align.horizontal,
    }

    local body = {
        layout = wibox.layout.fixed.vertical,
        spacing = 6,
        head,
        ui.divider(),
    }
    for _, r in ipairs(rows) do body[#body + 1] = r end
    body[#body + 1] = ui.text{
        font = ui.font.tiny,
        markup = ui.span("Click to switch · right-click for actions",
                         ui.color.text_faint),
    }

    return {
        content = wibox.widget(body),
        width = 250,
        geometry = nil, -- the pill under the pointer
    }
end

-------------------------------------------------------------------------- actions

local function action_row(label, active, enabled, onclick)
    local chip = ui.chip{
        label = label, active = active, enabled = enabled,
        align = "left", width = 214, height = 26, flat = false,
        font = ui.font.body,
        onclick = onclick,
    }
    return wibox.widget{
        chip,
        left = 0, right = 0, widget = wibox.container.margin,
    }
end

local function build_actions(t)
    if not t or not t.valid then return nil end
    local n = #real_clients(t)
    local focus = client.focus
    local can_send = focus ~= nil and focus.valid and focus.screen == t.screen

    local function done(fn)
        return function()
            fn()
            popover.close("action")
        end
    end

    local content = {
        layout = wibox.layout.fixed.vertical,
        spacing = 4,
        wibox.widget{
            { ui.text{ font = ui.font.strong,
                       markup = ui.span("Workspace " .. (t.name or ""), ui.color.text) },
              left = 4, widget = wibox.container.margin },
            nil,
            ui.text{ font = ui.font.tiny, align = "right",
                     markup = ui.span(string.format("%d window%s", n,
                         n == 1 and "" or "s"), ui.color.text_faint) },
            layout = wibox.layout.align.horizontal,
        },
        ui.divider(),
        action_row("View this workspace", t.selected, true,
            done(function() t:view_only() end)),
        action_row("Send focused window here", false, can_send,
            done(function()
                local c = client.focus
                if c and c.valid then c:move_to_tag(t) end
            end)),
        action_row("Toggle in view", t.selected, true,
            done(function() awful.tag.viewtoggle(t) end)),
        action_row("Next layout", false, true,
            done(function() awful.layout.inc(1, t) end)),
    }

    return {
        content = wibox.widget(content),
        width = 240,
        modal = true,
    }
end

-------------------------------------------------------------------------- pill template

local function paint_pill(root, tag, label, tick)
    local selected = tag.selected
    local occupied = #real_clients(tag) > 0
    local urgent = tag.urgent

    if dotws.is_dot(tag) then
        -- The dot: a small elegant circle in a wallpaper-derived accent,
        -- dimmed at rest, full accent with a restrained glow ring when
        -- selected.  No label, no decoration competing with the wallpaper.
        local base = dotws.accent_color
        local fg = urgent and ui.color.warn
            or (selected and base or dotws.mix(base, ui.color.text_dim, 0.55))
        ui.set_markup(label, string.format(
            '<span font="FontAwesome 7" foreground="%s">%s</span>', fg, FA_CIRCLE))
        root.bg = selected and (base .. "2e")
            or (occupied and ui.color.occupied or ui.color.transparent)
        root.border_width = selected and 1 or 0
        root.border_color = base .. "55"
        tick.visible = occupied
        tick.bg = urgent and ui.color.warn or base
        return
    end

    local fg
    if urgent then fg = ui.color.warn
    elseif selected then fg = ui.color.accent_hi
    elseif occupied then fg = ui.color.text
    else fg = ui.color.text_faint end

    ui.set_markup(label, ui.span(ui.truncate(tag.name or "?", 2), fg,
        selected and ui.font.mark or ui.font.small))

    root.bg = selected and ui.color.accent_bg
        or (occupied and ui.color.occupied or ui.color.transparent)
    root.border_width = 0
    tick.visible = occupied or selected
    tick.bg = urgent and ui.color.warn
        or (selected and ui.color.accent or "#ffffff40")
end

-- Every rendered pill, kept so the dot's wallpaper-derived accent can be
-- repainted when the wallpaper changes.
local pills = {}

local function repaint_pills()
    for i = #pills, 1, -1 do
        local p = pills[i]
        if not p.tag.valid then
            table.remove(pills, i)
        else
            paint_pill(p.root, p.tag, p.label, p.tick)
        end
    end
end

dotws.subscribe(repaint_pills)

local function tag_template(buttons)
    return {
        {
            {
                {
                    id = "label",
                    widget = wibox.widget.textbox,
                    align = "center", valign = "center",
                },
                layout = wibox.container.place,
                halign = "center", valign = "center",
            },
            {
                {
                    id = "tick",
                    bg = ui.color.accent,
                    shape = ui.radius_shape.pill,
                    forced_width = 9,
                    forced_height = 2,
                    widget = wibox.container.background,
                },
                layout = wibox.container.place,
                halign = "center", valign = "bottom",
            },
            layout = wibox.layout.stack,
        },
        id = "pill",
        bg = ui.color.transparent,
        shape = ui.radius_shape.pill,
        forced_width = PILL_W,
        forced_height = PILL_H,
        widget = wibox.container.background,
        buttons = buttons,
        create_callback = function(self, tag, index, objects) -- luacheck: ignore
            local label = self:get_children_by_id("label")[1]
            local tick = self:get_children_by_id("tick")[1]
            paint_pill(self, tag, label, tick)
            pills[#pills + 1] = { root = self, tag = tag, label = label, tick = tick }

            -- Resting background is a function so hover does not destroy the
            -- selected/occupied styling.
            ui.hover(self, function()
                local occupied = #real_clients(tag) > 0
                if tag.selected then return ui.color.accent_bg end
                return occupied and ui.color.occupied or ui.color.transparent
            end, function()
                return tag.selected and ui.color.accent_bg_hi or ui.color.hover
            end)

            popover.hover(self, "ws-preview", function()
                return build_preview(tag)
            end)
        end,
        update_callback = function(self, tag, index, objects) -- luacheck: ignore
            paint_pill(self, tag,
                self:get_children_by_id("label")[1],
                self:get_children_by_id("tick")[1])
        end,
    }
end

-------------------------------------------------------------------------- public

--- Workspace indicator for a screen.  Returns the taglist widget.
function M.widget(s)
    local buttons = gears.table.join(
        awful.button({}, 1, function(t) t:view_only() end),
        awful.button({ "Mod4" }, 1, function(t)
            if client.focus and client.focus.valid then
                client.focus:move_to_tag(t)
            end
        end),
        awful.button({ "Mod4" }, 3, function(t)
            if client.focus and client.focus.valid then
                client.focus:toggle_tag(t)
            end
        end),
        awful.button({}, 3, function(t)
            local spec = build_actions(t)
            if spec then
                spec.id = "ws-actions"
                popover.show(spec)
            end
        end),
        awful.button({}, 4, function() awful.tag.viewnext(s) end),
        awful.button({}, 5, function() awful.tag.viewprev(s) end)
    )

    local taglist = awful.widget.taglist{
        screen  = s,
        filter  = awful.widget.taglist.filter.all,
        buttons = buttons,
        layout  = wibox.layout.fixed.horizontal,
        widget_template = tag_template(buttons),
        style   = { spacing = 2 },
    }
    taglist.forced_height = PILL_H
    return taglist
end

--- The focused window's workspace label, used by the window block.
function M.label_for_client(c)
    if not c or not c.valid or not c.first_tag then return nil end
    return c.first_tag.name or tostring(c.first_tag.index)
end

--- Compact workspace grid for the expanded panel: 3 columns x 3 rows.
-- Each cell is [number][occupancy]; click switches, right click opens the
-- same action surface as the bar's pills.
function M.panel_rows(s, on_switch)
    local cells = {}
    for _, t in ipairs(s.tags) do
        local n = #t:clients()
        local chip = ui.chip{
            label = t.name or "?",
            width = 26, height = 22,
            active = t.selected,
        }
        chip:buttons(gears.table.join(
            awful.button({}, 1, function()
                if on_switch then on_switch(t) else t:view_only() end
            end),
            awful.button({}, 3, function()
                local spec = build_actions(t)
                if spec then spec.id = "ws-actions" popover.show(spec) end
            end)))
        local meta = ui.text{ font = ui.font.tiny, width = 76 }
        ui.set_markup(meta, ui.span(n == 0 and "empty" or (n .. (n == 1 and " window" or " windows")),
            n == 0 and ui.color.text_faint or ui.color.text_dim))
        cells[#cells + 1] = wibox.widget{
            { chip, right = 8, widget = wibox.container.margin },
            meta,
            layout = wibox.layout.fixed.horizontal,
            forced_width = 120,
            forced_height = 24,
        }
    end

    local rows = wibox.layout.fixed.vertical()
    rows.spacing = 2
    for i = 1, #cells, 3 do
        local row = wibox.layout.fixed.horizontal()
        row.spacing = 6
        for j = i, math.min(i + 2, #cells) do row:add(cells[j]) end
        rows:add(row)
    end
    return rows
end

return M
