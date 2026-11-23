--------------------------------------------------------------------------
-- opencode_ui.lua — OpenCode in every layer of the bar
--
-- Layer 1: a compact always-visible identity in the right cluster: status
--          dot, wordmark, current project while a session is active.
-- Layer 2: hovering reveals project, directory, session, agent, state and
--          pending interactions without occupying bar space.
-- Layer 3: clicking opens the OpenCode surface: session list with resume,
--          and the supported launch/terminal/copy actions.
-- Layer 4: panel_section() renders the same information for the expanded
--          intelligence panel.
--
-- All data comes from opencode.lua's published state; this module never
-- runs a command itself.  Nothing is shown that cannot be determined: an
-- unreachable service renders a neutral identity with an honest reason.
--------------------------------------------------------------------------

local awful = require("awful")
local gears = require("gears")
local wibox = require("wibox")

local ui      = require("ui")
local popover = require("popover")
local oc      = require("opencode")

local M = {}

local FA_TERMINAL = "\u{f120}"
local FA_FOLDER   = "\u{f07b}"
local FA_COPY     = "\u{f0c5}"
local FA_PLUS     = "\u{f067}"
local FA_PLAY     = "\u{f04b}"

local STATUS = {
    offline = { color = ui.color.text_faint, label = "not running" },
    idle    = { color = ui.color.text_dim,  label = "idle" },
    working = { color = ui.color.accent,    label = "working" },
    waiting = { color = ui.color.warn,      label = "waiting for you" },
    error   = { color = ui.color.danger,    label = "last task failed" },
}

local function status_of(st)
    return STATUS[st.status] or STATUS.offline
end

local function project_of(st)
    if st.current then return st.current.project end
end

local function dir_of(st)
    if st.current and st.current.dir ~= "" then return st.current.dir end
    return oc.current_dir()
end

local function pending_text(st)
    if st.pending.total <= 0 then return nil end
    local parts = {}
    if st.pending.permissions > 0 then
        parts[#parts + 1] = string.format("%d approval%s",
            st.pending.permissions, st.pending.permissions == 1 and "" or "s")
    end
    if st.pending.forms > 0 then
        parts[#parts + 1] = string.format("%d question%s",
            st.pending.forms, st.pending.forms == 1 and "" or "s")
    end
    return table.concat(parts, " · ")
end

-------------------------------------------------------------------------- rows

local function session_row(s, opts)
    opts = opts or {}
    local dot = ui.dot(s.working and ui.color.accent
        or (s.outcome == "failed" and ui.color.danger or ui.color.idle_dot), 5)
    local title = ui.text{ font = ui.font.small, ellipsize = "end",
                           width = opts.title_width or 210 }
    ui.set_text(title, s.title, s.working and ui.color.text or ui.color.text_dim)
    local meta = ui.text{ font = ui.font.tiny, align = "right", width = 92,
                          ellipsize = "end" }
    ui.set_text(meta, string.format("%s · %s", s.project, ui.rel_time(s.updated)),
        ui.color.text_faint)

    local row = wibox.container.background()
    row.shape = ui.radius_shape.card
    row.bg = ui.color.transparent
    row.forced_height = 24
    row.widget = ui.pad(wibox.widget{
        wibox.widget{
            { dot, left = 2, right = 8, widget = wibox.container.margin },
            title,
            layout = wibox.layout.fixed.horizontal,
        },
        nil,
        meta,
        layout = wibox.layout.align.horizontal,
    }, 4, 4, 0, 0)
    ui.hover(row, function() return ui.color.transparent end, ui.color.hover)
    if opts.on_pick then
        row:buttons(gears.table.join(awful.button({}, 1, function()
            opts.on_pick(s)
        end)))
    end
    return row
end

