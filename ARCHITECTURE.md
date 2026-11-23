# AETHER — architecture brief

AETHER is the name of this AwesomeWM desktop: a working X11 session on a
hybrid-GPU laptop (internal panel + HDMI) that has been refined into a
consistent visual system. This document describes **what exists and how it
fits together**, so a new agent can work on it without re-deriving the design.
Every claim is grounded in code; citations are `file:line` relative to
`~/.config/awesome/`.

Read order for a cold start: §2 (environment) → §3 (boot) → §4 (file map) →
§5 (UI model) → then the module section you need.

---

## 1. Scope and design intent

- **Not a rewrite.** Every module predates the AETHER work and is preserved
  unless a documented defect required a change (`README.md:5-7`).
- **One visual language.** Tokens live in `ui.lua`, and the module header states
  the rule: "the ambient bar, the contextual popovers, the control surface and
  the expanded panel cannot drift apart" (`ui.lua:4-7`).
- **Everything degrades.** Missing `picom`, `wpctl`, `playerctl`, the OpenCode
  CLI or the GTK launchers must leave the WM usable; the guards are inline
  (`2>/dev/null || true`, `command -v`, `caps` tables).
- **Measured, not asserted.** Behaviour claims belong in `docs/02-verification.md`
  with a probe or a capture; the latency baseline is `docs/05-performance.md`.

---

## 2. Environment (verified 2026-11-23)

| Item | Value |
|---|---|
| WM | awesome **4.3-8.1** (Ubuntu package), Lua 5.3.6, LGI 0.9.2, X11 |
| Session | GDM → `awesome-dual.desktop` → `/usr/local/bin/awesome-dual-display` → `exec awesome` |
| Screens | `eDP-1-1` 1920x1080 primary at +0+0, `HDMI-0` 1680x1050 @59.95 at +1920+0 |
| Work areas | `0,38 1920x1042` and `1920,38 1680x1012` (38 = `ui.bar_height` strut) |
| Compositor | pijulius picom **v13** at `/usr/local/bin/picom`, config `~/.config/picom/picom.conf` |
| Fonts | Inter (14 faces) present; `FontAwesome` for glyphs |
| GPU layout | NVIDIA is primary GPU of X screen 0 (`/usr/share/X11/xorg.conf.d/05-nvidia-primary.conf`, `PrimaryGPU "yes"`); Intel panel joins via output slaving |

Docs written against an earlier revision say "30 px bar" and "picom 12.5" —
stale. Live values above.

---

## 3. Boot chain

1. GDM starts the session file `/usr/share/xsessions/awesome-dual.desktop`
   (`Exec=/usr/local/bin/awesome-dual-display`). AccountsService
   `/var/lib/AccountsService/users/varun` has `Session=awesome-dual`, so GDM
   preselects it.
2. The wrapper (`system/awesome-dual-display`, installed copy in
   `/usr/local/bin`) does, in order: detect providers by name
   (`provider_named`, :27-29), `xrandr --setprovideroutputsource modesetting NVIDIA-0`
   (:51) — **this must happen before awesome enumerates screens** — detect
   connected `eDP*`/`HDMI*` outputs (:34-36), poll up to 2 s for the external
   output (:66-70), then apply
   `eDP --primary --auto` + `HDMI --mode 1680x1050 --rate 59.95 --right-of eDP`
   (:79-80). Falls back to internal-only when no HDMI (:82-83). Log:
   `~/.cache/awesome-display.log`.
3. The wrapper exports `XDG_SESSION_TYPE=x11`, `XDG_CURRENT_DESKTOP=awesome`,
   `DESKTOP_SESSION=awesome-dual`, `XDG_SESSION_DESKTOP=awesome-dual`, pushes
   them into the systemd user manager (`systemctl --user set-environment`,
   `NAME=VALUE` form — the bare-name form fails) and D-Bus
   (`dbus-update-activation-environment --systemd`), then `exec awesome`.
   Rationale: Chromium-based apps pick their ozone platform from the stale
   inherited value (:92-96).
4. `rc.lua` loads: theme, `glass.setup()`, screens/bars, rules, keys, then
   wallpaper, compositor, OpenCode (§4 order table).

Reload without logging out: `awesome-client 'awesome.restart()'`.

---

## 4. File map and load order

