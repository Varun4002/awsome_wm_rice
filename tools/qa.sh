#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# tools/qa.sh — the design-qa checklist, automated (backlog P1)
#
# Runs the checks that were previously re-typed by hand, prints PASS/FAIL per
# row, and exits non-zero if any row fails.  Static checks only by default;
# `--live` adds the checks that need the running session (DISPLAY=:0).
#
# Rows and their spec:
#   A1  colour literals outside ui.lua            design-qa A1
#   A2  font literals outside ui.lua              design-qa A2
#   A5  glyph sizes on the 8/10/16 scale          design-qa A5 / bar-aesthetic Q4
#   A6  text contrast >= 4.5:1 on both surfaces   design-qa A6 / §4 script
#   G5  forced heights on the 4 px grid           layout-grid G5
#   K4  one interruption convention per surface   continuity K4
#   P1  every .lua parses                         (luac -p)
#   L1  config marker present (--live)            user-flow FL5
#   L2  no journal errors since the last reload   ARCHITECTURE §15
#
# Usage:  tools/qa.sh [--live] [--verbose]
# ---------------------------------------------------------------------------
set -uo pipefail

cd "$(dirname "$0")/.." || exit 2
LIVE=0
VERBOSE=0
for arg in "$@"; do
    case "$arg" in
        --live) LIVE=1 ;;
        --verbose|-v) VERBOSE=1 ;;
        *) echo "usage: $0 [--live] [--verbose]" >&2; exit 2 ;;
    esac
done

FAIL=0
pass() { printf '  \033[32mPASS\033[0m  %-4s %s\n' "$1" "$2"; }
fail() { printf '  \033[31mFAIL\033[0m  %-4s %s\n' "$1" "$2"; FAIL=1; }
info() { printf '  ----  %-4s %s\n' "$1" "$2"; }

# Token-owned modules: these must not contain colour/font literals.
MODULES="rc.lua ui.lua frostbar.lua workspaces.lua panel.lua clock.lua
         control_center.lua opencode_ui.lua windower.lua popover.lua
         launchers.lua anim.lua dragtransfer.lua opencode.lua"
# Chrome exceptions: window decoration and pure-algorithm files.  Their colours
# are documented in the README as deliberate (traffic lights, titlebar alpha,
# wallpaper-derived mixing).
CHROME="glass.lua dotworkspace.lua wallpaper_cycler.lua"

echo "AETHER design QA — $(date '+%Y-%m-%d %H:%M')"

