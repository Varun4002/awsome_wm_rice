# 02 — Verification procedures

Every procedure lists the exact command and the expected result. Run the
relevant block after any change to the module it covers. All commands assume a
live session (`DISPLAY=:0`) and are safe to run repeatedly.

Quick rules:

- Never claim a UI behaviour is verified without a geometry probe or a capture.
- A reload is not a verification: always exercise the workflow afterwards.
- Record the evidence (numbers, file paths) in the milestone summary.

---

## 1. Configuration loads cleanly

```bash
for f in ~/.config/awesome/*.lua; do
    lua -e "assert(loadfile('$f'))" || echo "SYNTAX FAIL: $f"
done

# reload and inspect only the lines produced by this reload
date '+%Y-%m-%d %H:%M:%S' > /tmp/reload-start
awesome-client 'awesome.restart()'
sleep 2
journalctl --user -b --no-pager --since "$(cat /tmp/reload-start)" | grep 'E: awesome'
```

**Pass:** no syntax failures, no `E: awesome` lines, the bars reappear and the
existing clients keep their geometry.

---

## 2. Launcher placement — both monitors

```bash
# screen 1 = eDP-1-1 (0,0 1920x1080), work area 0,30 1920x1050
xdotool mousemove 1000 700
awesome-client "require('launchers').spawn('starlight')"
sleep 0.8
awesome-client 'for _,c in ipairs(client.get()) do
  if c.class=="starlight" then
    return string.format("starlight %d,%d %dx%d screen=%d", c.x, c.y, c.width, c.height, c.screen.index)
  end end'

# screen 2 = HDMI-0 (1920,0 1680x1050), work area 1920,30 1680x1020
xdotool mousemove 2760 520
awesome-client "require('launchers').spawn('launchpad')"
sleep 0.8
awesome-client 'for _,c in ipairs(client.get()) do
  if c.class=="launchpad" then
    return string.format("launchpad %d,%d %dx%d screen=%d", c.x, c.y, c.width, c.height, c.screen.index)
  end end'
```

Expected (bar visible, 2026-11-21):

| Launcher | Screen | Geometry | Formula |
|----------|--------|----------|---------|
| Starlight 684x542 | 1 | `618,284` | `(1920-684)/2`, `30+(1050-542)/2` |
| Starlight 684x542 | 2 | `2418,269` | `1920+(1680-684)/2`, `30+(1020-542)/2` |
| Launchpad 1068x688 | 1 | `426,211` | `(1920-1068)/2`, `30+(1050-688)/2` |
| Launchpad 1068x688 | 2 | `2226,196` | `1920+(1680-1068)/2`, `30+(1020-688)/2` |

**Note.** With a fullscreen client on the target screen the bar is hidden and
the work area is the full screen; y becomes 269 (Starlight) or 196 + 0
(Launchpad) on screen 1 as well. Recompute from `c.screen.workarea`, do not
compare against the table blindly.

---

## 3. No visible corner frame (the D10/D1 regression test)

A geometry probe alone cannot prove the window was invisible; capture the
screen while it opens.

```bash
cd /tmp/opencode
ffmpeg -hide_banner -loglevel error -f x11grab -framerate 60 \
    -video_size 1680x1050 -i :0.0+1920,0 -t 2.0 -y open.mp4 &
sleep 0.35
awesome-client "require('launchers').spawn('launchpad')"
wait
ffmpeg -hide_banner -loglevel error -i open.mp4 -vsync 0 frame-%03d.png

# mean grey level of the would-be corner patch (must stay constant) and of the
# centre (must change when the panel appears)
for f in frame-*.png; do
  c=$(convert "$f" -crop 300x200+20+60  +repage -colorspace gray -format '%[fx:mean]' info:)
  m=$(convert "$f" -crop 300x200+700+400 +repage -colorspace gray -format '%[fx:mean]' info:)
  echo "$f corner=$c centre=$m"
done
```

**Pass:** the corner value is constant to 3 decimals, the centre value changes
exactly once when the centred panel appears. Measured 2026-11-21:
corner `0.53027 → 0.52912` (the 0.001 change is the panel's shadow), centre
`0.3068 → 0.2198`.

---

## 4. Launcher focus stability (D5)

```bash
for i in $(seq 1 8); do
  xdotool mousemove 700 600
  awesome-client "require('launchers').spawn('starlight')"
  sleep 1.6
  awesome-client 'local n=0
    for _,c in ipairs(client.get()) do
      if c.class=="starlight" and c:isvisible() then n=n+1 end
    end return "visible="..n'
  [ -f /run/user/1000/starlight.pid ] && kill "$(cat /run/user/1000/starlight.pid)"
  sleep 0.6
done
```

**Pass:** `visible=1` on all runs. Before the `mouse::enter` guard this failed
3/8.

---

## 5. Fullscreen interaction

```bash
# 1. fullscreen an existing app on the target screen and focus it
awesome-client 'local t
  for _,c in ipairs(client.get()) do if c.class=="kitty" then t=c end end
  if t then t.fullscreen=true; t:emit_signal("request::activate","test",{raise=true}) end'

# 2. open the launcher on that screen
xdotool mousemove 1000 700
awesome-client "require('launchers').spawn('starlight')"
sleep 1.2
awesome-client 'local o="none"
  for _,c in ipairs(client.get()) do
    if c.class=="starlight" then
      o=string.format("vis=%s geom=%d,%d %dx%d focus=%s",
        tostring(c:isvisible()), c.x, c.y, c.width, c.height, tostring(client.focus==c))
    end end return o'
```

**Pass:** `vis=true`, `focus=true`, geometry centred on the full-screen work
area. Verified 3/3 on 2026-11-21.

---

## 6. Restart

1. Open a launcher, then `awesome-client 'awesome.restart()'`.
2. Wait 2 s; confirm no startup errors (section 1).
3. Open both launchers again and re-run section 2.

**Pass:** post-restart opens are centred. The launcher itself may dismiss
during the restart (GTK loses focus) — that is not a defect, but the restart
must not leave a half-mapped launcher behind.

---

## 7. Open-latency benchmark

```bash
~/.config/awesome/tools/bench-launcher.sh launchpad 3
~/.config/awesome/tools/bench-launcher.sh starlight 3
```

**Pass (2026-11-21):** Launchpad `manage` 248–271 ms, `visible` 329–391 ms;
Starlight `manage` 251–306 ms, `visible` 346–418 ms. Placement delay must stay
below 120 ms; anything near 350 ms means the hint wait is back.

---

## 8. Popovers do not overlap, system services degrade

```bash
awesome-client 'require("control_center").toggle()'
awesome-client 'require("frostbar").toggle_media()'   # only with a player
```

**Pass:** only one popover is visible at a time; the bar still responds if
`picom`, `wpctl` or `playerctl` are missing (they are guarded with
`2>/dev/null || true`). Full service-failure matrix: Phase 3.