| File | Role | Key entry points |
|---|---|---|
| `rc.lua` | entry point: theme, screens, bars, rules, keys, wiring | `AETHER_RC_MARKER = "dot-v1"` (:19) |
| `ui.lua` | **design tokens + widget primitives**; no state, no WM calls | `M.color`, `M.font`, `M.chip`, `M.slider`, `M.surface` |
| `popover.lua` | the surface manager for layers 2–4 (one shared wibox) | `M.show`, `M.hover`, `M.close_all` |
| `anim.lua` | one-shot 60 fps tween helper (tag-keyed) | `M.tween`, `M.stop` |
| `frostbar.lua` | frosted backdrop + media mini-player + volume + OSD | `M.wrap`, `M.new_song`, `M.new_volume` |
| `workspaces.lua` | workspace pills (dot + 1–9), hover preview, actions | `M.widget`, `M.panel_rows` |
| `windower.lua` | active-window block, window detail, window controls | `M.widget`, `M.open_controls` |
| `clock.lua` | two-line clock + calendar surface | `M.widget`, `M.attach` |
| `control_center.lua` | Wi-Fi/BT/brightness/volume surface; bar button | `M.toggle`, `M.new_button` |
| `panel.lua` | layer 4 expanded panel (aggregates the rest) | `M.toggle`, `M.close` |
| `opencode.lua` | OpenCode service integration (state + usage) | `M.start`, `M.actions` |
| `opencode_ui.lua` | OpenCode layers 1–4 rendering | `M.bar_widget`, `M.panel_section` |
| `glass.lua` | theme, opacity tiers, glass titlebar, picom lifecycle | `M.setup`, `M.start_compositor`, `M.titlebar` |
| `wallpaper_cycler.lua` | wallpaper crossfade + magick cache + per-screen painters | `M.setup`, `M.next`, `M.subscribe` |
| `launchers.lua` | placement authority for the GTK launchers | `M.spawn`, `M.has_open_launcher`, `M.install` |
| `dotworkspace.lua` | tag reconciliation, dot policy, wallpaper accent | `M.install`, `M.ensure_tags`, `M.accent_color` |
| `dragtransfer.lua` | drag-aware Super+Tab (cross-monitor transfer) | `M.on_super_tab`, `M.install` |
| `widgets/*.lua` | **orphaned** event-driven slider suite (see §14.3) | — |
| `system/` | reference copies of files outside the repo (`picom.conf`, session wrapper) | — |
| `tools/bench-launcher.sh` | launcher latency benchmark | — |
| `docs/` | audit, rollback, verification, defects, performance, dot/drag spec | — |

`rc.lua` execution order (the shape of the file):

```
requires → AETHER_RC_MARKER → error hooks → beautiful.init → glass.setup()
→ terminal/modkey → awful.layout.layouts (13) → menu → aether_mark()
→ screen.connect_for_each_screen{ tags, prompt, layoutbox, keyboardlayout,
  wibar + widget tree, frostbar.wrap, mouse::leave }
→ fullscreen_busy → reveal_timer → update_bars → 6 bar signals
→ root.buttons → globalkeys (34) → clientkeys (10) → numrow tags (4x9)
→ clientbuttons → root.keys → modal Escape grab (popover.subscribe)
→ launchers → delayed key registration (0.5 s: Alt+Space, Mod4+e, Mod4+b)
→ awful.rules.rules → launchers.install → dotws.install → dragtransfer.install
→ deferred dotws.ensure_tags (2.5 s) → manage/titlebar/focus signals
→ wallpaper_cycler.setup → glass.start_compositor → opencode.start
```

Module-load-time side effect to know: `windower` connects its client/tag/screen
handlers at require time (`windower.lua:514-537`), i.e. before
`awful.rules.rules` is populated; `dotworkspace.install` and
`dragtransfer.install` are explicit calls after the rules so they sit behind the
launcher placement authority in the manage chain (`rc.lua:823-832`).

---

## 5. The UI: five layers

Canonical definition (`rc.lua:166-170`): *"Layer 1 (the ambient bar) is assembled
here; layers 2-4 are owned by their modules and anchored to these widgets;
layer 5 is the signal wiring."* `popover.lua:4-6` states the same set from the
manager's side. (The code cites `docs/06-five-layer-bar.md`, which does not
exist; this section is that document.)

| Layer | Meaning | Owner | Instances |
|---|---|---|---|
| 1 | ambient bar, per screen, always visible | `rc.lua` + module bar widgets | `workspaces.widget`, `windower.widget`, `frostbar.new_song/new_volume`, `opencode_ui.bar_widget`, `clock.widget`, `control_center.new_button` |
| 2 | contextual reveal on hover, **non-modal** | module → `popover.hover` | `ws-preview`, `win-detail`, `clock-detail`, `opencode-detail` |
| 3 | click-opened control/action surface, **modal** | module → `popover.show` | `ws-actions`, `win-controls`, `cc`, `opencode`, `media` |
| 4 | expanded panel (AETHER mark / `Mod4+a`) | `panel.lua` | `panel` (396 px, aggregates OpenCode/Windows/Workspaces/System/Time) |
| 5 | signal wiring + autohide rule | `rc.lua` | `update_bars`, `reveal_timer`, `popover.subscribe` Escape grab, module subscriptions |

### 5.1 Layer 1 — the ambient bar

`awful.wibar{ position="top", height=ui.bar_height (38), ontop=true }`
(`rc.lua:253`), `bg="#0e0e10"` (`rc.lua:256`) — the bg exists because the
systray's embedded X window uses it; the frost paint covers the rest.
`ontop=true` is deliberate: awesome stacks ontop drawins above every client
layer, including fullscreen (`rc.lua:249-252`).

Widget tree (`rc.lua:261-292`, `wibox.layout.align.horizontal`):

```
left   : aether_mark()  ·  workspaces.widget(s)  ·  s.mypromptbox
centre : container.place( windower.widget(s) )        -- optically centred on the whole bar
right  : frostbar.new_song() · opencode_ui.bar_widget(s) · │ · frostbar.new_volume() · │
         keyboardlayout · layoutbox · systray · │ · control_center.new_button() · │ · clock.widget()
```

`│` = `ui.pad(ui.vrule(16), 8, 8, 0, 0)` group separators. The centre slot is
centred on the *bar* width so the window block stays put while side clusters
grow and shrink (`rc.lua:258-260`).

- `aether_mark()` (`rc.lua:172-196`): "AETHER" + accent dot, 28 px tall;
  left-click → `panel.toggle()` (layer 4), right-click → main menu.
