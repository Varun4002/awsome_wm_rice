# 07 — The dot workspace and drag-aware Super+Tab

Two connected desktop behaviours, implemented in `dotworkspace.lua`,
`dragtransfer.lua` and wired in `rc.lua` / `workspaces.lua` / `windower.lua`.

## The dot workspace (.)

- Every screen's tag table is `{ ".", "1", "2", … "9" }` — each monitor has
  its own dot and its own numbered sequence. The bar order is
  `AETHER  ·  1 2 3 … 9`.
- The dot is a wallpaper showcase: it must not hold ordinary application
  windows. Boot selects workspace `1`, never the dot.
- **Routing policy** (`dotworkspace.lua`, one signal handler on `tagged`):
  any ordinary client whose *only* tag is the dot is moved to workspace `1`
  of its screen, which is then selected. This covers launching while the
  dot is selected, late/async window maps, multi-window applications, and
  explicit moves (Mod4+click on the dot pill, window controls, keybindings).
  A client toggled onto the dot *alongside* its real workspace is an
  intentional action and stays.
- Exempt: **Starlight** and **Launchpad** (identified by `class` metadata,
  never by window title; both are sticky overlays), dialogs (they follow
  their transient parent's tag), and notification/dock/desktop/splash
  windows. Policy knobs live in `dotworkspace.config`.
- The dot pill is a small FontAwesome circle tinted with a pastel accent
  derived from the current wallpaper (async 1×1 `magick` average, cached
  per wallpaper; AETHER accent as fallback). Selected: full accent plus a
  1px glow ring; sticky overlays never count as occupancy.

## Super+Tab (Mod4+Tab)

- **No drag:** screen-local workspace cycle on the focused screen, forward
  through the tag array: `. → 1 → 2 → … → 9 → .` (wraps). The other
  monitor's view is never touched.
- **During a window drag** (Mod4+click on the body, or a plain click-drag
  on the glass titlebar — both go through `awful.mouse.resize` with the
  `mouse.move` context, which is where the drag lifecycle is hooked):
  - **first press:** only the dragged window is committed to the next
    monitor in cyclic screen order. Destination workspace = that screen's
    currently selected tag, except the dot, which routes to workspace `1`.
    That destination workspace is then selected *on the destination screen
    only*. Floating geometry is clamped into the destination workarea and
    the pointer is warped onto the window's grab point, so the drag
    continues on the new monitor. Tiled clients re-arrange under the
    destination layout. Floating/maximized/fullscreen client state
    survives (`move_to_tag` is client-level).
  - **later presses:** the transfer is already committed; presses cycle the
    *destination* screen's workspaces and carry the dragged window along,
    so it stays under the pointer. Repeats inside a 0.25 s cooldown are
    absorbed.
- Grab interaction, verified live on this machine (awesome 4.3, X11): root
  keybindings keep firing while awful's mousegrabber holds the pointer
  (Mod4+Tab switched tags mid-drag in an xdotool-driven test), so no
  keyboard grab of its own is needed.
- Maximized and fullscreen clients never enter a drag at all
  (`awful.mouse.client.move` refuses them), so they are never transferred
  by this path. Single-monitor setups: `other_screen()` returns nil and the
  drag simply continues.

## Failure handling

Window closed mid-drag (state invalidated, drag ends), destination monitor
disconnected (`other_screen` re-validates at every press), no second
monitor (no transfer), rapid repeated presses (cooldown + carry-along
semantics), dot destination (routes to workspace 1), and client validity
re-checked before every mutation — an unsafe transfer aborts before any
state is changed.
