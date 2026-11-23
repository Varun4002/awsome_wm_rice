--------------------------------------------------------------------------
-- ui.lua — AETHER design tokens and shared widget primitives
--
-- One visual language for every layer of the bar.  Nothing in here owns
-- state or talks to the WM: it only builds styled widgets and markup so the
-- ambient bar, the contextual popovers, the control surface and the
-- expanded panel cannot drift apart.
--
-- Obsidian Glass: deep graphite surfaces, a restrained cyan accent, silver
-- text hierarchy, 12 px corners on surfaces and 7 px on controls.  Pango
-- markup is always escaped through M.esc / M.span; client titles are never
-- interpolated raw.
--------------------------------------------------------------------------

local wibox = require("wibox")
local gears = require("gears")
local awful = require("awful")

local M = {}

M.bar_height = 38
-- Every bar cluster is fitted to this height and centred in the 38 px bar, so
-- all clusters share one vertical centre regardless of their own block height
-- (continuity K1).  Any height that is not a multiple of 4 is off the grid
-- (layout-grid G5).
M.bar_row_h = 24

M.color = {
    text         = "#e9edf3",
    text_dim     = "#98a0ad",
    text_faint   = "#7c8490", -- 5.1:1 on graphite; #6c7480 failed WCAG AA
    text_strong  = "#ffffff",
    accent       = "#7cc4ee",
    accent_hi    = "#aadfff",
    accent_bg    = "#7cc4ee26",
    accent_bg_hi = "#7cc4ee40",
    danger       = "#f07878",
    danger_bg    = "#f0787826",
    danger_hover = "#f0787838",
    warn         = "#e6b465",
    ok           = "#79d6a4",
    bg_popup     = "#0d0f13ef",
    bg_sunken    = "#0000004d",
    border       = "#ffffff1f",
    hover        = "#ffffff0f",
    active       = "#ffffff1a",
    track        = "#ffffff2b", -- ~17% white: dark-surface tracks must read
    -- Roles that only had literal spellings before: occupied row/pill bg,
    -- idle status dot, card surface, the panel window dot.
    occupied     = "#ffffff0d",
    idle_dot     = "#ffffff26",
    card_bg      = "#ffffff08",
    transparent  = "#00000000",
    -- Surfaces that only had literal spellings in modules: the bar's own base
    -- colour (frost fallback / tray background), the window chrome, and the
    -- unoccupied-but-selected pill tick.
    bg_bar       = "#0e0e10",
    border_soft  = "#ffffff40",
}

-- Type ladder: four steps, 1.25/1.2/1.67 apart.  Hierarchy comes from weight
-- and colour; the 1 px neighbours this replaces (9/11/13) were invisible at
-- 96 dpi and made the bar look hand-placed (bar-aesthetic Q4, design-qa C7).
M.font = {
    tiny    = "Inter Medium 8",
    small   = "Inter Medium 10",   -- was 9
    body    = "Inter Medium 10",
    strong  = "Inter SemiBold 10",
    mark    = "Inter SemiBold 10", -- was 9
    title   = "Inter SemiBold 12",
    clock   = "Inter SemiBold 12", -- was 11
    display = "Inter SemiBold 20",
}

-- Glyph scale: three sizes, each a token.  The old 9 / 12 / 13 / 17 are gone
-- (bar-aesthetic Q4).
M.glyph = { s = 8, m = 10, l = 16 }
-- The same three sizes as Pango font strings, for markup call sites
-- (`<span font="...">`), so no module spells its own size again.
M.glyph_font = {
    s = "FontAwesome " .. M.glyph.s,
    m = "FontAwesome " .. M.glyph.m,
    l = "FontAwesome " .. M.glyph.l,
}

M.radius = { popup = 12, card = 10, chip = 7, pill = 7 }