- Bar state per screen: `s.mywibox`, `s.mypromptbox`, `s.mylayoutbox`,
  `s._bar_hidden` (true while hidden *because of fullscreen content*),
  `s._bar_revealed` (written only — never read; see §14.2).

### 5.2 The frost layer (painted inside layer 1)

`frostbar.wrap(wibar, s)` (`frostbar.lua:306-338`) replaces the bar widget with a
custom container modelled on `wibox.container.background`; the child (the whole
layer-1 tree) is placed over the full area and paints **after** the backdrop
(`frostbar.lua:238-263`). `paint_frost` (:209-236) draws, in order:

1. the cached wallpaper strip (or the crossfading incoming strip with
   `paint_with_alpha(smoothstep(t))`), else `FALLBACK` `#0e0e10`;
2. a full-rect black tint at `TINT_ALPHA = 0.38`;
3. a 1 px hairline at the bottom (`HAIRLINE_ALPHA = 0.10`);
4. a 1 px highlight at the top (`HIGHLIGHT_ALPHA = 0.05`).

Strips are baked off-thread by `magick` into
`~/.cache/awesome-wallpaper-bar/<md5>.jpg`:

```
magick '<src>' -resize WxH^ -gravity center -extent WxH -blur 0x14 \
       -crop WxBARH+0+0 +repage -quality 95 '<dst>'
```
Cache key = md5 of `src|mtime|WxH|WxBARH` (`frostbar.lua:106-111`), in-memory
cache of 12 surfaces per screen, in-flight de-dupe via `building[dst]`.
Invariant: geometry/height changes drop the surfaces (`:322-333`). The strip
follows the cycler through `cycler.subscribe` (`:287-290`), reading
`cycler.frames()` each tick.

### 5.3 The popover framework (layers 2–4)

One wibox for all of them, created lazily and reused forever
(`popover.lua:30,72-93,234`): `ontop`, `type="menu"`, `bg = ui.color.bg_popup`
(`#0d0f13ef`), 12 px rounded shape, 1 px `ui.color.border`, popover opacity
fades via `anim.tween` (tag `"aether_popover"`, 0.14 s in / 0.10 s out).
**Consequence: layers 2–4 are never stacked — opening one replaces the other**
(`popover.lua:6-9,236-240`).

Placement (`popover.lua:137-160`):

```
w,h  = widget:fit(...) or forced_width, fallback 320x120
x    = anchor and anchor.x + floor((anchor.width - w)/2)
      or screen.x + floor((screen.width - w)/2)
y    = screen.y + bar_height + 6
clamp x into [screen.x+8, screen.x+screen.width-w-8]
if y > screen.y+screen.height-h-8 then y = max(screen.y+bar_height+6, that) end
```
`bar_height` comes from `s.mywibox.height` (38), the `+6` gap and 8 px margin are
part of the look. Content is always wrapped in `ui.surface(content, width)`
(pad 14,14,12,13).

Dismissal: Escape only for modal surfaces (rc.lua installs the grab while
`popover.any_modal()`, `rc.lua:664-677`); pointer leaving the popup
(`popover.lua:89-91`), a different id opening, screen removal/geometry change.
Hover surfaces have `HOVER_DELAY = 0.14` open / `HOVER_CLOSE = 0.10` close and
never steal keyboard input.

`M.suppressed` is set by the volume scrub so hover cards cannot open mid-drag.

### 5.4 Layer 2 — hover reveals

| Surface | Built by | Content |
|---|---|---|
| `ws-preview` | `workspaces.lua:68-117` | workspace name, up to 5 window rows (icon + title, `·min` marker), `+N more`, "Click to switch · right-click for actions" |
| `win-detail` | `windower.lua:116-157` | app icon, title, State / Workspace / Monitor / Layout key-values |
| `clock-detail` | `clock.lua:83-108` | big time, full date, month grid (`ui.calendar`), "Click to pin · Escape to dismiss" |
| `opencode-detail` | `opencode_ui.lua:261-312` | status, project, directory, wrapped title, pending count, usage windows |

### 5.5 Layer 3 — click surfaces

- `ws-actions` (`workspaces.lua:134-179`): View / Send focused window here
  (disabled when the focus is on another screen) / Toggle in view / Next layout.
- `win-controls` (`windower.lua:181-423`, 344 px): minimise, maximise/restore,
  close, toggles floating/fullscreen/sticky/ontop, move-to-workspace 1–9,
  move-to-monitor, tiling chips (master, swap prev/next — enabled only for
  tiling layouts in `TILING_LAYOUTS`), and a live re-render on ~14 client
  signals.
- `cc` (`control_center.lua:358-451`, 316 px): Connectivity card
  (Wi-Fi, Bluetooth, paired/connected devices), Display & sound card (dark mode,
  brightness, volume), and "Open controls" → panel.
- `opencode` (`opencode_ui.lua:316-404`, 360 px): status header, current session,
  up to 4 sessions (click resumes), usage windows, action chips, today's tokens.
- `media` (`frostbar.lua:999-1026`, 308 px): app · state, title, artist, seek
  slider, transport, volume slider + mute.

### 5.6 Layer 4 — expanded panel

`panel.lua` builds one temporary surface per open (`WIDTH = 396`), assembled from
`opencode_ui.panel_section`, `workspaces.panel_rows`, a window list, a system
read (`nmcli`/`bluetoothctl`/`brightnessctl`/`wpctl` in one shell program,
`panel.lua:35-40`), and `clock.attach`. It refreshes by signature diffing
(`window_signature` :95-105) on client/tag signals, and disposes every watcher on
close (`:288-297`). Dismissal: Escape, pointer leave, or the AETHER mark again.

