#!/usr/bin/env bash
# logcheck.sh — compare a run's LOGS (client + server) to known-good signatures. Sibling to
# compare.sh (screenshots): same REVIEW-not-fail flow, same explicit promote-to-bless step.
#
# WHY a "signature", not a diff: logs are noisy (timestamps, IP:port, hex addresses, generated
# refnums, pids), so a byte-diff always fails. We extract a normalized EVENT SIGNATURE — the ordered
# sequence of *significant* events (packet IDs, CoreScripts callbacks, connection/spawn/state lines)
# with volatile tokens masked — and diff THAT. A missing / extra / reordered event is exactly the
# regression class that matters in MP sync: a DedicatedPlayer spawn that didn't fire ("players can't see each
# other"), a movement/anim packet that went missing ("animations don't work"), a sync callback that
# stopped being called. The raw timestamped log is kept as an artifact — cross-reference its
# timestamps with the screenshot capture times (captures.tsv) when investigating a flagged run.
#
# Library:  source lib/logcheck.sh ; check_log <name> <rawlog>
# CLI:      lib/logcheck.sh check <name> <rawlog> | promote <name> <rawlog> | sig <rawlog> | selftest
set -uo pipefail

_LL_DIR=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)
LOG_REF_DIR=${RIG_LOG_REF_DIR:-$_LL_DIR/reference-logs}
LOG_REVIEW_DIR=${RIG_LOG_REVIEW_DIR:-/tmp/mp-rig-log-review}

# A line is SIGNIFICANT (kept in the signature) if it matches this vocabulary; everything else is
# dropped as noise. Extend via RIG_LOG_MARKERS for a specific run.
#
# Deliberately NARROW — a live multi-client run is inherently non-deterministic (ambient loading of
# neighbour cells, weather ticks, the order in which clients finish connecting), so a broad "every
# ID_*/every On* callback" vocabulary drifts ~20 lines every run and the check would REVIEW every
# time. The default keeps only events that (a) validate a checkpoint and (b) fire deterministically,
# plus the error tripwires that must stay ABSENT:
#   - connection gating + player/DedicatedPlayer creation (the mutual-visibility spawn)
#   - OnPlayerEndCharGen (chargen completed)
#   - the active-spells sync packet ID_PLAYER_SPELLS_ACTIVE (deterministic when fresh characters
#     receive a known number of effects; drop it via RIG_LOG_MARKERS if your scenario's effects vary)
#   - error signatures that must never appear
# Intentionally EXCLUDED as noise: OnObjectSpawn/OnContainer/OnActorList/OnCellLoad/OnWorldWeather/
# OnPlayerCellChange, the "DedicatedPlayer ... moved to <cell>" position stream, and Received
# ID_OBJECT_PLACE (it also fires for ambient cell objects, which drift). For a scenario-specific
# action, have your server script log one deterministic line and add it to RIG_LOG_MARKERS.
LOG_MARKERS=${RIG_LOG_MARKERS:-'(allowed|not allowed) to connect|has (connected|disconnected)|Creating new (player|DedicatedPlayer)|Called "OnPlayerEndCharGen"|ID_PLAYER_SPELLS_ACTIVE|Error in frame|script error|Server crash|Cannot get class|RefId is not a string'}

# Mask volatile tokens so two runs of the same scripted sequence yield identical signatures. Kept
# CONSERVATIVE on purpose (we do NOT mask all bare numbers — slot indices, effect args like arg=3,
# and counts are meaningful and must survive). Add masks here if a run proves noisy.
_log_normalize() {
    sed -E \
        -e 's/^\[[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}\][[:space:]]*//' \
        -e 's/\[(INFO|WARN|ERROR|DEBUG|VERBOSE)\][[:space:]]*:?[[:space:]]*//' \
        -e 's/[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\|[0-9]+/IP|PORT/g' \
        -e 's/0x[0-9a-fA-F]+/0xADDR/g' \
        -e 's/\bguid [0-9]+/guid GUID/g' \
        -e 's/\b[0-9]{4,}-[0-9]+\b/REFNUM/g' \
        -e 's/\bpid [0-9]+/pid PID/g' \
        -e 's/ \([0-9]+\)/ (PID)/g' \
        -e 's/-?[0-9]+\.[0-9]+/F/g'
}

# Ordered significant-event signature of a raw log.
_log_signature() { grep -hE "$LOG_MARKERS" "$1" 2>/dev/null | _log_normalize; }

