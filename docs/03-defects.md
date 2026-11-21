# 03 — Defect register

Every entry has a reproduction, the root cause, the fix (if any) and how it was
verified. "Open" means the defect is documented but not yet fixed; it must be
fixed before AETHER 1.0 if marked *critical* or *high*.

Severity: **critical** = data loss / unusable session; **high** = breaks a core
workflow; **medium** = visible defect or reliability risk; **low** = cosmetic.

---

## D1 — GTK launchers map at a preliminary geometry and ConfigureRequest(0,0)

**Severity:** high (fixed) · **Files:** `launchers.lua`, `rc.lua` · **Status:** fixed

**Reproduction.** Start with the launcher rules placing the window (no
`launchers.lua`): press `Alt+Space` with the pointer on `HDMI-0`. The window
first maps at the screen origin, then GTK sends a `ConfigureRequest` with
position (0,0), which Awesome honours for floating clients; the launcher ends
up on `eDP-1-1` at the top-left.

**Root cause.** GTK4 toplevels pick their size/position after the X window is
created. Rule-time placement runs before that request and is overwritten.

**Fix.** `launchers.lua` owns placement: it records the spawn screen, marks the
client `_aether_placement_pending`, centres it on every geometry event and
reveals it once the size is stable. `glass.lua` leaves the opacity alone while
the marker is set.

**Verified.** Geometry on both screens (2026-11-21):
screen 1 (1920x1050 work area) → `618,284 684x542` for Starlight and
`426,211 1068x688` for Launchpad; screen 2 (1680x1020) → `2418,269 684x542` and
`2226,196 1068x688`. All are exact centres.

---

## D2 — `reveal_timer` resolves to a global inside its own callback

**Severity:** high (fixed) · **File:** `rc.lua` · **Status:** fixed

**Reproduction.** Make any client fullscreen (`Mod4+f`). `update_bars()` hides
the wibar and starts `reveal_timer`. The callback raises
`rc.lua:331: attempt to index a nil value (global 'reveal_timer')` every 80 ms.
Each error also triggers `naughty.notify` through the `debug::error` handler.

**Root cause.** `local reveal_timer = gears.timer{ ... callback references
reveal_timer ... }`: the initializer cannot see the local being declared, so the
name resolves to the global (nil). The timer never stops and keeps polling
`mouse.coords()` forever.

**Evidence.** 6523 identical journal errors in one session between 14:50 and
14:59.

**Fix.** Declare `local reveal_timer` first, assign the timer on the next
statement, with a comment explaining why the split is required.

**Verified.** Zero `E: awesome` entries after a reload and after toggling a
fullscreen client; the timer stops when no bar is hidden.

---

## D3 — Launchpad builds every grid tile with a tooltip (271–784 ms)

**Severity:** high (fixed) · **File:** `launchpad.js` · **Status:** fixed

**Reproduction.** Time the construction of the grid: 54 ×
`new Gtk.Button({child, has_frame:false, css_classes, tooltip_text:'X'})`.
Measured 271 ms with a tooltip, 784 ms with a tooltip + CSS class, 2–3 ms
without any tooltip. The whole window is built before `present()`, so this
delay is fully on the open path.

**Root cause.** GTK creates a tooltip controller and resolves the tooltip
machinery per button that has `tooltip_text`; the label under the icon already
shows the application name, so the tooltip is redundant.

**Fix.** Remove `tooltip_text` from the tile (commented to prevent
reintroduction).

**Verified.** `manage` time for Launchpad dropped from 589–865 ms to 248–271 ms
(see `docs/05-performance.md`).

---

## D4 — Placement waits 350 ms for size hints that are never set at map time

**Severity:** medium (fixed) · **File:** `launchers.lua` · **Status:** fixed

**Reproduction.** Instrument the manage handler: at manage,
`c.size_hints.max_width`/`max_height` are `nil`. They only appear after the WM
has already moved the client, so `at_final_size()` cannot become true and the
old `HINT_WAIT` timer always fired at 350 ms.

**Root cause.** GTK4 publishes `min == max` only after the first
`ConfigureRequest` round trip; waiting for hints is a fixed 350 ms penalty.

**Fix.** Replace hint-based readiness with size stability: reveal 80 ms after
the last size change (hard cap 500 ms), while re-centring on every geometry
event.

**Verified.** Placement delay (manage → visible) is now 78–112 ms.

---

## D5 — Launcher dismisses itself when sloppy focus picks the window underneath

**Severity:** high (fixed) · **Files:** `launchers.lua`, `rc.lua` · **Status:** fixed

**Reproduction.** Open Starlight with the pointer over a tiled area, then let
its content resize (async results). X emits a crossing event for the window
under the pointer; `mouse::enter` moves focus there; GTK reports
`is-active=false` and the app calls `close()`. Reproduced 3 of 8 cold opens
(pointer at 700,600, screen 1). With a fullscreen client focused the same test
failed 3 of 3 before the fix.