### 5.7 Layer 5 — wiring and autohide

`update_bars()` (`rc.lua:351-375`) hides a bar when `fullscreen_busy(s)` — the
`max.fullscreen` layout, or a visible fullscreen client on that screen — and
restores it otherwise. Connected to `property::fullscreen`, `manage`,
`unmanage`, `tag property::selected`, `tag property::layout`,
`screen property::geometry` (`rc.lua:377-382`).

Reveal: `reveal_timer` (`rc.lua:327-349`) polls the pointer at 0.08 s only while
some bar is hidden; pointer within 6 px of the top edge and inside that screen's
x-range reveals the bar with a 0.15 s fade. Leaving the bar re-hides it
(`rc.lua:299-305`).

### 5.8 Design tokens (`ui.lua`)

```
bar_height 38
color: text #e9edf3 · text_dim #98a0ad · text_faint #6c7480 · text_strong #ffffff
       accent #7cc4ee · accent_hi #aadfff · accent_bg #7cc4ee26 · accent_bg_hi #7cc4ee40
       danger #f07878 · danger_bg #f0787826 · warn #e6b465 · ok #79d6a4
       bg_popup #0d0f13ef · bg_sunken #0000004d · border #ffffff1f
       hover #ffffff0f · active #ffffff1a · track #ffffff2b
font:  tiny Inter Medium 8 · small 9 · body 10 · strong Inter SemiBold 10
       mark Inter SemiBold 9 · title 12 · clock 11
radius popup 12 · card 10 · chip 7 · pill 7 ; gap 6
```

Primitives: `esc`, `span`, `set_markup` (dedupes on `_private.aether_markup`),
`text`, `set_text`, `icon`, `set_icon`, `truncate`, `first_letter`, `cell`,
`dot`, `spacer`, `vrule`, `pad`, `center`, `hbox`, `vbox`, `hover`, `chip`,
`app_name`, `app_icon`, `icon_slot`, `surface`, `section`, `key_value`,
`divider`, `slider`, `calendar`, `month_title`, `human`, `rel_time`, `time12`,
`pretty_path`, `basename`.

Two rules the header states and the code enforces: Pango markup is always
escaped (`esc`/`span`), and client titles are never interpolated raw.

---

## 6. Window management

### 6.1 Rules (`awful.rules.rules`, `rc.lua:715-820`)

| # | Match | Properties |
|---|---|---|
| 1 | catch-all | border width/colour, `focus = awful.client.focus.filter`, `raise`, `keys = clientkeys`, `buttons = clientbuttons`, `screen = awful.screen.preferred`, `placement = no_overlap + no_offscreen` |
| 2 | `instance`: DTA/copyq/pinentry; `class`: Arandr, Blueman-manager, Gpick, Kruler, MessageWin, Sxiv, Tor Browser, Wpa_gui, veromix, xtightvncviewer; `name`: Event Tester; `role`: AlarmWindow, ConfigManager, pop-up | `floating = true` |
| 3 | `type = {"normal","dialog"}` | `titlebars_enabled = true` → glass titlebar |
| 4 | `class = "starlight"` | floating, ontop, sticky, skip_taskbar, no border, no titlebar, focus, raise, `screen = launchers.screen_for("starlight")` |
| 5 | `class = "launchpad"` | same, `screen_for("launchpad")` |
| 6 | `class = "Brave-browser"` | `screen` = the pointer screen captured by `Mod4+b` (consume-once) |

Comment rule worth knowing: `launchers.install()` must run **after** the rules
because awesome connects `awful.rules`' manage handler when that module loads
(`rc.lua:823-826`).

### 6.2 Opacity tiers (`glass.lua`)

`target_opacity` (`:159-164`), first match wins:
fullscreen `1.00` → maximized `0.97` → floating `0.92` focused / `0.86` unfocused
→ tiled `0.94` focused / `0.88` unfocused.

`apply_opacity` (`:166-178`) guard order: invalid client → `_aether_placement_pending`
(launcher placement owns the value) → `opacity_exclude` (starlight/launchpad stay
at 1.0 because they carry their own alpha) → tier. Re-applied on `manage`,
`focus`, `unfocus`, and `property::` floating/fullscreen/maximized/vert/horiz
(`:180-192`).

Verified live: unfocused tiled kitty `0.88`, maximized/floating Brave `0.97`.

### 6.3 Glass titlebar (`glass.lua:286-383`)

Only for clients whose rule enables it (normal + dialog). Height 28, top corners
rounded at 12 px (matches picom `corner-radius = 12`), re-shaped on
`property::geometry` and once after 50 ms. Content: 16 px icon + class (left),
title (centre, recoloured on focus/name), state text + macOS traffic lights
(right: `#ff5f57` kill, `#febc2e` minimise, `#28c840` maximise). LMB drags,
RMB resizes. Live clients therefore sit 28 px lower in their frames.

### 6.4 Borders

`border_width = 2`, `border_focus = "#9aa7b8"`, `border_normal = "#3a414d"`
(`glass.lua:52-54`). Alpha in border colours is ignored by awesome (comment
:49-51). Focus/unfocus recolour is wired in `rc.lua:873-874`.

---

## 7. Screens, tags, workspaces

- Tag names per screen: `".", "1" … "9"` (10 tags). Lookup is **by name**
  everywhere, never by index, because the dot shifts positions
  (`dotworkspace.lua:136-165`).
