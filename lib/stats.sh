#!/usr/bin/env bash
# stats.sh — host load recording and run statistics. A test on a shared or software-rendered box is
# sometimes non-deterministic; this file makes that measurable instead of something to wait out.
#
#   rig_load_snapshot <file> start|end   append the host's load to a key=value file (load.txt): the
#                                        runner calls it around every run set and scenario attempt
#   lib/stats.sh selftest                proves it without a game or a display
#
# load.txt keys (docs/SCENARIO-FORMAT.md §5): cores; start_epoch start_loadavg (1/5/15 min) start_busy
# (% of all cores busy over a RIG_LOAD_SAMPLE-second sample, "-" when not sampled); the same three for
# end_; duration (s); run_busy (% of all cores busy between start and end, the run's own load included).
set -uo pipefail
_ST_LIB_DIR=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)
RIG_LOAD_SAMPLE=${RIG_LOAD_SAMPLE:-0.5}   # seconds of the CPU-busy sample at start and end; 0 = no sample

# _st_cpu — "<busy> <total>" jiffies of the aggregate cpu line of /proc/stat. guest and guest_nice are
# already counted in user and nice, so they are left out of the total.
_st_cpu() {
    local _c u n s i w q sq st
    read -r _c u n s i w q sq st _ < /proc/stat 2>/dev/null || return 1
    [ "$_c" = cpu ] || return 1
    st=${st:-0}
    echo "$((u + n + s + q + sq + st)) $((u + n + s + i + w + q + sq + st))"
}
# _st_pct <busy0> <total0> <busy1> <total1> — busy share in % with one decimal; "-" with no ticks.
_st_pct() { awk -v b="$(( $3 - $1 ))" -v t="$(( $4 - $2 ))" 'BEGIN{ if (t > 0) printf "%.1f", 100*b/t; else printf "-" }'; }
# rig_busy_sample <seconds> — % of all cores busy over a sample of that length; "-" when unavailable.
rig_busy_sample() {
    local a b
    case $1 in 0|0.0|'') echo -; return 0 ;; esac
    a=$(_st_cpu) || { echo -; return 0; }
    sleep "$1"
    b=$(_st_cpu) || { echo -; return 0; }
    # shellcheck disable=SC2086  # two words each
    _st_pct $a $b
}
# rig_load_snapshot <file> start|end — append one side of the snapshot. `end` reads start_epoch and
# start_cpu back from the file to compute duration and run_busy.
rig_load_snapshot() {
    local f=$1 side=$2 l1 l5 l15 busy now cpu c0 e0
    read -r l1 l5 l15 _ < /proc/loadavg 2>/dev/null || { l1=-; l5=-; l15=-; }
    case $side in
        start)
            busy=$(rig_busy_sample "$RIG_LOAD_SAMPLE")
            cpu=$(_st_cpu) || cpu='- -'
            {
                echo "# load.txt — host load around this run (lib/stats.sh); busy = % of all cores"
                echo "cores=$(nproc 2>/dev/null || echo -)"
                echo "start_epoch=$EPOCHSECONDS"
                echo "start_loadavg=$l1 $l5 $l15"
                echo "start_busy=$busy"
                echo "start_cpu=$cpu"
            } >> "$f" ;;
        end)
            now=$EPOCHSECONDS
            cpu=$(_st_cpu) || cpu='- -'
            c0=$(sed -n 's/^start_cpu=//p' "$f" 2>/dev/null | tail -1)
            e0=$(sed -n 's/^start_epoch=//p' "$f" 2>/dev/null | tail -1)
            busy=$(rig_busy_sample "$RIG_LOAD_SAMPLE")
            {
                echo "end_epoch=$now"
                echo "end_loadavg=$l1 $l5 $l15"
                echo "end_busy=$busy"
                if [[ $e0 =~ ^[0-9]+$ ]]; then echo "duration=$((now - e0))"; else echo "duration=-"; fi
                # shellcheck disable=SC2086  # two words each
                if [[ "$c0 $cpu" =~ ^[0-9]+\ [0-9]+\ [0-9]+\ [0-9]+$ ]]; then echo "run_busy=$(_st_pct $c0 $cpu)"; else echo "run_busy=-"; fi
            } >> "$f" ;;
        *) echo "rig_load_snapshot: side must be start or end" >&2; return 64 ;;
    esac
    return 0
}

# ================================================================================================
# selftest — no game binary, no display
# ================================================================================================
stats_selftest() {
    local t fails=0 out
    t=$(mktemp -d)
    _ok()  { echo "  ok   $1"; }
    _bad() { echo "  FAIL $1 :: $2"; fails=$((fails+1)); }
    _has() { if grep -qE -- "$3" <<<"$2"; then _ok "$1"; else _bad "$1" "$(head -c 600 <<<"$2")"; fi; }

    # -- 1. load snapshot --
    local f=$t/load.txt
    RIG_LOAD_SAMPLE=0.1 rig_load_snapshot "$f" start; RIG_LOAD_SAMPLE=0 rig_load_snapshot "$f" end
    out=$(cat "$f")
    _has "snapshot: start keys" "$out" '^start_loadavg=[0-9.]+ [0-9.]+ [0-9.]+$'
    _has "snapshot: start busy sampled" "$out" '^start_busy=[0-9]+\.[0-9]$'
    _has "snapshot: no end sample at RIG_LOAD_SAMPLE=0" "$out" '^end_busy=-$'
    _has "snapshot: duration from start_epoch" "$out" '^duration=[0-9]+$'
    _has "snapshot: run_busy" "$out" '^run_busy=([0-9]+\.[0-9]|-)$'
    if rig_load_snapshot "$f" middle 2>/dev/null; then _bad "snapshot: a bad side is refused" "rc 0"; else _ok "snapshot: a bad side is refused"; fi

    rm -rf "$t"
    echo "selftest done (fails=$fails)"
    return "$fails"
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    case "${1:-}" in
        selftest) stats_selftest; exit $? ;;
        *) echo "usage: lib/stats.sh selftest" >&2; exit 64 ;;
    esac
fi