**Root cause.** Spotlights dismiss on blur, but the launcher is a *modal*
overlay: the pointer moving (or a transient crossing event from the launcher's
own resize) must not hand focus to a client underneath it while it is open.

**Fix.** `launchers.has_open_launcher()` reports a visible, past-placement
launcher; `rc.lua`'s `mouse::enter` handler ignores focus requests while one is
open. Clicking a client still activates it through the button bindings (that is
the intended dismissal path).

**Verified.** 8/8 Starlight opens stable with the pointer inside the launcher
area; 3/3 with a fullscreen client focused on the same screen; the launcher
stays focused and centred.

---

## D6 — Starlight logs a Wayland/layer-shell CRITICAL on X11

**Severity:** low (open) · **File:** `starlight.js` · **Status:** open

**Reproduction.** Start Starlight under X11; stderr contains
`init_and_get_layer_shell_global: assertion 'GDK_IS_WAYLAND_DISPLAY
(gdk_display)' failed`, then the graceful "layer-shell unsupported" warning.
Everything works; only the log is noisy.

**Cause / fix.** `LayerShell.is_supported()` is called before the display type
is checked, and the Gtk4LayerShell import has already tried to initialise. A
`Gdk.Display.get_default()` type check before touching `LayerShell` would keep
the log clean. Cosmetic, deferred to the launcher cleanup pass.

---

## D7 — Spawn-screen memory uses `os.time()` with a TTL

**Severity:** low (fixed) · **File:** `launchers.lua` · **Status:** fixed

**Reproduction.** Record the pointer's screen, wait >2 s, then let the window
map: the remembered screen is ignored because `os.time()` has 1 s resolution
and the TTL was 2 s. A slow cold start could lose the intended monitor.

**Fix.** The remembered screen is consumed by the next manage of that class, so
the TTL is now only a safety net for a manually started launcher (5 s).

---

## D8 — Brightness writes run `sudo -n brightnessctl` from a UI control

**Severity:** medium (open) · **File:** `control_center.lua` · **Phase 3**

**Reproduction.** Drag the brightness slider: each step spawns `sudo -n
brightnessctl -q set N%`. `sudo -n true` succeeds on this machine, so it works,
but a desktop control should not need blanket passwordless sudo.

**Fix direction.** Install a narrow udev rule (or a polkit helper) granting the
`video` group write access to `/sys/class/backlight/intel_backlight/brightness`,
then drop `sudo` from the command. Must be verified with
`brightnessctl --device=intel_backlight set 50%` as the normal user.

---

## D9 — Bar widgets poll with shell forks every 2–3 s

**Severity:** medium (open) · **Files:** `frostbar.lua`, `control_center.lua` · **Phase 3/4**

**Reproduction.** `ps -eo pid,ppid,cmd` shows `sh -c wpctl ...` every 2 s and
`playerctl metadata ...` every 3 s per session. Each is a fork+exec and a D-Bus
round trip; it is not event-driven.

**Fix direction.** Switch audio to the PipeWire/WirePlumber event stream (or
`wpctl` on a longer interval with invalidation on `pactl subscribe`), and MPRIS
to `playerctl -F` with a single long-lived watcher. Both must degrade cleanly
when the tool or the service is missing.

---

## D10 — `glass.apply_opacity` re-shows a launcher during placement

**Severity:** high (fixed) · **File:** `glass.lua` · **Status:** fixed

**Reproduction.** Open a launcher on a cold cache and watch the screen: the
window is briefly visible at the screen origin before it is centred. Log
`property::opacity` at manage: `1.0` (glass), focus event `1.0` again, then the
launcher sets `0`, but a later focus event sets `1.0` before placement
completes.

**Root cause.** `glass.apply_opacity` runs on every focus change and
unconditionally set `1.0` for launcher classes, overriding the placement
authority's hidden state.

**Fix.** `apply_opacity` returns early while
`c._aether_placement_pending` is set; the placement authority owns opacity
until the window is in its final position.

**Verified.** 60 fps capture of a cold Launchpad open on screen 2: the corner
patch of the screen is unchanged (mean 0.5303) across the whole sequence, while
the centre changes only when the centred panel appears. Launchpad's first
visible frame is centred.

---

## D11 — Fullscreen client hides the bar and changes the work area

**Severity:** low (by design) · **File:** `rc.lua` · **Status:** documented

The wibar's strut disappears when `update_bars()` hides it for a fullscreen
client, so `scr.workarea` becomes the full screen geometry. Launchers then
centre in the full screen (e.g. y=269 instead of 284 on screen 1). This is
correct behaviour — placement always uses the work area that exists at
placement time, not the one at spawn time. No fix required; keep it in mind
when comparing screenshots.
