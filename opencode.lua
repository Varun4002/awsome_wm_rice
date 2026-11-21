--------------------------------------------------------------------------
-- opencode.lua — OpenCode integration: discovery, state, actions
--
-- OpenCode (v2) runs a local background service.  This module is the only
-- place that talks to it; the bar renders `M.state` and never runs a command
-- itself.  The interface is deliberately small:
--
--   M.state      availability, sessions, active drains, pending requests,
--                the selected session and a derived status
--   M.subscribe  called when the published state actually changes
--   M.refresh    force a poll (opening a surface does this)
--   M.actions    supported operations, each gated on a capability probe
--
-- Transport: one `curl` fetches four read-only JSON documents into
-- ~/.cache/aether/, then a single `jq` reduces them to TSV.  That is one
-- process per poll (~10 ms measured), no background helper, no blocking call
-- in the WM loop, and no JSON parser added to the config.
--
-- Authentication uses the CLI's own service file (~/.local/state/opencode/
-- service.json, mode 0600).  The password is copied into a 0600 curl config,
-- never into a command line, the UI, or a log.
--
-- Polling is adaptive (2 s while an agent runs or waits, 6 s idle, 10 s
-- while OpenCode is unreachable) instead of subscribing to the SSE stream:
-- an event reader would need a supervised helper, a pidfile and reconnect
-- logic for a payload this small.
--------------------------------------------------------------------------

local awful = require("awful")
local gears = require("gears")
local lfs   = require("lfs")

local M = {}

local HOME = os.getenv("HOME") or ""

M.config = {
    service_file = HOME .. "/.local/state/opencode/service.json",
    binary       = HOME .. "/.opencode/bin/opencode",
    terminal     = "kitty",
    state_dir    = HOME .. "/.cache/aether",
    auth_file    = HOME .. "/.cache/aether/opencode.auth",
    request_timeout = 2,
    poll_working = 2.0,
    poll_idle    = 6.0,
    poll_offline = 10.0,
    stats_ttl    = 60,
    usage_url       = "https://opencode.ai/zen/go/v1/usage",
    usage_ttl       = 300, -- same cadence class as the GNOME usage extension
    auth_json       = HOME .. "/.local/share/opencode/auth.json",
    usage_auth_file = HOME .. "/.cache/aether/opencode-go.auth",
}

M.state = {
    status      = "offline",  -- offline | idle | working | waiting | error
    reachable   = false,
    reason      = "starting",
    version     = nil,
    sessions    = {},         -- newest first
    active      = {},         -- [session id] = true
    current     = nil,        -- active session first, else newest
    pending     = { permissions = 0, forms = 0, total = 0 },
    updated_at  = 0,
}

-- OpenCode Go usage limits, fetched straight from the hosted API.  windows
-- are pre-sorted (5-hour, weekly, monthly): { id, name, pct, resets, status }.
M.usage = {
    ok         = false,
    reason     = "not fetched yet",
    windows    = {},
    fetched_at = 0,
}

M.caps = { curl = false, jq = false, kitty = false, xclip = false,
           xdg_open = false, opencode = false, probed = false }

local listeners = {}
local started = false
local inflight = false
local poll_timer
local auth_written = { url = nil, password = nil }
local stats_cache = { at = 0, tokens = nil, sessions = nil }

-------------------------------------------------------------------------- helpers

local function shquote(s)
    return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

local function is_dir(path)
    return path and lfs.attributes(path, "mode") == "directory"
end

local NON_TUI = {
    serve = true, service = true, api = true, run = true, session = true,
    stats = true, mcp = true, models = true, plugin = true, auth = true,
    upgrade = true, uninstall = true, debug = true, acp = true, pair = true,
    mini = true, reload = true, completions = true, web = true, generate = true,
}

local function unescape_tsv(s)
    return (s:gsub("\\(.)", function(ch)
        if ch == "t" then return "\t" end
        if ch == "n" then return "\n" end
        if ch == "r" then return "\r" end
        return ch
    end)):gsub("[%c]", " ")
end