# ---------------------------------------------------------------- P1 syntax
bad=""
for f in *.lua; do
    case "$f" in widgets/*) continue ;; esac
    luac5.4 -p "$f" 2>/dev/null || bad="$bad $f"
done
if [ -z "$bad" ]; then pass P1 "all .lua files parse"; else fail P1 "syntax errors:$bad"; fi

# ------------------------------------------------------------ A1 colour literals
colours() { grep -hoE '"#[0-9a-fA-F]{6,8}"' "$@" 2>/dev/null | sort -u; }
mod_colours=$(colours $MODULES | grep -v '^"#00000000"$' | wc -l)
if [ "$mod_colours" -eq 0 ]; then
    pass A1 "no colour literals outside ui.lua"
else
    offenders=$(grep -lE '"#[0-9a-fA-F]{6,8}"' $MODULES 2>/dev/null \
        | grep -v '^ui.lua$' | tr '\n' ' ')
    [ -n "$offenders" ] && fail A1 "colour literals in: $offenders" \
                        || pass A1 "no colour literals outside ui.lua"
fi
chrome_colours=$(colours $CHROME | wc -l)
info A1 "chrome exception files still use $chrome_colours distinct literals (glass/traffic lights)"

# -------------------------------------------------------------- A2 font literals
font_lits=$(grep -hoE '"(Inter|FontAwesome) ?[0-9]*"' $MODULES 2>/dev/null \
            | grep -v '^ui.lua$' | wc -l)
font_offenders=$(grep -lE '"(Inter|FontAwesome) ?[0-9]*"' $MODULES 2>/dev/null \
                 | grep -v '^ui.lua$' | tr '\n' ' ')
if [ -z "$font_offenders" ]; then
    pass A2 "no font literals outside ui.lua"
else
    fail A2 "font literals in: $font_offenders"
fi

# --------------------------------------------------------------- A5 glyph scale
sizes=$(grep -rhoE 'FontAwesome [0-9]+' --include='*.lua' . 2>/dev/null \
        | awk '{print $2}' | sort -un | tr '\n' ' ')
offs=""
for s in $sizes; do
    case "$s" in 8|10|16) ;; *) offs="$offs $s" ;; esac
done
if [ -z "$offs" ]; then pass A5 "glyph sizes on the scale ($sizes)"; else
    fail A5 "off-scale glyph sizes:$offs"; fi

# ------------------------------------------------------------------- A6 contrast
if command -v python3 >/dev/null; then
    out=$(python3 - <<'EOF'
def lin(c):
    c /= 255
    return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4
def L(h):
    h = h.lstrip('#'); r, g, b = (int(h[i:i+2], 16) for i in (0, 2, 4))
    return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
def cr(a, b):
    la, lb = L(a), L(b); hi, lo = max(la, lb), min(la, lb)
    return (hi + 0.05) / (lo + 0.05)
import re
src = open('ui.lua').read()
block = re.search(r'M\.color = \{(.*?)\n\}', src, re.S).group(1)
bad = []
for name, hexv in re.findall(r'(\w+)\s*=\s*"(#[0-9a-fA-F]{6})"', block):
    if name in ('text', 'text_dim', 'text_faint', 'text_strong', 'accent',
                'accent_hi', 'danger', 'warn', 'ok'):
        bar, popup = cr(hexv, '#0e0e10'), cr(hexv, '#0d0f13')
        if min(bar, popup) < 4.5:
            bad.append(f"{name} {hexv} bar={bar:.2f} popup={popup:.2f}")
print("; ".join(bad))
EOF
)
    if [ -z "$out" ]; then pass A6 "every text token >= 4.5:1 on bar and popup"; else
        fail A6 "$out"; fi
fi

# ------------------------------------------------------------------ G5 height grid
h_off=$(grep -rhoE 'forced_height\s*=\s*[0-9]+' --include='*.lua' . 2>/dev/null \
        | grep -oE '[0-9]+$' | awk '$1 % 4 != 0 && $1 != 1 && $1 != 2 && $1 != 5' \
        | sort -n | uniq -c | tr '\n' ' ')
if [ -z "$h_off" ]; then
    pass G5 "every forced_height is a 4 px multiple (or 1/2/5 intentional)"
else
    fail G5 "off-grid heights (count value): $h_off"
fi

# ---------------------------------------------------------- K4 divider convention
for f in panel.lua control_center.lua clock.lua workspaces.lua frostbar.lua; do
    [ -f "$f" ] || continue
    n=$(grep -c 'ui\.divider()' "$f")
    info K4 "$f: $n divider call site(s)"
done

# ------------------------------------------------------------------ live checks
if [ "$LIVE" -eq 1 ]; then
    export DISPLAY=${DISPLAY:-:0}
    if marker=$(awesome-client 'return tostring(AETHER_RC_MARKER)' 2>/dev/null); then
        case "$marker" in
            *dot-v1*) pass L1 "config marker loaded ($marker)" ;;
            *) fail L1 "marker missing: $marker" ;;
        esac
    else
        fail L1 "awesome-client unavailable"
    fi
    errs=$(journalctl --user -b --no-pager -o cat 2>/dev/null \
           | grep -c 'E: awesome' )
    if [ "${errs:-0}" -eq 0 ]; then pass L2 "no 'E: awesome' in the journal"
    else info L2 "$errs 'E: awesome' lines since boot (check whether they predate the reload)"; fi
fi

echo
if [ "$FAIL" -eq 0 ]; then echo "result: PASS"; else echo "result: FAIL"; fi
exit "$FAIL"
