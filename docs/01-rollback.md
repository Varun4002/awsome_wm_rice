# 01 — Rollback and recovery

The pre-AETHER state is preserved twice: a tarball outside the config tree and
the first commit of each repository.

## Known-good state

| Tree | Baseline commit | Describe |
|------|-----------------|----------|
| `~/.config/awesome` | `1739f2f` | `baseline: pre-AETHER awesome configuration (Phase 0)` |
| `~/projects/launchpad` | `2f5a61e` | `baseline: launchpad GTK4 app-grid launcher (pre-AETHER)` |
| `~/projects/starlight` | `dcc9dab` | `baseline: starlight search launcher (pre-AETHER)` |

Tarballs (pre-AETHER, includes the launcher wrappers from `~/.local/bin`):

```
~/.local/share/aether/backups/aether-pre-baseline-<stamp>.tar.gz
~/.local/share/aether/backups/system-awesome-dual-display-<stamp>.tar.gz
```

## Roll back one file

```bash
cd ~/.config/awesome
git diff <file>            # confirm what is about to be reverted
git checkout 1739f2f -- <file>
awesome-client 'awesome.restart()'
```

## Roll back everything

```bash
# 1. config + launcher sources + wrappers
tar xzf ~/.local/share/aether/backups/aether-pre-baseline-20261121-150204.tar.gz -C ~
# 2. session script (root-owned)
sudo tar xzf ~/.local/share/aether/backups/system-awesome-dual-display-20261121-150204.tar.gz -C /usr/local/bin
# 3. reload
awesome-client 'awesome.restart()'
```

The tarball contains `.config/awesome`, `.config/picom/picom.conf`,
`projects/launchpad`, `projects/starlight` and `.local/bin/{starlight,launchpad}`.

## Recovery when awesome will not start

1. **The config errors at load.** Awesome shows a critical notification and
   falls back to `/etc/xdg/awesome/rc.lua`; the session keeps running. Fix with
   `git -C ~/.config/awesome checkout 1739f2f -- .` (or the file), then reload.
2. **Reload from a terminal.** `Mod4+Ctrl+r` restarts awesome. If the binding is
   gone because the config failed, run from any TTY/Terminal:
   `DISPLAY=:0 awesome-client 'awesome.restart()'`.
3. **Config is so broken that awesome-client cannot connect.** Switch to a TTY
   (`Ctrl+Alt+F2`), log in, run
   `DISPLAY=:0 awesome -c /etc/xdg/awesome/rc.lua` is *not* safe while the
   session is live — instead restore the file:
   `git -C ~/.config/awesome checkout 1739f2f -- .`, then return to the session
   and restart it.
4. **Full session restart.** Log out and back in (GDM session "awesome (dual
   display)"). The session script re-applies the RandR/PRIME layout; its log is
   `~/.cache/awesome-display.log`.
5. **Compositor stuck.** `pkill -x picom` then
   `awesome-client 'require("glass").restart_compositor()'`. Windows stay
   opaque in the meantime; the WM itself is unaffected.

## After any rollback

Run `docs/02-verification.md` sections 1 and 2. A rollback that leaves a stale
launcher pidfile behind can make the next `Alt+Space` toggle close instead of
open: `rm -f /run/user/1000/{starlight,launchpad}.pid`.
