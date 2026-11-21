# 00 — Baseline audit (Phase 0)

Read-only audit of the live system, performed before any AETHER change.
Everything below was verified on the running session unless marked
*(assumption)*.

## 1. Host and graphics stack

| Item | Value (verified) |
|------|------------------|
| OS | Ubuntu 26.04.1 LTS, kernel `7.0.0-43-generic` |
| X server | X.Org 1.21.1.22, X11 session (`XDG_SESSION_TYPE=x11`) |
| GPU | Intel CometLake-H UHD (`00:02.0`) + NVIDIA TU106M RTX 2060 Mobile (`01:00.0`) |
| Layout | NVIDIA is X screen 0's primary GPU; Intel (modesetting) is slaved as an output source |
| Compositor | picom 12.5, GLX backend, dual_kawase blur, `unredir-if-possible = true` |
| WM | awesome 4.3 (Lua 5.3.6, LGI 0.9.2, xcb-randr 1.6) |
| GTK launchers | GTK 4.22.4 via gjs 1.88.0 |
| Image tooling | ImageMagick 7.1.2 (`magick`, `import`) |

Package versions: `awesome 4.3-8.1`, `picom 12.5-1build1`, `libgtk-4-1
4.22.4+ds-0ubuntu0.2`, `gjs 1.88.0-1`, `imagemagick 8:7.1.2.18+dfsg1-1`,
`lua-filesystem 1.9.0-1`, `lua-lgi 0.9.2-7`.

## 2. Session startup chain

1. GDM starts the **awesome (dual display)** session
   (`/usr/share/xsessions/awesome-dual.desktop`).
2. Its `Exec` is `/usr/local/bin/awesome-dual-display` (reference copy in
   `system/awesome-dual-display`). The script:
   - finds the NVIDIA and modesetting providers by name and runs
     `xrandr --setprovideroutputsource <modesetting> <nvidia>` so both panels
     join X screen 0 (this must happen before awesome starts),
   - detects connected `eDP*` / `HDMI*` outputs dynamically,
   - applies `eDP-1-1 --primary --auto`, `HDMI-0 --mode 1680x1050 --rate 59.95
     --right-of eDP-1-1`,
   - exports `XDG_SESSION_TYPE=x11`, `XDG_CURRENT_DESKTOP=awesome`,
     `DESKTOP_SESSION=awesome-dual`, pushes them into systemd/D-Bus,
   - `exec awesome`.
3. awesome runs `~/.config/awesome/rc.lua` (`awesome.conffile`).
4. `rc.lua` loads the theme defaults, then `glass.setup()` (theme + opacity
   signals), builds one wibar per screen, applies rules, installs the launcher
   placement handler, starts the wallpaper cycler and, at the very end,
   `glass.start_compositor()` (picom + 15 s watchdog).

Log: `~/.cache/awesome-display.log` (session script), journal (awesome stdout).
The session script is **outside** this repo; `system/` keeps a reference copy.

## 3. Displays and work areas (verified)

```
Monitors: 2
 0: +*eDP-1-1 1920/344x1080/194+0+0   (primary)
 1: +HDMI-0  1680/476x1050/268+1920+0 (right of eDP)
```

| Screen | Geometry | Work area (bar visible) | Tags |
|--------|----------|-------------------------|------|
| 1 (`eDP-1-1`) | 0,0 1920x1080 | 0,30 1920x1050 | 9 |
| 2 (`HDMI-0`) | 1920,0 1680x1050 | 1920,30 1680x1020 | 9 |

The 30 px work-area offset is the wibar strut. When a fullscreen client is
visible on a screen, `update_bars()` hides that bar and the work area grows to
the full screen geometry (verified: launcher centring then uses y=269 instead of
284 on screen 1). Placement must therefore read `scr.workarea` at the moment of
placement, not at spawn time.

## 4. Modules and ownership

| File | Responsibility | State held |
|------|----------------|-----------|
| `rc.lua` | tags, wibars, rules, keys/buttons, autohide, screenshot, Brave screen memory | `s.mywibox`, `s._bar_hidden` |
| `glass.lua` | theme keys, opacity tiers, picom spawn/watchdog, titlebars | watchdog timer |
| `frostbar.lua` | bar backdrop surfaces, song/volume/usage widgets, media popover | per-screen strip cache, `media` table |
| `control_center.lua` | Wi-Fi/BT/brightness popover, bar button | switch state, pending brightness |
| `launchers.lua` | capture spawn screen, hide → centre → reveal GTK launchers | `target[class]` |
| `wallpaper_cycler.lua` | shared wallpaper, crossfade, cache baking | screens, bag/seen, `current/pending` |
| `anim.lua` | tagged 60 fps tweens | `active[tag]` |

