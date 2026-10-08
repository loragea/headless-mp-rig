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
# Library:  source lib/logcheck.sh ; logcheck_set_refs <refdir> ; check_log <name> <rawlog>
# CLI:      RIG_LOG_REF_DIR=<refdir> lib/logcheck.sh check <name> <rawlog> | promote <name> <rawlog> | sig <rawlog> | selftest
set -uo pipefail

# Where the blessed signatures live and where review output goes. Bind them per scenario AFTER sourcing
# with logcheck_set_refs (below); the RIG_* environment values are read once at source time for older
# consumers that export them first.
#   LOG_REF_DIR     blessed <name>.events files — no default: check_log / promote_log refuse until set.
#   LOG_REVIEW_DIR  candidate signatures and diffs; default $RIG_RUN_DIR/review when a run dir exists
#                   (rig_run_dir), else ${TMPDIR:-/tmp}/mp-rig-log-review. Resolved at check time.
LOG_REF_DIR=${RIG_LOG_REF_DIR:-}
LOG_REVIEW_DIR=${RIG_LOG_REVIEW_DIR:-}

# A line is SIGNIFICANT (kept in the signature) if it matches this vocabulary; everything else is
# dropped as noise. Each scenario declares its own vocabulary (scenario.conf LOG_MARKERS, or
# RIG_LOG_MARKERS / logcheck_set_refs for library consumers): the events that validate its checkpoints
# AND fire deterministically. Keep it narrow: a live multi-client run is non-deterministic (ambient
# cell loads, weather ticks, the order clients finish connecting), so "every ID_* packet" drifts
# every run.
#
# The default is only a tripwire set, true for any OpenMW-multiplayer build: server-script errors,
# crashes, aborts and failed assertions. A signature built from it is empty on a healthy run and
# names the error line otherwise.
LOG_TRIPWIRE_MARKERS='Error in frame|script error|Server crash|bad argument|luabridge|Segmentation fault|core dumped|terminate called|Assertion .*failed|unhandled exception'
LOG_MARKERS=${RIG_LOG_MARKERS:-$LOG_TRIPWIRE_MARKERS}

# logcheck_set_refs <refdir> [reviewdir] [markers] — bind this scenario's signature set, and optionally
# its review dir and marker vocabulary (empty = keep the current value / the defaults above).
logcheck_set_refs() {
    LOG_REF_DIR=${1:?logcheck_set_refs: need a reference dir}
    LOG_REVIEW_DIR=${2:-}
    [ -n "${3:-}" ] && LOG_MARKERS=$3
    return 0
}
_lc_review() {
    if [ -n "$LOG_REVIEW_DIR" ]; then printf '%s' "$LOG_REVIEW_DIR"
    elif [ -n "${RIG_RUN_DIR:-}" ]; then printf '%s' "$RIG_RUN_DIR/review"
    else printf '%s' "${TMPDIR:-/tmp}/mp-rig-log-review"; fi
}
_lc_need_ref() { [ -n "$LOG_REF_DIR" ] || { echo "ERROR: no reference dir — call logcheck_set_refs <refdir> (or export RIG_LOG_REF_DIR before sourcing logcheck.sh)" >&2; return 2; }; }

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
    local name=$1 raw=$2 review
    _lc_need_ref || return 2
    [ -f "$raw" ] || { echo "ERROR $name: raw log missing ($raw)" >&2; return 2; }
    review=$(_lc_review); mkdir -p "$review"
    local ref=$LOG_REF_DIR/$name.events cand=$review/$name.events
    _log_signature "$raw" > "$cand"
    if [ ! -f "$ref" ]; then
        echo "REVIEW $name: no reference log yet — captured signature $cand ($(wc -l <"$cand") events; promote to bless)"
        return 1
    fi
    if diff -u "$ref" "$cand" > "$review/$name.logdiff" 2>&1; then
        rm -f "$review/$name.logdiff"
        echo "PASS   $name: log signature matches ($(wc -l <"$cand") events)"
        return 0
    fi
    echo "REVIEW $name: log signature differs — diff $review/$name.logdiff"
    return 1
}

# promote_log <name> <rawlog> — bless the signature as the new reference (human-approved). Also keeps
# the raw sample for reference, so an investigator has a full known-good log to compare against.
promote_log() {
    local name=$1 raw=$2
    _lc_need_ref || return 2
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
    # Self-contained marker vocabulary covering the events used below, so the test validates the
    # signature/normalization logic independently of the default markers.
    logcheck_set_refs "$t" "$t/review" 'is incoming|allowed to connect|Creating new (player|DedicatedPlayer)|Called "OnPlayer|ID_PLAYER_BASEINFO'
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
    local saved=$LOG_REF_DIR; LOG_REF_DIR=''
    _ck "no ref dir           -> ERROR"  2 "$t/ref.log"
    LOG_REF_DIR=$saved
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