local function action_row(st)
    local dir = dir_of(st)
    local caps = oc.caps
    local top, bottom = {}, {}
    local any = false

    if caps.kitty and caps.opencode then
        top[#top + 1] = ui.chip{
            glyph = FA_PLAY, label = "Open OpenCode",
            onclick = function() oc.actions.focus_or_launch() end,
        }
        top[#top + 1] = ui.chip{
            glyph = FA_PLUS, label = "New session",
            onclick = function() oc.actions.new_session(dir) end,
        }
        any = true
    end
    if caps.kitty then
        bottom[#bottom + 1] = ui.chip{
            glyph = FA_TERMINAL, label = "Terminal",
            onclick = function() oc.actions.terminal(dir) end,
        }
        any = true
    end
    if caps.xclip then
        bottom[#bottom + 1] = ui.chip{
            glyph = FA_COPY, label = "Copy path",
            onclick = function() oc.actions.copy_path(dir) end,
        }
        any = true
    end
    if caps.xdg_open then
        bottom[#bottom + 1] = ui.chip{
            glyph = FA_FOLDER, label = "Project",
            onclick = function() oc.actions.open_project(dir) end,
        }
        any = true
    end

    if not any then
        return ui.text{ font = ui.font.tiny,
            markup = ui.span("Terminal integration unavailable (kitty not found)",
                             ui.color.text_faint) }
    end

    local box = wibox.layout.fixed.vertical()
    box.spacing = 4
    local function add_row(items)
        if #items == 0 then return end
        local row = { layout = wibox.layout.fixed.horizontal, spacing = 4 }
        for i, item in ipairs(items) do row[i] = item end
        box:add(wibox.widget(row))
    end
    add_row(top)
    add_row(bottom)
    return box
end

local function stats_line()
    local tb = ui.text{ font = ui.font.tiny }
    ui.set_text(tb, "", ui.color.text_faint)
    oc.stats(function(tokens, sessions)
        if tokens and tokens > 0 then
            ui.set_text(tb, string.format("Today  %s tokens · %d sessions",
                ui.human(tokens), sessions or 0), ui.color.text_faint, ui.font.tiny)
        else
            ui.set_text(tb, "Today  no usage recorded", ui.color.text_faint, ui.font.tiny)
        end
    end)
    return tb
end

-------------------------------------------------------------------------- usage limits

-- Human reset countdown + the reset moment on a 12-hour clock, matching
-- the bar clock ("in 2h 05m · 11:58 AM").
local function usage_reset_text(resets)
    if not resets then return "—" end
    local d = resets - os.time()
    if d <= 0 then return "resetting" end
    local mins = math.ceil(d / 60)
    local rel
    if mins < 60 then
        rel = mins .. "m"
    else
        local h = math.floor(mins / 60)
        if h < 24 then
            rel = string.format("%dh %02dm", h, mins % 60)
        else
            rel = string.format("%dd %dh", math.floor(h / 24), h % 24)
        end
    end
    local clock = ui.time12(resets)
    return string.format("in %s · %s", rel, clock)
end

local function usage_row(w, bar_width)
    local color = w.pct >= 95 and ui.color.danger
        or (w.pct >= 80 and ui.color.warn or ui.color.accent)
    local name = ui.text{ font = ui.font.small, ellipsize = "end", width = 62 }
    ui.set_text(name, w.name, ui.color.text_dim, ui.font.small)
    local bar = wibox.widget.progressbar()
    -- 4.3 progressbar drops constructor args: assign as properties.
    bar.max_value        = 100
    bar.value            = w.pct
    bar.color            = color
    bar.background_color = ui.color.track
    bar.shape            = gears.shape.rounded_rect
    bar.bar_shape        = gears.shape.rounded_rect
    bar.forced_width  = bar_width
    bar.forced_height = 5
    local pct = ui.text{ font = ui.font.body, align = "right", width = 40 }
    ui.set_text(pct, string.format("%d%%", math.floor(w.pct + 0.5)),
        w.pct >= 95 and ui.color.danger or ui.color.text, ui.font.body)
    local reset = ui.text{ font = ui.font.tiny, align = "right",
                           ellipsize = "end", width = 100 }
    ui.set_text(reset, usage_reset_text(w.resets), ui.color.text_faint, ui.font.tiny)
    local row = wibox.widget{
        name,
        { bar, layout = wibox.container.place, valign = "center" },
        pct,
        reset,
        spacing = 8,
        layout = wibox.layout.fixed.horizontal,
    }
    row.forced_height = 20
    return row