# check_log <name> <rawlog>
#   0 = signature matches (PASS). 1 = differs / no reference (REVIEW). 2 = hard error.
check_log() {
    local name=$1 raw=$2
    [ -f "$raw" ] || { echo "ERROR $name: raw log missing ($raw)" >&2; return 2; }
    mkdir -p "$LOG_REVIEW_DIR"
    local ref=$LOG_REF_DIR/$name.events cand=$LOG_REVIEW_DIR/$name.events
    _log_signature "$raw" > "$cand"
    if [ ! -f "$ref" ]; then
        echo "REVIEW $name: no reference log yet — captured signature $cand ($(wc -l <"$cand") events; promote to bless)"
        return 1
    fi
    if diff -u "$ref" "$cand" > "$LOG_REVIEW_DIR/$name.logdiff" 2>&1; then
        rm -f "$LOG_REVIEW_DIR/$name.logdiff"
        echo "PASS   $name: log signature matches ($(wc -l <"$cand") events)"
        return 0
    fi
    echo "REVIEW $name: log signature differs — diff $LOG_REVIEW_DIR/$name.logdiff"
    return 1
}

# promote_log <name> <rawlog> — bless the signature as the new reference (human-approved). Also keeps
# the raw sample for reference, so an investigator has a full known-good log to compare against.
promote_log() {
    local name=$1 raw=$2
    [ -f "$raw" ] || { echo "ERROR: raw log missing ($raw)" >&2; return 2; }
    mkdir -p "$LOG_REF_DIR"
    _log_signature "$raw" > "$LOG_REF_DIR/$name.events"
    cp "$raw" "$LOG_REF_DIR/$name.sample.log" 2>/dev/null || true
    echo "PROMOTED $name -> $LOG_REF_DIR/$name.events (note the build it was captured on, then commit)"
}

# selftest — synthetic logs prove: identical->PASS, same events but different timestamps/IPs/
# addresses->PASS (normalization), a missing event->REVIEW.
selftest() {
    local t fails=0
    t=$(mktemp -d)
    LOG_REF_DIR=$t LOG_REVIEW_DIR=$t/review
    # Self-contained marker vocabulary covering the events used below, so the test validates the
    # signature/normalization logic independently of the default markers.
    LOG_MARKERS='is incoming|allowed to connect|Creating new (player|DedicatedPlayer)|Called "OnPlayer|ID_PLAYER_BASEINFO'
    # Full [YYYY-MM-DD HH:MM:SS] timestamps so _log_normalize strips them (it targets that format).
    cat > "$t/ref.log" <<'EOF'
[2026-01-01 10:00:01] [INFO]: A connection is incoming from 127.0.0.1|54321
[2026-01-01 10:00:02] [INFO]: Received ID_GAME_PREINIT from 127.0.0.1|54321
[2026-01-01 10:00:03] Client was allowed to connect
[2026-01-01 10:00:03] Creating new player at 0x55aa1234 for slot 0
[2026-01-01 10:00:04] Called "OnPlayerConnect"
[2026-01-01 10:00:05] Received ID_PLAYER_BASEINFO about StandardP2
EOF
    # same events, totally different volatile tokens (timestamps, IPs, addresses)
    cat > "$t/same.log" <<'EOF'
[2026-06-30 23:59:59] [WARN]: A connection is incoming from 192.168.0.5|11111
[2026-06-30 23:59:59] [INFO]: Received ID_GAME_PREINIT from 192.168.0.5|11111
[2026-06-30 08:15:00] Client was allowed to connect
[2026-06-30 08:15:00] Creating new player at 0x99ffeeee for slot 0
[2026-06-30 08:15:01] Called "OnPlayerConnect"
[2026-06-30 08:15:02] Received ID_PLAYER_BASEINFO about StandardP2
EOF
    # missing the BASEINFO event (the "can't see each other" signature)
    grep -v ID_PLAYER_BASEINFO "$t/ref.log" > "$t/missing.log"

    promote_log scene "$t/ref.log" >/dev/null
    _ck() { local d=$1 want=$2 f=$3 out rc=0; out=$(check_log scene "$f") || rc=$?
            if [ "$rc" = "$want" ]; then echo "  ok   [$d] rc=$rc :: $out"
            else echo "  FAIL [$d] rc=$rc want=$want :: $out"; fails=$((fails+1)); fi; }
    _ck "identical            -> PASS"   0 "$t/ref.log"
    _ck "volatile-only diff   -> PASS"   0 "$t/same.log"
    _ck "missing event        -> REVIEW" 1 "$t/missing.log"
    echo "selftest done (fails=$fails)"; rm -rf "$t"; return "$fails"
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    case "${1:-}" in
        check)   shift; check_log "$@" ;;
        promote) shift; promote_log "$@" ;;
        sig)     shift; _log_signature "$1" ;;
        selftest) selftest ;;
        *) echo "usage: logcheck.sh {check <name> <log> | promote <name> <log> | sig <log> | selftest}" >&2; exit 2 ;;
    esac
fi
