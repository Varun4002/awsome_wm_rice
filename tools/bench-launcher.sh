#!/usr/bin/env bash
# bench-launcher.sh — reproducible open-latency benchmark for the GTK launchers.
#
# Measures, inside the WM (monotonic clock, no shell round-trip in the path):
#   manage  = spawn call -> the launcher is handed to awesome's manage signal
#   visible = spawn call -> the placement authority reveals it (opacity 1)
# The delta between the two is the placement-authority delay.
#
# Usage: tools/bench-launcher.sh [starlight|launchpad] [runs]
# Requires a running awesome session (DISPLAY set) and awesome-client.
set -u

cls=${1:-launchpad}
runs=${2:-3}
runtime=${XDG_RUNTIME_DIR:-/tmp}
pidfile="$runtime/$cls.pid"

close_launcher() {
    if [[ -s "$pidfile" ]]; then
        kill "$(cat "$pidfile")" 2>/dev/null || true
        rm -f "$pidfile"
    fi
}

for i in $(seq 1 "$runs"); do
    close_launcher
    sleep 0.5

    awesome-client "
        local GLib = require('lgi').GLib
        local run = (rawget(_G, '__aether_bench_run') or 0) + 1
        rawset(_G, '__aether_bench_run', run)
        local rec = { run = run, t0 = GLib.get_monotonic_time() / 1000, marks = {} }
        rawset(_G, '__aether_bench', rec)
        local managed = false
        local function mark(k)
            if rawget(_G, '__aether_bench').run ~= run then return end
            rec.marks[#rec.marks + 1] = string.format('%s=%.0f', k,
                GLib.get_monotonic_time() / 1000 - rec.t0)
        end
        client.connect_signal('manage', function(c)
            if c.class == '$cls' then managed = true; mark('manage') end
        end)
        client.connect_signal('property::opacity', function(c)
            if managed and c.class == '$cls' and c.opacity == 1 then mark('visible') end
        end)
        require('launchers').spawn('$cls')
    " >/dev/null

    sleep 2
    printf '%-10s run %d: %s\n' "$cls" "$i" \
        "$(awesome-client 'return table.concat(_G.__aether_bench.marks, " ")' | sed 's/^   string "//; s/"$//')"
    close_launcher
done