- `dotws.ensure_tags(s)` (`:175-212`) is diff-based: if the names match
  positionally it returns immediately; otherwise it adds the canonical set,
  moves clients across by name, deletes the old tags, and selects workspace 1 if
  nothing is selected. Called at screen creation and once 2.5 s after load.
- Boot selects workspace `1`, never the dot (`rc.lua:226-229`).
- Layouts (13, `rc.lua:107-124`): floating, tile, tile.left/bottom/top, fair,
  fair.horizontal, spiral, spiral.dwindle, max, max.fullscreen, magnifier,
  corner.nw. Every tag starts on `floating` (`dotworkspace.lua:189-191`).
- **Dot policy** (`dotworkspace.lua:218-248`, one `tagged` handler): an ordinary
  client whose *only* tag is the dot is moved to workspace 1 of its screen, which
  is selected. Exempt: `starlight`/`launchpad` (sticky overlays, matched by
  class), any `sticky`/`skip_taskbar` client, non-normal/dialog types, and
  dialogs whose transient parent is on a real workspace (they follow the parent).
  A window toggled onto the dot *alongside* its workspace is intentional and
  stays.
- Dot pill (`workspaces.lua:183-204`): FontAwesome circle tinted with
  `dotws.accent_color` — a pastel derived from the wallpaper by
  `magick '<src>' -resize 1x1! -depth 8 txt:-` (`dotworkspace.lua:93-121`,
  cached per wallpaper, blended 0.55 toward white). Selected = accent + 1 px
  glow border; occupied = `#ffffff0d` + 2 px tick.
- Numbered pills: 24x20, fg ladder urgent → warn, selected → accent_hi,
  occupied → text, else text_faint; tick visible when occupied or selected.

**Super+Tab** (`dragtransfer.lua`):
- no drag → `awful.tag.viewnext` on the focused screen (screen-local, wraps);
- during a drag (`awful.mouse.resize` "mouse.move" context) → first press moves
  only the dragged client to the next screen in cyclic order, selecting that
  screen's tag there (dot → workspace 1), clamping floating geometry into the
  destination workarea and warping the pointer to the grab offset; later presses
  carry the window along the destination's tag cycle. Cooldown 0.25 s.
- Maximized/fullscreen clients never enter a drag at all, so they are never
  transferred by this path; a single-monitor setup makes `other_screen()` nil and
  the drag simply continues.

---

## 8. Bar widgets

**Workspaces** (`workspaces.lua`): `awful.widget.taglist` with a stack-based
pill template (background + label + 2 px tick), custom buttons
(1 view, `Mod4+1` send, `Mod4+3` toggle, 3 actions popover, 4/5 cycle), hover
preview, and `M.panel_rows` for layer 4. The always-running per-screen widgets
are the only state; `pills` is a registry re-painted on `dotws.subscribe`.

**Windower** (`windower.lua`): per-screen "active window" block, 340x28, showing
icon, app name (26 chars), title (38 chars), state (`Tiled`/`Floating`/
`Maximized`/`Fullscreen`/`Minimized`) and `sticky`/`ontop` marks. Falls back to
`Desktop` / `No window focused`. It keeps `last[screen]` so a screen always
shows its last window even when another screen has focus. Left click activates
(and opens controls if already focused), right click opens the classic client
list, hover opens layer 2.

**Clock** (`clock.lua`): two lines, `ui.time12(now)` and `%a %d %b`, 64 px wide,
right-aligned. One self-rescheduling one-shot wakes `60 - seconds + 0.05` after
each minute boundary, so it drifts by nothing. `M.attach` lets the panel reuse
the same painting.

**Media** (`frostbar.lua`): bar mini-player = app · play/pause glyph · artist —
title (capped 26 chars) · seek bar + time. Data: one `playerctl metadata` poll
every 3 s (tab-separated deliberately, titles contain `|`); position poll every
0.5 s only while the media card is open; seek writes are throttled to one per
250 ms with a 1.2 s hold so the poll cannot fight the drag. Single source for
all screens (`media` table). The card is force-closed when the player
disappears.

**Volume** (`frostbar.lua`): icon + `N%`, `wpctl get-volume` every 2 s; wheel =
±5 %; click starts a horizontal scrub (1 %/px, 120 ms throttle, drag suppresses
hover popovers, muted → unmute on first move) with an OSD; a click without
movement focuses the playing app via `busctl` → pid match. The OSD is its own
208x44 wibox (`type="menu"`, `ontop`) centred above the anchor, 0.12 s fade in,
0.15 s fade out 0.35 s after release.

