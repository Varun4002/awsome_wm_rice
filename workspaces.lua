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

local FA_CIRCLE = "\u{f111}" -- occupancy dot in the other-screen chip
local FA_PICTURE = "\u{f03e}" -- the showcase (wallpaper) control

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
        ui.cell(ui.app_icon(c, 16)),
        { tb, left = 8, widget = wibox.container.margin },
        layout = wibox.layout.fixed.horizontal,
        forced_height = 20,
    }
end

local function build_preview(t)
    if not t or not t.valid then return nil end
    local is_dot = dotws.is_dot(t)
    local clients = real_clients(t)
    local rows = {}
    local shown = 0
    for _, c in ipairs(clients) do
        shown = shown + 1
        if shown <= 5 then rows[#rows + 1] = preview_row(c) end
    end
    if #rows == 0 then
        rows[1] = ui.text{ font = ui.font.small,
                           markup = ui.span(is_dot and "Just the wallpaper"
                                                or "No windows on this workspace",
                                            ui.color.text_faint) }
    elseif shown > #rows then
        rows[#rows + 1] = ui.text{
            font = ui.font.tiny,
            markup = ui.span(string.format("+%d more", shown - #rows),
                             ui.color.text_faint),
        }
    end

    -- The dot is a mode, not a workspace: its label names the mode, not a slot
    -- number (navigation §3.2 — "Workspace ." predicted nothing).
    local head = wibox.widget{
        ui.text{ font = ui.font.strong,
                 markup = ui.span(is_dot and "Showcase"
                                     or ("Workspace " .. (t.name or "")),
                                  ui.color.text) },
        nil,
        ui.text{ font = ui.font.small, align = "right",
                 markup = ui.span(is_dot and "wallpaper"
                                     or string.format("%d window%s", #clients,
                                          #clients == 1 and "" or "s"),
                                  ui.color.text_dim) },
        layout = wibox.layout.align.horizontal,
    }

    local body = {
        layout = wibox.layout.fixed.vertical,
        spacing = ui.space.s,
        head,
        ui.divider(),
    }
    for _, r in ipairs(rows) do body[#body + 1] = r end
    body[#body + 1] = ui.text{
        font = ui.font.tiny,
        markup = ui.span(is_dot and "Click to show the wallpaper · right-click for actions"
                         or "Click to switch · right-click for actions",
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
        align = "left", width = 214, height = 24, flat = false,
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
        spacing = ui.space.xs,
        wibox.widget{
            { ui.text{ font = ui.font.strong,
                       markup = ui.span(dotws.is_dot(t) and "Showcase"
                                            or ("Workspace " .. (t.name or "")),
                                        ui.color.text) },
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

--- Open the action surface for a tag.  Named so the popover back-stack can
-- rebuild it (navigation N8): a surface that is replaced by another modal
-- layer is reachable again with BackSpace.
local function open_actions(t)
    local spec = build_actions(t)
    if not spec then return end
    spec.id = "ws-actions"
    spec.reopen = function() open_actions(t) end
    popover.show(spec)
end

-------------------------------------------------------------------------- pill template

local function paint_pill(root, tag, label, tick)
    local selected = tag.selected
    local occupied = #real_clients(tag) > 0
    local urgent = tag.urgent

    local fg
    if urgent then fg = ui.color.warn
    elseif selected then fg = ui.color.accent_hi
    elseif occupied then fg = ui.color.text
    else fg = ui.color.text_dim end

    ui.set_markup(label, ui.span(ui.truncate(tag.name or "?", 2), fg,
        selected and ui.font.mark or ui.font.small))

    root.bg = selected and ui.color.accent_bg
        or (occupied and ui.color.occupied or ui.color.transparent)
    root.border_width = 0
    tick.visible = occupied or selected
    tick.bg = urgent and ui.color.warn
        or (selected and ui.color.accent or ui.color.border_soft)
end

-- Every rendered pill, kept so the dot's wallpaper-derived accent can be
-- repainted when the wallpaper changes.
local pills = {}
local showcases = {}

local function repaint_pills()
    for i = #pills, 1, -1 do
        local p = pills[i]
        if not p.tag.valid then
            table.remove(pills, i)
        else
            paint_pill(p.root, p.tag, p.label, p.tick)
        end
    end
    for i = #showcases, 1, -1 do
        local w = showcases[i]
        if not (w.screen and w.screen.valid) then
            table.remove(showcases, i)
        else
            w.paint()
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

--- Workspace indicator for a screen.  Returns one row: the dot showcase (a
--- mode, rendered as its own control) followed by the nine numbered pills.
--
-- The dot used to be a peer pill inside the taglist: unlabelled, competing in
-- the 1–9 numbering space, and its preview read "Workspace ." — a label that
-- predicted nothing, and a 10th top-level destination (navigation §3.2).
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
            open_actions(t)
        end),
        awful.button({}, 4, function() awful.tag.viewnext(s) end),
        awful.button({}, 5, function() awful.tag.viewprev(s) end)
    )

    local taglist = awful.widget.taglist{
        screen  = s,
        -- Numbered workspaces only; the dot is the showcase control below.
        filter  = function(t) return not dotws.is_dot(t) end,
        buttons = buttons,
        layout  = wibox.layout.fixed.horizontal,
        widget_template = tag_template(buttons),
        style   = { spacing = ui.space.xs },
    }
    taglist.forced_height = PILL_H

    local showcase = M.showcase(s)
    if not showcase then return taglist end
    return wibox.widget{
        showcase,
        { taglist, left = ui.space.s, widget = wibox.container.margin },
        layout = wibox.layout.fixed.horizontal,
    }
end

--- The dot showcase as a separate control (navigation §3.2).  Same wallpaper-
--- derived accent and the same click target as before, but labelled by its
--- preview and visually apart from the numbered strip.
function M.showcase(s)
    local dot = dotws.dot_tag(s)
    if not dot then return nil end
    local icon = ui.icon(FA_PICTURE, ui.glyph.m, ui.color.text_dim)
    local root = wibox.container.background()
    root.shape = ui.radius_shape.pill
    root.forced_width = PILL_W
    root.forced_height = PILL_H
    root.widget = wibox.container.place(icon)
    root.border_width = 0

    local entry = { screen = s, root = root, icon = icon }
    function entry.paint()
        local tag = dotws.dot_tag(s)
        if not tag then return end
        local base = dotws.accent_color
        local selected = tag.selected
        ui.set_icon(icon, FA_PICTURE, ui.glyph.m,
            selected and base or dotws.mix(base, ui.color.text_dim, 0.35))
        root.bg = selected and (base .. "2e")
            or (#real_clients(tag) > 0 and ui.color.occupied or ui.color.hover)
        root.border_width = selected and 1 or 0
        root.border_color = base .. "55"
    end
    entry.paint()
    showcases[#showcases + 1] = entry

    -- Its own buttons: the taglist's handlers receive a *tag* because the
    -- taglist passes one, so reusing them here called t:view_only() on the
    -- widget and the showcase silently did nothing.
    local function tag()
        local t = dotws.dot_tag(s)
        if t and t.valid then return t end
    end
    ui.buttons_deep(root, gears.table.join(
        awful.button({}, 1, function() local t = tag() if t then t:view_only() end end),
        awful.button({ "Mod4" }, 1, function()
            local t = tag()
            if t and client.focus and client.focus.valid then
                client.focus:move_to_tag(t)
            end
        end),
        awful.button({ "Mod4" }, 3, function()
            local t = tag()
            if t and client.focus and client.focus.valid then
                client.focus:toggle_tag(t)
            end
        end),
        awful.button({}, 3, function() local t = tag() if t then open_actions(t) end end),
        awful.button({}, 4, function() awful.tag.viewnext(s) end),
        awful.button({}, 5, function() awful.tag.viewprev(s) end)))
    popover.hover(root, "ws-preview", function() return build_preview(dot) end)
    return root
end

--- Where the other monitor is (navigation N6, flow T3/T9).  The bar showed
--- only the focused screen's workspace, so the other monitor's state was
--- invisible without moving focus there.  One chip: screen index, its
--- selected workspace, and an occupancy dot.  Returns nil with one screen.
local other_screen_chips = {}

local function paint_other_screen(e)
    local s = e.screen
    if not (s and s.valid) then
        e.root.visible = false
        return
    end
    local other
    for scr in screen do
        if scr ~= s and scr.valid then other = scr break end
    end
    if not other then
        e.root.visible = false
        return
    end
    local tag = other.selected_tag
    local n = 0
    if tag then
        for _, c in ipairs(tag:clients()) do
            if not (c.sticky or c.skip_taskbar) then n = n + 1 end
        end
    end
    local name = tag and (dotws.is_dot(tag) and "showcase" or (tag.name or "?")) or "—"
    e.root.visible = true
    ui.set_markup(e.text, string.format(
        '<span foreground="%s">S%d</span> <span foreground="%s">%s</span>'
            .. '<span foreground="%s"> %s</span>',
        ui.color.text_faint, other.index,
        n > 0 and ui.color.text_dim or ui.color.text_faint, ui.esc(name),
        n > 0 and ui.color.accent or ui.color.idle_dot,
        '<span font="' .. ui.glyph_font.s .. '">' .. FA_CIRCLE .. '</span>'))
end

local function paint_all_other_screens()
    for i = #other_screen_chips, 1, -1 do
        local e = other_screen_chips[i]
        if not (e.screen and e.screen.valid) then
            table.remove(other_screen_chips, i)
        else
            paint_other_screen(e)
        end
    end
end

function M.other_screen(s)
    local text = ui.text{ font = ui.font.small }
    local root = wibox.container.background()
    root.shape = ui.radius_shape.chip
    root.bg = ui.color.transparent
    root.forced_height = ui.block_h
    root.widget = wibox.container.place(
        ui.pad(text, ui.space.s, ui.space.s, 0, 0))

    local entry = { screen = s, root = root, text = text }
    other_screen_chips[#other_screen_chips + 1] = entry
    paint_other_screen(entry)

    ui.hover(root, function() return ui.color.transparent end, ui.color.hover)
    ui.buttons_deep(root, gears.table.join(awful.button({}, 1, function()
        for scr in screen do
            if scr ~= s and scr.valid then awful.screen.focus(scr) break end
        end
    end)))
    return root
end

client.connect_signal("manage", paint_all_other_screens)
client.connect_signal("unmanage", paint_all_other_screens)
client.connect_signal("tagged", paint_all_other_screens)
client.connect_signal("untagged", paint_all_other_screens)
tag.connect_signal("property::selected", paint_all_other_screens)
screen.connect_signal("added", paint_all_other_screens)
screen.connect_signal("removed", paint_all_other_screens)

--- The focused window's workspace label, used by the window block.
function M.label_for_client(c)
    if not c or not c.valid or not c.first_tag then return nil end
    return c.first_tag.name or tostring(c.first_tag.index)
end

--- Compact workspace grid for the expanded panel: 3 columns x 3 rows.
-- Each cell is [number][occupancy]; click switches, right click opens the
-- same action surface as the bar's pills.
-- Cells are computed from the available width, never hardcoded: three columns of
-- 120 px plus 6 px gutters needed 372 px inside a 368 px content box and clipped
-- the third cell (layout-grid G3/G4).  The dot gets its own full-width row — it is
-- a mode (wallpaper showcase), not a workspace, and as a peer cell it left the
-- numbered grid with an orphan row (`3,3,3,1`, continuity K2).
function M.panel_rows(s, on_switch, opts)
    opts = opts or {}
    local width  = opts.width or 368
    local gutter = opts.gutter or ui.space.s
    local cell_h = 24

    local function cell(t, w, meta_text)
        local chip = ui.chip{
            label = t.name or "?",
            width = 26, height = 24,
            active = t.selected,
        }
        chip:buttons(gears.table.join(
            awful.button({}, 1, function()
                if on_switch then on_switch(t) else t:view_only() end
            end),
            awful.button({}, 3, function()
                open_actions(t)
            end)))
        local meta = ui.text{ font = ui.font.tiny, width = math.max(40, w - 42) }
        ui.set_markup(meta, ui.span(meta_text, ui.color.text_faint))
        return wibox.widget{
            { chip, right = ui.space.s, widget = wibox.container.margin },
            meta,
            layout = wibox.layout.fixed.horizontal,
            forced_width = w,
            forced_height = cell_h,
        }
    end

    local function count_text(t)
        local n = 0
        for _, c in ipairs(t:clients()) do
            if not (c.sticky or c.skip_taskbar) then n = n + 1 end
        end
        if n == 0 then return "empty" end
        return n .. (n == 1 and " window" or " windows")
    end

    local rows = wibox.layout.fixed.vertical()
    rows.spacing = gutter

    -- Mode row: the dot, full width, labelled for what it is.
    local dot = dotws.dot_tag(s)
    if dot then rows:add(cell(dot, width, "wallpaper showcase")) end

    -- Numbered workspaces: three columns, exactly filling the content box.
    local numbered = {}
    for i = 1, 9 do
        local t = dotws.numbered(s, i)
        if t then numbered[#numbered + 1] = t end
    end
    local cell_w = math.max(96, math.floor((width - 2 * gutter) / 3))
    for i = 1, #numbered, 3 do
        local row = wibox.layout.fixed.horizontal()
        row.spacing = gutter
        for j = i, math.min(i + 2, #numbered) do
            row:add(cell(numbered[j], cell_w, count_text(numbered[j])))
        end
        rows:add(row)
    end
    return rows
end

return M
