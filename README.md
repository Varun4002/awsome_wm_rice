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