**Keyboard layout / layoutbox / systray**: `awful.widget.keyboardlayout()` per
bar (cannot be shared), `awful.widget.layoutbox(s)` (left/right/wheel cycles
layouts), `wibox.widget.systray()` (only one systray can carry icons — the tray
icons appear on screen 1's bar only).

**Control center** (`control_center.lua`): one `PROBE` shell program per tick
(2.5 s while open, none when closed) reads Wi-Fi radio/SSID, Bluetooth power and
paired/connected devices, brightness, volume/mute, dark mode. Writes: `nmcli
radio wifi`, `bluetoothctl power`, `gsettings … color-scheme`, `wpctl
set-volume`, `wpctl set-mute`, and `sudo -n brightnessctl -q set N%` (defect D8).
Slider writes coalesce into one shell call per 250 ms.

**OpenCode** (`opencode.lua` + `opencode_ui.lua`): reads
`~/.local/state/opencode/service.json` (url/password/version/pid, only
`127.0.0.1` accepted), polls four endpoints through **one** curl + **one** jq
transformation (1.5–2 s `request_timeout`), adaptively: 2 s while working or
waiting, 6 s idle, 10 s offline. Credentials live in a curl config file
(`~/.cache/aether/opencode.auth`, 0600), never on a command line. Usage windows
(5-hour/weekly/monthly) come from `https://opencode.ai/zen/go/v1/usage` with a
300 s TTL and a bearer header file; percentages are normalised across response
shapes. Layer 1 shows `opencode · N` (N = pending permissions + forms) in warn
colour while waiting, `opencode · <project>` while working or idle, `opencode` in
danger on error. Actions: resume session, new session, terminal, copy path,
open project — each gated on `kitty`/`xclip`/`xdg-open`/the CLI.

---

## 9. Wallpaper pipeline

`wallpaper_cycler.lua`, configured from `rc.lua:877-878` with
`directory = ~/wallpapers` (non-recursive scan of
jpg/jpeg/png/bmp/tga; 1800 s interval, 2.0 s crossfade, 16 ms tick).

- One fullscreen wibox per screen (`type="desktop"`, `ontop=false`,
  `input_passthrough=true`), all showing the same image.
- Shuffle bag: every file once per cycle, no immediate repeat, pruned when files
  disappear.
- Cache: `~/.cache/awesome-wallpaper/<md5 of src|mtime|WxH>.jpg`, baked
  off-thread by `magick -resize WxH^ -gravity center -extent WxH -strip -quality 95`,
  in-thread fallback when the cache is cold (prints a line, costs one frame).
- Crossfade: smoothstep alpha + 1.04 → 1.0 zoom on the incoming surface; idle
  cost is zero (the timer stops between fades).
- `sync_root()` also sets the X root pixmap so the pre-map moment does not flash
  the stock theme wallpaper.
- State: `~/.cache/awesome-wallpaper/current` remembers the shown image across
  restarts (a reload keeps it instead of picking a new one).
- Screens: `connect_for_each_screen(attach)` covers screens added later, and
  `attach` now paints the current wallpaper immediately (a screen added at
  runtime used to stay black until the next switch); geometry changes rebuild
  surfaces; removed screens are hidden (no `wibox:destroy` in 4.3).
- Public API: `setup`, `stop`, `next`, `preview(seconds)`, `status()`,
  `frames()`, `subscribe(fn)`. Consumers: `frostbar` (strips) and
  `dotworkspace` (accent).

---

## 10. Compositor

`~/.config/picom/picom.conf` (byte-identical to `system/picom.conf`): GLX
backend, vsync, `detect-client-opacity = true`, `blur-background` +
`blur-method = "dual_kawase"` + `blur-strength = 8` (fixed, so the material looks
constant across opacity tiers), `corner-radius = 12`, shadows
(radius 18, opacity 0.35, offset 0/6), fading, `unredir-if-possible`. Windows are
excluded from rounding/shadow/blur when they are `class_g 'awesome'` normal
windows (the bar and titlebar are shaped by glass), desktop/dock/notification
windows, or fullscreen.

Lifecycle is owned by `glass.lua`: `start_compositor()` probes
`command -v picom && pgrep -x picom` and spawns
`picom --config <path> --daemon` only if absent; a 15 s watchdog re-probes and
respawns; `restart_compositor()` does `pkill -x picom` then restart. No
compositor ⇒ windows render opaque; the WM is unaffected.

---

## 11. Launchers (placement authority)

`launchers.lua` exists because GTK4 toplevels map at a preliminary geometry and
then send a `ConfigureRequest` with (0,0), which awesome honours for floating
clients — rule-time placement always loses (defect D1).

Algorithm: `M.spawn(class)` records `mouse.screen` and the timestamp *before*
the process exists; the window rules read `M.screen_for(class)`; on `manage` the
entry is consumed, the client is hidden (`opacity = 0`,
`_aether_placement_pending = true`), centred with the size GTK mapped with, and
revealed 80 ms after the last `property::geometry` change (hard cap 500 ms), with
re-centring on every subsequent geometry event for the client's lifetime.
`glass.apply_opacity` returns early while the marker is set, which is what stops
the corner flash (defect D10). `M.install()` is idempotent and must be called
after the rules.

`M.has_open_launcher()` feeds `rc.lua`'s sloppy-focus handler so a crossing event
from the launcher's own resize cannot hand focus to the window underneath (D5).

### 11.1 Launchpad is rofi

**The "Launchpad" on this desktop is rofi.** There is no `launchpad` binary: its
repo and `~/.local/bin` wrapper went with the AETHER removal, and no copy exists
under `~/projects` (only `starlight` does). So `Mod4+e` runs

```
rofi -show drun          # searchable application launcher
rofi -show window        # Mod4+Shift+O: every open window, all screens
```

via `launchers.search(mode)` (`launchers.lua`), which probes `command -v rofi`
once, spawns it, and raises the same rate-limited notice as the GTK launchers if
it is missing (flow FL1 — no silent dead end). The key is registered with the
rest of `globalkeys`, **not** by the deferred timer: a 0.5 s re-grab could fail
silently after a restart (the binding showed up in `root.keys()` yet never
fired, which is how the launcher keys were lost before).

If Starlight/Launchpad are ever rebuilt, the placement machinery in §11 still
applies to `class = "starlight"` / `class = "launchpad"`; the keys would then be
rebound from `launchers.search(...)` back to `launchers.spawn(...)`.

`Alt+Space` (Starlight) is still bound to a binary that does not exist: pressing
it raises the "not installed" notice instead of doing nothing silently.

---

## 12. Keybindings (current)

`Mod4` = Super. Registered in `rc.lua` `globalkeys`; only `Alt+Space` is added
by a 0.5 s timer (its GTK client needs `launchers.install()` to have run). The
`Mod4+e` / `Mod4+Shift+O` / `Mod4+b` bindings were moved into `globalkeys`
because a deferred re-grab can fail silently and awesome then caches the
combination as grabbed — the key appears in `root.keys()` and never fires.

| Keys | Action |
|---|---|
| `Mod4+s` | hotkeys help |
| `Mod4+a` | expanded AETHER panel (layer 4) |
| `Mod4+d` | dot wallpaper showcase |
| `Mod4+Left/Right` | previous/next workspace |
| `Mod4+Escape` | workspace history back |
| `Mod4+j/k` | focus next/previous client |
| `Mod4+Shift+j/k` | swap client by index |
| `Mod4+Ctrl+j/k` | focus next/previous screen |
| `Mod4+u` | jump to urgent |
| `Mod4+Tab` | next workspace on this screen; mid-drag → transfer window to the other monitor |
| `Mod4+Return` | terminal (`x-terminal-emulator`) |
| `Mod4+Ctrl+r` | restart awesome |
| `Mod4+Shift+q` | quit awesome |
| `Mod4+q`, `Alt+F4` | close focused client |
| `Print` | screenshot to `~/Pictures/Screenshots/` |
| `Mod4+l` | lock (`xsecurelock`) |
| `Alt+h/l` | master width ∓0.05 |
| `Mod4+Shift+h/l` | master count ±1 |
| `Mod4+Ctrl+h/l` | column count ±1 |
| `Mod4+space`, `Mod4+Shift+space` | next/previous layout |
| `Mod4+Ctrl+n` | restore minimized |
| `Mod4+r` | run prompt |
| `Mod4+x` | Lua prompt |
| `Mod4+p` | menubar |
| `Mod4+w` | main menu |
| `Mod4+1..9` / `Mod4+Ctrl+1..9` | view / toggle workspace |
| `Mod4+Shift+1..9` / `Mod4+Ctrl+Shift+1..9` | move client / toggle client on workspace |
| `Mod4+f` | fullscreen |
| `Mod4+Shift+c` | close (client key) |
| `Mod4+Ctrl+space` | toggle floating |
| `Mod4+Ctrl+Return` | move to master |
| `Mod4+o` | move to screen |
| `Mod4+t` | toggle keep-on-top |
| `Mod4+n` | minimize |
| `Mod4+m` / `Mod4+Ctrl+m` / `Mod4+Shift+m` | maximize / vertical / horizontal |
| `Mod4+e` | **launchpad = rofi**: `rofi -show drun` (searchable applications) |
| `Mod4+Shift+O` | `rofi -show window` (search every open window, all screens) |
| `Mod4+b` | Brave on the screen under the pointer |
| `Alt+Space` | Starlight search (**binary not installed** — raises a notice) |
| `Escape` | dismiss a modal surface (grabbed only while one is open) |
| `BackSpace` | up one surface layer; dismisses when there is nothing to go back to |

Mouse: root `3` main menu, wheel next/prev workspace; clients
`1` activate, `Mod4+1` move, `Mod4+3` resize; workspace pill `1/Mod4+1/Mod4+3/3/4/5`
as listed in §8; windower block left = activate (+controls), right = client list;
layoutbox click/wheel cycles layouts; clock click pins the calendar.

---

## 13. External dependencies and degradation

| Dependency | Used by | If missing |
|---|---|---|
| `picom` (pijulius v13) | glass | no blur/rounding/shadow; windows opaque; watchdog retries every 15 s |
| `magick` | wallpaper + frost strips | in-thread fallback per switch (visible stall), no dot accent (falls back to AETHER accent) |
| `wpctl` | volume widget, control center | reads/writes no-op (`2>/dev/null \|\| true`); UI keeps working |
| `playerctl` | media widget, card | widget hides, card refuses to open |
| `nmcli`, `bluetoothctl`, `gsettings` | control center | rows show unavailable; switches no-op |
| `brightnessctl` (+ `sudo -n`) | control center | brightness slider inert |
| `busctl` | volume click-to-focus | click does nothing |
| `curl`, `jq`, `opencode`, `kitty`, `xclip`, `xdg-open` | OpenCode integration | state `offline` with a reason string; action chips hidden |
| `starlight`, `launchpad` | launchers | bindings silently dead |
| `xsecurelock`, `import`, `x-terminal-emulator` | keys | spawn fails, WM fine |
| `lgi`, `lfs` | wallpaper/frost/opencode | `require` fails ⇒ rc.lua errors at load |

---

## 14. Known gaps, dead code, stale docs

### 14.1 Open work
1. **Starlight missing** (§11) — `Alt+Space` raises a notice. `Mod4+e` is now
   rofi, so an application launcher works. Options:
   rebuild the GTK apps, or rebind those two keys.
2. **No `docs/06-five-layer-bar.md`** — `rc.lua:27` cites it; §5 of this file is
   the replacement.
3. **Brightness via blanket passwordless sudo** (D8) — wants a udev/polkit
   helper.
4. **Subprocess polling** (D9) — `wpctl` every 2 s, `playerctl` every 3 s,
   control center every 2.5 s while open.
5. **Wallpaper surface cache is unbounded** between switches (memory grows with
   each geometry).
6. **Launcher open latency** is dominated by GTK process start (~250 ms); the
   remaining win needs a persistent launcher process.

### 14.2 Dead code / dead state (verified)
- `widgets/volume.lua`, `widgets/brightness.lua`, `widgets/seekbar.lua` and
  `widgets/animated_slider.lua` have **no require sites** (only
  `seekbar → animated_slider`). The live bar uses frostbar's polling and
  `ui.slider`. The event-driven versions (`pw-mon`, `playerctl -F`) are unused.
- Unused: `workspaces.label_for_client`, `client_state`, `windower.open_controls`
  (exported but only called internally), `frostbar.close_media` (exported; the
  local function is used by the media poll and `toggle_media`),
  `frostbar.poll_debug` (diagnostics hook for `awesome-client`),
  `anim.stop`, `anim.ease.linear/out_back`, `M.radius`, `M.gap`,
  `ui.text_strong`, `ui.bg_sunken`, `ui.active`, `ui.font.title`, `ui.font.clock`,
  `ui.basename`, `dotworkspace.config.destination`, `clock.subscribe`,
  `animated_slider.M.debouncer`, `animated_slider`'s `handle_color`/`muted`.
- Write-only state: `s._bar_revealed`, `dragtransfer.state.source_screen/source_tag`,
  `control_center.state.bright`.
- Duplicated logic worth refactoring if touched: two tween engines
  (`anim.lua` + `animated_slider`), five markup-dedupe variants, two
  bar-anchored placement routines (`popover.place` vs `frostbar.osd_show`), two
  volume/media backends (polling vs the unused event-driven ones).
- Debug output left in the shipping path: `print("AETHERDEBUG close …")` on
  every popover close (`popover.lua:264`).

### 14.3 Stale documentation
- `docs/00-audit.md` and `docs/02-verification.md` assume a **30 px** bar
  (`ui.bar_height` is 38) and picom 12.5 (v13 is installed).
- `glass.lua:22-24` says titlebars "are disabled in rc.lua's rules"; the rules
  enable them for normal/dialog (`rc.lua:763-765`).
- `README.md` mixes the AETHER description with the earlier "full backup" text.
- `docs/01-rollback.md` references tarballs under `~/.local/share/aether/backups/`
  and `~/projects/{starlight,launchpad}` that no longer exist.

---

## 15. Verification and safe workflow

```bash
# 1. Syntax (Lua 5.4 loader; awesome runs 5.3, close enough for syntax)
cd ~/.config/awesome && for f in *.lua widgets/*.lua; do
  lua -e "local ok,e=loadfile('$f'); if not ok then print('FAIL $f: '..tostring(e)) end"; done

# 2. Reload + check only what this reload produced
date '+%Y-%m-%d %H:%M:%S' > /tmp/reload-start
awesome-client 'awesome.restart()'
sleep 3
journalctl --user -b --no-pager --since "$(cat /tmp/reload-start)" | grep 'E: awesome'

# 3. State probes
awesome-client 'return string.format("%s tags=%d screens=%d clients=%d",
  awesome.version, #screen[1].tags, screen.count(), #client.get())'
xrandr --listactivemonitors

# 4. Runtime behaviour (does not need a reload)
awesome-client 'local c=client.focus; if c then c.fullscreen=true end'
#   → screen[1].mywibox.visible must become false; toggling back restores it
```

Pass criteria (from `docs/02-verification.md`): no `E: awesome` lines, no syntax
failures, bars reappear, clients keep geometry, only one popover at a time, and
launcher placement delay stays under 120 ms (`tools/bench-launcher.sh`).

Recovery: a broken `rc.lua` falls back to `/etc/xdg/awesome/rc.lua` and the
session keeps running; fix with `git -C ~/.config/awesome checkout <commit> -- <file>`
then reload. Stuck compositor: `pkill -x picom` + `require("glass").restart_compositor()`.

---

## 16. Conventions when changing this config

- UI values come from `ui.lua`; do not hardcode colours or fonts in a module.
- Escape text in markup (`ui.span`/`ui.esc`); never interpolate a client title raw.
- Anything above the bar goes through `popover.lua` (one surface at a time),
  not a new wibox, unless it is a HUD like the volume OSD.
- Long-running I/O is async (`awful.spawn.easy_async*`) and coalesced; nothing
  shells out on the WM thread.
- Keep the degrade-cleanly rule: a missing binary must never break the bar.
- Comments explain **why** (the file is full of "this exists because awesome
  does X" notes); preserve that style and cite defect IDs (D1…D11) where relevant.
- Record any behaviour claim with a probe or a capture in `docs/02-verification.md`,
  and any fixed defect in `docs/03-defects.md`.
- Do not commit to `~/.config/awesome` unless asked; HEAD is `50ec77b` and three
  files are currently modified (see below).

---

## 17. Current working-tree state (2026-11-23)

`git -C ~/.config/awesome status`: modified `glass.lua` (notification icon
lookup: Papirus + svg + 48 px), `wallpaper_cycler.lua` (paint the current
wallpaper on screens attached after setup), `system/awesome-dual-display`
(`systemctl --user set-environment` needs `NAME=VALUE`; the bare-name form failed
every login). Everything else is clean at HEAD `50ec77b`.