Cross-module coupling: `frostbar` requires `wallpaper_cycler` and `anim`;
`control_center` and `frostbar` lazily require each other to close popovers (no
load cycle); `rc.lua` owns everything else. `glass.setup()` runs before the bars
and rules so its `manage` handler is registered first.

## 5. External commands referenced by the config

All verified present on PATH:

| Command | Used by | Guard in code |
|---------|---------|---------------|
| `magick` | wallpaper/strip cache baking | async `easy_async_with_shell` |
| `playerctl` | media widget, popover | `2>/dev/null \|\| true` |
| `wpctl` | volume widget, popover | `2>/dev/null \|\| true` |
| `nmcli` | control center Wi-Fi | `2>/dev/null \|\| true` |
| `bluetoothctl` | control center Bluetooth | `2>/dev/null` |
| `brightnessctl` | control center brightness | read unprivileged; write via `sudo -n` |
| `picom` | `glass.start_compositor` | `command -v` + `pgrep` before spawn |
| `xsecurelock` | `Mod4+l` | spawn |
| `import` | `Print` screenshot | `mkdir -p && import` |
| `jq`, `opencode` | usage widget | `PATH=... opencode stats ... \| jq` |
| `busctl` | `frostbar.focus_player` | `2>/dev/null` |
| `x-terminal-emulator` | terminal keybinding/menu | spawn |
| `bash`, `gjs` | launcher wrappers | — |

`sudo -n true` succeeds: the user has passwordless sudo. Brightness writes are
therefore functional, but they are still a privileged command launched from a
UI interaction (see defect D8 / Phase 3).

## 6. Runtime state and caches

- `~/.cache/awesome-wallpaper/` — screen-sized cover-fit JPEGs, one per
  wallpaper/size (30 files, ~12.5 MB at audit time); `current` remembers the
  shown path across restarts.
- `~/.cache/awesome-wallpaper-bar/` — bar-height blurred strips, one per
  wallpaper/screen size (28 files); baked by `magick` off the WM thread.
- Launcher pidfiles: `/run/user/1000/starlight.pid`, `launchpad.pid`
  (toggle wrappers kill the previous instance).
- Starlight ranking history: `~/.local/state/starlight/usage.json`.
- Memory at audit (3 clients, 2 screens): awesome 160 MB RSS, picom 129 MB RSS.

## 7. Keyboard bindings (baseline — must be preserved)

`Mod4` = Super. Full list from `rc.lua`; the AETHER work must not remove or
rebind any of these without explicit approval.

| Binding | Action |
|---------|--------|
| `Mod4+s` | hotkeys help |
| `Mod4+Left/Right` | previous/next tag |
| `Mod4+Escape` | tag history back |
| `Mod4+j/k` | focus next/previous client |
| `Mod4+w` | main menu |
| `Mod4+Shift+j/k` | swap client by index |
| `Mod4+Ctrl+j/k` | focus next/previous screen |
| `Mod4+u` | jump to urgent |
| `Mod4+Tab` | next tag on focused screen |
| `Mod4+Return` | terminal |
| `Mod4+Ctrl+r` | restart awesome |
| `Mod4+Shift+q` | quit awesome |
| `Mod4+q`, `Alt+F4` | close focused app |
| `Print` | screenshot to `~/Pictures/Screenshots` |
| `Mod4+l` | lock (xsecurelock) |
| `Alt+l / Alt+h` | master width ±0.05 |
| `Mod4+Shift+h/l` | master count ±1 |
| `Mod4+Ctrl+h/l` | column count ±1 |
| `Mod4+space`, `Mod4+Shift+space` | next/previous layout |
| `Mod4+Ctrl+n` | restore minimized |
| `Mod4+r` | run prompt |
| `Mod4+x` | Lua prompt |
| `Mod4+p` | menubar |
| `Mod4+f` | fullscreen |
| `Mod4+Shift+c` | close (client key) |
| `Mod4+Ctrl+space` | toggle floating |
| `Mod4+Ctrl+Return` | move to master |
| `Mod4+o` | move to screen |
| `Mod4+t` | toggle keep-on-top |
| `Mod4+n` | minimize |
| `Mod4+m`, `Mod4+Ctrl+m`, `Mod4+Shift+m` | maximize / vertical / horizontal |
| `Mod4+1..9` | view tag |
| `Mod4+Ctrl+1..9` | toggle tag |
| `Mod4+Shift+1..9` | move client to tag |
| `Mod4+Ctrl+Shift+1..9` | toggle client on tag |
| `Alt+Space` | Starlight search |
| `Mod4+e` | Launchpad app grid |
| `Mod4+b` | Brave on the pointer's screen |
| `Mod4+Left/Right drag`, `Mod4+Right drag` | move/resize client (client keys) |
| Root `right click` | main menu |
| Root `scroll` | next/previous tag |

