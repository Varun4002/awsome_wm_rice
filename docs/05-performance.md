# 05 — Performance baseline and results

Measured on the live session, 2026-11-21, Ubuntu 26.04, awesome 4.3.

## Method

- **Latency:** `tools/bench-launcher.sh <class> <runs>` records monotonic
  timestamps *inside the WM*: the `launchers.spawn()` call, the `manage` signal
  and the reveal (opacity 1). No shell round-trip is in the measured path.
- **GTK-side breakdown:** an instrumented copy of `launchpad.js` printing
  `GLib.get_real_time()` deltas (module load, activate, AppIndex, tiles,
  `present`, first frame). Instrumentation was removed afterwards.
- **Visual proof:** 60 fps `ffmpeg` x11grab capture, frame-by-frame mean
  brightness of the corner and centre regions.
- **Journal:** `journalctl --user -b` filtered for `E: awesome`.

Machine state during the runs: 2 screens, 3–4 clients, picom 12.5 running,
wallpaper caches warm (30 screen-sized images, 28 bar strips).

## Open latency (spawn → first visible frame)

| Launcher | Before | After | Change |
|----------|--------|-------|--------|
| Launchpad (`Mod4+e`) | 940–1216 ms | 329–391 ms | −64% |
| Starlight (`Alt+Space`) | 324–348 ms | 346–418 ms | +30–70 ms for a guaranteed centred first frame |

Split by stage (Launchpad, before → after):

| Stage | Before | After | Cause |
|-------|--------|-------|-------|
| spawn → `manage` | 589–865 ms | 248–271 ms | `tooltip_text` on 54 tiles (D3) |
| `manage` → visible | 350–351 ms | 78–112 ms | hint wait replaced by size stability (D4) |

Starlight's `manage` time was already 287–312 ms (its UI is much smaller); its
placement delay dropped from 35 ms to ~80–110 ms because the reveal now waits
for size stability instead of a single 20 ms settle, which is what prevents the
corner frame.

## Event-loop health

| Metric | Before | After |
|--------|--------|-------|
| `E: awesome` per session | 6523 (one 10-minute window) | 0 |
| Timers running while fullscreen | 80 ms reveal timer forever, each tick raising | stops when no bar is hidden |
| Notifications from `debug::error` | one per 80 ms while fullscreen | none |

## Component costs measured (cold GTK process)

| Phase | Time | Note |
|-------|------|------|
| gjs + GTK init → `activate` | 80–95 ms | process-level, unavoidable without a daemon |
| `AppIndex` (54 showable apps) | 14 ms | scans `.desktop` files |
| Build 54 tiles | 49–535 ms before; ~50 ms after | tooltip controllers dominated |
| `present()` → `manage` | 53 ms | GTK realize/map |
| `present()` → first frame | 115–140 ms | GTK layout/paint |

## Still on the table (not done)

1. **Persistent launcher process.** The remaining ~250 ms is GTK process
   startup + first layout. A long-lived GTK process that hides and re-presents
   its window would cut opens to tens of milliseconds. This is an
   architectural change (lifecycle, D-Bus activation, memory) and needs an
   explicit decision.
2. **Subprocess polling (D9).** `wpctl` every 2 s and `playerctl metadata`
   every 3 s fork a shell. Converting to event streams removes ~2 forks/s.
3. **awesome memory.** 160 MB RSS after 3 h, dominated by cached wallpaper
   surfaces (30 screen-sized + 28 strip surfaces). The per-screen surface cache
   is unbounded between wallpaper changes; a cap would reduce it.
4. **Launcher AppIndex on every open.** 14 ms; a shared cache file is possible
   but low value until the process is persistent.
5. **Wallpaper cache build.** `magick` resize+blur runs at wallpaper change and
   is already off the WM thread; measure again after Phase 2 (bar redesign) to
   confirm strip sizes did not grow.

## Reproduce

```bash
~/.config/awesome/tools/bench-launcher.sh launchpad 3
~/.config/awesome/tools/bench-launcher.sh starlight 3
```