end

-- One row per rate-limit window (5-hour, weekly, monthly). `width` is the
-- row's usable width; the fill bar gets whatever the fixed columns leave.
local function usage_rows(width)
    local body = wibox.layout.fixed.vertical()
    body.spacing = 3
    local u = oc.usage
    if not u.ok then
        body:add(ui.text{ font = ui.font.tiny, wrap = "word", width = width,
            markup = ui.span("Usage unavailable — " .. (u.reason or "not fetched yet"),
                             ui.color.text_faint) })
        return body
    end
    local bar_width = math.max(40, width - 62 - 40 - 100 - 3 * 8)
    for _, w in ipairs(u.windows) do
        body:add(usage_row(w, bar_width))
    end
    return body
end

-- Kick a TTL-gated fetch so cards opened a while ago show fresh numbers.
local function refresh_usage()
    oc.refresh_usage()
end

-------------------------------------------------------------------------- Layer 2

local function detail(st)
    local s = status_of(st)
    local body = wibox.layout.fixed.vertical()
    body.spacing = 6

    local head = wibox.widget{
        wibox.widget{
            { ui.dot(s.color, 7), right = 8, widget = wibox.container.margin },
            ui.text{ font = ui.font.strong,
                     markup = ui.span("OpenCode", ui.color.text, ui.font.strong) },
            layout = wibox.layout.fixed.horizontal,
        },
        nil,
        ui.text{ font = ui.font.tiny, align = "right",
                 markup = ui.span(st.version and ("v" .. st.version) or "",
                                  ui.color.text_faint) },
        layout = wibox.layout.align.horizontal,
    }
    body:add(head)

    if not st.reachable then
        body:add(ui.text{ font = ui.font.small,
            markup = ui.span(st.reason or "unavailable", ui.color.text_faint) })
        body:add(ui.text{ font = ui.font.tiny,
            markup = ui.span("The bar keeps working without it.", ui.color.text_faint) })
    else
        body:add(ui.key_value("State", s.label, { fg = s.color }))
        if st.current then
            body:add(ui.key_value("Project", st.current.project))
            body:add(ui.key_value("Directory", ui.pretty_path(st.current.dir),
                                  { fg = ui.color.text_faint }))
            local title = ui.text{ font = ui.font.small, wrap = "word", width = 292 }
            ui.set_markup(title, ui.span(st.current.title, ui.color.text_dim))
            body:add(ui.divider())
            body:add(title)
        elseif st.status == "idle" then
            body:add(ui.text{ font = ui.font.small,
                markup = ui.span("No active session", ui.color.text_dim) })
        end
        local pending = pending_text(st)
        if pending then
            body:add(ui.key_value("Waiting", pending, { fg = ui.color.warn }))
        end
        body:add(ui.section("Usage", { spacing_before = 4 }))
        refresh_usage()
        body:add(usage_rows(292))
        body:add(ui.text{ font = ui.font.tiny,
            markup = ui.span("Click for sessions and actions", ui.color.text_faint) })
    end

    return { content = body, width = 320 }
end

-------------------------------------------------------------------------- Layer 3