`Alt+Space`, `Mod4+e` and `Mod4+b` are registered 0.5 s after load by a timer
(comment: grabs during config load can fail silently on restart). This is a
deliberate workaround; keep it unless a safer registration point is proven.

## 8. Compositor lifecycle (as implemented)

- `glass.setup()` registers opacity handlers, not the compositor.
- `glass.start_compositor()` (last line of `rc.lua`): if picom is not running,
  spawn `picom --config ~/.config/picom/picom.conf --daemon`; then a 15 s
  watchdog re-checks `command -v picom && pgrep -x picom` and respawns.
- `glass.restart_compositor()` exists for config tweaks via `awesome-client`.
- Degradation: without picom, `client.opacity` is ignored; windows stay opaque
  instead of failing. Blur/rounding/shadow disappear.

## 9. Performance baseline (measured, 2026-11-21)

Tool: `tools/bench-launcher.sh` (monotonic clock inside the WM).
Values are milliseconds from the `launchers.spawn()` call.

| Launcher | run | manage | visible | placement delay |
|----------|-----|--------|---------|-----------------|
| Launchpad (`Mod4+e`) | 1 | 641 | 991 | 350 |
| | 2 | 865 | 1216 | 351 |
| | 3 | 589 | 940 | 351 |
| Starlight (`Alt+Space`) | 1 | 294 | 329 | 35 |
| | 2 | 287 | 324 | 37 |
| | 3 | 312 | 348 | 36 |

Component breakdown (GTK side, instrumented copy, `GLib.get_real_time`):

| Phase | Time |
|-------|------|
| gjs + GTK init → `activate` | 80–95 ms |
| `AppIndex` scan (54 showable apps) | 14 ms |
| Build 54 grid tiles | **49–535 ms** (bimodal; `tooltip_text` dominated) |
| `present()` → first frame | 115–140 ms |
| `present()` → awesome `manage` | 53 ms |
| Placement wait (hints) | 350 ms |

Microbenchmark: `new Gtk.Button({tooltip_text = 'X'})` ×54 = 271 ms; with a
child and `css_classes` = 784 ms; without a tooltip = 2–3 ms.

Journal finding: 6523 `E: awesome` errors in one session, all
`rc.lua:331: attempt to index a nil value (global 'reveal_timer')`, emitted at
the reveal timer's 80 ms interval.

## 10. Defect register summary

`docs/03-defects.md` is authoritative and tracks status (D1–D11 below are the
defects found during this audit; D10/D11 were isolated while verifying the
launcher fixes).

| ID | Severity | Summary |
|----|----------|---------|
| D1 | high | GTK launchers map at a preliminary geometry and send ConfigureRequest(0,0); rule-time placement cannot work |
| D2 | high | `reveal_timer` is a global inside its own callback → error every 80 ms, notification spam, timer never stops |
| D3 | high | Launchpad builds 54 tiles with `tooltip_text` → 271–784 ms before the window is presented |
| D4 | medium | Placement waits 350 ms for `size_hints.max_*`, which are nil at manage and only appear after a WM resize |
| D5 | high | Launcher focus/visibility under a fullscreen client is not reliable (intermittent self-close; observed once, not yet reproducible) |
| D6 | low | Starlight prints a GTK CRITICAL on X11 when probing layer-shell, despite the graceful fallback |
| D7 | low | Launchpad/Starlight spawn screen memory uses `os.time()` (1 s resolution) with a 2 s TTL |
| D8 | medium | Brightness writes run `sudo -n brightnessctl` from a UI control (needs udev/permission alternative) |
| D9 | medium | Bar widgets fork shell commands every 2–3 s (volume, media); event-driven alternatives not yet evaluated |

## 11. Phase 0 conclusion

The configuration is working and internally coherent. The two launchers are
functionally correct on both monitors today, but their open path is slow
(bimodal GTK widget construction + a fixed 350 ms placement wait) and the
fullscreen interaction is not verified. The autohide `reveal_timer` bug is
actively spamming the WM's event loop and generating notifications. These are
the first targets; Phase 2+ visual and service work follows only after the
window-management path is reliable and measured.