-- Spacing scale (layout-grid §3.1): 4 px base unit, 2 px only for hairline
-- optical offsets (a tick, a rule's padding).  `M.gap` was defined and never
-- read; every new spacing must come from here.
M.space = { xxs = 2, xs = 4, s = 8, m = 12, l = 16, xl = 24, xxl = 32 }

-- Drop-in shape functions bound to the radius tokens: `widget.shape =
-- ui.radius_shape.chip` instead of a bare rounded_rect, which silently
-- falls back to gears' default radius 10 and made M.radius dead.
M.radius_shape = {}
for rname, rval in pairs(M.radius) do
    M.radius_shape[rname] = function(cr, w, h)
        gears.shape.rounded_rect(cr, w, h, rval)
    end
end

M.block_h = 24 -- height of a bar block (clock, window, ...) inside the 38 px bar

local FA = "FontAwesome "

-------------------------------------------------------------------------- text

function M.esc(s)
    return (tostring(s or ""):gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"))
end

-- Markup span with both attributes optional.  Text is always escaped.
function M.span(text, fg, font)
    local attrs = {}
    if fg then attrs[#attrs + 1] = 'foreground="' .. fg .. '"' end
    if font then attrs[#attrs + 1] = 'font="' .. font .. '"' end
    if #attrs == 0 then return M.esc(text) end
    return string.format("<span %s>%s</span>", table.concat(attrs, " "), M.esc(text))
end

-- A textbox that only relayouts when the string actually changes.
local function set_markup(tb, markup)
    if tb._private.aether_markup == markup then return end
    tb._private.aether_markup = markup
    tb:set_markup_silently(markup)
end
M.set_markup = set_markup

function M.text(opts)
    opts = opts or {}
    local tb = wibox.widget.textbox()
    tb.font = opts.font or M.font.body
    if opts.ellipsize then tb.ellipsize = opts.ellipsize end
    if opts.wrap then tb.wrap = opts.wrap end
    tb.align = opts.align or "left"
    tb.valign = opts.valign or "center"
    if opts.width then tb.forced_width = opts.width end
    if opts.markup then set_markup(tb, opts.markup) end
    return tb
end

-- Set plain text with a fixed colour/font, escaped.
function M.set_text(tb, text, fg, font)
    set_markup(tb, M.span(text, fg or M.color.text, font or tb.font))
end

function M.icon(glyph, size, fg)
    local tb = wibox.widget.textbox()
    -- awesome 4.3 textboxes default to ellipsize="end": a glyph wider than its
    -- cell is silently replaced by "…" (a 16 px sliders glyph in a 16 px cell
    -- rendered as three dots).  An icon is never ellipsized — clip instead.
    tb.ellipsize = "none"
    tb.font = FA .. (size or M.glyph.m)
    tb.valign = "center"
    tb.align = "center"
    set_markup(tb, string.format('<span foreground="%s">%s</span>',
        fg or M.color.text_dim, glyph))
    return tb
end

function M.set_icon(tb, glyph, size, fg)
    tb.ellipsize = "none"
    tb.font = FA .. (size or M.glyph.m)
    set_markup(tb, string.format('<span foreground="%s">%s</span>',
        fg or M.color.text_dim, glyph))
end

function M.truncate(s, max)
    s = tostring(s or "")
    if utf8.len(s) and utf8.len(s) <= max then return s end
    local ok, off = pcall(utf8.offset, s, max)
    if ok and off then return s:sub(1, off - 1) .. "…" end
    return s:sub(1, max) .. "…"
end

function M.first_letter(s)
    local ok, cp = pcall(utf8.codepoint, s or "", 1)
    if not ok or not cp then return "?" end
    return utf8.char(cp):upper()
end

--- Attach one button table to a widget and every widget under it.
-- A click is dispatched to the leaf widget under the pointer, so handlers put
-- only on a container are dead as soon as a child (icon, label, placed cell)
-- covers it — the showcase control silently did nothing for exactly that
-- reason.  Use this for any container whose area is filled by children.
function M.buttons_deep(widget, buttons)
    local base = require("wibox.widget.base")
    local function walk(w)
        if not w then return end
        if w.buttons then pcall(w.buttons, w, buttons) end
        local ok, kids = pcall(base.get_children, w)
        if ok and kids then
            for _, child in ipairs(kids) do walk(child) end
        end
    end
    walk(widget)
    return widget
end

--- Vertically centred cell for a composite widget (icon stacks, chips).
-- A child declared as `{ widget = <instance> }` gets its children cleared by
-- the declarative parser (base.lua drill: set_children({})), so composite
-- widgets must be wrapped in a fresh container instead.
function M.cell(widget)
    return wibox.widget{ widget, widget = wibox.container.place, valign = "center" }
end

-------------------------------------------------------------------------- shapes

function M.dot(fg, size, opts)
    opts = opts or {}
    local dot = wibox.container.background()
    dot.shape = opts.shape or gears.shape.circle
    dot.bg = fg or M.color.accent
    dot.forced_width = size or 6
    dot.forced_height = opts.height or size or 6
    dot.widget = wibox.widget.textbox()
    return dot
end

function M.spacer(w, h)
    local s = wibox.widget.separator{ orientation = "vertical" }
    s.forced_width = w or 1
    s.forced_height = h or 1
    s.color = M.color.transparent
    return s
end

function M.vrule(h)
    return wibox.widget{
        orientation = "vertical",
        color = M.color.border,
        forced_width = 1,
        forced_height = h or 14,
        widget = wibox.widget.separator,
    }
end

function M.pad(w, l, r, t, b)
    return wibox.container.margin(w, l or 0, r or 0, t or 0, b or 0)
end

function M.center(w)
    return wibox.widget{ widget = w, halign = "center", valign = "center",
                         layout = wibox.container.place }
end

function M.hbox(children, spacing)
    children.layout = wibox.layout.fixed.horizontal
    children.spacing = spacing or 0
    return wibox.widget(children)
end

function M.vbox(children, spacing)
    children.layout = wibox.layout.fixed.vertical
    children.spacing = spacing or 0
    return wibox.widget(children)
end

-------------------------------------------------------------------------- hover

-- Attach hover feedback to a widget.  `base` and `hover` may be functions:
-- an "active" chip keeps its accent while the pointer is over it.
local function resolve(v)
    if type(v) == "function" then return v() end
    return v
end

function M.hover(widget, base, hover, on_enter, on_leave)
    widget:connect_signal("mouse::enter", function()
        if widget._aether_no_hover then return end
        widget.bg = resolve(hover) or M.color.hover
        if on_enter then on_enter() end
    end)
    widget:connect_signal("mouse::leave", function()
        widget.bg = resolve(base)
        if on_leave then on_leave() end
    end)
    return widget
end

-------------------------------------------------------------------------- chips

--- A compact control: glyph + label on a rounded surface.
-- args: glyph, label, size (glyph), font, active, danger, enabled, width,
--       align, onclick, tooltip_text (unused; AETHER has no tooltip framework)
-- Returns { widget = <container.background>, set = function(fields) end }.
function M.chip(args)
    local glyph = M.icon(args.glyph or "", args.size or 10, args.fg)
    glyph.visible = args.glyph ~= nil
    local label = M.text{ font = args.font or M.font.small, ellipsize = "end" }
    local state = { active = false, enabled = true, danger = false }

    local glyph_slot = { glyph, left = 0, right = 6, widget = wibox.container.margin }
    glyph_slot.visible = args.glyph ~= nil
    local body = M.hbox({ glyph_slot, label }, 0)

    local root = wibox.container.background()
    root.shape = M.radius_shape.chip
    local place = wibox.container.place(M.pad(body, args.pad_l or 9, args.pad_r or 9, 0, 0))
    place.halign = args.align or "center"
    place.valign = "center"
    root.widget = place
    root.forced_height = args.height or 24
    if args.width then root.forced_width = args.width end

    local function base_bg()
        if not state.enabled then return M.color.transparent end
        if state.danger and state.active then return M.color.danger_bg end
        if state.active then return M.color.accent_bg end
        return args.flat and M.color.transparent or M.color.hover
    end
    local function hover_bg()
        if not state.enabled then return M.color.transparent end
        if state.danger then return M.color.danger_hover end
        if state.active then return M.color.accent_bg_hi end
        return M.color.hover
    end

    local function paint()
        root.bg = base_bg()
        local fg = M.color.text_dim
        if not state.enabled then fg = M.color.text_faint
        elseif state.danger then fg = M.color.danger
        elseif state.active then fg = M.color.accent_hi end
        set_markup(label, M.span(label._aether_plain or "", fg, label.font))
        if args.glyph then
            M.set_icon(glyph, args.glyph, args.size or 10, fg)
        end
        root.opacity = state.enabled and 1 or 0.55
    end

    function root:set_state(t)
        for k, v in pairs(t) do state[k] = v end
        paint()
    end
    function root:set_label(s)
        label._aether_plain = s or ""
        label.visible = label._aether_plain ~= ""
        paint()
    end
    function root:set_glyph(g)
        M.set_icon(glyph, g or "", args.size or 10,
            state.danger and M.color.danger or (state.active and M.color.accent_hi or M.color.text_dim))
        glyph.visible = g ~= nil
        glyph_slot.visible = g ~= nil
    end
    root._aether_plain = args.label or ""
    label._aether_plain = args.label or ""
    label.visible = (args.label or "") ~= ""
    paint()

    M.hover(root, base_bg, hover_bg)

    -- Pressed state (design-qa S3): the button signals "registered" before the
    -- action runs, using the same active tint the rest of the system uses.
    root:connect_signal("button::press", function()
        if state.enabled then root.bg = M.color.active end
    end)
    root:connect_signal("button::release", function()
        root.bg = base_bg()
    end)

    if args.onclick then
        root:buttons(gears.table.join(awful.button({}, 1, function()
            if state.enabled then args.onclick(root) end
        end)))
    end
    return root
end

-------------------------------------------------------------------------- icons

local APP_NAMES = {
    ["brave-browser"] = "Brave",
    Brave = "Brave",
    firefox = "Firefox",
    Chromium = "Chromium",
    ["google-chrome"] = "Chrome",
    kitty = "Kitty",
    Alacritty = "Alacritty",
    org = "Nautilus",
    ["org.gnome.nautilus"] = "Files",
    code = "VS Code",
    ["code-oss"] = "VS Code",
    Spotify = "Spotify",
    mpv = "mpv",
    vlc = "VLC",
    Gimp = "GIMP",
    Inkscape = "Inkscape",
    TelegramDesktop = "Telegram",
    ["discord"] = "Discord",
    Slack = "Slack",
    starlight = "Starlight",
    launchpad = "Launchpad",
}

function M.app_name(c)
    local class = c and (c.class or c.instance) or ""
    if class == "" then return "Application" end
    local mapped = APP_NAMES[class] or APP_NAMES[class:lower()]
    if mapped then return mapped end
    local s = class:gsub("%.desktop$", "")
    s = s:gsub("^org%.gnome%.", "")
    s = s:gsub("^org%.", "")
    s = s:gsub("[-_]", " ")
    s = s:gsub("(%a)([%w']*)", function(a, b) return a:upper() .. b end)
    return s
end

--- Application icon with a typographic fallback (rounded chip + initial).
-- The fallback keeps the bar stable when a client publishes no _NET_WM_ICON.
function M.app_icon(c, size)
    local slot = M.icon_slot(size)
    slot.set(c)
    return slot.widget
end

--- Updatable application icon: slot.set(client) swaps between the real
-- _NET_WM_ICON and the initial-chip fallback without relayout jitter.
function M.icon_slot(size)
    size = size or 16
    local chip = wibox.container.background()
    chip.shape = M.radius_shape.chip
    chip.bg = M.color.accent_bg
    chip.forced_width = size
    chip.forced_height = size
    local letter = M.text{ font = "Inter SemiBold " .. math.max(8, math.floor(size * 0.55)),
                           align = "center" }
    chip.widget = M.center(letter)

    local img = wibox.widget.imagebox()
    img.forced_width = size
    img.forced_height = size
    img.resize = true
    img.visible = false

    local widget = wibox.widget{
        chip, img,
        layout = wibox.layout.stack,
        forced_width = size, forced_height = size,
    }

    local function set(c)
        local surface = (c and c.valid) and c.icon or nil
        img:set_image(surface)
        img.visible = surface ~= nil
        chip.visible = surface == nil
        if surface == nil then
            set_markup(letter, M.span(M.first_letter(M.app_name(c)), M.color.accent_hi))
        end
    end

    return { widget = widget, set = set }
end

-------------------------------------------------------------------------- surfaces

-- Internal padding of a popover body.  The popup itself draws bg/border.
-- Surface padding: one pair of constants for every layer, symmetric top/bottom
-- (was 14/14 horizontal and 12/13 vertical — off-scale and asymmetric, grid G2).
M.surface_pad_h = 16
M.surface_pad_v = 12

function M.surface(content, width)
    local box = M.pad(content, M.surface_pad_h, M.surface_pad_h,
                              M.surface_pad_v, M.surface_pad_v)
    if width then box.forced_width = width end
    return box
end

function M.section(title, opts)
    opts = opts or {}
    local tb = M.text{ font = M.font.tiny }
    set_markup(tb, M.span(title:upper(), M.color.text_faint, M.font.tiny))
    -- No inset: the heading sits on the same leading axis as the rows below
    -- it, so the eye follows one line down a surface (continuity K3).
    local row = wibox.widget{
        { tb, widget = wibox.container.margin },
        layout = wibox.layout.align.horizontal,
    }
    if opts.spacing_before then
        return wibox.widget{
            M.spacer(1, opts.spacing_before), row,
            layout = wibox.layout.fixed.vertical,
        }
    end
    return row
end

function M.key_value(key, value, opts)
    opts = opts or {}
    local k = M.text{ font = M.font.small, ellipsize = "end" }
    set_markup(k, M.span(key, M.color.text_faint, M.font.small))
    local v = M.text{ font = opts.font or M.font.small, ellipsize = "end",
                      align = "right" }
    set_markup(v, M.span(value or "—", opts.fg or M.color.text_dim,
                        opts.font or M.font.small))
    local row = wibox.widget{
        { k, forced_width = opts.key_width or 70, widget = wibox.container.margin },
        nil,
        v,
        layout = wibox.layout.align.horizontal,
    }
    row.forced_height = opts.height or 20
    return row
end

function M.divider()
    return wibox.widget{
        orientation = "horizontal",
        color = M.color.border,
        forced_height = 1,
        widget = wibox.widget.separator,
    }
end

-------------------------------------------------------------------------- layout glyph

--- Token-coloured layout indicator (replaces the stock layoutbox PNGs,
--- whose white window art dominated the bar: .skills_upgrades U1).
-- Paints a 16x12 diagram: container cells stroked in text_dim, the master
-- region in accent, max.fullscreen filled with accent_bg.
function M.layout_indicator(scr)
    local base = require("wibox.widget.base")
    local w = base.make_widget(nil, "aether_layout_indicator")

    function w:fit(_, width, height)
        return math.min(16, width), math.min(12, height)
    end

    function w:draw(_, cr, width, height)
        local name = awful.layout.getname(awful.layout.get(scr)) or ""
        local m = 1.5
        local x0, y0 = m, m
        local iw, ih = width - 2 * m, height - 2 * m
        local cell = gears.color(M.color.text_dim)
        local accent = gears.color(M.color.accent)
        local accent_bg = gears.color(M.color.accent_bg)
        cr:set_line_width(1)

        local function stroke(x, y, ww, hh)
            cr:rectangle(x, y, ww, hh)
            cr:stroke()
        end
        local function fill_accent(x, y, ww, hh)
            cr:set_source(accent_bg)
            cr:rectangle(x, y, ww, hh)
            cr:fill()
            cr:set_source(accent)
            cr:rectangle(x, y, ww, hh)
            cr:stroke()
        end

        cr:set_source(cell)
        if name == "floating" then
            stroke(x0, y0 + ih * 0.35, iw * 0.5, ih * 0.55)
            stroke(x0 + iw * 0.42, y0, iw * 0.58, ih * 0.6)
        elseif name == "tile" then
            fill_accent(x0, y0, iw / 3, ih)
            stroke(x0 + iw / 3, y0, iw * 2 / 3, ih / 2 - 0.5)
            stroke(x0 + iw / 3, y0 + ih / 2 + 0.5, iw * 2 / 3, ih / 2 - 0.5)
        elseif name == "tile.left" then
            fill_accent(x0 + iw * 2 / 3, y0, iw / 3, ih)
            stroke(x0, y0, iw * 2 / 3, ih / 2 - 0.5)
            stroke(x0, y0 + ih / 2 + 0.5, iw * 2 / 3, ih / 2 - 0.5)
        elseif name == "tile.bottom" then
            fill_accent(x0, y0, iw, ih / 2)
            stroke(x0, y0 + ih / 2 + 0.5, iw / 2 - 0.5, ih / 2 - 0.5)
            stroke(x0 + iw / 2 + 0.5, y0 + ih / 2 + 0.5, iw / 2 - 0.5, ih / 2 - 0.5)
        elseif name == "tile.top" then
            fill_accent(x0, y0 + ih / 2, iw, ih / 2)
            stroke(x0, y0, iw / 2 - 0.5, ih / 2 - 0.5)
            stroke(x0 + iw / 2 + 0.5, y0, iw / 2 - 0.5, ih / 2 - 0.5)
        elseif name == "fair" or name == "spiral" or name == "dwindle" then
            fill_accent(x0, y0, iw / 2 - 0.5, ih)
            stroke(x0 + iw / 2 + 0.5, y0, iw / 2 - 0.5, ih / 2 - 0.5)
            stroke(x0 + iw / 2 + 0.5, y0 + ih / 2 + 0.5, iw / 2 - 0.5, ih / 2 - 0.5)
        elseif name == "fair.horizontal" then
            fill_accent(x0, y0, iw, ih / 2 - 0.5)
            stroke(x0, y0 + ih / 2 + 0.5, iw / 2 - 0.5, ih / 2 - 0.5)
            stroke(x0 + iw / 2 + 0.5, y0 + ih / 2 + 0.5, iw / 2 - 0.5, ih / 2 - 0.5)
        elseif name == "max" then
            fill_accent(x0, y0, iw, ih)
        elseif name == "max.fullscreen" then
            cr:set_source(accent_bg)
            cr:rectangle(x0, y0, iw, ih)
            cr:fill()
            cr:set_source(accent)
            cr:rectangle(x0, y0, iw, ih)
            cr:stroke()
        elseif name == "magnifier" then
            fill_accent(x0 + iw * 0.25, y0, iw * 0.5, ih)
            stroke(x0, y0 + ih * 0.3, iw * 0.2, ih * 0.4)
            stroke(x0 + iw * 0.8, y0 + ih * 0.3, iw * 0.2, ih * 0.4)
        elseif name == "corner.nw" then
            fill_accent(x0, y0, iw * 0.6, ih * 0.6)
            stroke(x0 + iw * 0.6 + 0.5, y0, iw * 0.4 - 0.5, ih * 0.4)
            stroke(x0, y0 + ih * 0.6 + 0.5, iw * 0.4, ih * 0.4)
        else
            stroke(x0, y0, iw, ih)
        end
    end

    -- Layout and selection changes arrive on tag objects; a 16x12 repaint
    -- is cheap enough to do from every instance rather than track screens.
    local function repaint() w:emit_signal("widget::redraw_needed") end
    tag.connect_signal("property::layout", repaint)
    tag.connect_signal("property::selected", repaint)
    return w
end

-------------------------------------------------------------------------- sliders

-- awesome 4.3's slider draws only a track and a handle — there is no value
-- fill at all, and a 4px track at 8% alpha was invisible on the popups, so
-- scrubbing gave no visible feedback.  This composite paints its own track
-- + accent fill underneath the stock slider (which keeps the pointer
-- machinery: click jumps, hold-drag scrubs) and delegates value access and
-- signals, so call sites read like a plain slider.
function M.slider(args)
    args = args or {}
    -- awesome 4.3's slider silently DROPS its constructor argument table
    -- (verified in .skills_upgrades/bar-aesthetic): every property must be
    -- assigned after construction or it renders as a bare slab.
    local inner = wibox.widget.slider()
    inner.minimum        = args.minimum or 0
    inner.maximum        = args.maximum or 100
    inner.value          = args.value or (args.minimum or 0)
    inner.bar_shape      = gears.shape.rounded_bar
    inner.bar_height     = 0 -- the underlay paints track + fill
    inner.handle_shape   = gears.shape.circle
    inner.handle_width   = 10
    inner.handle_margins = { left = 0, right = 0, top = 5, bottom = 5 }
    inner.handle_color   = args.handle_color or M.color.text
    local track_color = args.track or M.color.track
    local fill_color  = args.fill or M.color.accent
    local base = require("wibox.widget.base")
    local under = base.make_widget(nil, "aether_slider_underlay")
    function under:draw(_, cr, width, height)
        local bh = args.bar_height or 5
        local y = math.floor((height - bh) / 2)
        cr:translate(0, y)
        cr:set_source(gears.color(track_color))
        gears.shape.rounded_bar(cr, width, bh)
        cr:fill()
        local frac = (inner.value - inner.minimum) /
                     math.max(1, inner.maximum - inner.minimum)
        if frac > 0 then
            local fw = math.max(bh, math.floor((width - 1) * frac + 0.5))
            cr:set_source(gears.color(fill_color))
            gears.shape.rounded_bar(cr, fw, bh)
            cr:fill()
        end
        cr:translate(0, -y)
    end
    inner:connect_signal("property::value", function()
        under:emit_signal("widget::redraw_needed")
    end)

    local stack = wibox.widget{ under, inner, layout = wibox.layout.stack }
    stack.forced_width  = args.width
    stack.forced_height = args.height or 20

    -- Delegation: value access and the signals call sites rely on.
    function stack:set_value(v) inner:set_value(v) end
    function stack:get_value() return inner.value end
    function stack:set_sensitive(v) inner.sensitive = v end
    inner:connect_signal("property::value", function()
        stack:emit_signal("property::value")
    end)
    -- button::press/release bubble up from the inner slider on their own.
    return stack
end

-------------------------------------------------------------------------- calendar

local WEEKDAYS = { "Mo", "Tu", "We", "Th", "Fr", "Sa", "Su" }

local function days_in_month(year, month)
    return os.date("*t", os.time{ year = year, month = month + 1, day = 0 }).day
end

--- Monday-first month grid.  `today` is highlighted with the accent.
function M.calendar(year, month, cell_width)
    year = year or tonumber(os.date("%Y"))
    month = month or tonumber(os.date("%m"))
    cell_width = cell_width or 30

    local cols = {}
    for i, name in ipairs(WEEKDAYS) do
        local tb = M.text{ font = M.font.tiny, align = "center" }
        set_markup(tb, M.span(name, M.color.text_faint, M.font.tiny))
        cols[i] = { tb, forced_width = cell_width, forced_height = 20,
                    widget = wibox.container.place }
    end
    local grid = { layout = wibox.layout.fixed.vertical, spacing = 2 }
    local head = { layout = wibox.layout.fixed.horizontal }
    for i = 1, #cols do head[i] = cols[i] end
    grid[1] = head

    local first = os.time{ year = year, month = month, day = 1 }
    local offset = (os.date("*t", first).wday + 5) % 7 -- Monday first
    local total = days_in_month(year, month)
    local today = tonumber(os.date("%d"))
    local same_month = tonumber(os.date("%m")) == month and tonumber(os.date("%Y")) == year

    local row = { layout = wibox.layout.fixed.horizontal }
    local col = offset
    for _ = 1, offset do
        row[#row + 1] = { M.spacer(1, 1), forced_width = cell_width,
                          forced_height = 24, widget = wibox.container.place }
    end
    for day = 1, total do
        local tb = M.text{ font = M.font.small, align = "center" }
        if same_month and day == today then
            set_markup(tb, M.span(tostring(day), M.color.accent_hi, M.font.mark))
            row[#row + 1] = {
                { tb, widget = wibox.container.place },
                bg = M.color.accent_bg, shape = M.radius_shape.chip,
                forced_width = cell_width, forced_height = 24,
                widget = wibox.container.background,
            }
        else
            set_markup(tb, M.span(tostring(day), M.color.text_dim, M.font.small))
            row[#row + 1] = { tb, forced_width = cell_width, forced_height = 24,
                              widget = wibox.container.place }
        end
        col = col + 1
        if col == 7 and day ~= total then
            col = 0
            grid[#grid + 1] = row
            row = { layout = wibox.layout.fixed.horizontal }
        end
    end
    if #row > 0 then grid[#grid + 1] = row end
    return wibox.widget(grid)
end

function M.month_title(year, month)
    return os.date("%B %Y", os.time{ year = year, month = month, day = 1 })
end

-------------------------------------------------------------------------- misc

function M.human(n)
    n = tonumber(n) or 0
    if n >= 1000000 then
        return (string.format("%.1f", n / 1000000):gsub("%.0$", "")) .. "M"
    elseif n >= 1000 then
        return string.format("%.0f", n / 1000) .. "K"
    end
    return tostring(n)
end

function M.rel_time(ms)
    local now = os.time() * 1000
    local d = math.max(0, now - (tonumber(ms) or now))
    local m = math.floor(d / 60000)
    if m < 1 then return "just now" end
    if m < 60 then return m .. "m ago" end
    local h = math.floor(m / 60)
    if h < 24 then return h .. "h ago" end
    local days = math.floor(h / 24)
    if days == 1 then return "yesterday" end
    return days .. "d ago"
end

--- 12-hour clock text ("9:41 AM").  Lua's os.date whitelist rejects %l,
-- so the meridiem math is done here instead of via strftime.
function M.time12(now)
    local t = os.date("*t", now or os.time())
    local h = t.hour % 12
    if h == 0 then h = 12 end
    return string.format("%d:%02d %s", h, t.min, t.hour < 12 and "AM" or "PM")
end

--- One composition policy for every bar width (layout-grid G7 / A2).
-- Beyond truncation, this is the only place that decides what a narrower bar
-- drops, so the 1920 panel and the 1680 monitor cannot drift apart.
function M.bar_budget(width)
    width = width or 1920
    if width >= 1800 then
        return { song = 26, project = true, project_chars = 14, date = true }
    elseif width >= 1600 then
        return { song = 18, project = false, project_chars = 0, date = true }
    end
    return { song = 0, project = false, project_chars = 0, date = false }
end

--- Home-relative path ("~/projects/aether").
function M.pretty_path(path)
    if not path or path == "" then return "—" end
    local home = os.getenv("HOME")
    if home and path:sub(1, #home) == home then
        local rest = path:sub(#home + 1)
        if rest == "" then return "~" end
        return "~" .. rest
    end
    return path
end

--- Last path component, used as the project label of a session directory.
function M.basename(path)
    if not path or path == "" then return "—" end
    local base = path:gsub("/+$", ""):match("([^/]+)$")
    if not base or base == "" then return "/" end
    if path == os.getenv("HOME") then return "~" end
    return base
end

return M