local function open_surface(opts)
    opts = opts or {}
    if opts.refresh then oc.refresh() end
    refresh_usage()

    local st = oc.state
    local s = status_of(st)

    local head = wibox.widget{
        wibox.widget{
            { ui.dot(s.color, 8), right = 9, widget = wibox.container.margin },
            ui.text{ font = ui.font.clock,
                     markup = ui.span("OpenCode", ui.color.text, ui.font.clock) },
            layout = wibox.layout.fixed.horizontal,
        },
        nil,
        ui.text{ font = ui.font.tiny, align = "right",
                 markup = ui.span(string.format("%s · v%s", s.label,
                     st.version or "?"), s.color, ui.font.tiny) },
        layout = wibox.layout.align.horizontal,
    }

    local body = wibox.layout.fixed.vertical()
    body.spacing = 7
    body:add(head)

    if not st.reachable then
        body:add(ui.text{ font = ui.font.small, wrap = "word", width = 332,
            markup = ui.span(st.reason or "OpenCode is not available.",
                             ui.color.text_dim) })
        body:add(ui.text{ font = ui.font.tiny, wrap = "word", width = 332,
            markup = ui.span("Start OpenCode in a terminal; AETHER picks it up on the next poll.",
                             ui.color.text_faint) })
    else
        local pending = pending_text(st)
        if pending then
            body:add(wibox.widget{
                { ui.dot(ui.color.warn, 6), right = 8, widget = wibox.container.margin },
                ui.text{ font = ui.font.small,
                         markup = ui.span(pending, ui.color.warn) },
                layout = wibox.layout.fixed.horizontal,
            })
        end
        if st.current then
            local title = ui.text{ font = ui.font.small, wrap = "word", width = 332 }
            ui.set_markup(title, ui.span(st.current.title, ui.color.text_dim))
            body:add(ui.key_value("Project", st.current.project))
            body:add(ui.key_value("Path", ui.pretty_path(st.current.dir),
                                  { fg = ui.color.text_faint }))
            body:add(ui.key_value("Agent", st.current.agent ~= "" and st.current.agent or "—"))
            body:add(ui.divider())
            body:add(title)
        end

        body:add(ui.section("Sessions", { spacing_before = 4 }))
        local count = 0
        local list = wibox.layout.fixed.vertical()
        list.spacing = 1
        for _, session in ipairs(st.sessions) do
            if count >= 4 then break end
            count = count + 1
            list:add(session_row(session, {
                title_width = 236,
                on_pick = function(x)
                    if oc.actions.resume(x) then popover.close("resume") end
                end,
            }))
        end
        if count == 0 then
            list:add(ui.text{ font = ui.font.small,
                markup = ui.span("No sessions yet", ui.color.text_faint) })
        end
        body:add(list)

        body:add(ui.section("Usage", { spacing_before = 4 }))
        body:add(usage_rows(332))
    end

    body:add(ui.divider())
    body:add(action_row(st))
    body:add(stats_line())

    popover.show{
        id = "opencode",
        content = body,
        width = 360,
        modal = true,
    }
end
M.open_surface = open_surface

-- One module-level subscription keeps an open surface live.  It never
-- mutates the listener list while it runs, so publish() stays iteration-safe.
oc.subscribe(function()
    if popover.is_open("opencode") then open_surface() end
end)

-------------------------------------------------------------------------- Layer 1

local bar_entries = {}

local function paint_entry(e)
    local st = oc.state
    local s = status_of(st)
    local project = project_of(st)

    e.dot.bg = s.color
    e.dot.opacity = (st.status == "offline") and 0.5 or 1

    local text = "opencode"
    local color = st.reachable and ui.color.text_dim or ui.color.text_faint
    local glyph -- optional FA glyph before the label (U6)
    if st.status == "waiting" and st.pending.total > 0 then
        -- Glyph prefix so "· 1" reads as "something needs you", not as a
        -- session counter (U6).
        glyph = "\u{f12a}" -- fa-exclamation, same family the bar already uses
        text = string.format("opencode · %d", st.pending.total)
        color = ui.color.warn
    elseif st.status == "working" and project then
        text = "opencode · " .. project
        color = ui.color.text
    elseif st.status == "error" then
        text = "opencode"
        color = ui.color.danger
    elseif st.reachable and st.status == "idle" and project then
        text = "opencode · " .. project
        color = ui.color.text_dim
    end
    if glyph then
        ui.set_markup(e.label, string.format(
            '<span font="FontAwesome 9" foreground="%s">%s</span>'
                .. '<span font="%s" foreground="%s"> %s</span>',
            color, ui.esc(glyph), ui.font.small, color, ui.esc(text)))
    else
        ui.set_text(e.label, text, color, ui.font.small)
    end
