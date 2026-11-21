# AETHER — desktop environment configuration

AETHER is the name of this AwesomeWM 4.3 desktop: an existing, working X11
session (`eDP-1-1` + `HDMI-0`, NVIDIA/Intel PRIME) that is being refined into a
consistent, reliable, performance-conscious environment. It is **not** a
rewrite: every module here predates the AETHER work and is preserved unless a
documented defect required a change.

## Layout

| Path | Role |
|------|------|
| `rc.lua` | WM entry point: tags, bars, rules, key/mouse bindings, signal wiring |
| `glass.lua` | Theme values, window opacity tiers, picom lifecycle, titlebars |
| `frostbar.lua` | Frosted bar backdrop (baked wallpaper strips) + media/volume/usage widgets + media popover |
| `control_center.lua` | Wi-Fi / Bluetooth / brightness popover and bar button |
| `launchers.lua` | Placement authority for the GTK launchers (Starlight, Launchpad) |
| `wallpaper_cycler.lua` | Shared crossfading wallpaper cycler + cache baking |
| `anim.lua` | One-shot tween helper for bar/popover animations |
| `system/` | Reference copies of files outside this repo (`picom.conf`, session script) |
| `tools/` | Reproducible checks and benchmarks (not loaded by awesome) |
| `docs/` | Audit, defect register, rollback, verification procedures |

The GTK launchers live in their own trees and are versioned separately:

- `~/projects/starlight/hyprland/starlight.js` (class `starlight`, `Alt+Space`)
- `~/projects/launchpad/launchpad.js` (class `launchpad`, `Mod4+e`)
- wrappers: `~/.local/bin/starlight`, `~/.local/bin/launchpad`

## Validate / reload

```bash
# Language/syntax check (Lua 5.3 semantics, via the system Lua loader)
for f in ~/.config/awesome/*.lua; do lua -e "assert(loadfile('$f'))" || echo "FAIL $f"; done

# Reload the live WM and check for errors introduced by the reload
awesome-client 'awesome.restart()'
journalctl --user -b --no-pager | grep 'E: awesome' | tail -20

# Open-latency benchmark (requires a live session)
~/.config/awesome/tools/bench-launcher.sh launchpad 3
```

## Rollback

See `docs/01-rollback.md`. Short version: every commit in this repo is a
working state; `git checkout <commit> -- .` restores one file set, and
`~/.local/share/aether/backups/` holds a pre-AETHER tarball.

# awsome_wm_rice

Full backup of the **AETHER** AwesomeWM 4.3 (X11) rice, including everything
built on 2026-11-21:

## Modules
| file | role |
|---|---|
| `rc.lua` | tag table (`.` showcase + 1–9), bar assembly, keybinds, client rules |
| `frostbar.lua` | frosted-glass bar backdrop; now-playing mini-player (play/pause, time, seekbar); press-drag volume scrub with OSD; media popover |
| `workspaces.lua` | workspace pills (dot + 1–9), hover previews, workspace actions |
| `windower.lua` | per-screen active-window block + window control surface |
| `dotworkspace.lua` | `"."` wallpaper-showcase policy: central app routing, Starlight/Launchpad exemption, wallpaper-derived accent, idempotent tag reconcile |
| `dragtransfer.lua` | drag-aware Super+Tab: screen-local tag cycling, cross-monitor window transfer, under-bar drag clamp |
| `opencode.lua` / `opencode_ui.lua` | OpenCode integration: sessions + OpenCode Go usage windows (5-hour / weekly / monthly) |
| `widgets/` | animated slider suite: base engine, volume (wpctl + pw-mon), brightness, media seekbar (playerctl -F) |
| `clock.lua` | two-line 12-hour clock + calendar surface |
| `panel.lua`, `control_center.lua`, `popover.lua`, `ui.lua`, `glass.lua`, `launchers.lua`, `anim.lua`, `wallpaper_cycler.lua` | five-layer bar surfaces, design tokens, compositor lifecycle, launchers, wallpaper crossfades |
| `docs/` | audit, defects, verification, performance notes, dot-workspace/drag-transfer spec |
| `system/`, `tools/` | dual-display session script, picom config, benchmarks |

## Runtime dependencies
awesome 4.3 · picom · kitty · starlight and launchpad (wrapper scripts in
`~/.local/bin`) · PipeWire (`wpctl`, `pw-mon`) · `playerctl` · `brightnessctl` ·
ImageMagick (`magick`) · `xdotool` · `curl` + `jq` · lua-lgi + lfs.

## Keybindings (highlights)
`Super+Tab` next tag on the focused screen — during a window drag it transfers
the dragged window to the other monitor · `Super+D` dot wallpaper showcase ·
`Alt+Space` Starlight · `Super+E` Launchpad · `Super+A` AETHER panel ·
`Super+Space` next layout · `Print` screenshot · `Super+Q` close window.