local function signature(st)
    local parts = { st.status, tostring(st.pending.total), tostring(#st.sessions) }
    for _, s in ipairs(st.sessions) do
        parts[#parts + 1] = s.id .. ":" .. s.title .. ":" .. tostring(s.outcome) ..
            ":" .. tostring(s.working) .. ":" .. tostring(s.updated)
    end
    -- Usage windows drive the same listeners; include them so a fresh
    -- fetch repaints the open surfaces.
    local u = M.usage
    parts[#parts + 1] = tostring(u.ok) .. ":" .. tostring(u.reason)
    for _, w in ipairs(u.windows) do
        parts[#parts + 1] = w.id .. ":" .. string.format("%.1f", w.pct) ..
            ":" .. tostring(w.resets) .. ":" .. tostring(w.status)
    end
    return table.concat(parts, "|")
end

local function publish()
    M.state.updated_at = os.time()
    local sig = signature(M.state)
    if sig == M._sig then return end
    M._sig = sig
    for _, fn in ipairs(listeners) do pcall(fn, M.state) end
end

-------------------------------------------------------------------------- discovery

--- Read the CLI's service registration without ever logging the secret.
local function read_service()
    local f = io.open(M.config.service_file, "r")
    if not f then return nil, "OpenCode service is not running" end
    local raw = f:read("*a") or ""
    f:close()
    local url = raw:match('"url"%s*:%s*"([^"]+)"')
    local password = raw:match('"password"%s*:%s*"([^"]*)"')
    local version = raw:match('"version"%s*:%s*"([^"]*)"')
    local pid = tonumber(raw:match('"pid"%s*:%s*(%d+)') or "")
    if not url or not password then
        return nil, "OpenCode service file is unreadable"
    end
    if not url:match("^http://127%.0%.0%.1:%d+$") then
        return nil, "unexpected OpenCode service url"
    end
    return { url = url, password = password, version = version, pid = pid }
end

local function write_auth(svc)
    if auth_written.url == svc.url and auth_written.password == svc.password then
        return true
    end
    local f = io.open(M.config.auth_file, "w")
    if not f then return false end
    f:write('user = "opencode:', svc.password:gsub("\\", "\\\\"):gsub('"', '\\"'), '"\n')
    f:close()
    -- ~/.cache is already 0700; the extra chmod is defence in depth.
    awful.spawn.with_shell("chmod 600 " .. shquote(M.config.auth_file) .. " 2>/dev/null || true")
    auth_written = { url = svc.url, password = svc.password }
    return true
end

-------------------------------------------------------------------------- poll

local JQ_PROGRAM = [[
($s[0]) as $S | ($a[0]) as $A | ($p[0]) as $P | ($f[0]) as $F
| if (($S.data|type)!="array") or (($A.data|type)!="object")
     or (($P.data|type)!="array") or (($F.data|type)!="array") then empty
  else
    (["H", ($P.data|length), ($F.data|length)] | @tsv),
    ($S.data[] | ["S", .id, (.title // ""), (.location.directory // ""),
      (.agent // ""), (.outcome // ""), ((.time.updated // 0)|tostring),
      (if ($A.data[.id] // null) then "1" else "0" end)] | @tsv)
  end
]]

local function poll_command(svc)
    local d = M.config.state_dir
    local t = M.config.request_timeout
    return string.format(
        "curl -fsS --fail-early -m %d -K %s " ..
        "-o %s/s.json %s " ..
        "-o %s/a.json %s " ..
        "-o %s/p.json %s " ..
        "-o %s/f.json %s && " ..
        "jq -n -r --slurpfile s %s/s.json --slurpfile a %s/a.json " ..
        "--slurpfile p %s/p.json --slurpfile f %s/f.json %s",
        t, shquote(M.config.auth_file),
        shquote(d), shquote(svc.url .. "/api/session?limit=12&order=desc"),
        shquote(d), shquote(svc.url .. "/api/session/active"),
        shquote(d), shquote(svc.url .. "/api/permission/request"),
        shquote(d), shquote(svc.url .. "/api/form"),
        shquote(d), shquote(d), shquote(d), shquote(d),
        shquote(JQ_PROGRAM))
end

local function parse(out)
    local sessions, active = {}, {}
    local pending = { permissions = 0, forms = 0, total = 0 }
    local saw_header = false

    for line in (out or ""):gmatch("[^\n]+") do
        local f = {}
        for field in (line .. "\t"):gmatch("([^\t]*)\t") do
            f[#f + 1] = unescape_tsv(field)
        end
        if f[1] == "H" then
            saw_header = true
            pending.permissions = tonumber(f[2]) or 0
            pending.forms = tonumber(f[3]) or 0
            pending.total = pending.permissions + pending.forms
        elseif f[1] == "S" and #f >= 8 then
            local s = {
                id      = f[2],
                title   = f[3] ~= "" and f[3] or "Untitled session",
                dir     = f[4],
                agent   = f[5],
                outcome = f[6],
                updated = tonumber(f[7]) or 0,
                working = f[8] == "1",
            }
            local base = s.dir ~= "" and s.dir:gsub("/+$", ""):match("([^/]+)$") or nil
            if s.dir == HOME then base = "~" end
            s.project = base or "—"
            sessions[#sessions + 1] = s
            if s.working then active[s.id] = true end
        end
    end

    if not saw_header then return nil end
    return sessions, active, pending
end

local function derive(st)
    st.reachable = true
    st.reason = nil
    local current
    for _, s in ipairs(st.sessions) do
        if st.active[s.id] then current = s break end
    end
    st.current = current or st.sessions[1]

    if st.pending.total > 0 then
        st.status = "waiting"
    elseif next(st.active) ~= nil then
        st.status = "working"
    elseif st.current and st.current.outcome == "failed" then
        st.status = "error"
    else
        st.status = "idle"
    end
end

local function set_offline(reason)
    local st = M.state
    st.reachable = false
    st.reason = reason
    st.status = "offline"
    st.sessions = {}
    st.active = {}
    st.current = nil
    st.pending = { permissions = 0, forms = 0, total = 0 }
    publish()
end

local function next_delay()
    local st = M.state
    if not st.reachable then return M.config.poll_offline end
    if st.status == "working" or st.status == "waiting" then
        return M.config.poll_working
    end
    return M.config.poll_idle
end

local function schedule()
    if poll_timer then poll_timer:stop() end
    poll_timer = gears.timer.start_new(next_delay(), function()
        poll_timer = nil
        M.refresh()
        return false
    end)
end

function M.refresh()
    if inflight then return end
    if not (M.caps.curl and M.caps.jq) then
        set_offline("curl or jq is not installed")
        return
    end
    local svc, why = read_service()
    if not svc then
        set_offline(why)
        return
    end
    if not write_auth(svc) then
        set_offline("cannot prepare credential file")
        return
    end

    inflight = true
    awful.spawn.easy_async_with_shell(poll_command(svc), function(out, err, _, code)
        inflight = false
        if code ~= 0 or out == "" then
            local detail = (err or ""):gsub("%s+$", "")
            set_offline(detail ~= ""
                and ("OpenCode service is not reachable: " .. detail:sub(1, 160))
                or "OpenCode service is not reachable")
            schedule()
            return
        end
        local sessions, active, pending = parse(out)
        if not sessions then
            set_offline("unexpected OpenCode response")
            schedule()
            return
        end
        local st = M.state
        st.version = svc.version
        st.sessions = sessions
        st.active = active
        st.pending = pending
        derive(st)
        publish()
        schedule()
    end)
end

-------------------------------------------------------------------------- TUI discovery

--- Ancestor pids of every running OpenCode TUI process, read straight from
-- /proc (one synchronous pass, ~10 ms, only on demand).  The service,
-- `opencode serve`, `stats`, `run` and other subcommands are excluded.
local function tui_ancestors()
    local ancestors = {}
    local ok, iter = pcall(lfs.dir, "/proc")
    if not ok then return ancestors end
    for entry in iter do
        if entry:match("^%d+$") then
            local fd = io.open("/proc/" .. entry .. "/cmdline", "rb")
            if fd then
                local data = fd:read(4096) or ""
                fd:close()
                local argv = {}
                for arg in data:gmatch("([^%z]+)") do argv[#argv + 1] = arg end
                local exe = argv[1] and argv[1]:match("([^/]+)$")
                local sub = argv[2]
                local is_tui = true
                if sub and sub:sub(1, 1) ~= "-" and NON_TUI[sub] then
                    is_tui = false
                end
                if exe == "opencode" and is_tui then
                    local pid = tonumber(entry)
                    for _ = 1, 12 do
                        if not pid or pid <= 1 then break end
                        ancestors[pid] = true
                        local stat = io.open("/proc/" .. pid .. "/stat", "rb")
                        if not stat then break end
                        local line = stat:read("*l") or ""
                        stat:close()
                        local rest = line:match("^.*%)%s(.*)$") or ""
                        pid = tonumber(rest:match("^%S+%s+(%d+)"))
                    end
                end
            end
        end
    end
    return ancestors
end

--- The client whose terminal hosts an OpenCode TUI, if detectably one.
function M.find_tui_client()
    local ancestors = tui_ancestors()
    local best, best_score
    for _, c in ipairs(client.get()) do
        if c.pid and ancestors[c.pid] then
            local score = 0
            if c == client.focus then score = score + 2 end
            if c.name and c.name:lower():find("opencode", 1, true) then score = score + 1 end
            if c.minimized then score = score - 1 end
            if not best or score > best_score then best, best_score = c, score end
        end
    end
    if best and best.valid then return best end
end

-------------------------------------------------------------------------- actions

local function spawn(cmd)
    awful.spawn.with_shell(cmd)
end

function M.current_dir()
    local st = M.state
    if st.current and is_dir(st.current.dir) then return st.current.dir end
    return HOME
end

local A = {}

function A.resume(session)
    if not session or type(session.id) ~= "string"
        or not session.id:match("^ses_[%w]+$") then return false end
    if not is_dir(session.dir) then return false end
    if not M.caps.kitty then return false end
    spawn(string.format("%s --directory %s -e %s --session %s %s",
        M.config.terminal, shquote(session.dir),
        shquote(M.config.binary), session.id, shquote(session.dir)))
    return true
end

function A.new_session(dir)
    dir = is_dir(dir) and dir or HOME
    if not M.caps.kitty then return false end
    spawn(string.format("%s --directory %s -e %s %s",
        M.config.terminal, shquote(dir), shquote(M.config.binary), shquote(dir)))
    return true
end

function A.terminal(dir)
    dir = is_dir(dir) and dir or HOME
    if not M.caps.kitty then return false end
    spawn(string.format("%s --directory %s", M.config.terminal, shquote(dir)))
    return true
end

function A.copy_path(dir)
    if not is_dir(dir) or not M.caps.xclip then return false end
    spawn(string.format("printf '%%s' %s | xclip -selection clipboard", shquote(dir)))
    return true
end

function A.open_project(dir)
    if not is_dir(dir) or not M.caps.xdg_open then return false end
    spawn(string.format("xdg-open %s", shquote(dir)))
    return true
end

--- "Open OpenCode": focus the detected TUI window, otherwise launch a new
-- session in the current project.  Returns "focus" | "launch" | false.
function A.focus_or_launch()
    local c = M.find_tui_client()
    if c then
        if c.minimized then c.minimized = false end
        c:emit_signal("request::activate", "aether_opencode", { raise = true })
        return "focus"
    end
    if A.new_session(M.current_dir()) then return "launch" end
    return false
end

M.actions = A

-------------------------------------------------------------------------- usage stats

--- Today's token usage from `opencode stats`, fetched on demand and cached.
-- Returns cb(tokens, sessions); both nil when unavailable.
function M.stats(cb)
    local now = os.time()
    if stats_cache.at + M.config.stats_ttl > now then
        return cb(stats_cache.tokens, stats_cache.sessions)
    end
    if not (M.caps.opencode and M.caps.jq) then return cb(nil, nil) end
    awful.spawn.easy_async_with_shell(
        string.format("%s stats --days 0 --json 2>/dev/null " ..
            "| jq -r '[(.tokens.input + .tokens.output + .tokens.reasoning), .sessions] | @tsv' " ..
            "2>/dev/null || true", shquote(M.config.binary)),
        function(out)
            local a, b = out:match("(%d+)%s+(%d+)")
            stats_cache = { at = os.time(), tokens = tonumber(a), sessions = tonumber(b) }
            cb(tonumber(a), tonumber(b))
        end)
end

--------------------------------------------------------------------------
-- usage limits (OpenCode Go)

-- The hosted API reports rate-limit windows; this reduces any shape of it
-- (object or array, percent/remaining/used-limit variants) to TSV rows
-- "U id percent status resetsAt".  Verified against the live response.
local USAGE_JQ = [[
def pctw($w):
  ([$w.percent, $w.usagePercent, $w.usedPercent, $w.percentUsed, $w.usage_percent] | first(.[] | numbers))
  // ([$w.remainingPercent, $w.remaining_percent, $w.remaining] | first(.[] | numbers) | if . == null then null else 100 - . end)
  // (([$w.used, $w.amount, $w.consumed, $w.value, $w.usedTokens] | first(.[] | numbers)) as $u
      | ([$w.limit, $w.total, $w.quota, $w.max, $w.cap, $w.tokenLimit] | first(.[] | numbers)) as $l
      | if ($u != null) and ($l != null) and ($l > 0) then ($u / $l * 100) else null end);
def resetw($w): ($w.resetsAt // $w.resetAt // $w.reset // $w.nextReset // $w.renewAt // "");
def win($id; $w):
  if ($w | type) == "object" then
    pctw($w) as $p
    | select($p != null)
    | ["U", $id, $p, ($w.status // "ok"), (resetw($w) | tostring)] | @tsv
  else empty end;
. as $in | ($in.usage // $in) as $u
| if ($u | type) == "array" then $u[] | win(.id // .name // "?"; .)
  elif ($u | type) == "object" then $u | to_entries[] | win(.key; .value)
  else empty end
]]

local USAGE_NAMES = {
    rolling = "5-hour", rolling5h = "5-hour", ["5-hour"] = "5-hour",
    weekly = "Weekly", monthly = "Monthly", daily = "Daily",
}
local USAGE_RANK = { rolling = 1, rolling5h = 1, weekly = 2, monthly = 3 }

local usage_inflight = false
local usage_auth = { key = nil } -- header file already written for this key

--- The Go API key lives in the CLI's own 0600 auth file; read with the same
-- regex approach as read_service(), never logged.
local function read_go_key()
    local f = io.open(M.config.auth_json, "r")
    if not f then return nil end
    local raw = f:read("*a") or ""
    f:close()
    local block = raw:match('"opencode%-go"%s*:%s*%b{}') or ""
    local key = block:match('"key"%s*:%s*"([^"]*)"')
    return key ~= "" and key or nil
end

-- The key is written into a 0600 curl header file ("authorization: Bearer
-- ...") and passed with -H @file — never onto a command line.
local function write_usage_auth(key)
    if usage_auth.key == key then return true end
    local f = io.open(M.config.usage_auth_file, "w")
    if not f then return false end
    f:write("authorization: Bearer " .. key .. "\n")
    f:close()
    awful.spawn.with_shell("chmod 600 " ..
        shquote(M.config.usage_auth_file) .. " 2>/dev/null || true")
    usage_auth.key = key
    return true
end

--- Epoch seconds for the API's reset timestamps: ISO 8601 (with Z or a
-- numeric offset) or a unix number in seconds/milliseconds.
local function reset_epoch(v)
    if not v or v == "" then return nil end
    if v:match("^%-?%d+%.?%d*$") then
        local n = tonumber(v)
        if not n then return nil end
        if n > 1e12 then n = n / 1000 end -- ms -> s
        return math.floor(n)
    end
    local y, mo, d, h, mi, s, tail =
        v:match("^(%d%d%d%d)-(%d%d)-(%d%d)[Tt ](%d%d):(%d%d):(%d%d)(.*)$")
    if not y then return nil end
    tail = tail:gsub("^%.%d+", "") -- fractional seconds
    -- os.time builds an as-if-local epoch; correct it with
    --   true = as_if_local + local_offset - timestamp_offset
    local t = os.time({ year = y, month = mo, day = d,
                        hour = h, min = mi, sec = s, isdst = false })
    local off = 0
    local sign, oh, om = tail:match("^([%+%-])(%d%d):?(%d%d)")
    if sign then
        off = tonumber(oh) * 3600 + tonumber(om) * 60
        if sign == "-" then off = -off end
    end
    local now = os.time()
    local local_off = os.time(os.date("*t", now)) - os.time(os.date("!*t", now))
    return t + local_off - off
end

local function parse_usage(out)
    local windows, seen = {}, {}
    for line in (out or ""):gmatch("[^\n]+") do
        local f = {}
        for field in (line .. "\t"):gmatch("([^\t]*)\t") do
            f[#f + 1] = unescape_tsv(field)
        end
        if f[1] == "U" and f[2] and f[2] ~= "" and tonumber(f[3]) then
            local w = {
                id     = f[2],
                name   = USAGE_NAMES[f[2]] or f[2]:gsub("[-_]+", " "),
                pct    = math.max(0, math.min(100, tonumber(f[3]))),
                status = f[4] ~= "" and f[4] or "ok",
                resets = reset_epoch(f[5]),
            }
            if not seen[w.name] then -- same window under two ids: first wins
                seen[w.name] = true
                windows[#windows + 1] = w
            end
        end
    end
    if #windows == 0 then return nil end
    table.sort(windows, function(a, b)
        local ra, rb = USAGE_RANK[a.id] or 9, USAGE_RANK[b.id] or 9
        if ra ~= rb then return ra < rb end
        return a.id < b.id
    end)
    return windows
end

local function fetch_usage(force)
    if not M.caps.probed then return end
    if not force and M.usage.fetched_at + M.config.usage_ttl > os.time() then
        publish() -- surface the cached copy
        return
    end
    if usage_inflight then return end
    if not (M.caps.curl and M.caps.jq) then
        M.usage.ok, M.usage.reason = false, "curl or jq is not installed"
        publish()
        return
    end
    local key = read_go_key()
    if not key then
        M.usage.ok, M.usage.reason = false,
            "no opencode-go key in ~/.local/share/opencode/auth.json"
        M.usage.windows = {}
        publish()
        return
    end
    if not write_usage_auth(key) then
        M.usage.ok, M.usage.reason = false, "cannot prepare the usage credential file"
        publish()
        return
    end
    usage_inflight = true
    awful.spawn.easy_async_with_shell(string.format(
        "curl -fsS -m 5 -H @%s -o %s/usage.json %s && " ..
        "jq -r %s %s/usage.json",
        shquote(M.config.usage_auth_file),
        shquote(M.config.state_dir), shquote(M.config.usage_url),
        shquote(USAGE_JQ), shquote(M.config.state_dir)),
        function(out, err, _, code)
            usage_inflight = false
            if code ~= 0 or out == "" then
                local detail = (err or ""):gsub("%s+$", "")
                M.usage.ok = false
                M.usage.reason = "usage lookup failed" ..
                    (detail ~= "" and (": " .. detail:sub(1, 120)) or "")
                publish()
                return
            end
            local windows = parse_usage(out)
            M.usage.windows = windows or {}
            M.usage.ok = windows ~= nil
            if windows then
                M.usage.reason = nil
            else
                M.usage.reason = "unexpected usage response"
            end
            M.usage.fetched_at = os.time()
            publish()
        end)
end

--- Fetch usage now unless the cache is still fresh.
function M.refresh_usage(force)
    fetch_usage(force)
end

-------------------------------------------------------------------------- lifecycle

function M.subscribe(fn)
    listeners[#listeners + 1] = fn
    return function()
        for i = #listeners, 1, -1 do
            if listeners[i] == fn then table.remove(listeners, i) end
        end
    end
end

local function probe()
    awful.spawn.easy_async_with_shell(
        "for x in curl jq kitty xclip xdg-open; do " ..
        "if command -v \"$x\" >/dev/null 2>&1; then printf '%s 1\\n' \"$x\"; " ..
        "else printf '%s 0\\n' \"$x\"; fi; done; " ..
        "if [ -x " .. shquote(M.config.binary) .. " ]; then echo 'opencode 1'; " ..
        "else echo 'opencode 0'; fi",
        function(out)
            for name, val in (out or ""):gmatch("([%w%-_]+) ([01])") do
                local key = name:gsub("%-", "_")
                M.caps[key] = (val == "1")
            end
            M.caps.probed = true
            M.refresh()
            fetch_usage()
        end)
end

function M.start()
    if started then return end
    started = true
    pcall(function()
        require("gears.filesystem").make_directories(M.config.state_dir)
    end)
    probe()
    gears.timer{ timeout = M.config.usage_ttl, autostart = true,
                 callback = function() fetch_usage() end }
end

return M