end

local function register(e)
    bar_entries[#bar_entries + 1] = e
    paint_entry(e)
end

oc.subscribe(function()
    for _, e in ipairs(bar_entries) do paint_entry(e) end
end)

--- Ambient OpenCode presence for a screen's bar.
function M.bar_widget(s)
    local dot = ui.dot(ui.color.text_faint, 6)
    local label = ui.text{ font = ui.font.small }

    local root = wibox.container.background()
    root.shape = ui.radius_shape.card
    root.bg = ui.color.transparent
    root.forced_height = 26
    root.widget = wibox.container.place(wibox.widget{
        { dot, right = 7, widget = wibox.container.margin },
        label,
        layout = wibox.layout.fixed.horizontal,
        spacing = 0,
    })
    local entry = { dot = dot, label = label, screen = s }
    register(entry)

    ui.hover(root, function() return ui.color.transparent end, ui.color.hover)

    root:buttons(gears.table.join(awful.button({}, 1, function()
        if popover.is_open("opencode") then
            popover.close("toggle")
        else
            open_surface({ refresh = true })
        end
    end)))

    popover.hover(root, "opencode-detail", function()
        if not oc.state.reachable and not oc.caps.probed then return nil end
        return detail(oc.state)
    end)

    return root
end

-------------------------------------------------------------------------- Layer 4

--- OpenCode section for the expanded panel.  Returns a widget with
-- :render() (rebuild) and :dispose() (drop subscriptions).
function M.panel_section(on_close)
    local container = wibox.layout.fixed.vertical()
    container.spacing = 6

    local function render()
        local st = oc.state
        local s = status_of(st)
        container:reset()

        local head = wibox.widget{
            wibox.widget{
                { ui.dot(s.color, 7), right = 8, widget = wibox.container.margin },
                ui.text{ font = ui.font.small,
                         markup = ui.span(s.label, s.color, ui.font.small) },
                layout = wibox.layout.fixed.horizontal,
            },
            nil,
            ui.text{ font = ui.font.tiny, align = "right",
                     markup = ui.span(st.version and ("v" .. st.version) or "",
                                      ui.color.text_faint) },
            layout = wibox.layout.align.horizontal,
        }
        container:add(head)

        if not st.reachable then
            container:add(ui.text{ font = ui.font.tiny, wrap = "word", width = 348,
                markup = ui.span(st.reason or "not available", ui.color.text_faint) })
        else
            local project = ui.text{ font = ui.font.strong }
            ui.set_text(project, st.current and st.current.project or "no session",
                st.current and ui.color.text or ui.color.text_faint, ui.font.strong)
            local dir = ui.text{ font = ui.font.tiny, ellipsize = "end", width = 240,
                                 align = "right" }
            ui.set_text(dir, st.current and ui.pretty_path(st.current.dir) or "",
                ui.color.text_faint, ui.font.tiny)
            container:add(wibox.widget{
                project, nil, dir,
                layout = wibox.layout.align.horizontal,
            })
            if st.current then
                local title = ui.text{ font = ui.font.small, wrap = "word", width = 348 }
                ui.set_markup(title, ui.span(st.current.title, ui.color.text_dim))
                container:add(title)
            end
            local pending = pending_text(st)
            if pending then
                container:add(ui.text{ font = ui.font.small,
                    markup = ui.span(pending, ui.color.warn) })
            end
            local list = wibox.layout.fixed.vertical()
            list.spacing = 1
            for i, session in ipairs(st.sessions) do
                if i > 2 then break end
                list:add(session_row(session, {
                    title_width = 220,
                    on_pick = function(x)
                        if oc.actions.resume(x) then
                            if on_close then on_close() end
                        end
                    end,
                }))
            end
            container:add(list)
            container:add(action_row(st))
            container:add(ui.section("Usage", { spacing_before = 6 }))
            container:add(usage_rows(348))
        end
    end

    render()
    local unsub = oc.subscribe(render)
    container.render = render
    container.dispose = function() unsub() end
    return container
end

return M
