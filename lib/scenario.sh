#!/usr/bin/env bash
# scenario.sh — the scenario runner: executes a scenario directory (scenario.conf + steps.sh) against
# a real server and clients and writes one verdict. The format is docs/SCENARIO-FORMAT.md; this file
# implements it.
#
# Use:
#   bin/rig run <dir>... [flags]           the front end (sources this file, calls scenario_run)
#   lib/scenario.sh selftest               proves the parser, log windows, verdict and INFRA stop
#                                          without a game binary
#   lib/scenario.sh _run-one <dir> <out>   internal: one attempt of one scenario (bin/rig run calls it)
#   lib/scenario.sh _dry-run <dir>         internal: the --dry-run check of one scenario
#
# Process model: bin/rig run is the parent; every scenario attempt runs in a fresh child process
# (`lib/scenario.sh _run-one`) so rig state, traps and the steps.sh namespace never leak between
# scenarios. The child writes <out>/RESULT; the parent aggregates RESULT lines into RESULTS.
# The verb functions (boot, key, assert, wait, type, ...) shadow shell builtins of the same names,
# so they are defined only inside the child (_sc_define_verbs), never in bin/rig itself.
set -uo pipefail
_SC_LIB_FILE=${BASH_SOURCE[0]}
_SC_LIB_DIR=$(cd "$(dirname "$(readlink -f "$_SC_LIB_FILE")")" && pwd)
if ! declare -F rig_run_dir >/dev/null; then
    # shellcheck source=rig.sh
    source "$_SC_LIB_DIR/rig.sh"
fi
if ! declare -F compare_shot >/dev/null; then
    # shellcheck source=compare.sh
    source "$_SC_LIB_DIR/compare.sh"
fi
if ! declare -F check_log >/dev/null; then
    # shellcheck source=logcheck.sh
    source "$_SC_LIB_DIR/logcheck.sh"
fi

# The server-log error lines that must never appear. A constant, not a default vocabulary: a scenario
# uses it in `assert absent server "$RIG_TRIPWIRES"` and in its LOG_MARKERS.
export RIG_TRIPWIRES='script error|Server crash|bad argument|luabridge|Error in frame'
RIG_LOGIN_CAP=${RIG_LOGIN_CAP:-30}                # login: secs to see the server's "[rig-bridge] player <p> in"
RIG_CHAT_KEY=${RIG_CHAT_KEY:-F6}                  # hidechat: the client's chat-window toggle key
RIG_BRIDGE_CAP=${RIG_BRIDGE_CAP:-5}               # setup verbs: secs for the server bridge to answer a command
RIG_PROBE_CAP=${RIG_PROBE_CAP:-10}                # probe: secs for the client probe's [rigprobe:done] after the bridge sent it
RIG_SCENARIOS=${RIG_SCENARIOS:-$RIG_ROOT/scenarios}   # --tag/--all search roots (space-separated)

SC_DEFAULT_MARKERS=$LOG_MARKERS     # logcheck.sh's vocabulary, used when LOG_MARKERS is not set
# The kinds the client probe answers (probe/scripts/rig/probe.lua); `dump` requests all of them.
SC_PROBE_KINDS="cell stats quest topics inv nearby items effects faction spells time weather"
SC_CONF_KEYS="NAME PURPOSE PLAYERS PASSWORDS TAGS CONTENT FIXTURE OVERLAY PROBE PROBE_RANGE PROBE_PERIOD SETTINGS LOG_MARKERS COST WIGGLE"
SC_VERBS="boot login logout wiggle settle key hold type mouse click rmb look turn chat cast scroll hidechat
console console-file console-object server save probe wait assert shot pair signature checkpoint mark note artifact"

# ================================================================================================
# scenario.conf — parsed without running it (discovery, checks); sourced only by a run
# ================================================================================================
_sc_key_ok() {
    case " $SC_CONF_KEYS " in *" $1 "*) return 0;; esac
    [[ $1 =~ ^P_[A-Z0-9_]+$ ]]
}
# _sc_conf_check <file> — one line per problem (naming the line and key); return 1 if any.
_sc_conf_check() {
    local f=$1 n=0 line key bad=0
    [ -f "$f" ] || { echo "scenario.conf: missing ($f)"; return 1; }
    while IFS= read -r line || [ -n "$line" ]; do
        n=$((n+1))
        [[ $line =~ ^[[:space:]]*(#.*)?$ ]] && continue
        if [[ $line =~ ^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)= ]]; then
            key=${BASH_REMATCH[2]}
            _sc_key_ok "$key" && continue
            echo "scenario.conf:$n: unknown key $key (allowed: $SC_CONF_KEYS, P_<NAME>)"
        else
            echo "scenario.conf:$n: not a KEY=value line: $line"
        fi
        bad=1
    done < "$f"
    return "$bad"
}
# _sc_unquote <text after '='> — the shell value of a simple assignment: "..." / '...' / bare word.
_sc_unquote() {
    local s=$1
    if [[ $s =~ ^\"([^\"]*)\" ]]; then printf '%s' "${BASH_REMATCH[1]}"
    elif [[ $s =~ ^\'([^\']*)\' ]]; then printf '%s' "${BASH_REMATCH[1]}"
    else printf '%s' "${s%%[[:space:]]*}"; fi
}
# _sc_conf_get <file> <KEY> — the key's value without sourcing the file (last assignment wins;
# $VAR references stay literal).
_sc_conf_get() {
    local f=$1 k=$2 line v=
    while IFS= read -r line || [ -n "$line" ]; do
        [[ $line =~ ^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]] || continue
        [ "${BASH_REMATCH[2]}" = "$k" ] && v=$(_sc_unquote "${BASH_REMATCH[3]}")
    done < "$f"
    printf '%s' "$v"
}
# _sc_scenario_name <dir> — NAME from the conf, else the directory name; made path-safe.
_sc_scenario_name() {
    local n; n=$(_sc_conf_get "$1/scenario.conf" NAME 2>/dev/null)
    [ -n "$n" ] || n=$(basename "$1")
    printf '%s' "${n//[^A-Za-z0-9._-]/_}"
}
# _sc_load_conf <dir> — check, then source scenario.conf and apply defaults (run and dry-run only).
_sc_load_conf() {
    local d=$1 k msg
    if ! msg=$(_sc_conf_check "$d/scenario.conf"); then SC_CONF_ERR=$msg; return 1; fi
    for k in $SC_CONF_KEYS $(compgen -v P_); do unset "$k"; done     # no P_* inherited from the caller
    # shellcheck source=/dev/null
    source "$d/scenario.conf" || { SC_CONF_ERR="scenario.conf: sourcing failed"; return 1; }
    for k in $(compgen -v P_); do export "${k?}"; done
    # shellcheck disable=SC2034  # the conf values are read by steps.sh and hooks.sh
    NAME=$(_sc_scenario_name "$d"); PURPOSE=${PURPOSE:-}; TAGS=${TAGS:-}; COST=${COST:-}
    PLAYERS=${PLAYERS:-}; PASSWORDS=${PASSWORDS:-}; CONTENT=${CONTENT:-}; FIXTURE=${FIXTURE:-.}
    OVERLAY=${OVERLAY:-}; PROBE=${PROBE:-0}; SETTINGS=${SETTINGS:-}; LOG_MARKERS=${LOG_MARKERS:-$SC_DEFAULT_MARKERS}; WIGGLE=${WIGGLE:-1}
    [ -n "$PLAYERS" ] || { SC_CONF_ERR="scenario.conf: PLAYERS is required"; return 1; }
    [ -n "$CONTENT" ] || { SC_CONF_ERR="scenario.conf: CONTENT is required (a content profile name from rig.conf)"; return 1; }
    read -r -a SC_PLAYERS <<<"$PLAYERS"
    local -a pw=(); read -r -a pw <<<"$PASSWORDS"
    [ "${#SC_PLAYERS[@]}" -le 3 ] || { SC_CONF_ERR="scenario.conf: PLAYERS has ${#SC_PLAYERS[@]} names; the rig drives at most 3 clients"; return 1; }
    local i p
    SC_SLOT=(); SC_PASS=()
    for i in "${!SC_PLAYERS[@]}"; do
        p=${SC_PLAYERS[i]}
        [[ $p =~ ^[A-Za-z0-9_]+$ ]] || { SC_CONF_ERR="scenario.conf: player name '$p' must be letters, digits or _"; return 1; }
        SC_SLOT[$p]=$((i+1)); SC_PASS[$p]=${pw[i]:-$p}
    done
    case $WIGGLE in 0|1) ;; *) SC_CONF_ERR="scenario.conf: WIGGLE must be 0 or 1"; return 1;; esac
    PROBE_RANGE=${PROBE_RANGE:-}; PROBE_PERIOD=${PROBE_PERIOD:-}
    [ -z "$PROBE_RANGE" ] || [[ $PROBE_RANGE =~ ^[0-9]+$ ]] || { SC_CONF_ERR="scenario.conf: PROBE_RANGE '$PROBE_RANGE' is not a distance in game units"; return 1; }
    [ -z "$PROBE_PERIOD" ] || _sc_is_num "$PROBE_PERIOD" || { SC_CONF_ERR="scenario.conf: PROBE_PERIOD '$PROBE_PERIOD' is not a number of seconds"; return 1; }
    return 0
}

# ================================================================================================
# Probe lines — [rigprobe:<kind>] key=value ... (values with spaces are "quoted")
# ================================================================================================
# _sc_probe_tokens <line> — print kind=<kind>, then one key=value per field, quotes removed.
_sc_probe_tokens() {
    local s=$1
    [[ $s =~ \[rigprobe:([A-Za-z0-9_-]+)\](.*)$ ]] || return 1
    printf 'kind=%s\n' "${BASH_REMATCH[1]}"
    s=${BASH_REMATCH[2]}
    while [[ $s =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_.]*)=(\"([^\"]*)\"|([^\"[:space:]][^[:space:]]*)?)(.*)$ ]]; do
        if [ "${BASH_REMATCH[2]:0:1}" = '"' ]; then
            printf '%s=%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[3]}"
        else
            printf '%s=%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[4]}"
        fi
        s=${BASH_REMATCH[5]}
    done
    [[ $s =~ ^[[:space:]]*$ ]]
}

# ================================================================================================
# Verdict — RESULT lines and run-set severity
# ================================================================================================
# _sc_result_line <status> <code> <scenario> <fails> <regressions> <attempts>
_sc_result_line() { printf 'RESULT %s %s %s %s %s %s\n' "$1" "$2" "$3" "$4" "$5" "$6"; }
# _sc_aggregate <code>... — the run-set exit code: severity 3 > 1 > 2 > 4 > 0; 4 only when all are 4.
_sc_aggregate() {
    local c has=' ' n=0 n4=0
    for c in "$@"; do has="$has$c "; n=$((n+1)); [ "$c" = 4 ] && n4=$((n4+1)); done
    case $has in *' 3 '*) echo 3; return;; esac
    case $has in *' 1 '*) echo 1; return;; esac
    case $has in *' 2 '*) echo 2; return;; esac
    if [ "$n" -gt 0 ] && [ "$n4" = "$n" ]; then echo 4; return; fi
    case $has in *' 0 '*) echo 0; return;; esac
    echo 3      # no scenario reported a code
}

# ================================================================================================
# Step recorder — rows, call sites, marks, log windows
# ================================================================================================
# Per-run state (the child sets these; selftest sets them on synthetic logs).
SC_DIR='' SC_RUN='' SC_NAME='' SC_DRY=0 SC_INFRA='' SC_STEP=0 SC_T0=$SECONDS SC_PHASE=setup SC_FINAL=0
SC_CUR_STEP=0 SC_CUR_LINE='' SC_CUR_DESC='' SC_LAST_STATUS='' SC_FIRST_LOGIN=1
SC_CAPTURE=${SC_CAPTURE:-0} SC_STRICT=${SC_STRICT:-0} SC_KEEP_UP=${SC_KEEP_UP:-0} SC_ATTEMPT=${SC_ATTEMPT:-1}
SC_PLAYERS=()
declare -A SC_EVER_BOOTED=() SC_BOOT_HOW=() SC_SLOT=() SC_PASS=() SC_OFF=() SC_NAMED=() SC_BOOTED=() SC_IN=() SC_SHOTROW=() SC_PAIRIN=()
# Rows, indexed by step number: status, call site, verb text, t+s, offsets, detail.
declare -a SC_RSTAT=() SC_RLINE=() SC_RDESC=() SC_RT=() SC_ROFF=() SC_RDET=()

# _sc_callsite — "<file>:<line>" of the first caller outside this library (steps.sh or hooks.sh).
_sc_callsite() {
    local i f
    for ((i=1; i<${#FUNCNAME[@]}; i++)); do
        f=${BASH_SOURCE[i+1]:-}
        if [ -n "$f" ] && [ "$f" != "$_SC_LIB_FILE" ]; then printf '%s:%s' "${f##*/}" "${BASH_LINENO[i]}"; return; fi
    done
    printf '?'
}
_sc_row_text() { local i=$1; printf '%s\t%s\t%s\t%s\t%s\t%s\t%s' "$i" "${SC_RLINE[i]}" "${SC_RDESC[i]}" "${SC_RSTAT[i]}" "${SC_RT[i]}" "${SC_ROFF[i]}" "${SC_RDET[i]}"; }
_sc_clean() { local s=${1//$'\t'/ }; s=${s//$'\n'/ }; printf '%s' "$s"; }
# _sc_say <text> — one line to run.log (stdout) and, when the parent passed one, the console (fd 3).
_sc_say() {
    printf '%s\n' "$1"
    if [ "$SC_DRY" != 1 ] && { true >&3; } 2>/dev/null; then printf '%s\n' "$1" >&3; fi
}
# _sc_begin <verb> <args>... — open a step row. Returns 1 (row already written) when the step must
# not execute: dry-run, or the scenario stopped on INFRA.
_sc_begin() {
    local a desc=''
    for a in "$@"; do
        if [[ $a =~ [[:space:]] || -z $a ]]; then desc="$desc '$a'"; else desc="$desc $a"; fi
    done
    SC_STEP=$((SC_STEP+1)); SC_CUR_STEP=$SC_STEP
    SC_CUR_LINE=$(_sc_callsite); SC_CUR_DESC=$(_sc_clean "${desc# }")
    if [ "$SC_DRY" = 1 ]; then _sc_dry_check "$@"; return 1; fi
    if [ -n "$SC_INFRA" ]; then _sc_row SKIP "" "after INFRA"; return 1; fi
    if [ -n "${RIG_SRV:-}" ] && ! kill -0 "$RIG_SRV" 2>/dev/null; then
        _sc_infra "the server (pid $RIG_SRV) died (see server.log)"; return 1
    fi
    local msg
    if ! msg=$(_sc_argcheck "$@"); then
        case $1 in boot|login) _sc_infra "$msg";; *) _sc_row FAIL "" "$msg";; esac
        return 1
    fi
    return 0
}
# _sc_row <status> <offsets> <detail> — close the current step.
_sc_row() {
    local st=$1 off=${2:-} det t row
    det=$(_sc_clean "${3:-}")
    t=$((SECONDS - SC_T0))
    SC_RSTAT[SC_CUR_STEP]=$st SC_RLINE[SC_CUR_STEP]=$SC_CUR_LINE SC_RDESC[SC_CUR_STEP]=$SC_CUR_DESC
    SC_RT[SC_CUR_STEP]=$t SC_ROFF[SC_CUR_STEP]=$off SC_RDET[SC_CUR_STEP]=$det
    row=$(_sc_row_text "$SC_CUR_STEP")
    SC_LAST_STATUS=$st
    if [ "$SC_DRY" != 1 ] && [ -n "$SC_RUN" ]; then printf '%s\n' "$row" >> "$SC_RUN/steps.tsv"; fi
    _sc_say "[t+${t}s] $SC_CUR_LINE $SC_CUR_DESC -> $st${det:+ $det}"
    case $st in FAIL|NO-REFERENCE|REGRESSION) return 1;; esac
    return 0
}
# _sc_infra <reason> — fail the current step and stop the scenario: later steps record SKIP.
_sc_infra() {
    SC_INFRA=$1
    _sc_row FAIL "$(_sc_offsets_now)" "INFRA: $1"
    return 1
}

# Logs: "server", one key per player (its client log) and, with PROBE=1, "probe-<p>" per player (the
# [rigprobe:*] lines of that client's log, copied into probe-<p>.log by _sc_probe_sync).
_sc_logkeys() {
    local p
    printf '%s\n' server "${SC_PLAYERS[@]+"${SC_PLAYERS[@]}"}"
    if [ "${PROBE:-0}" = 1 ]; then for p in "${SC_PLAYERS[@]+"${SC_PLAYERS[@]}"}"; do printf 'probe-%s\n' "$p"; done; fi
}
_sc_logfile() {
    case $1 in
        server)  printf '%s' "${RIG_SRV_STDOUT:-$SC_RUN/server.log}" ;;
        probe-*) printf '%s' "$SC_RUN/$1.log" ;;
        *)       printf '%s' "$SC_RUN/client-$1.log" ;;
    esac
}
# _sc_fresh <file> — bring a probe log up to date before it is read; other files are left alone.
_sc_fresh() { case $1 in "$SC_RUN"/probe-*.log) local p=${1##*/probe-}; _sc_probe_sync "${p%.log}";; esac; return 0; }
_sc_size() { local s; _sc_fresh "$1"; s=$(stat -c %s "$1" 2>/dev/null) || s=0; printf '%s' "${s:-0}"; }
# _sc_probe_sync <p> — append the complete [rigprobe:*] lines the client log gained since the last call
# to probe-<p>.log, each starting at "[rigprobe:" (the engine's print prefix is dropped). A partial
# last line waits for the next call; a client log shorter than the saved offset (the client
# restarted) is read from 0. State lives in files, so a call from a subshell counts.
_sc_probe_sync() {
    local p=$1 cl pl of off size tmp n part
    [ -n "$SC_RUN" ] || return 0
    cl=$SC_RUN/client-$p.log; pl=$SC_RUN/probe-$p.log; of=$SC_RUN/.probe-$p.off
    [ -f "$pl" ] || : > "$pl"
    off=$(cat "$of" 2>/dev/null); off=${off:-0}
    size=$(stat -c %s "$cl" 2>/dev/null) || size=0
    [ "$size" -lt "$off" ] && off=0
    if [ "$size" -le "$off" ]; then echo "$off" > "$of"; return 0; fi
    tmp=$SC_RUN/.probe-$p.chunk
    tail -c +"$((off + 1))" "$cl" 2>/dev/null | head -c "$((size - off))" > "$tmp"
    n=$(stat -c %s "$tmp" 2>/dev/null) || n=0
    if [ -n "$(tail -c1 "$tmp")" ]; then part=$(tail -n1 "$tmp" | wc -c); n=$((n - part)); fi
    [ "$n" -gt 0 ] && head -c "$n" "$tmp" | grep -a -o '\[rigprobe:[A-Za-z0-9_-]*\].*' >> "$pl"
    echo "$((off + n))" > "$of"
    rm -f "$tmp"
    return 0
}
# _sc_mark_all [name] — advance every log's offset to its current end (and name the point).
_sc_mark_all() {
    local k s
    while IFS= read -r k; do
        s=$(_sc_size "$(_sc_logfile "$k")")
        SC_OFF[$k]=$s
        [ -n "${1:-}" ] && SC_NAMED["$1|$k"]=$s
    done < <(_sc_logkeys)
    return 0
}
_sc_offsets_now() {
    local k out=''
    while IFS= read -r k; do out="$out $k:${SC_OFF[$k]:-0}"; done < <(_sc_logkeys)
    printf '%s' "${out# }"
}
# _sc_close_row <status> <detail> — close a lifecycle/input/setup/custom verb's row; the offsets column
# records the implicit mark the verb took when it started acting (_sc_mark_all).
_sc_close_row() { _sc_row "$1" "$(_sc_offsets_now)" "${2:-}"; }
# _sc_window_start <logkey> <mark-name|''> — echo the window's start offset; 1 if the mark is unknown.
_sc_window_start() {
    local k=$1 m=${2:-}
    local o
    if [ -z "$m" ]; then o=${SC_OFF[$k]:-0}
    elif [ "$m" = start ]; then o=0
    elif [ -n "${SC_NAMED["$m|$k"]+x}" ]; then o=${SC_NAMED["$m|$k"]}
    else return 1; fi
    # A log shorter than its offset was rewritten (a client restarted): its whole content is new.
    [ "$o" -gt "$(_sc_size "$(_sc_logfile "$k")")" ] && o=0
    printf '%s' "$o"
}
# _sc_grep_from <file> <offset> <ERE> — does the ERE match a line in the file past byte <offset>?
_sc_grep_from() { _sc_fresh "$1"; grep -qE -- "$3" < <(tail -c +"$(( $2 + 1 ))" "$1" 2>/dev/null); }
# _sc_poll <cap> <cmd>... — run cmd until it succeeds or cap secs pass (at least one try).
_sc_poll() {
    local cap=$1 t0=$SECONDS; shift
    while true; do
        "$@" && return 0
        (( SECONDS - t0 >= cap )) && return 1
        sleep 0.5
    done
}
_sc_is_num() { [[ $1 =~ ^[0-9]+([.][0-9]+)?$ ]]; }
_sc_geom_ok() { [ "$1" = FULL ] || [[ $1 =~ ^[0-9]+x[0-9]+\+[0-9]+\+[0-9]+$ ]]; }

# ================================================================================================
# Argument checks — one table for the run (_sc_begin) and the dry-run/lint, so a malformed verb call
# fails before a three-minute boot
# ================================================================================================
_sc_ac_p() { _sc_known "${1:-}" || { echo "unknown player '${1:-}' (PLAYERS=${SC_PLAYERS[*]})"; return 1; }; }
_sc_ac_n() { _sc_is_num "${1:-}" || { echo "$2: '${1:-}' is not a number"; return 1; }; }
_sc_ac_i() { [[ ${1:-} =~ ^-?[0-9]+$ ]] || { echo "$2: '${1:-}' is not an integer"; return 1; }; }
_sc_ac_g() { _sc_geom_ok "${1:-}" || { echo "$2: '${1:-}' is not WxH+X+Y or FULL"; return 1; }; }
_sc_ac_e() { [ -n "${1:-}" ] || { echo "$2: no ERE"; return 1; }; }
_sc_ac_cap() { [ -z "${1:-}" ] || _sc_ac_n "$1" "$2 cap"; }
# _sc_ac_max <verb text> <argc> <max>
_sc_ac_max() { [ "$2" -le "$3" ] || { echo "$1: $2 arguments, at most $3 — quote an argument holding spaces, and quote operators ('>=')"; return 1; }; }
# _sc_ac_line <text> <verb> — a command that travels as one line of the bridge's command file.
_sc_ac_line() { [[ $1 != *[$'\t\n\r']* ]] || { echo "$2: the command holds a tab or newline (one command per call; console-file for several)"; return 1; }; }
# _sc_ac_console_file <path> <name> — every command line of a console file travels as one bridge
# line: a tab in it would end the command there.
_sc_ac_console_file() {
    local line n=0
    while IFS= read -r line || [ -n "$line" ]; do
        n=$((n + 1)); line=${line%$'\r'}
        [[ $line =~ ^[[:space:]]*(#.*)?$ ]] && continue
        [[ $line != *$'\t'* ]] || { echo "console-file $2:$n: the command holds a tab (the bridge would run only the text before it)"; return 1; }
    done < "$1"
    return 0
}
# _sc_ac_kind <kind> <verb> [extra] — a probe kind the probe answers.
_sc_ac_kind() {
    case " $SC_PROBE_KINDS ${3:-} " in *" ${1:-} "*) [ -n "${1:-}" ] && return 0;; esac
    echo "$2: '${1:-}' is not a probe kind ($SC_PROBE_KINDS${3:+ $3})"; return 1
}
# _sc_ac_cond <field><op><value> — a probe condition; ops = != < <= > >= ~ (quote < and >).
_sc_ac_cond() {
    _sc_probe_cond_parse "$1" && return 0
    echo "assert probe: '$1' is not <field><op><value> with op = != < <= > >= ~ (quote it: 'dist<400')"; return 1
}
# _sc_ac_delta <p> <kind> <field> <op> <n> [<selector>...] [<seqA> <seqB>]
_sc_ac_delta() {
    local x nums=0
    _sc_ac_p "${1:-}" || return 1; _sc_ac_kind "${2:-}" "assert probe-delta" || return 1
    [[ ${3:-} =~ ^[A-Za-z_][A-Za-z0-9_.]*$ ]] || { echo "assert probe-delta: expected <p> <kind> <field> <op> <n> [<selector>...] [<seqA> <seqB>]"; return 1; }
    case ${4:-} in =|'!='|'<'|'<='|'>'|'>=') ;; *) echo "assert probe-delta: operator '${4:-}' is not one of = != < <= > >= (quote it: '<')"; return 1;; esac
    [[ ${5:-} =~ ^-?[0-9]+([.][0-9]+)?$ ]] || { echo "assert probe-delta: '${5:-}' is not a number"; return 1; }
    for x in "${@:6}"; do
        if [[ $x =~ ^[0-9]+$ ]]; then nums=$((nums + 1))
        elif [ "$nums" -gt 0 ]; then echo "assert probe-delta: the two request seqs come last"; return 1
        else _sc_ac_cond "$x" || return 1; fi
    done
    case $nums in 0|2) ;; *) echo "assert probe-delta: give two request seqs or none (got $nums)"; return 1;; esac
}
_sc_ac_op() { case ${1:-} in =|==|'!='|'<'|'<='|'>'|'>=') ;; *) echo "assert count: operator '${1:-}' is not one of = == != < <= > >= (quote it: '>=')"; return 1;; esac; }
# _sc_argcheck <verb> <args>... — echo the first problem with a verb call's arguments; 1 if any.
_sc_argcheck() {
    local v=$1 x; shift
    local -a rest=()
    case $v in wait|assert)
        while [ $# -gt 0 ]; do
            if [ "$1" = --since ]; then [ -n "${2:-}" ] || { echo "--since needs a mark name"; return 1; }; shift 2; continue; fi
            rest+=("$1"); shift
        done
        set -- "${rest[@]+"${rest[@]}"}" ;;
    esac
    case $v in
        boot)   [ $# -gt 0 ] || { echo "boot: name at least one player"; return 1; }
                for x in "$@"; do _sc_ac_p "$x" || return 1; done ;;
        login)  _sc_ac_p "${1:-}" || return 1
                case ${2:-returning} in returning|fresh) ;; *) echo "login: mode '$2' is not returning or fresh"; return 1;; esac
                _sc_ac_max login $# 2 ;;
        logout|rmb|cast|hidechat) _sc_ac_p "${1:-}" || return 1; _sc_ac_max "$v" $# 1 ;;
        wiggle) _sc_ac_max wiggle $# 0 ;;
        settle) _sc_ac_n "${1:-}" settle || return 1
                [ -n "${2:-}" ] || { echo 'settle: give the reason: settle <secs> "<reason>"'; return 1; }
                _sc_ac_max settle $# 2 ;;
        key)    _sc_ac_p "${1:-}" || return 1; [ $# -ge 2 ] || { echo "key: no keys"; return 1; } ;;
        hold)   _sc_ac_p "${1:-}" || return 1; [ -n "${2:-}" ] || { echo "hold: no key"; return 1; }
                _sc_ac_n "${3:-}" "hold secs" || return 1; _sc_ac_max hold $# 3 ;;
        type|chat) _sc_ac_p "${1:-}" || return 1; [ -n "${2:-}" ] || { echo "$v: no text"; return 1; }; _sc_ac_max "$v" $# 2 ;;
        mouse|click) _sc_ac_p "${1:-}" || return 1
                [[ ${2:-} =~ ^[0-9]+$ && ${3:-} =~ ^[0-9]+$ ]] || { echo "$v: x y must be screen pixels"; return 1; }
                _sc_ac_max "$v" $# 3 ;;
        look)   _sc_ac_p "${1:-}" || return 1; _sc_ac_i "${2:-}" "look dx" || return 1
                [ -z "${3:-}" ] || _sc_ac_i "$3" "look dy" || return 1; _sc_ac_max look $# 3 ;;
        turn)   _sc_ac_p "${1:-}" || return 1; _sc_ac_i "${2:-}" "turn dx" || return 1
                [ -z "${3:-}" ] || [[ $3 =~ ^[0-9]+$ ]] || { echo "turn: steps '$3' is not a count"; return 1; }
                _sc_ac_max turn $# 3 ;;
        scroll) _sc_ac_p "${1:-}" || return 1; [ -n "${2:-}" ] || { echo "scroll: no quick-key"; return 1; }
                shift 2
                if [ $# -gt 0 ] && [ "$1" != until ]; then shift; fi      # the close key (or none)
                if [ $# -gt 0 ]; then
                    [ $# = 6 ] && [ "$1" = until ] && [ "$2" = server ] && [ -n "$3" ] && _sc_is_num "$4" && [ "$5" = tries ] && [[ $6 =~ ^[0-9]+$ ]] \
                        || { echo "scroll: expected scroll <p> <quickkey> [<closekey>|none] [until server <ERE> <cap> tries <n>]"; return 1; }
                fi ;;
        console|server) _sc_ac_p "${1:-}" || return 1; [ -n "${2:-}" ] || { echo "$v: no command"; return 1; }
                [ "$v" = server ] || _sc_ac_line "${2:-}" console || return 1
                _sc_ac_max "$v" $# 2 ;;
        console-file) _sc_ac_p "${1:-}" || return 1; [ -n "${2:-}" ] || { echo "console-file: no file"; return 1; }
                [ -f "$SC_DIR/$2" ] || { echo "console-file: no file $2 in the scenario dir"; return 1; }
                _sc_ac_max console-file $# 2 || return 1
                _sc_ac_console_file "$SC_DIR/$2" "$2" ;;
        console-object) _sc_ac_p "${1:-}" || return 1
                [ $# = 4 ] || { echo "console-object: expected <p> \"<cell>\" <refnum-mpnum> \"<cmd>\""; return 1; }
                [[ $3 =~ ^[0-9]+-[0-9]+$ ]] || { echo "console-object: '$3' is not <refnum>-<mpnum> (e.g. 0-12)"; return 1; }
                _sc_ac_line "$2" console-object || return 1; _sc_ac_line "$4" console-object || return 1 ;;
        save)   if [ "${1:-}" = cell ]; then [ -n "${2:-}" ] || { echo "save cell: no cell"; return 1; }
                    _sc_ac_line "$2" "save cell" || return 1; _sc_ac_max save $# 2
                else _sc_ac_p "${1:-}" || return 1; _sc_ac_max save $# 1; fi ;;
        probe)  _sc_ac_p "${1:-}" || return 1; _sc_ac_kind "${2:-}" probe dump || return 1; _sc_ac_max probe $# 2 ;;
        wait)   case ${1:-} in
                    server) _sc_ac_e "${2:-}" "wait server" || return 1; _sc_ac_cap "${3:-}" "wait server" || return 1; _sc_ac_max "wait server" $# 3 ;;
                    client) _sc_ac_p "${2:-}" || return 1; _sc_ac_e "${3:-}" "wait client" || return 1
                            _sc_ac_cap "${4:-}" "wait client" || return 1; _sc_ac_max "wait client" $# 4 ;;
                    probe)  _sc_ac_p "${2:-}" || return 1; _sc_ac_e "${3:-}" "wait probe" || return 1
                            _sc_ac_cap "${4:-}" "wait probe" || return 1; _sc_ac_max "wait probe" $# 4 ;;
                    stable) _sc_ac_p "${2:-}" || return 1; [ -z "${3:-}" ] || _sc_ac_g "$3" "wait stable" || return 1
                            for x in "${@:4}"; do _sc_ac_n "$x" "wait stable" || return 1; done
                            _sc_ac_max "wait stable" $# 6 ;;
                    *) echo "wait: expected server|client|probe|stable, got '${1:-}'"; return 1 ;;
                esac ;;
        assert) case ${1:-} in
                    server) _sc_ac_e "${2:-}" "assert server" || return 1; _sc_ac_cap "${3:-}" "assert server" || return 1; _sc_ac_max "assert server" $# 3 ;;
                    client) _sc_ac_p "${2:-}" || return 1; _sc_ac_e "${3:-}" "assert client" || return 1
                            _sc_ac_cap "${4:-}" "assert client" || return 1; _sc_ac_max "assert client" $# 4 ;;
                    absent) case ${2:-} in
                                server) _sc_ac_e "${3:-}" "assert absent" || return 1; _sc_ac_max "assert absent server" $# 3 ;;
                                client) _sc_ac_p "${3:-}" || return 1; _sc_ac_e "${4:-}" "assert absent" || return 1; _sc_ac_max "assert absent client" $# 4 ;;
                                *) echo "assert absent: expected server|client <p>"; return 1 ;;
                            esac ;;
                    count)  case ${2:-} in
                                server) shift 2 ;;
                                client) _sc_ac_p "${3:-}" || return 1; shift 3 ;;
                                *) echo "assert count: expected 'assert count server|client <p> <fixed> <op> <n>'"; return 1 ;;
                            esac
                            [ $# = 3 ] || { echo "assert count: expected <fixed> <op> <n> after the log, got $# argument(s) (quote the operator: '>=')"; return 1; }
                            _sc_ac_op "$2" || return 1
                            [[ $3 =~ ^[0-9]+$ ]] || { echo "assert count: <n> '$3' is not a count"; return 1; } ;;
                    probe)  _sc_ac_p "${2:-}" || return 1; _sc_ac_kind "${3:-}" "assert probe" || return 1
                            [ $# -ge 4 ] || { echo "assert probe: expected <p> <kind> <field><op><value>... (e.g. actor=b 'dist<400')"; return 1; }
                            for x in "${@:4}"; do _sc_ac_cond "$x" || return 1; done ;;
                    probe-delta) shift; _sc_ac_delta "$@" || return 1 ;;
                    probe-count) _sc_ac_p "${2:-}" || return 1; _sc_ac_kind "${3:-}" "assert probe-count" || return 1
                            case ${4:-} in =|'!='|'<'|'<='|'>'|'>=') ;; *) echo "assert probe-count: expected <p> <kind> <op> <n> [<field><op><value>...]; operator '${4:-}' is not one of = != < <= > >= (quote it: '>=')"; return 1;; esac
                            [[ ${5:-} =~ ^[0-9]+$ ]] || { echo "assert probe-count: <n> '${5:-}' is not a count"; return 1; }
                            for x in "${@:6}"; do _sc_ac_cond "$x" || return 1; done ;;
                    json)   [ -n "${2:-}" ] && [ -n "${3:-}" ] || { echo "assert json: expected <relpath> '<python expression>'"; return 1; }
                            _sc_ac_max "assert json" $# 3 ;;
                    *) echo "assert: expected server|client|absent|count|probe|probe-delta|probe-count|json, got '${1:-}'"; return 1 ;;
                esac ;;
        shot)   _sc_ac_p "${1:-}" || return 1; [ -n "${2:-}" ] || { echo "shot: no name"; return 1; }
                [ -z "${3:-}" ] || _sc_ac_g "$3" "shot crop" || return 1; _sc_ac_max shot $# 3 ;;
        pair)   [ -n "${1:-}" ] && [ -n "${2:-}" ] && [ -n "${3:-}" ] || { echo "pair: expected <name> <A> <B> [metric] [floor]"; return 1; }
                [ -z "${5:-}" ] || _sc_ac_n "$5" "pair floor" || return 1; _sc_ac_max pair $# 5 ;;
        signature) _sc_ac_max signature $# 1 ;;
        checkpoint) [ -n "${1:-}" ] || { echo "checkpoint: no name"; return 1; }
                case ${2:-} in ''|sp|mp-only) ;; *) echo "checkpoint: mode '$2' is not sp or mp-only"; return 1;; esac
                case ${3:-} in ''|divergent) ;; *) echo "checkpoint: third argument must be 'divergent'"; return 1;; esac
                _sc_ac_max checkpoint $# 3 ;;
        mark)   [ "${1:-}" != start ] || { echo "mark: 'start' is predefined"; return 1; }; _sc_ac_max mark $# 1 ;;
        artifact) [ -n "${1:-}" ] || { echo "artifact: no file"; return 1; }; _sc_ac_max artifact $# 2 ;;
        *)      return 0 ;;
    esac
}

# ================================================================================================
# Players
# ================================================================================================
_sc_known() { [ -n "${SC_SLOT[$1]+x}" ]; }
_sc_disp() { case ${SC_SLOT[$1]} in 1) printf '%s' "$RIG_DISPLAY";; 2) printf '%s' "$RIG_DISPLAY2";; 3) printf '%s' "$RIG_DISPLAY3";; esac; }
_sc_pid()  { case ${SC_SLOT[$1]} in 1) printf '%s' "${RIG_CLI:-}";; 2) printf '%s' "${RIG_CLI2:-}";; 3) printf '%s' "${RIG_CLI3:-}";; esac; }
# _sc_need_client <p> — the player is known, booted and its client alive; else a FAIL row (return 1).
_sc_need_client() {
    local p=${1:-} pid
    _sc_known "$p" || { _sc_row FAIL "" "unknown player '$p' (PLAYERS=${SC_PLAYERS[*]})"; return 1; }
    [ -n "${SC_BOOTED[$p]:-}" ] || { _sc_row FAIL "" "player $p is not booted (call boot $p first)"; return 1; }
    pid=$(_sc_pid "$p")
    kill -0 "$pid" 2>/dev/null || { _sc_infra "client $p (pid $pid) exited (see client-$p.log)"; return 1; }
    return 0
}
# Grab the player's display before an input verb: the baseline `wait stable` compares against.
_sc_baseline() { rig_grab_region "$(_sc_disp "$1")" FULL "$SC_RUN/.baseline-$1.png" 2>/dev/null || true; }
_sc_wiggler_restart() {
    if [ -n "${RIG_WIGGLER:-}" ]; then kill "$RIG_WIGGLER" 2>/dev/null; RIG_WIGGLER=''; fi
    rig_start_idle_wiggler 3>&-
}

# ================================================================================================
# Lifecycle verbs
# ================================================================================================
_scv_boot() {
    _sc_begin boot "$@" || return 0
    local p
    [ $# -gt 0 ] || { _sc_infra "boot: name at least one player"; return 1; }
    for p in "$@"; do _sc_known "$p" || { _sc_infra "boot: unknown player '$p' (PLAYERS=${SC_PLAYERS[*]})"; return 1; }; done
    SC_BOOT_MSG=''
    if ! _sc_boot_impl "$@"; then _sc_infra "$SC_BOOT_MSG"; return 1; fi
    [ -n "${RIG_WIGGLER:-}" ] && _sc_wiggler_restart
    _sc_close_row OK "$SC_BOOT_MSG"
}
# _sc_boot_impl <players>... — start what is not running and wait for each client's connection and
# boot milestone. Sets SC_BOOT_MSG (the detail, or the reason on failure); returns 1 on failure.
_sc_boot_impl() {
    local p slot log pid t0 deadline out='' hit miss='' how srvnew=0
    for p in "$@"; do [ -n "${SC_BOOTED[$p]:-}" ] && { SC_BOOT_MSG="boot: $p is already booted"; return 1; }; done
    if [ -z "${RIG_SRV:-}" ]; then
        if ! ( rig_require_clean ) 2>/dev/null; then SC_BOOT_MSG="boot: a $RIG_SERVER_BIN is already running (left by bin/rig up or a crashed run); stop it with: bin/rig down"; return 1; fi
        srvnew=1
        rig_start_server 3>&-
        kill -0 "$RIG_SRV" 2>/dev/null || { SC_BOOT_MSG="boot: the server exited during start (see server.log)"; return 1; }
        out="server pid $RIG_SRV;"
    fi
    for p in "$@"; do
        slot=${SC_SLOT[$p]}; log=$SC_RUN/client-$p.log
        case $slot in
            1) rig_start_xvfb 3>&-;  rig_make_profile "$RIG_PROFILE"; rig_start_client "$log" 3>&- ;;
            2) rig_start_xvfb2 3>&-; rig_start_client2 "$log" 3>&- ;;
            3) rig_start_xvfb3 3>&-; rig_start_client3 "$log" 3>&- ;;
        esac
        SC_BOOTED[$p]=1; SC_EVER_BOOTED[$p]=1
    done
    # The implicit mark: after the clients start (each start truncates its log), before the waits. A
    # server this boot started is read from its first line.
    _sc_mark_all
    [ "$srvnew" = 1 ] && SC_OFF[server]=0
    t0=$SECONDS; deadline=$((t0 + RIG_BOOT_CAP))
    for p in "$@"; do
        log=$SC_RUN/client-$p.log; pid=$(_sc_pid "$p")
        while ! grep -q 'ID_CONNECTION_REQUESTED_ACCEPTED' "$log" 2>/dev/null; do
            kill -0 "$pid" 2>/dev/null || { SC_BOOT_MSG="boot: client $p exited before connecting (see client-$p.log)"; return 1; }
            (( SECONDS >= deadline )) && { SC_BOOT_MSG="boot: client $p did not connect within RIG_BOOT_CAP=${RIG_BOOT_CAP}s (see client-$p.log)"; return 1; }
            sleep 1
        done
        out="$out $p connected +$((SECONDS-t0))s;"
    done
    # Boot milestone, per client, cap RIG_WORLD_LOAD from here: the client logs 'Sending ID_PLAYER_MAP'
    # as its initial world load completes, or (content that never sends it) its display shows a
    # rendered, settled frame: not black, and two consecutive grabs within 0.012 RMSE (KB-15).
    t0=$SECONDS; deadline=$((t0 + RIG_WORLD_LOAD)); hit=1
    for p in "$@"; do
        if how=$(_sc_boot_ready "$p" "$deadline"); then out="$out $p ready ($how) +$((SECONDS-t0))s;"; SC_BOOT_HOW[$p]=$how
        else hit=0; miss="$miss $p"; fi
    done
    if [ "$hit" = 1 ]; then sleep "$RIG_BOOT_SETTLE"
    else out="$out no boot milestone from${miss} within RIG_WORLD_LOAD=${RIG_WORLD_LOAD}s (proceeding)"; fi
    SC_BOOT_MSG=$out
}

# _sc_boot_ready <p> <deadline> — echo "probe ready", "milestone" or "stable frame" once the client is
# ready; 1 at the deadline. With PROBE=1 only the probe's [rigprobe:ready] line counts: it is printed on
# the first frame the player script runs, in the world.
_sc_boot_ready() {
    local p=$1 deadline=$2 log disp tdir prev='' cur d m same=0
    log=$SC_RUN/client-$p.log; disp=$(_sc_disp "$p")
    if [ "${PROBE:-0}" = 1 ]; then
        while (( SECONDS < deadline )); do
            grep -aq '\[rigprobe:ready\]' "$log" 2>/dev/null && { echo "probe ready"; return 0; }
            sleep 1
        done
        return 1
    fi
    tdir=$(mktemp -d)
    while (( SECONDS < deadline )); do
        if grep -q 'Sending ID_PLAYER_MAP' "$log" 2>/dev/null; then rm -rf "$tdir"; echo milestone; return 0; fi
        cur=$tdir/$SECONDS.png
        if DISPLAY="$disp" import -window root "$cur" 2>/dev/null; then
            m=$(magick "$cur" -format '%[fx:mean]' info: 2>/dev/null)
            # Three consecutive non-black grabs within 0.012 RMSE of each other (two comparisons).
            if [ -n "$prev" ] && awk -v m="${m:-0}" 'BEGIN{exit !(m+0 > 0.01)}'; then
                d=$(_rig_rmse "$prev" "$cur")
                if [ -n "$d" ] && awk -v v="$d" 'BEGIN{exit !(v+0 <= 0.012)}'; then same=$((same+1)); else same=0; fi
                [ "$same" -ge 2 ] && { rm -rf "$tdir"; echo "stable frame"; return 0; }
            else same=0; fi
            prev=$cur
        fi
        sleep 1
    done
    rm -rf "$tdir"
    return 1
}
_scv_login() {
    _sc_begin login "$@" || return 0
    local p=${1:-} mode=${2:-returning} disp cap re
    _sc_known "$p" || { _sc_infra "login: unknown player '$p'"; return 1; }
    [ -n "${SC_BOOTED[$p]:-}" ] || { _sc_infra "login: player $p is not booted"; return 1; }
    disp=$(_sc_disp "$p")
    _sc_mark_all
    case $mode in
        returning) rig_login "$disp" "$p" "${SC_PASS[$p]}" 0 "$SC_RUN/client-$p.log" >&2; cap=$RIG_LOGIN_CAP ;;
        fresh)     rig_register_player "$disp" "$p" "${SC_PASS[$p]}" >&2;               cap=$((RIG_LOGIN_CAP * 3)) ;;
        *)         _sc_infra "login: mode '$mode' is not returning or fresh"; return 1 ;;
    esac
    re="\[rig-bridge\] player $p in"
    if ! _sc_poll "$cap" _sc_grep_from "$(_sc_logfile server)" "${SC_OFF[server]:-0}" "$re"; then
        local hint=''
        [ "${SC_BOOT_HOW[$p]:-}" = "stable frame" ] && hint="; the boot milestone was a settled frame, possibly a loading screen: raise RIG_WORLD_LOAD"
        grep -qs '\[rig-bridge\] off' "$(_sc_logfile server)" && hint="$hint; the server bridge is off: see its '[rig-bridge] off' line in server.log"
        grep -qs '\[rig-bridge\] loaded' "$(_sc_logfile server)" || hint="$hint; server.log has no '[rig-bridge] loaded' line: the bridge did not load (bin/rig doctor checks RIG_CORESCRIPTS)"
        _sc_infra "login $p: no '[rig-bridge] player $p in' in server.log within ${cap}s (wrong password, or the client never reached the world; see client-$p.log$hint)"
        return 1
    fi
    SC_IN[$p]=1
    rig_wait_stable "$disp" FULL 12 0.7 0.012 - >/dev/null 2>&1 || true     # let the world finish rendering
    if [ "$SC_FIRST_LOGIN" = 1 ]; then
        SC_FIRST_LOGIN=0
        [ "$WIGGLE" != 0 ] && _sc_wiggler_restart
    fi
    _sc_close_row OK "server logged $p in ($mode)"
}
_scv_logout() {
    _sc_begin logout "$@" || return 0
    local p=${1:-} det
    _sc_need_client "$p" || return 1
    _sc_mark_all
    rig_logout "$(_sc_pid "$p")"
    unset "SC_IN[$p]" "SC_BOOTED[$p]"
    if _sc_poll 20 _sc_grep_from "$(_sc_logfile server)" "${SC_OFF[server]:-0}" "\[rig-bridge\] player $p out"; then
        det="server logged $p out"
    else det="client stopped; the server did not log '[rig-bridge] player $p out' within 20s"; fi
    _sc_close_row OK "$det"
}
# wiggle and settle are waits: they do not move the implicit mark.
_scv_wiggle() {
    _sc_begin wiggle "$@" || return 0
    _sc_wiggler_restart
    _sc_row OK "" "idle wiggler on every booted display"
}
_scv_settle() {
    _sc_begin settle "$@" || return 0
    local s=${1:-} why=${2:-}
    _sc_is_num "$s" || { _sc_row FAIL "" "settle: '$s' is not a number of seconds"; return 1; }
    sleep "$s"
    _sc_row OK "" "${why:-warning: settle without a reason}"
}

# ================================================================================================
# Input verbs — each: check the client, grab the wait-stable baseline, implicit mark, act
# ================================================================================================
# _sc_input <p> <cmd>... — mark, run cmd, close the row: a later assert sees what the input caused.
_sc_input() {
    local p=$1; shift
    _sc_need_client "$p" || return 1
    _sc_baseline "$p"
    _sc_mark_all
    if "$@" >&2; then _sc_close_row OK ""
    else _sc_close_row FAIL "input command failed: $*"; fi
}
_scv_key()   { _sc_begin key "$@" || return 0; local p=${1:-}; shift; [ $# -gt 0 ] || { _sc_row FAIL "" "key: no keys"; return 1; }
               _sc_input "$p" rig_key "$(_sc_disp_safe "$p")" "$@"; }
_scv_hold()  {
    _sc_begin hold "$@" || return 0
    local p=${1:-} k=${2:-} s=${3:-}
    _sc_is_num "$s" || { _sc_row FAIL "" "hold: '$s' is not a number of seconds"; return 1; }
    case $k in mouse1) _sc_input "$p" _sc_hold_button "$(_sc_disp_safe "$p")" 1 "$s" ;;
               mouse3) _sc_input "$p" _sc_hold_button "$(_sc_disp_safe "$p")" 3 "$s" ;;
               '') _sc_row FAIL "" "hold: no key"; return 1 ;;
               *)  _sc_input "$p" rig_tap "$(_sc_disp_safe "$p")" "$k" "$s" ;;
    esac
}
_sc_hold_button() { DISPLAY="$1" xdotool mousedown "$2" && sleep "$3" && DISPLAY="$1" xdotool mouseup "$2"; }
_scv_type()  { _sc_begin type "$@" || return 0; _sc_input "${1:-}" rig_type "$(_sc_disp_safe "${1:-}")" "${2:-}"; }
_scv_mouse() { _sc_begin mouse "$@" || return 0; _sc_input "${1:-}" _sc_mousemove "$(_sc_disp_safe "${1:-}")" "${2:-}" "${3:-}"; }
_sc_mousemove() { [[ $2 =~ ^[0-9]+$ && $3 =~ ^[0-9]+$ ]] || return 1; DISPLAY="$1" xdotool mousemove "$2" "$3"; }
_scv_click() { _sc_begin click "$@" || return 0
               [[ ${2:-} =~ ^[0-9]+$ && ${3:-} =~ ^[0-9]+$ ]] || { _sc_row FAIL "" "click: x y must be screen pixels"; return 1; }
               _sc_input "${1:-}" rig_click "$(_sc_disp_safe "${1:-}")" "$2" "$3"; }
_scv_rmb()   { _sc_begin rmb "$@" || return 0; _sc_input "${1:-}" rig_rmb "$(_sc_disp_safe "${1:-}")"; }
_scv_look()  { _sc_begin look "$@" || return 0
               [[ ${2:-x} =~ ^-?[0-9]+$ && ${3:-0} =~ ^-?[0-9]+$ ]] || { _sc_row FAIL "" "look: dx dy must be integers"; return 1; }
               _sc_input "${1:-}" rig_look "$(_sc_disp_safe "${1:-}")" "$2" "${3:-0}"; }
_scv_turn()  { _sc_begin turn "$@" || return 0
               [[ ${2:-x} =~ ^-?[0-9]+$ && ${3:-4} =~ ^[0-9]+$ ]] || { _sc_row FAIL "" "turn: dx must be an integer, steps a count"; return 1; }
               _sc_input "${1:-}" rig_turn "$(_sc_disp_safe "${1:-}")" "$2" "${3:-4}"; }
_scv_chat()  { _sc_begin chat "$@" || return 0; _sc_input "${1:-}" rig_chat_command "$(_sc_disp_safe "${1:-}")" "${2:-}"; }
_scv_cast()  { _sc_begin cast "$@" || return 0; _sc_input "${1:-}" _sc_hold_button "$(_sc_disp_safe "${1:-}")" 1 0.25; }
_sc_disp_safe() { if _sc_known "${1:-}"; then _sc_disp "$1"; fi; }
# scroll <p> <quickkey> [<closekey>|none] [until server <ERE> <cap> tries <n>] — read a scroll bound to
# a quick-key: the quick-key, the close key (default space: closes the read parchment; `none` in
# combat, where no parchment opens), a cast; with `until`, repeat until the server logs the ERE (KB-2).
_scv_scroll() {
    _sc_begin scroll "$@" || return 0
    local p=${1:-} qk=${2:-} close=space re='' cap=8 tries=1 i disp start
    shift 2
    if [ $# -gt 0 ] && [ "$1" != until ]; then close=$1; shift; fi
    if [ $# -gt 0 ]; then re=$3; cap=$4; tries=$6; fi
    _sc_need_client "$p" || return 1
    disp=$(_sc_disp "$p"); _sc_baseline "$p"
    _sc_mark_all
    start=$(_sc_size "$(_sc_logfile server)")
    for ((i=1; i<=tries; i++)); do
        rig_key "$disp" "$qk"; sleep 2
        [ "$close" != none ] && { rig_key "$disp" "$close"; sleep 1; }
        _sc_hold_button "$disp" 1 0.25
        [ -z "$re" ] && { _sc_close_row OK ""; return 0; }
        if _sc_poll "$cap" _sc_grep_from "$(_sc_logfile server)" "$start" "$re"; then
            _sc_close_row OK "server logged /$re/ on try $i"; return 0
        fi
    done
    _sc_close_row FAIL "no /$re/ in server.log after $tries tries (${cap}s each)"
}
# hidechat <p> — press the chat toggle until the client log's last chat-mode line is "Chat hidden" (KB-4).
_scv_hidechat() {
    _sc_begin hidechat "$@" || return 0
    local p=${1:-} disp log n before after t0
    _sc_need_client "$p" || return 1
    disp=$(_sc_disp "$p"); log=$SC_RUN/client-$p.log; _sc_baseline "$p"
    _sc_mark_all
    for n in 1 2 3 4 5 6 7 8; do
        if [ "$(grep -oE 'Chat hidden|Chat visible|Chat appearing when needed' "$log" 2>/dev/null | tail -1)" = "Chat hidden" ]; then
            sleep 0.5; _sc_close_row OK "chat hidden after $((n-1)) press(es) of $RIG_CHAT_KEY"; return 0
        fi
        before=$(grep -c "Switch chat mode" "$log" 2>/dev/null)
        rig_key "$disp" "$RIG_CHAT_KEY"
        t0=$SECONDS
        while (( SECONDS - t0 < 2 )); do
            after=$(grep -c "Switch chat mode" "$log" 2>/dev/null)
            [ "${after:-0}" -gt "${before:-0}" ] && break
            sleep 0.3
        done
    done
    _sc_close_row FAIL "client $p never logged 'Chat hidden' after 8 presses of $RIG_CHAT_KEY (set RIG_CHAT_KEY?)"
}

# ================================================================================================
# Setup verbs — commands pushed through the server bridge (overlay/scripts/custom/rig-bridge.lua)
# ================================================================================================
# The command file protocol, in <run>/bridge/ (the server reads RIG_BRIDGE_DIR):
#   cmd-<seq>.meta  one line, tab-separated: <verb> <player> <arg>...  (renamed into place: atomic)
#   cmd-<seq>.lua   the body of a `lua` command (written before the .meta)
#   done-<seq> / err-<seq>  the bridge's answer: one line of detail
# seq counts 1, 2, 3 ... per run; the bridge executes them in order. A probe request's seq is the
# seq the client probe echoes in its lines.
SC_BRIDGE_SEQ=0 SC_BRIDGE_REPLY=''
_sc_bridge_answered() { [ -f "$1/done-$2" ] || [ -f "$1/err-$2" ]; }
# _sc_bridge_send <verb> <player> [arg]... [--body <text>] — write one command and await its answer.
# Returns 0 done, 1 err (SC_BRIDGE_REPLY holds the message), 2 no answer within RIG_BRIDGE_CAP.
_sc_bridge_send() {
    local dir=$SC_RUN/bridge seq body='' have_body=0 line
    local -a f=()
    while [ $# -gt 0 ]; do
        if [ "$1" = --body ]; then body=${2:-}; have_body=1; shift 2; continue; fi
        f+=("$1"); shift
    done
    mkdir -p "$dir"
    seq=$((SC_BRIDGE_SEQ + 1)); SC_BRIDGE_SEQ=$seq; SC_BRIDGE_REPLY=''
    [ "$have_body" = 1 ] && printf '%s\n' "$body" > "$dir/cmd-$seq.lua"
    line=$(IFS=$'\t'; printf '%s' "${f[*]}")
    printf '%s\n' "$line" > "$dir/.cmd-$seq.tmp" && mv "$dir/.cmd-$seq.tmp" "$dir/cmd-$seq.meta"
    if ! _sc_poll "$RIG_BRIDGE_CAP" _sc_bridge_answered "$dir" "$seq"; then return 2; fi
    if [ -f "$dir/done-$seq" ]; then SC_BRIDGE_REPLY=$(head -c 300 "$dir/done-$seq"); return 0; fi
    SC_BRIDGE_REPLY=$(head -c 300 "$dir/err-$seq"); return 1
}
_sc_bridge_timeout() {
    _sc_infra "the server bridge did not answer command $SC_BRIDGE_SEQ within RIG_BRIDGE_CAP=${RIG_BRIDGE_CAP}s (bridge/cmd-$SC_BRIDGE_SEQ.meta unanswered). First check: grep rig-bridge server.log — no 'loaded' line: the bridge was not required; no 'commands from' line: RIG_BRIDGE_DIR did not reach the server"
}
# _sc_setup_ready <p> — the player's client runs and the server logged it in; else a FAIL row.
_sc_setup_ready() {
    _sc_need_client "${1:-}" || return 1
    [ -n "${SC_IN[$1]:-}" ] || { _sc_row FAIL "" "$1 is not logged in (the server pushes the command to a logged-in player: login $1 first)"; return 1; }
    return 0
}
# _sc_bridge_row <verb> <player> [arg]... — send one command and close the row with its answer.
_sc_bridge_row() {
    local rc=0
    _sc_bridge_send "$@" || rc=$?
    case $rc in
        0) _sc_close_row OK "bridge $SC_BRIDGE_SEQ: $SC_BRIDGE_REPLY" ;;
        1) _sc_close_row FAIL "bridge $SC_BRIDGE_SEQ refused: $SC_BRIDGE_REPLY" ;;
        *) _sc_bridge_timeout ;;
    esac
}
_scv_console() {
    _sc_begin console "$@" || return 0
    _sc_setup_ready "${1:-}" || return 1
    _sc_mark_all
    _sc_bridge_row console "$1" "${2:-}"
}
_scv_console_object() {
    _sc_begin console-object "$@" || return 0
    _sc_setup_ready "${1:-}" || return 1
    _sc_mark_all
    _sc_bridge_row object "$1" "$2" "$3" "$4"
}
_scv_server() {
    _sc_begin server "$@" || return 0
    _sc_setup_ready "${1:-}" || return 1
    _sc_mark_all
    _sc_bridge_row lua "$1" --body "${2:-}"
}
_scv_save() {
    _sc_begin save "$@" || return 0
    if [ "${1:-}" = cell ]; then
        [ -n "${RIG_SRV:-}" ] || { _sc_row FAIL "" "save cell: no server (boot a player first)"; return 1; }
        _sc_mark_all
        _sc_bridge_row savecell - "${2:-}"
    else
        _sc_setup_ready "${1:-}" || return 1
        _sc_mark_all
        _sc_bridge_row save "$1"
    fi
}
# console-file <p> <file> — every line that is not blank or a # comment, in order, one bridge command each.
_scv_console_file() {
    _sc_begin console-file "$@" || return 0
    local p=${1:-} file=$SC_DIR/${2:-} line n=0 sent=0 first='' rc msg
    _sc_setup_ready "$p" || return 1
    [ -f "$file" ] || { _sc_row FAIL "" "console-file: no file ${2:-} in the scenario dir"; return 1; }
    _sc_mark_all
    while IFS= read -r line || [ -n "$line" ]; do
        n=$((n + 1)); line=${line%$'\r'}
        [[ $line =~ ^[[:space:]]*(#.*)?$ ]] && continue
        if ! msg=$(_sc_ac_line "$line" "console-file ${2}:$n"); then _sc_close_row FAIL "$msg${first:+ (lines before it were sent: bridge $first-$SC_BRIDGE_SEQ)}"; return 1; fi
        rc=0; _sc_bridge_send console "$p" "$line" || rc=$?
        first=${first:-$SC_BRIDGE_SEQ}
        case $rc in
            0) sent=$((sent + 1)) ;;
            1) _sc_close_row FAIL "${2}:$n: bridge $SC_BRIDGE_SEQ refused: $SC_BRIDGE_REPLY"; return 1 ;;
            *) _sc_bridge_timeout; return 1 ;;
        esac
    done < "$file"
    _sc_close_row OK "$sent command(s) from ${2}${first:+ (bridge $first-$SC_BRIDGE_SEQ)}"
}

# ================================================================================================
# Client probe — requests by seq, line sets, conditions
# ================================================================================================
# Probe requests per player: "<seq>:<kind>" words, oldest first (a `dump` answers every kind).
declare -A SC_PROBE_REQS=()
# _sc_probe_usable <p> — 0 when the client probe is loaded on p; else SC_PROBE_WHY says why not.
_sc_probe_usable() {
    local p=$1
    SC_PROBE_WHY=''
    if [ "${PROBE:-0}" != 1 ]; then SC_PROBE_WHY=${SC_PROBE_OFF_WHY:-"probe: off (PROBE=1 in scenario.conf loads it)"}; return 1; fi
    _sc_fresh "$(_sc_logfile "probe-$p")"      # the probe log lags the client log until it is synced
    if ! grep -aq '^\[rigprobe:ready\]' "$(_sc_logfile "probe-$p")" 2>/dev/null; then
        SC_PROBE_WHY="probe: client $p never logged [rigprobe:ready] (a client without OpenMW Lua player scripts, or the probe failed to load: see client-$p.log)"
        return 1
    fi
    return 0
}
# _sc_probe_caps <p> — the caps= list of the client's last ready line.
_sc_probe_caps() {
    local line
    _sc_fresh "$(_sc_logfile "probe-$1")"
    line=$(grep -a '^\[rigprobe:ready\]' "$(_sc_logfile "probe-$1")" 2>/dev/null | tail -1)
    _sc_probe_tokens "$line" 2>/dev/null | sed -n 's/^caps=//p'
}
# _sc_probe_need_caps <p> <cap>... — 0 if every cap is present; else SC_PROBE_WHY names the first missing.
_sc_probe_need_caps() {
    local p=$1 caps c; shift
    caps=",$(_sc_probe_caps "$p"),"
    for c in "$@"; do
        case $caps in *",$c,"*) ;; *) SC_PROBE_WHY="probe: client $p lacks cap '$c' (caps=${caps:1:${#caps}-2})"; return 1;; esac
    done
    return 0
}
# The cap a field needs beyond its kind's.
_sc_probe_field_cap() { case $1 in anim|animup) echo anim;; lock|locked) echo lock;; stance) echo stance;; dead) echo dead;; deathdone) echo deathdone;; weapon) echo equip;; esac; }
# _sc_probe_lines <p> <kind> <seq> — the request's lines of that kind (raw, from probe-<p>.log).
_sc_probe_lines() {
    local line s
    while IFS= read -r line; do
        s=$(_sc_probe_tokens "$line" 2>/dev/null | sed -n 's/^seq=//p' | head -1)
        [ "$s" = "$3" ] && printf '%s\n' "$line"
    done < <(grep -a "^\\[rigprobe:$2\\] " "$(_sc_logfile "probe-$1")" 2>/dev/null)
}
# _sc_probe_last <p> <kind> [n] — the seq of the n-th last request (default 1) that answered <kind>
# (a request of that kind or a dump). Returns 1 when there is none, 3 when that request was sent but
# never answered (its lines may arrive later and must not be read as current).
_sc_probe_last() {
    local -a hits=()
    local n=${3:-1} w k
    for w in ${SC_PROBE_REQS[$1]:-}; do
        k=${w#*:}; k=${k%%:*}
        case $k in "$2"|dump) hits+=("$w");; esac
    done
    [ "${#hits[@]}" -ge "$n" ] || return 1
    w=${hits[${#hits[@]}-n]}
    printf '%s' "${w%%:*}"
    [[ $w == *:failed ]] && return 3
    return 0
}
# _sc_probe_pick <verb> <p> <kind> [n] — SC_PICK = _sc_probe_last's seq; on none or an unanswered
# request write the FAIL row and return 1.
_sc_probe_pick() {
    local rc=0
    SC_PICK=$(_sc_probe_last "$2" "$3" "${4:-1}") || rc=$?
    case $rc in
        0) return 0 ;;
        3) _sc_row FAIL "" "$1: the last 'probe $2 $3' request (seq $SC_PICK) was not answered; its lines may still arrive, so no $3 lines are read until a new 'probe $2 $3' succeeds" ;;
        *) if [ "${4:-1}" -gt 1 ]; then _sc_row FAIL "" "$1: needs ${4} 'probe $2 $3' (or dump) requests before it"
           else _sc_row FAIL "" "$1: no 'probe $2 $3' (or dump) request before this assert"; fi ;;
    esac
    return 1
}
# _sc_probe_request <p> <kind> — push "lua rigprobe <kind> <seq>" through the bridge and await the
# client's [rigprobe:done] ... seq=<seq>. Returns 0 answered, 1 bridge refused, 2 bridge silent,
# 3 client silent. SC_PROBE_SEQ = the request's seq. A refused or unanswered request is recorded as
# failed, so a later assert on its kind FAILs instead of reading an older request.
_sc_probe_request() {
    local p=$1 kind=$2 rc=0
    _sc_bridge_send probe "$p" "$kind" || rc=$?
    SC_PROBE_SEQ=$SC_BRIDGE_SEQ
    if [ "$rc" = 0 ] && ! _sc_poll "$RIG_PROBE_CAP" _sc_grep_from "$(_sc_logfile "probe-$p")" 0 "^\\[rigprobe:done\\] .*seq=$SC_PROBE_SEQ( |\$)"; then
        rc=3
    fi
    case $rc in
        0)   SC_PROBE_REQS[$p]="${SC_PROBE_REQS[$p]:-} $SC_PROBE_SEQ:$kind" ;;
        1|3) SC_PROBE_REQS[$p]="${SC_PROBE_REQS[$p]:-} $SC_PROBE_SEQ:$kind:failed" ;;
    esac
    return "$rc"
}
# _sc_probe_request_row <p> <kind> — a request whose failure closes the current row; 0 when answered.
_sc_probe_request_row() {
    local rc=0
    _sc_probe_request "$1" "$2" || rc=$?
    case $rc in
        0) return 0 ;;
        1) _sc_row FAIL "" "probe $1 $2: bridge $SC_PROBE_SEQ refused: $SC_BRIDGE_REPLY" ;;
        2) _sc_bridge_timeout ;;
        *) _sc_row FAIL "" "probe $1 $2: client $1 did not answer seq $SC_PROBE_SEQ within RIG_PROBE_CAP=${RIG_PROBE_CAP}s (no '[rigprobe:done] ... seq=$SC_PROBE_SEQ' in probe-$1.log; see client-$1.log). It may still be answered later: every assert on $2 FAILs until a new 'probe $1 $2' succeeds" ;;
    esac
    return 1
}
# probe <p> <kind|dump> — request a probe report; later `assert probe` reads its lines. An observation:
# it does not move the mark.
_scv_probe() {
    _sc_begin probe "$@" || return 0
    local p=${1:-} kind=${2:-} last n miss
    _sc_need_client "$p" || return 1
    _sc_probe_usable "$p" || { _sc_row SKIP "" "$SC_PROBE_WHY"; return 0; }
    _sc_setup_ready "$p" || return 1
    _sc_probe_request_row "$p" "$kind" || return 1
    last=$(_sc_probe_lines "$p" 'done' "$SC_PROBE_SEQ" | tail -1)
    n=$(_sc_probe_field "$last" lines); miss=$(_sc_probe_field "$last" missing)
    _sc_row OK "" "seq $SC_PROBE_SEQ: ${n:-?} line(s) in probe-$p.log${miss:+; not available on this client: $miss}"
}
# _sc_probe_cond_parse <field><op><value> — sets SC_C_FIELD SC_C_OP SC_C_VAL.
_sc_probe_cond_parse() {
    [[ ${1:-} =~ ^([A-Za-z_][A-Za-z0-9_.]*)(!=|<=|>=|=|<|>|~)(.*)$ ]] || return 1
    SC_C_FIELD=${BASH_REMATCH[1]} SC_C_OP=${BASH_REMATCH[2]} SC_C_VAL=${BASH_REMATCH[3]}
}
_sc_is_signed() { [[ $1 =~ ^-?[0-9]+([.][0-9]+)?$ ]]; }
# _sc_probe_cmp <actual> <op> <want> — = and != compare numbers numerically when both are numbers,
# else as strings; < <= > >= need two numbers; ~ is an ERE match.
_sc_probe_cmp() {
    local a=$1 op=$2 w=$3
    case $op in
        '~')  [[ $a =~ $w ]] ;;
        '='|'!=')
            local eq=1
            if _sc_is_signed "$a" && _sc_is_signed "$w"; then awk -v a="$a" -v b="$w" 'BEGIN{exit !(a+0 == b+0)}' && eq=0
            else [ "$a" = "$w" ] && eq=0; fi
            if [ "$op" = '=' ]; then return "$eq"; else [ "$eq" != 0 ]; fi ;;
        *)    _sc_is_signed "$a" && _sc_is_signed "$w" || return 1
              awk -v a="$a" -v b="$w" -v op="$op" 'BEGIN{
                  if (op == "<") r = a+0 < b+0; else if (op == "<=") r = a+0 <= b+0
                  else if (op == ">") r = a+0 > b+0; else r = a+0 >= b+0
                  exit !r }' ;;
    esac
}
# _sc_probe_line_ok <line> <cond>... — every condition holds on the line's fields.
_sc_probe_line_ok() {
    local line=$1 kv c; shift
    declare -A fld=()
    while IFS= read -r kv; do fld[${kv%%=*}]=${kv#*=}; done < <(_sc_probe_tokens "$line")
    for c in "$@"; do
        _sc_probe_cond_parse "$c" || return 1
        [ -n "${fld[$SC_C_FIELD]+x}" ] || return 1
        _sc_probe_cmp "${fld[$SC_C_FIELD]}" "$SC_C_OP" "$SC_C_VAL" || return 1
    done
    return 0
}
# _sc_probe_field <line> <field> — print the field's value; 1 when the line has no such field.
_sc_probe_field() {
    local kv
    while IFS= read -r kv; do [ "${kv%%=*}" = "$2" ] && { printf '%s' "${kv#*=}"; return 0; }; done < <(_sc_probe_tokens "$1")
    return 1
}
# _sc_probe_quote <lines> — a request's line set for a FAIL detail: the first lines, "|"-joined, short.
_sc_probe_quote() {
    local q
    q=$(head -4 <<<"$1" | sed 's/^\[rigprobe:[^]]*\] p=[^ ]* t=[^ ]* seq=[0-9]* //' | paste -sd'|')
    [ "$(grep -c '' <<<"$1")" -gt 4 ] && q="$q|..."
    printf '%s' "${q:0:400}"
}
# _sc_probe_precheck <p> <kind> <field>... — the SKIP checks every probe assertion shares. Returns 1
# after writing a SKIP row.
_sc_probe_precheck() {
    local p=$1 kind=$2 f c; shift 2
    local -a need=("$kind")
    for f in "$@"; do c=$(_sc_probe_field_cap "$f"); [ -n "$c" ] && need+=("$c"); done
    if ! _sc_probe_usable "$p" || ! _sc_probe_need_caps "$p" "${need[@]}"; then _sc_row SKIP "" "$SC_PROBE_WHY"; return 1; fi
    return 0
}
# assert probe <p> <kind> <cond>... — PASS when one line of the last request answering <kind> meets
# every condition.
_sc_assert_probe() {
    local p=${1:-} kind=${2:-} seq lines line c
    local -a fields=()
    shift 2
    for c in "$@"; do _sc_probe_cond_parse "$c" && fields+=("$SC_C_FIELD"); done
    _sc_probe_precheck "$p" "$kind" "${fields[@]+"${fields[@]}"}" || return 0
    _sc_probe_pick "assert probe" "$p" "$kind" || return 1
    seq=$SC_PICK
    lines=$(_sc_probe_lines "$p" "$kind" "$seq")
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        if _sc_probe_line_ok "$line" "$@"; then
            _sc_row PASS "" "seq $seq: ${line:0:300}"; return 0
        fi
    done <<<"$lines"
    if [ -z "$lines" ]; then _sc_row FAIL "" "seq $seq: no $kind line with $*: the request answered no $kind lines"
    else _sc_row FAIL "" "seq $seq: no $kind line with $* among $(grep -c . <<<"$lines") line(s): $(_sc_probe_quote "$lines")"; fi
}
# assert probe-count <p> <kind> <op> <n> [<cond>...] — the number of <kind> lines of the last request
# answering <kind> that meet every condition, compared with <n>: absence (= 0) and exactly-one (= 1).
_sc_assert_probe_count() {
    local p=${1:-} kind=${2:-} op=${3:-} want=${4:-} lines line c n=0
    local -a fields=()
    shift 4
    for c in "$@"; do _sc_probe_cond_parse "$c" && fields+=("$SC_C_FIELD"); done
    _sc_probe_precheck "$p" "$kind" "${fields[@]+"${fields[@]}"}" || return 0
    _sc_probe_pick "assert probe-count" "$p" "$kind" || return 1
    lines=$(_sc_probe_lines "$p" "$kind" "$SC_PICK")
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        _sc_probe_line_ok "$line" "$@" && n=$((n + 1))
    done <<<"$lines"
    if _sc_probe_cmp "$n" "$op" "$want"; then _sc_row PASS "" "seq $SC_PICK: $n $kind line(s)${*:+ with $*}, $op $want"
    else _sc_row FAIL "" "seq $SC_PICK: $n $kind line(s)${*:+ with $*}, wanted $op $want${lines:+: $(_sc_probe_quote "$lines")}"; fi
}
# assert probe-delta <p> <kind> <field> <op> <n> [<selector>...] [<seqA> <seqB>] — the field's value in
# request B minus request A (default: the last two requests answering <kind>), compared with <n>. In
# each request the first line meeting the selectors and holding the field is used.
_sc_assert_probe_delta() {
    local p=${1:-} kind=${2:-} field=${3:-} op=${4:-} want=${5:-} sa sb a b d line x
    local -a sel=() nums=()
    shift 5
    for x in "$@"; do if [[ $x =~ ^[0-9]+$ ]]; then nums+=("$x"); else sel+=("$x"); fi; done
    _sc_probe_precheck "$p" "$kind" "$field" || return 0
    if [ "${#nums[@]}" = 2 ]; then sa=${nums[0]}; sb=${nums[1]}
    else
        _sc_probe_pick "assert probe-delta" "$p" "$kind" 1 || return 1; sb=$SC_PICK
        _sc_probe_pick "assert probe-delta" "$p" "$kind" 2 || return 1; sa=$SC_PICK
    fi
    for x in a b; do
        local s; if [ "$x" = a ]; then s=$sa; else s=$sb; fi
        local v=''
        while IFS= read -r line; do
            [ -n "$line" ] || continue
            _sc_probe_line_ok "$line" "${sel[@]+"${sel[@]}"}" || continue
            v=$(_sc_probe_field "$line" "$field") && _sc_is_signed "$v" && break
            v=''
        done < <(_sc_probe_lines "$p" "$kind" "$s")
        [ -n "$v" ] || { _sc_row FAIL "" "assert probe-delta: seq $s has no $kind line with a numeric $field${sel[*]:+ and ${sel[*]}}"; return 1; }
        if [ "$x" = a ]; then a=$v; else b=$v; fi
    done
    d=$(awk -v a="$a" -v b="$b" 'BEGIN{ printf "%g", b - a }')
    if _sc_probe_cmp "$d" "$op" "$want"; then _sc_row PASS "" "$field: $a (seq $sa) -> $b (seq $sb), delta $d $op $want"
    else _sc_row FAIL "" "$field: $a (seq $sa) -> $b (seq $sb), delta $d, wanted $op $want"; fi
}

# ================================================================================================
# Waits and assertions
# ================================================================================================
# _sc_split_since <args>... — sets SC_SINCE (the --since mark, or '') and SC_ARGS (the rest);
# returns 1 when a --since has no mark name.
_sc_split_since() {
    SC_SINCE=''; SC_ARGS=()
    while [ $# -gt 0 ]; do
        if [ "$1" = --since ]; then
            [ -n "${2:-}" ] || return 1
            SC_SINCE=$2; shift 2; continue
        fi
        SC_ARGS+=("$1"); shift
    done
    return 0
}
# _sc_window_match <logkey> <ERE> <cap> <what> — poll the window; PASS/FAIL row naming the window.
_sc_window_match() {
    local k=$1 re=$2 cap=$3 fail=$4 file start end hint=''
    file=$(_sc_logfile "$k")
    start=$(_sc_window_start "$k" "$SC_SINCE") || { _sc_row FAIL "" "no mark named '$SC_SINCE'"; return 1; }
    if _sc_poll "$cap" _sc_grep_from "$file" "$start" "$re"; then
        end=$(_sc_size "$file")
        _sc_row PASS "$k:$start-$end" "/$re/ in ${file##*/}"
        return 0
    fi
    end=$(_sc_size "$file")
    if [ "$start" -gt 0 ] && grep -qE -- "$re" < <(head -c "$start" "$file" 2>/dev/null); then
        hint=" (it matches before the window; --since <mark> widens it)"
    fi
    _sc_row "$fail" "$k:$start-$end" "no /$re/ in ${file##*/} bytes $start-$end within ${cap}s$hint"
    return 1
}
_scv_wait() {
    _sc_begin wait "$@" || return 0
    _sc_split_since "$@" || { _sc_row FAIL "" "--since needs a mark name"; return 1; }
    set -- "${SC_ARGS[@]+"${SC_ARGS[@]}"}"
    local src=${1:-} p
    case $src in
        server) [ -n "${2:-}" ] || { _sc_row FAIL "" "wait server: no ERE"; return 1; }
                _sc_window_match server "$2" "${3:-10}" FAIL ;;
        client) p=${2:-}; _sc_known "$p" || { _sc_row FAIL "" "wait client: unknown player '$p'"; return 1; }
                [ -n "${3:-}" ] || { _sc_row FAIL "" "wait client: no ERE"; return 1; }
                _sc_window_match "$p" "$3" "${4:-10}" FAIL ;;
        probe)  p=${2:-}; _sc_known "$p" || { _sc_row FAIL "" "wait probe: unknown player '$p'"; return 1; }
                [ -n "${3:-}" ] || { _sc_row FAIL "" "wait probe: no ERE"; return 1; }
                _sc_probe_usable "$p" || { _sc_row SKIP "" "$SC_PROBE_WHY"; return 0; }
                _sc_window_match "probe-$p" "$3" "${4:-10}" FAIL ;;
        stable) _sc_wait_stable "${@:2}" ;;
        *)      _sc_row FAIL "" "wait: expected server|client|probe|stable, got '$src'"; return 1 ;;
    esac
}
# wait stable <p> <crop|FULL> [cap] [eps] [delta] — KB-15; baseline = the grab before p's last input.
_sc_wait_stable() {
    local p=${1:-} geom=${2:-FULL} cap=${3:-8} eps=${4:-0.004} delta=${5:-0.05} base out
    _sc_need_client "$p" || return 1
    _sc_geom_ok "$geom" || { _sc_row FAIL "" "wait stable: '$geom' is not WxH+X+Y or FULL"; return 1; }
    base=$SC_RUN/.baseline-$p.png
    if [ -f "$base" ] && [ "$geom" != FULL ]; then
        magick "$base" -crop "$geom" +repage "$SC_RUN/.baseline-$p-crop.png" 2>/dev/null && base=$SC_RUN/.baseline-$p-crop.png
    fi
    [ -f "$base" ] || base=''
    if out=$(rig_wait_stable "$(_sc_disp "$p")" "$geom" "$cap" 0.7 "$eps" "$delta" "$base" 2>&1); then
        _sc_row OK "" "${out##*$'\n'}"
    else
        _sc_row OK "" "timeout after ${cap}s (proceeded)"
    fi
}
_sc_cmp() {   # _sc_cmp <a> <op> <b> — numeric comparison
    case $2 in
        =|==) [ "$1" -eq "$3" ];; '!=') [ "$1" -ne "$3" ];;
        '<')  [ "$1" -lt "$3" ];; '<=') [ "$1" -le "$3" ];;
        '>')  [ "$1" -gt "$3" ];; '>=') [ "$1" -ge "$3" ];;
        *) return 2;;
    esac
}
_scv_assert() {
    _sc_begin assert "$@" || return 0
    _sc_split_since "$@" || { _sc_row FAIL "" "--since needs a mark name"; return 1; }
    set -- "${SC_ARGS[@]+"${SC_ARGS[@]}"}"
    local kind=${1:-} p file c
    case $kind in
        server) [ -n "${2:-}" ] || { _sc_row FAIL "" "assert server: no ERE"; return 1; }
                _sc_window_match server "$2" "${3:-10}" FAIL ;;
        client) p=${2:-}; _sc_known "$p" || { _sc_row FAIL "" "assert client: unknown player '$p'"; return 1; }
                [ -n "${3:-}" ] || { _sc_row FAIL "" "assert client: no ERE"; return 1; }
                _sc_window_match "$p" "$3" "${4:-10}" FAIL ;;
        absent)
            local re
            case ${2:-} in
                server) file=$(_sc_logfile server); re=${3:-}; p=server ;;
                client) p=${3:-}; _sc_known "$p" || { _sc_row FAIL "" "assert absent client: unknown player '$p'"; return 1; }
                        file=$(_sc_logfile "$p"); re=${4:-} ;;
                *) _sc_row FAIL "" "assert absent: expected server|client <p>"; return 1 ;;
            esac
            [ -n "$re" ] || { _sc_row FAIL "" "assert absent: no ERE"; return 1; }
            local hit; hit=$(grep -nE -- "$re" "$file" 2>/dev/null | head -1)
            if [ -n "$hit" ]; then _sc_row FAIL "$p:0-$(_sc_size "$file")" "found /$re/ at ${file##*/}:${hit:0:200}"
            else _sc_row PASS "$p:0-$(_sc_size "$file")" "no /$re/ in ${file##*/}"; fi ;;
        count)      # assert count server <fixed> <op> <n> | assert count client <p> <fixed> <op> <n>
            local k=server
            if [ "${2:-}" = client ]; then k=${3:-}; shift 3; else shift 2; fi
            file=$(_sc_logfile "$k")
            c=$(grep -cF -- "${1:-}" "$file" 2>/dev/null); c=${c:-0}
            _sc_cmp "$c" "${2:-}" "${3:-0}"; local rc=$?
            if [ "$rc" = 2 ]; then _sc_row FAIL "" "assert count: unknown op '${2:-}' (= == != < <= > >=)"
            elif [ "$rc" = 0 ]; then _sc_row PASS "$k:0-$(_sc_size "$file")" "count('${1:-}')=$c $2 $3 in ${file##*/}"
            else _sc_row FAIL "$k:0-$(_sc_size "$file")" "count('${1:-}')=$c in ${file##*/}, wanted $2 $3"; fi ;;
        probe)       _sc_assert_probe "${@:2}" ;;
        probe-delta) _sc_assert_probe_delta "${@:2}" ;;
        probe-count) _sc_assert_probe_count "${@:2}" ;;
        json) _sc_assert_json "${2:-}" "${3:-}" ;;
        *) _sc_row FAIL "" "assert: expected server|client|absent|count|probe|probe-delta|probe-count|json, got '$kind'"; return 1 ;;
    esac
}
# assert json <relpath> '<python expression>' — d = the parsed document under the work copy's data/.
_sc_assert_json() {
    local rel=$1 expr=$2 path out rc
    [ -n "$rel" ] && [ -n "$expr" ] || { _sc_row FAIL "" "assert json: expected <relpath> '<python expression>'"; return 1; }
    path=${SC_DATA_DIR:-$RIG_CORESCRIPTS/data}/$rel
    out=$(python3 -I -c '
import json, sys
try:
    with open(sys.argv[1], encoding="utf-8") as fh:
        d = json.load(fh)
except Exception as e:
    print("cannot read %s: %s" % (sys.argv[1], e)); sys.exit(2)
try:
    r = eval(sys.argv[2], {"__builtins__": __builtins__}, {"d": d})
except Exception as e:
    print("expression error: %r" % (e,)); sys.exit(3)
print(("value=%r" % (r,))[:200])
sys.exit(0 if r else 1)
' "$path" "$expr" 2>&1); rc=$?
    if [ "$rc" = 0 ]; then _sc_row PASS "" "$rel: $out"
    else _sc_row FAIL "" "$rel: ${out:-python3 exit $rc}"; fi
}

# ================================================================================================
# Screenshots and signatures
# ================================================================================================
_scv_shot() {
    _sc_begin shot "$@" || return 0
    local p=${1:-} name=${2:-} crop=${3:-} out msg rc=0
    [ -n "$name" ] || { _sc_row FAIL "" "shot: no name"; return 1; }
    [ -z "$crop" ] || _sc_geom_ok "$crop" || { _sc_row FAIL "" "shot: crop '$crop' is not WxH+X+Y or FULL"; return 1; }
    _sc_need_client "$p" || return 1
    out=$SC_RUN/shots/$name.png; mkdir -p "$SC_RUN/shots"
    if ! rig_grab_region "$(_sc_disp "$p")" "${crop:-FULL}" "$out" || [ ! -s "$out" ]; then
        _sc_row FAIL "" "capture of $p's display $(_sc_disp "$p") failed (ImageMagick import -window root)"; return 1
    fi
    printf '%s\t%s\n' "$name" "$(date +%s.%N)" >> "$SC_RUN/shots/captures.tsv"
    SC_SHOTROW[$name]=$SC_CUR_STEP
    if [ "$SC_CAPTURE" = 1 ]; then _sc_row OK "" "captured shots/$name.png (--capture)"; return 0; fi
    if [ ! -f "$SC_DIR/reference-images/$name.png" ]; then
        if [ "$SC_STRICT" = 1 ]; then _sc_row NO-REFERENCE "" "no reference-images/$name.png (--strict-refs); candidate shots/$name.png"
        else _sc_row UNBLESSED "" "no reference-images/$name.png; candidate shots/$name.png"; fi
        return $?
    fi
    msg=$(compare_shot "$name" "$out" 2>&1) || rc=$?
    case $rc in 0) _sc_row PASS "" "$msg";; 1) _sc_row REGRESSION "" "$msg";; *) _sc_row FAIL "" "compare error: $msg";; esac
}
# pair <name> <A> <B> [metric] [floor] — two shots must DIFFER: metric >= floor.
_scv_pair() {
    _sc_begin pair "$@" || return 0
    local name=${1:-} a=${2:-} b=${3:-} metric=${4:-} floor=${5:-} mt raw v
    [ -n "$name" ] && [ -n "$a" ] && [ -n "$b" ] || { _sc_row FAIL "" "pair: expected <name> <A> <B> [metric] [floor]"; return 1; }
    SC_PAIRIN[$a]=1; SC_PAIRIN[$b]=1
    for v in "$a" "$b"; do [ -f "$SC_RUN/shots/$v.png" ] || { _sc_row FAIL "" "pair: no shot '$v' (take it with shot first)"; return 1; }; done
    if [ -z "$metric" ] || [ -z "$floor" ]; then
        mt=$(manifest_lookup "$name")
        if [ -f "$SC_DIR/reference-images/manifest.tsv" ] && awk -F'\t' -v n="$name" '$1==n{f=1} END{exit !f}' "$SC_DIR/reference-images/manifest.tsv"; then
            metric=${metric:-$(cut -f1 <<<"$mt")}; floor=${floor:-$(cut -f2 <<<"$mt")}
        fi
        metric=${metric:-RMSE}; floor=${floor:-0.02}
    fi
    raw=$(magick compare -metric "$metric" "$SC_RUN/shots/$a.png" "$SC_RUN/shots/$b.png" null: 2>&1)
    v=$(_extract_value <<<"$raw")
    [ -n "$v" ] || { _sc_row FAIL "" "pair: could not read a $metric value: ${raw:0:160}"; return 1; }
    if awk -v v="$v" -v t="$floor" 'BEGIN{exit !(v+0 >= t+0)}'; then _sc_row PASS "" "$a vs $b: $metric=$v >= $floor"
    else _sc_row FAIL "" "$a vs $b: $metric=$v < $floor (frames too similar)"; fi
}
# signature [name] — the server log's event signature against reference-logs/<name>.events.
_scv_signature() {
    _sc_begin signature "$@" || return 0
    local name=${1:-$SC_NAME} file msg rc=0
    file=$(_sc_logfile server)
    [ -f "$file" ] || { _sc_row FAIL "" "signature: no server log"; return 1; }
    logcheck_set_refs "$SC_DIR/reference-logs" "$SC_RUN/review" "$LOG_MARKERS"
    msg=$(check_log "$name" "$file" 2>&1) || rc=$?
    if [ "$SC_CAPTURE" = 1 ]; then _sc_row OK "" "captured review/$name.events (--capture)"; return 0; fi
    if [ ! -f "$SC_DIR/reference-logs/$name.events" ]; then
        if [ "$SC_STRICT" = 1 ]; then _sc_row NO-REFERENCE "" "no reference-logs/$name.events (--strict-refs); candidate review/$name.events"
        else _sc_row UNBLESSED "" "no reference-logs/$name.events; candidate review/$name.events"; fi
        return $?
    fi
    case $rc in 0) _sc_row PASS "" "$msg";; 1) _sc_row REGRESSION "" "$msg";; *) _sc_row FAIL "" "$msg";; esac
}
# checkpoint <name> [sp|mp-only] [divergent] — per logged-in player: a full-screen shot and a probe
# dump (every kind, awaited by its seq) into checkpoints/<name>/<p>.png and <p>.probe.
_scv_checkpoint() {
    _sc_begin checkpoint "$@" || return 0
    local name=${1:-} mode=${2:-} div=${3:-} dir p n=0 rc det=''
    [ -n "$name" ] || { _sc_row FAIL "" "checkpoint: no name"; return 1; }
    case $mode in ''|sp|mp-only) ;; *) _sc_row FAIL "" "checkpoint: mode must be sp or mp-only"; return 1;; esac
    case $div in ''|divergent) ;; *) _sc_row FAIL "" "checkpoint: third argument must be 'divergent'"; return 1;; esac
    dir=$SC_RUN/checkpoints/$name; mkdir -p "$dir"
    for p in "${SC_PLAYERS[@]}"; do
        [ -n "${SC_IN[$p]:-}" ] || continue
        rig_grab_region "$(_sc_disp "$p")" FULL "$dir/$p.png"
        printf '# checkpoint %s player %s mode=%s %s\n' "$name" "$p" "${mode:-sp}" "$div" > "$dir/$p.probe"
        if _sc_probe_usable "$p"; then
            rc=0; _sc_probe_request "$p" dump || rc=$?
            case $rc in
                0) _sc_probe_lines_all "$p" "$SC_PROBE_SEQ" >> "$dir/$p.probe" ;;
                2) _sc_bridge_timeout; return 1 ;;
                *) _sc_row FAIL "" "checkpoint $name: probe dump of $p failed (seq $SC_PROBE_SEQ${SC_BRIDGE_REPLY:+: $SC_BRIDGE_REPLY})"; return 1 ;;
            esac
            det="$det $p:seq $SC_PROBE_SEQ"
        else
            echo "# no probe dump: $SC_PROBE_WHY" >> "$dir/$p.probe"
        fi
        n=$((n+1))
    done
    _sc_row OK "" "checkpoints/$name: $n player(s)${det:+; probe dumps$det}"
}
# _sc_probe_lines_all <p> <seq> — every line of one request (all kinds, the done line last).
_sc_probe_lines_all() {
    local line s
    while IFS= read -r line; do
        s=$(_sc_probe_tokens "$line" 2>/dev/null | sed -n 's/^seq=//p' | head -1)
        [ "$s" = "$2" ] && printf '%s\n' "$line"
    done < "$(_sc_logfile "probe-$1")"
}

# ================================================================================================
# Misc
# ================================================================================================
_scv_mark() {
    _sc_begin mark "$@" || return 0
    [ "${1:-}" = start ] && { _sc_row FAIL "" "mark: 'start' is predefined"; return 1; }
    _sc_mark_all "${1:-}"
    _sc_row OK "$(_sc_offsets_now)" "${1:+named $1}"
}
_scv_note() { _sc_begin note "$@" || return 0; _sc_row OK "" "${*}"; }
_scv_artifact() {
    _sc_begin artifact "$@" || return 0
    local src=${1:-} name=${2:-}
    [ -n "$src" ] || { _sc_row FAIL "" "artifact: no file"; return 1; }
    [ "${src:0:1}" = / ] || src=${SC_DATA_DIR:-$RIG_CORESCRIPTS/data}/$src
    name=${name:-$(basename "$src")}
    mkdir -p "$SC_RUN/artifacts"
    if cp -a "$src" "$SC_RUN/artifacts/$name" 2>/dev/null; then _sc_row OK "" "artifacts/$name"
    else _sc_row FAIL "" "artifact: cannot copy $src"; fi
}
# Custom verbs from hooks.sh: verb_<name> becomes <name>; return 0 = OK, else FAIL; then mark.
_sc_custom() {
    local name=$1; shift
    _sc_begin "$name" "$@" || return 0
    local step=$SC_CUR_STEP line=$SC_CUR_LINE desc=$SC_CUR_DESC rc=0
    _sc_mark_all
    "verb_$name" "$@" || rc=$?
    SC_CUR_STEP=$step SC_CUR_LINE=$line SC_CUR_DESC=$desc
    if [ "$rc" = 0 ]; then _sc_close_row OK "verb_$name"; else _sc_close_row FAIL "verb_$name returned $rc"; fi
}

# _sc_define_verbs — define the verb names (child process only: several shadow shell builtins).
_sc_define_verbs() {
    local v f
    for v in $SC_VERBS; do
        f=_scv_${v//-/_}
        eval "$v() { $f \"\$@\"; }"
    done
    while IFS= read -r f; do
        v=${f#verb_}
        case " $(echo $SC_VERBS) " in *" $v "*) echo "hooks.sh: $f shadows the built-in verb '$v'" >&2; return 1;; esac
        [[ $v =~ ^[a-z][a-z0-9_-]*$ ]] || { echo "hooks.sh: $f: verb names are lower case" >&2; return 1; }
        eval "$v() { _sc_custom $v \"\$@\"; }"
    done < <(compgen -A function verb_)
    return 0
}

# ================================================================================================
# Finalize — downgrade pair inputs, rewrite steps.tsv, compute the verdict, write RESULT
# ================================================================================================
SC_TSV_HEADER=$'# step\tline\tverb\tstatus\tt+s\toffsets\tdetail'
_sc_finalize() {
    local i name code fails=0 regs=0 status
    [ "$SC_FINAL" = 1 ] && return 0
    SC_FINAL=1
    for name in "${!SC_PAIRIN[@]}"; do
        i=${SC_SHOTROW[$name]:-}; [ -n "$i" ] && [ -n "${SC_RSTAT[i]:-}" ] || continue
        case ${SC_RSTAT[i]} in
            UNBLESSED|NO-REFERENCE) SC_RSTAT[i]=OK; SC_RDET[i]="pair input (no reference needed); ${SC_RDET[i]}" ;;
        esac
    done
    for i in "${!SC_RSTAT[@]}"; do
        case ${SC_RSTAT[i]} in FAIL|NO-REFERENCE) fails=$((fails+1));; REGRESSION) regs=$((regs+1));; esac
    done
    if [ -n "$SC_INFRA" ]; then status=INFRA; code=3
    elif [ "$fails" -gt 0 ]; then status=FAIL; code=1
    elif [ "$regs" -gt 0 ]; then status=REGRESSION; code=2
    elif [ "$SC_ATTEMPT" -gt 1 ]; then status=PASS-RETRY; code=0
    else status=PASS; code=0; fi
    SC_CODE=$code
    if [ -n "$SC_RUN" ] && [ "$SC_DRY" != 1 ]; then
        { echo "$SC_TSV_HEADER"; for i in "${!SC_RSTAT[@]}"; do _sc_row_text "$i"; echo; done; } > "$SC_RUN/steps.tsv"
        _sc_result_line "$status" "$code" "${SC_NAME:-?}" "$fails" "$regs" "$SC_ATTEMPT" > "$SC_RUN/RESULT"
        rm -f "$SC_RUN"/.baseline-*.png
        if [ "${PROBE:-0}" = 1 ]; then
            for i in "${SC_PLAYERS[@]+"${SC_PLAYERS[@]}"}"; do [ -n "${SC_EVER_BOOTED[$i]:-}" ] && _sc_probe_sync "$i"; done
            rm -f "$SC_RUN"/.probe-*.off
        fi
        _sc_copy_profiles
    fi
    SC_RESULT=$(_sc_result_line "$status" "$code" "${SC_NAME:-?}" "$fails" "$regs" "$SC_ATTEMPT")
    _sc_say "$SC_RESULT"
}
# _sc_copy_profiles — copy each booted client's profile config (the content block it booted with,
# settings.cfg, MyGUI.log) into profiles/<player>/. The live profiles stay on RIG_PROFILE* (RAM-backed
# /tmp by default), because client disk writes on a slow filesystem shift frame timing.
_sc_copy_profiles() {
    local i p prof f
    for i in "${!SC_PLAYERS[@]}"; do
        p=${SC_PLAYERS[i]}
        case $i in 0) prof=$RIG_PROFILE;; 1) prof=$RIG_PROFILE2;; *) prof=$RIG_PROFILE3;; esac
        [ -n "${SC_EVER_BOOTED[$p]:-}" ] && [ -d "$prof/config/openmw" ] || continue
        mkdir -p "$SC_RUN/profiles/$p"
        for f in openmw.cfg settings.cfg MyGUI.log; do
            [ -f "$prof/config/openmw/$f" ] && cp "$prof/config/openmw/$f" "$SC_RUN/profiles/$p/"
        done
    done
    return 0
}
# _sc_finalize_skip <reason> — content missing: RESULT SKIP 4, nothing booted.
_sc_finalize_skip() {
    SC_FINAL=1; SC_CODE=4
    echo "$SC_TSV_HEADER" > "$SC_RUN/steps.tsv"
    SC_RESULT=$(_sc_result_line SKIP 4 "$SC_NAME" 0 0 "$SC_ATTEMPT")
    echo "$SC_RESULT" > "$SC_RUN/RESULT"
    _sc_say "SKIP $SC_NAME: $1"
    _sc_say "$SC_RESULT"
}

# _sc_run_steps — source steps.sh in a function scope (so `local` works there).
_sc_run_steps() {
    SC_PHASE=steps
    # shellcheck source=/dev/null
    builtin source "${SC_STEPS_FILE:-$SC_DIR/steps.sh}"
    SC_PHASE='done'
}

# ================================================================================================
# One attempt of one scenario (child process)
# ================================================================================================
_sc_on_exit() {
    local rc=$?
    if [ "$SC_FINAL" != 1 ]; then
        SC_STEP=$((SC_STEP+1)); SC_CUR_STEP=$SC_STEP; SC_CUR_LINE=runner
        if [ "$SC_PHASE" = steps ]; then SC_CUR_DESC=steps.sh; SC_INFRA="steps.sh aborted (exit $rc; see run.log)"
        else SC_CUR_DESC=setup; SC_INFRA="${SC_SETUP_WHAT:-setup} failed (exit $rc; see run.log)"; fi
        _sc_row FAIL "" "INFRA: $SC_INFRA"
        _sc_finalize
    fi
    if [ "$SC_KEEP_UP" = 1 ] && [ -n "${RIG_SRV:-}" ]; then
        _sc_say "kept up: server pid ${RIG_SRV:-} and the clients keep running; stop them with: bin/rig down"
    else
        rig_cleanup 2>/dev/null
    fi
    exit "${SC_CODE:-3}"
}
_sc_run_one() {
    local dir=$1 out=$2 msg k
    SC_DIR=$(cd "$dir" && pwd) || { echo "no scenario dir $dir" >&2; exit 3; }
    mkdir -p "$out" || exit 3
    SC_RUN=$(cd "$out" && pwd); RIG_RUN_DIR=$SC_RUN; RIG_SHOTDIR=$SC_RUN/shots
    SC_NAME=$(_sc_scenario_name "$SC_DIR")
    exec >>"$SC_RUN/run.log" 2>&1
    SC_T0=$SECONDS
    trap _sc_on_exit EXIT
    echo "$SC_TSV_HEADER" > "$SC_RUN/steps.tsv"
    _sc_say "== $SC_NAME ($SC_DIR) attempt $SC_ATTEMPT -> $SC_RUN"

    SC_SETUP_WHAT="reading scenario.conf"
    if ! _sc_load_conf "$SC_DIR"; then
        SC_STEP=1; SC_CUR_STEP=1; SC_CUR_LINE=scenario.conf; SC_CUR_DESC=conf
        _sc_infra "${SC_CONF_ERR//$'\n'/; }"; _sc_finalize; exit
    fi
    # SC_STEPS_FILE (internal; bin/rig up) runs another choreography with this scenario's conf and fixture.
    if [ ! -f "${SC_STEPS_FILE:-$SC_DIR/steps.sh}" ] || ! msg=$(bash -n "${SC_STEPS_FILE:-$SC_DIR/steps.sh}" 2>&1); then
        SC_STEP=1; SC_CUR_STEP=1; SC_CUR_LINE=steps.sh; SC_CUR_DESC="bash -n"
        _sc_infra "steps.sh: ${msg:-missing}"; _sc_finalize; exit
    fi
    if ! msg=$(rig_content_check "$CONTENT"); then
        _sc_finalize_skip "content profile '$CONTENT' is not available: ${msg//$'\n'/; }"; exit
    fi

    SC_SETUP_WHAT="checking prerequisites"
    if ! msg=$( (rig_check_prereqs) 2>&1 ); then
        SC_STEP=1; SC_CUR_STEP=1; SC_CUR_LINE=runner; SC_CUR_DESC=prereqs
        _sc_infra "$msg"; _sc_finalize; exit
    fi
    local -a ovs=()
    [ -n "$OVERLAY" ] && ovs+=("$SC_DIR/$OVERLAY")
    SC_SETUP_WHAT="building the CoreScripts work copy"
    rig_corescripts_overlay "$SC_RUN/corescripts" "${ovs[@]+"${ovs[@]}"}"
    SC_SETUP_WHAT="writing the server config"
    rig_set_server_home
    if [ -n "$SETTINGS" ]; then
        [ -f "$SC_DIR/$SETTINGS" ] || rig_die "SETTINGS: no file $SC_DIR/$SETTINGS"
        RIG_SETTINGS_SRC=$SC_DIR/$SETTINGS
    fi
    SC_SETUP_WHAT="selecting content profile $CONTENT"
    RIG_CONTENT_SOFT=1 rig_use_content "$CONTENT" || exit
    if [ "$PROBE" = 1 ] && ! rig_client_lua; then
        # A client that cannot load .omwscripts would be refused at login by the plugin check (the
        # probe is in requiredDataFiles.json): run without the probe instead; its verbs SKIP.
        SC_PROBE_OFF_WHY="probe: off for this client ($RIG_CLIENT_LUA_WHY)"
        _sc_say "note: PROBE=1, but $RIG_CLIENT_LUA_WHY: the probe is off for this run and the probe verbs SKIP"
        PROBE=0
    fi
    if [ "$PROBE" = 1 ]; then
        SC_SETUP_WHAT="installing the client probe"
        # The scenario's own probe settings win over rig.conf's.
        [ -n "$PROBE_RANGE" ] && RIG_PROBE_RANGE=$PROBE_RANGE
        [ -n "$PROBE_PERIOD" ] && RIG_PROBE_PERIOD=$PROBE_PERIOD
        rig_use_probe "$SC_RUN/probe"
    fi
    # The server bridge reads its commands from here (rig-bridge.lua: RIG_BRIDGE_DIR).
    mkdir -p "$SC_RUN/bridge"; export RIG_BRIDGE_DIR=$SC_RUN/bridge
    SC_SETUP_WHAT="loading the fixture"
    case $FIXTURE in
        -) rig_clear_state ;;
        *) rig_load_scenario "$SC_DIR/$FIXTURE" ;;
    esac
    compare_set_refs "$SC_DIR/reference-images" "" "$SC_RUN/review"
    _sc_write_env
    SC_SETUP_WHAT="loading hooks.sh"
    if [ -f "$SC_DIR/hooks.sh" ]; then
        # shellcheck source=/dev/null
        source "$SC_DIR/hooks.sh"
    fi
    _sc_define_verbs || exit
    _sc_mark_all
    _sc_run_steps
    if [ -n "${RIG_SRV:-}" ] && [ -z "$SC_INFRA" ] && ! kill -0 "$RIG_SRV" 2>/dev/null; then
        SC_STEP=$((SC_STEP+1)); SC_CUR_STEP=$SC_STEP; SC_CUR_LINE=runner; SC_CUR_DESC="server alive"
        _sc_infra "the server (pid $RIG_SRV) died during the run (see server.log)"
    fi
    _sc_finalize
    exit
}
_sc_write_env() {
    local v rigc csc bid
    rigc=$(git -C "$RIG_ROOT" rev-parse HEAD 2>/dev/null || echo unknown)
    [ -n "$(git -C "$RIG_ROOT" status --porcelain 2>/dev/null)" ] && rigc="$rigc-dirty"
    csc=$(git -C "${RIG_CORESCRIPTS_SRC:-$RIG_CORESCRIPTS}" rev-parse HEAD 2>/dev/null || echo unknown)
    [ -n "$(git -C "${RIG_CORESCRIPTS_SRC:-$RIG_CORESCRIPTS}" status --porcelain 2>/dev/null)" ] && csc="$csc-dirty"
    bid=${RIG_BUILD_ID:-}
    [ -n "$bid" ] || bid="sha256:$(sha256sum "$RIG_BUILD/$RIG_CLIENT_BIN" 2>/dev/null | cut -c1-16)"
    {
        echo "# env.txt — the inputs of this run (lib/scenario.sh)"
        echo "scenario=$SC_NAME"
        echo "scenario_dir=$SC_DIR"
        echo "attempt=$SC_ATTEMPT"
        echo "flags=capture:$SC_CAPTURE strict_refs:$SC_STRICT keep_up:$SC_KEEP_UP keep_work:$RIG_KEEP_WORK"
        echo "rig_commit=$rigc"
        echo "corescripts_commit=$csc"
        echo "build_id=$bid"
        echo "date=$(date -Is)"
        echo "host=$(uname -srm)"
        for v in $(compgen -v RIG_ | sort); do
            case $(declare -p "$v" 2>/dev/null) in
                "declare -a"*) local -n _arr=$v; printf '%s=(%s)\n' "$v" "${_arr[*]+"${_arr[*]}"}"; unset -n _arr ;;
                *) printf '%s=%s\n' "$v" "${!v}" ;;
            esac
        done
        for v in $(compgen -v P_ | sort); do printf '%s=%s\n' "$v" "${!v}"; done
    } > "$SC_RUN/env.txt"
}

# ================================================================================================
# --dry-run: conf check, bash -n, steps.sh with stubbed verbs and an empty PATH
# ================================================================================================
SC_DRY_OFF='' SC_DRY_CWD=''
declare -A SC_DRY_MARKS=()
_sc_dry_check() {   # dry-run: the shared argument checks, plus --since names a mark set earlier
    local v=$1 msg a prev=''
    if ! msg=$(_sc_argcheck "$@"); then _sc_row FAIL "" "$msg"; return; fi
    case $v in
        wait|assert)
            for a in "${@:2}"; do
                if [ "$prev" = --since ] && [ "$a" != start ] && [ -z "${SC_DRY_MARKS[$a]:-}" ]; then
                    _sc_row FAIL "" "--since $a: no earlier 'mark $a' in steps.sh"; return
                fi
                prev=$a
            done ;;
        mark) [ -n "${2:-}" ] && SC_DRY_MARKS[$2]=1 ;;
    esac
    _sc_row OK "" "dry-run"
}
_sc_dry_run() {
    local dir=$1 msg rc=0 line bad=0 i
    SC_DRY=1; SC_DIR=$(cd "$dir" && pwd) || { echo "dry-run: no dir $dir"; return 1; }
    SC_NAME=$(_sc_scenario_name "$SC_DIR")
    echo "== dry-run $SC_NAME ($SC_DIR)"
    _sc_load_conf "$SC_DIR" || { echo "FAIL ${SC_CONF_ERR}"; return 1; }
    [ -f "$SC_DIR/steps.sh" ] || { echo "FAIL steps.sh: missing"; return 1; }
    msg=$(bash -n "$SC_DIR/steps.sh" 2>&1) || { echo "FAIL steps.sh: $msg"; return 1; }
    if [ -f "$SC_DIR/hooks.sh" ]; then
        msg=$(bash -n "$SC_DIR/hooks.sh" 2>&1) || { echo "FAIL hooks.sh: $msg"; return 1; }
        # shellcheck source=/dev/null
        source "$SC_DIR/hooks.sh"
    fi
    _sc_define_verbs || return 1
    SC_DRY_OFF=$(mktemp)
    # Every command that is not a verb, a shell builtin or a function lands here (PATH is empty).
    command_not_found_handle() { printf '%s\t%s\n' "$(_sc_callsite)" "$1" >> "$SC_DRY_OFF"; return 127; }
    eval()   { printf '%s\t%s\n' "$(_sc_callsite)" eval   >> "$SC_DRY_OFF"; }
    exec()   { printf '%s\t%s\n' "$(_sc_callsite)" exec   >> "$SC_DRY_OFF"; }
    source() { printf '%s\t%s\n' "$(_sc_callsite)" source >> "$SC_DRY_OFF"; }
    local savepath=$PATH savecwd=$PWD
    # steps.sh runs in an empty directory: a file appearing there is an unquoted redirection.
    SC_DRY_CWD=$(mktemp -d); builtin cd "$SC_DRY_CWD" || return 1
    # Under set -u an unset variable ends this process inside steps.sh; say what that means.
    trap '[ "$SC_PHASE" = steps ] && echo "FAIL steps.sh aborted: an unset variable (steps.sh runs under set -u; see the bash message above)"; rm -rf "$SC_DRY_CWD" "$SC_DRY_OFF"' EXIT
    # In a dry-run every verb returns 0, so a failing top-level command of steps.sh is a mistake: most
    # often an unquoted '<' (assert probe a nearby dist<400 reads from a file named 400).
    SC_DRY_STEPS=$SC_DIR/steps.sh
    _sc_dry_err() { [ "${BASH_SOURCE[1]:-}" = "$SC_DRY_STEPS" ] && printf 'steps.sh:%s\tfailed\n' "$1" >> "$SC_DRY_OFF"; return 0; }
    set -E; trap '_sc_dry_err "$LINENO"' ERR
    # shellcheck disable=SC2123  # emptying the search path is the point
    PATH=/nonexistent-rig-dry-run     # an empty PATH would search the current directory
    _sc_run_steps || rc=$?
    PATH=$savepath
    trap - ERR; set +E
    unset -f command_not_found_handle eval exec source
    if [ -n "$(ls -A "$SC_DRY_CWD")" ]; then
        echo "FAIL steps.sh wrote $(ls -A "$SC_DRY_CWD" | sed "s/.*/'&'/" | tr '\n' ' ')in its working directory: an unquoted > or < (quote operators: assert count server 'x' '>=' 2)"
        bad=1
    fi
    builtin cd "$savecwd" || true
    while IFS=$'\t' read -r line msg; do
        if [ "$msg" = failed ]; then
            echo "FAIL $line: the command failed before any verb ran: an unquoted < or > (quote conditions: 'dist<400')?"
        else
            echo "FAIL $line: '$msg' is not a verb (external commands, eval, exec and source are not allowed in steps.sh)"
        fi
        bad=1
    done < "$SC_DRY_OFF"
    rm -f "$SC_DRY_OFF"
    for i in "${!SC_RSTAT[@]}"; do [ "${SC_RSTAT[i]}" = FAIL ] && bad=1; done
    [ "$rc" = 0 ] || { echo "FAIL steps.sh returned $rc"; bad=1; }
    if [ "$bad" = 0 ]; then echo "dry-run $SC_NAME: ok ($SC_STEP steps)"; else echo "dry-run $SC_NAME: FAILED"; fi
    return "$bad"
}

# ================================================================================================
# bin/rig run — the parent: select scenarios, run each attempt in a child, aggregate RESULTS
# ================================================================================================
_sc_usage() {
    cat <<'EOF'
usage: bin/rig run <dir>... | --tag T | --all  [--out DIR] [--capture] [--strict-refs]
                                                [--retry-failed N] [--dry-run] [--keep-up] [--keep-work]
  <dir> with a scenario.conf is one scenario; any other dir is searched for scenarios.
  --tag/--all without dirs search RIG_SCENARIOS. Exit: 0 pass, 1 fail, 2 regression, 3 infra, 4 skip.
  See docs/SCENARIO-FORMAT.md.
EOF
}
# _sc_find <root> — scenario dirs under a root (sorted).
_sc_find() { find "$1" -name scenario.conf -not -path '*/attempt-*' -printf '%h\n' 2>/dev/null | sort; }
_sc_has_tags() {   # _sc_has_tags <dir> <tag>... — every tag is a word of TAGS
    local d=$1 t tags; shift
    tags=" $(_sc_conf_get "$d/scenario.conf" TAGS) "
    for t in "$@"; do case $tags in *" $t "*) ;; *) return 1;; esac; done
}
scenario_run() {
    local out='' retries=0 dry=0 all=0 a d n i code attempt name sdir line k
    local -a tags=() args=() dirs=() codes=() names=()
    SC_CAPTURE=0 SC_STRICT=0 SC_KEEP_UP=0
    while [ $# -gt 0 ]; do
        case $1 in
            --out)          out=${2:-}; [ -n "$out" ] || { _sc_usage >&2; return 64; }; shift ;;
            --capture)      SC_CAPTURE=1 ;;
            --strict-refs)  SC_STRICT=1 ;;
            --retry-failed) retries=${2:-}; [[ $retries =~ ^[0-9]+$ ]] || { echo "rig run: --retry-failed needs a count" >&2; return 64; }; shift ;;
            --dry-run)      dry=1 ;;
            --keep-up)      SC_KEEP_UP=1; RIG_KEEP_WORK=1 ;;
            --keep-work)    RIG_KEEP_WORK=1 ;;
            --tag)          [ -n "${2:-}" ] || { _sc_usage >&2; return 64; }; tags+=("$2"); shift ;;
            --all)          all=1 ;;
            -h|--help)      _sc_usage; return 0 ;;
            -*)             echo "rig run: unknown flag $1" >&2; _sc_usage >&2; return 64 ;;
            *)              args+=("$1") ;;
        esac
        shift
    done
    if [ "${#args[@]}" -eq 0 ]; then
        if [ "$all" = 1 ] || [ "${#tags[@]}" -gt 0 ]; then read -r -a args <<<"$RIG_SCENARIOS"
        else _sc_usage >&2; return 64; fi
    fi
    for a in "${args[@]}"; do
        [ -d "$a" ] || { echo "rig run: no such directory: $a" >&2; return 64; }
        if [ -f "$a/scenario.conf" ]; then dirs+=("$(cd "$a" && pwd)")
        else while IFS= read -r d; do dirs+=("$(cd "$d" && pwd)"); done < <(_sc_find "$a"); fi
    done
    if [ "${#tags[@]}" -gt 0 ]; then
        local -a keep=()
        for d in "${dirs[@]+"${dirs[@]}"}"; do _sc_has_tags "$d" "${tags[@]}" && keep+=("$d"); done
        dirs=("${keep[@]+"${keep[@]}"}")
    fi
    [ "${#dirs[@]}" -gt 0 ] || { echo "rig run: no scenario selected (${args[*]}${tags[*]:+ tags: ${tags[*]}})" >&2; return 64; }

    if [ "$dry" = 1 ]; then
        local bad=0
        for d in "${dirs[@]}"; do bash "$_SC_LIB_DIR/scenario.sh" _dry-run "$d" || bad=1; done
        return "$bad"
    fi
    if [ "$SC_KEEP_UP" = 1 ] && [ "${#dirs[@]}" -gt 1 ]; then echo "rig run: --keep-up takes exactly one scenario" >&2; return 64; fi
    if [ "$SC_KEEP_UP" = 1 ] && [ "$retries" -gt 0 ]; then echo "rig run: --keep-up cannot be combined with --retry-failed (a retry tears the kept world down)" >&2; return 64; fi

    # The run-set dir.
    if [ -n "$out" ]; then
        if [ -e "$out" ] && [ -n "$(ls -A "$out" 2>/dev/null)" ]; then echo "rig run: --out $out exists and is not empty" >&2; return 64; fi
        mkdir -p "$out" || { echo "rig run: cannot create $out" >&2; return 3; }
        RIG_SET_DIR=$(cd "$out" && pwd)
    else
        if [ "${#dirs[@]}" -eq 1 ]; then name=$(_sc_scenario_name "${dirs[0]}")
        elif [ "${#tags[@]}" -gt 0 ]; then name=$(IFS=+; printf '%s' "${tags[*]}"); name=${name//[^A-Za-z0-9._+-]/_}
        else name='set'; fi
        RIG_RUN_DIR=''; rig_run_dir "$name" >/dev/null
        RIG_SET_DIR=$RIG_RUN_DIR; RIG_RUN_DIR=''
    fi
    : > "$RIG_SET_DIR/RESULTS"
    export RIG_SET_DIR SC_CAPTURE SC_STRICT SC_KEEP_UP RIG_KEEP_WORK
    echo "rig run: ${#dirs[@]} scenario(s) -> $RIG_SET_DIR"
    local booted_before=0
    for i in "${!dirs[@]}"; do
        d=${dirs[i]}
        name=$(_sc_scenario_name "$d"); k=$name; n=2
        while [ -e "$RIG_SET_DIR/$k" ]; do k=$name-$n; n=$((n+1)); done
        sdir=$RIG_SET_DIR/$k; names+=("$k")
        attempt=1
        while true; do
            [ "$booted_before" = 1 ] && rig_clean_slate
            code=0
            SC_ATTEMPT=$attempt bash "$_SC_LIB_DIR/scenario.sh" _run-one "$d" "$sdir" 3>&1 || code=$?
            line=$(head -1 "$sdir/RESULT" 2>/dev/null)
            if [[ $line =~ ^RESULT\ [A-Z-]+\ ([0-9])\  ]]; then code=${BASH_REMATCH[1]}
            else line=$(_sc_result_line INFRA 3 "$name" 1 0 "$attempt"); code=3; echo "$line" > "$sdir/RESULT"; fi
            [ "$code" != 4 ] && booted_before=1
            case $code in 1|2|3) ;; *) break;; esac
            [ "$attempt" -le "$retries" ] || break
            mkdir -p "$sdir/attempt-$attempt"
            for a in "$sdir"/* "$sdir"/.[!.]*; do
                [ -e "$a" ] || continue
                case ${a##*/} in attempt-*) continue;; esac
                mv "$a" "$sdir/attempt-$attempt/"
            done
            echo "rig run: $k attempt $attempt -> code $code; retrying (attempt-$attempt/ kept)"
            attempt=$((attempt+1))
        done
        echo "$line" >> "$RIG_SET_DIR/RESULTS"
        codes+=("$code")
    done
    code=$(_sc_aggregate "${codes[@]}")
    echo "---- RESULTS ($RIG_SET_DIR/RESULTS)"
    cat "$RIG_SET_DIR/RESULTS"
    echo "rig run: exit $code"
    [ "$code" = 0 ] || [ "$code" = 4 ] || echo "rig run: what failed and which file to open: bin/rig explain $RIG_SET_DIR"
    return "$code"
}

# ================================================================================================
# selftest — synthetic logs and scenarios; no game binary, no display
# ================================================================================================
scenario_selftest() {
    local t fails=0 out rc
    t=$(mktemp -d)
    _ok()  { echo "  ok   [$1]"; }
    _bad() { echo "  FAIL [$1] ${2:-}"; fails=$((fails+1)); }
    _check() { if [ "$2" = "$3" ]; then _ok "$1"; else _bad "$1" "got '$2' want '$3'"; fi; }

    # -- 1. scenario.conf parser --
    mkdir -p "$t/s1"
    cat > "$t/s1/scenario.conf" <<'EOF'
# a comment
NAME=journal-sync
PURPOSE="a journal change on one client reaches the other"
PLAYERS="a b"
TAGS="smoke two-player"   # trailing comment
CONTENT=example
LOG_MARKERS="Called \"OnPlayerJournal\"|$RIG_TRIPWIRES"
COST=3
WIGGLE=0
PROBE_RANGE=4096
P_QUEST_ID=quest_01
P_TOPIC="latest rumors"
EOF
    if out=$(_sc_conf_check "$t/s1/scenario.conf"); then _ok "conf: fixed keys + P_* accepted"; else _bad "conf: fixed keys + P_* accepted" "$out"; fi
    _check "conf: quoted P_ value"        "$(_sc_conf_get "$t/s1/scenario.conf" P_TOPIC)" "latest rumors"
    _check "conf: value with comment"     "$(_sc_conf_get "$t/s1/scenario.conf" TAGS)" "smoke two-player"
    _check "conf: bare value"             "$(_sc_conf_get "$t/s1/scenario.conf" P_QUEST_ID)" "quest_01"
    if _sc_has_tags "$t/s1" two-player smoke && ! _sc_has_tags "$t/s1" nightly; then _ok "conf: tag selection"; else _bad "conf: tag selection"; fi
    mkdir -p "$t/s1b"; printf 'PLAYERS=a\nCONTENT=example\nPROBE_RANGE=far\n' > "$t/s1b/scenario.conf"
    if ( _sc_load_conf "$t/s1b" ); then _bad "conf: a non-numeric PROBE_RANGE is refused"
    else _check "conf: a non-numeric PROBE_RANGE is refused" "$( _sc_load_conf "$t/s1b"; echo "$SC_CONF_ERR")" "scenario.conf: PROBE_RANGE 'far' is not a distance in game units"; fi
    printf 'NAME=x\nFOO=1\np_lower=2\n' > "$t/bad.conf"
    out=$(_sc_conf_check "$t/bad.conf"); rc=$?
    if [ "$rc" = 1 ] && grep -q 'unknown key FOO' <<<"$out" && grep -q 'unknown key p_lower' <<<"$out"; then _ok "conf: unknown keys rejected by name"
    else _bad "conf: unknown keys rejected by name" "rc=$rc out=$out"; fi
    if ( _sc_load_conf "$t/s1" && [ "$P_TOPIC" = "latest rumors" ] && [ "${SC_SLOT[b]}" = 2 ] && [ "${SC_PASS[a]}" = a ] \
         && [[ $LOG_MARKERS == *"Server crash"* ]] && [ "$(bash -c 'echo "$P_QUEST_ID"')" = quest_01 ] && [ "$PROBE_RANGE" = 4096 ] ); then
        _ok "conf: sourced for a run (P_* exported, slots, password default, \$RIG_TRIPWIRES)"
    else _bad "conf: sourced for a run"; fi

    # -- 2. probe-line tokenizer --
    out=$(_sc_probe_tokens '[rigprobe:nearby] p=a seq=3 t=12.5 actor="Big Bob" rec=$dynamic0 empty="" dist=120 anim=idle1')
    _check "probe: tokens with quoted values" "$(tr '\n' '|' <<<"$out")" 'kind=nearby|p=a|seq=3|t=12.5|actor=Big Bob|rec=$dynamic0|empty=|dist=120|anim=idle1|'
    if _sc_probe_tokens 'no probe here' >/dev/null; then _bad "probe: non-probe line rejected"; else _ok "probe: non-probe line rejected"; fi
    if _sc_probe_tokens '[rigprobe:cell] p=a cell="unterminated' >/dev/null; then _bad "probe: malformed field rejected"; else _ok "probe: malformed field rejected"; fi

    # -- 3. log windows on synthetic logs --
    SC_RUN=$t/run; mkdir -p "$SC_RUN"; SC_DIR=$t/s1; SC_NAME=selftest
    SC_PLAYERS=(a); SC_SLOT=([a]=1); SC_OFF=(); SC_NAMED=(); SC_RSTAT=(); SC_STEP=0; SC_INFRA=''; SC_FINAL=0; SC_DRY=0
    RIG_SRV_STDOUT=$SC_RUN/server.log
    _sc_define_verbs
    printf '[INFO]: alpha before the mark\n' > "$SC_RUN/server.log"
    printf 'client: hello\n' > "$SC_RUN/client-a.log"
    _sc_mark_all
    printf '[INFO]: beta after the mark\n' >> "$SC_RUN/server.log"
    assert server 'alpha' 0 >/dev/null;               _check "window: line before the mark does not match" "$SC_LAST_STATUS" FAIL
    _check "window: FAIL row names the window offsets" "${SC_ROFF[SC_STEP]}" "server:30-58"
    assert server 'beta' 0 >/dev/null;                _check "window: line after the mark matches" "$SC_LAST_STATUS" PASS
    assert server --since start 'alpha' 0 >/dev/null; _check "window: --since start widens" "$SC_LAST_STATUS" PASS
    mark m1 >/dev/null
    printf '[INFO]: gamma\n' >> "$SC_RUN/server.log"
    mark >/dev/null
    assert server 'gamma' 0 >/dev/null;               _check "window: mark moves past gamma" "$SC_LAST_STATUS" FAIL
    assert server 'gamma' --since m1 0 >/dev/null;    _check "window: --since <name> (flag after the ERE)" "$SC_LAST_STATUS" PASS
    assert server --since nosuch 'gamma' 0 >/dev/null; _check "window: unknown mark fails" "$SC_LAST_STATUS" FAIL
    assert count server 'before the mark' '>=' 1 >/dev/null; _check "count: whole log" "$SC_LAST_STATUS" PASS
    assert count server '[INFO]' '=' 3 >/dev/null;    _check "count: fixed string, ==" "$SC_LAST_STATUS" PASS
    assert count server 'beta' '<' 1 >/dev/null;      _check "count: failing comparison" "$SC_LAST_STATUS" FAIL
    assert count client a 'hello' '=' 1 >/dev/null;   _check "count: client log" "$SC_LAST_STATUS" PASS
    assert count server 'beta' 1 >/dev/null;          _check "count: missing operator fails" "$SC_LAST_STATUS" FAIL
    assert absent server 'alpha' >/dev/null;          _check "absent: whole log (pre-mark line found)" "$SC_LAST_STATUS" FAIL
    assert absent server 'delta' >/dev/null;          _check "absent: no line" "$SC_LAST_STATUS" PASS
    assert client a 'hello' 0 >/dev/null;             _check "client: before the mark" "$SC_LAST_STATUS" FAIL
    assert absent client a 'hello' >/dev/null;        _check "absent client: whole log" "$SC_LAST_STATUS" FAIL
    printf 'client: world\n' >> "$SC_RUN/client-a.log"
    wait client a 'world' 0 >/dev/null;               _check "wait client: past the mark" "$SC_LAST_STATUS" PASS
    assert client zz 'x' 0 >/dev/null;                _check "client: unknown player" "$SC_LAST_STATUS" FAIL
    mkdir -p "$t/data/player"; printf '{"login":{"name":"a"},"stats":{"level":3}}\n' > "$t/data/player/a.json"
    SC_DATA_DIR=$t/data
    assert json player/a.json 'd["stats"]["level"] >= 3' >/dev/null; _check "json: python expression on d" "$SC_LAST_STATUS" PASS
    assert json player/a.json 'd["login"]["name"] == "b"' >/dev/null; _check "json: false expression" "$SC_LAST_STATUS" FAIL
    assert json player/none.json 'True' >/dev/null;   _check "json: missing file" "$SC_LAST_STATUS" FAIL
    unset SC_DATA_DIR
    assert server 'beta' 0 --since >/dev/null;        _check "window: trailing --since without a name fails" "$SC_LAST_STATUS" FAIL
    # The implicit mark is taken when a verb starts acting: what the verb causes is inside the window.
    out=$(
        SC_BOOTED=([a]=1)
        _sc_need_client() { return 0; }; _sc_baseline() { :; }
        rig_key() { echo 'REPLY to key' >> "$SC_RUN/server.log"; }
        ( sleep 0.5; echo 'EVENT during settle' >> "$SC_RUN/server.log" ) &
        settle 1 "waiting for the event" >/dev/null
        assert server 'EVENT during settle' 0 >/dev/null; printf '%s ' "$SC_LAST_STATUS"
        key a Return >/dev/null
        assert server 'REPLY to key' 0 >/dev/null; printf '%s ' "$SC_LAST_STATUS"
        assert server 'EVENT during settle' 0 >/dev/null; printf '%s' "$SC_LAST_STATUS"
    )
    _check "window: settle does not mark; an input verb marks before it acts" "$out" "PASS PASS FAIL"
    mark >/dev/null; : > "$SC_RUN/client-a.log"; echo 'after restart' >> "$SC_RUN/client-a.log"
    assert client a 'after restart' 0 >/dev/null;     _check "window: a rewritten (shorter) log is read from 0" "$SC_LAST_STATUS" PASS
    assert probe a nearby actor=b >/dev/null;         _check "probe: PROBE=0 -> SKIP" "$SC_LAST_STATUS" SKIP

    # The client probe needs a client that loads Lua scripts (rig_client_lua).
    out=$(
        RIG_BUILD=$t/b; mkdir -p "$RIG_BUILD/res/vfs"; printf 'resources=./res\n' > "$RIG_BUILD/openmw.cfg"
        rig_client_lua; printf '%s ' "$?"
        : > "$RIG_BUILD/res/vfs/builtin.omwscripts"; rig_client_lua; printf '%s ' "$?"
        RIG_RDF_BUILTIN=0 rig_client_lua; printf '%s' "$?"
    )
    _check "probe: a pre-0.48 build (no builtin.omwscripts) or RIG_RDF_BUILTIN=0 has no Lua" "$out" "1 0 1"

    # -- 4. exit-code aggregation and RESULT format --
    _check "aggregate: all skipped -> 4"      "$(_sc_aggregate 4 4)" 4
    _check "aggregate: pass + skip -> 0"      "$(_sc_aggregate 0 4)" 0
    _check "aggregate: fail + skip -> 1"      "$(_sc_aggregate 1 4)" 1
    _check "aggregate: regression + fail -> 1" "$(_sc_aggregate 2 1 0)" 1
    _check "aggregate: infra wins -> 3"       "$(_sc_aggregate 0 1 2 3 4)" 3
    _check "aggregate: regression + skip -> 2" "$(_sc_aggregate 2 4 0)" 2
    _check "aggregate: single pass -> 0"      "$(_sc_aggregate 0)" 0
    out=$(_sc_result_line PASS-RETRY 0 example 0 0 2)
    if [[ $out =~ ^RESULT\ (PASS|PASS-RETRY|FAIL|REGRESSION|INFRA|SKIP)\ [0-4]\ [^[:space:]]+\ [0-9]+\ [0-9]+\ [0-9]+$ ]]; then _ok "RESULT line format: $out"
    else _bad "RESULT line format" "$out"; fi

    # -- 5. verdict: FAIL counted, pair inputs need no reference, INFRA stops the rest --
    SC_ATTEMPT=1; SC_STRICT=1
    _sc_finalize >/dev/null
    _check "verdict: failed assertions -> FAIL" "$(cat "$SC_RUN/RESULT")" "$(_sc_result_line FAIL 1 selftest 12 0 1)"
    SC_RUN=$t/run2; mkdir -p "$SC_RUN"; SC_RSTAT=(); SC_STEP=0; SC_FINAL=0; SC_SHOTROW=(); SC_PAIRIN=()
    SC_CUR_STEP=1; SC_STEP=1; SC_CUR_LINE=steps.sh:1; SC_CUR_DESC="shot a 10"; SC_SHOTROW[10]=1; _sc_row NO-REFERENCE "" "x" >/dev/null
    SC_CUR_STEP=2; SC_STEP=2; SC_CUR_LINE=steps.sh:2; SC_CUR_DESC="shot a 20"; SC_SHOTROW[20]=2; _sc_row NO-REFERENCE "" "x" >/dev/null
    SC_PAIRIN[10]=1
    _sc_finalize >/dev/null
    _check "verdict: unreferenced pair input is OK, other NO-REFERENCE fails" "$(cat "$SC_RUN/RESULT")" "$(_sc_result_line FAIL 1 selftest 1 0 1)"
    _check "verdict: pair input row rewritten" "$(sed -n 2p "$SC_RUN/steps.tsv" | cut -f4)" OK
    SC_STRICT=0
    out=$(SC_RUN=$t/run2b; mkdir -p "$SC_RUN"; SC_RSTAT=(); SC_FINAL=0; SC_PAIRIN=(); SC_SHOTROW=()
          SC_CUR_STEP=1; SC_CUR_LINE=steps.sh:1; SC_CUR_DESC="shot a 30"; _sc_row REGRESSION "" "x" >/dev/null
          SC_CUR_STEP=2; SC_CUR_LINE=steps.sh:2; SC_CUR_DESC="assert"; _sc_row PASS "" "x" >/dev/null
          _sc_finalize >/dev/null; cat "$SC_RUN/RESULT")
    _check "verdict: a moved reference alone -> REGRESSION 2" "$out" "$(_sc_result_line REGRESSION 2 selftest 0 1 1)"
    out=$(SC_RUN=$t/run2c; mkdir -p "$SC_RUN"; SC_RSTAT=(); SC_FINAL=0; SC_PAIRIN=(); SC_SHOTROW=(); SC_ATTEMPT=2
          SC_CUR_STEP=1; SC_CUR_LINE=steps.sh:1; SC_CUR_DESC="assert"; _sc_row PASS "" "x" >/dev/null
          _sc_finalize >/dev/null; cat "$SC_RUN/RESULT")
    _check "verdict: a pass on attempt 2 -> PASS-RETRY 0" "$out" "$(_sc_result_line PASS-RETRY 0 selftest 0 0 2)"
    _check "aggregate: no codes -> 3"         "$(_sc_aggregate)" 3

    SC_RUN=$t/run3; mkdir -p "$SC_RUN"; SC_RSTAT=(); SC_STEP=0; SC_FINAL=0; SC_INFRA=''; SC_SHOTROW=(); SC_PAIRIN=()
    SC_DIR=$t/s3; mkdir -p "$SC_DIR"
    printf 'boot a\nkey a Return\nassert server never 1\nsettle 30 "would take 30s"\nlogin a\n' > "$SC_DIR/steps.sh"
    _sc_boot_impl() { SC_BOOT_MSG="boot: selftest refuses to boot"; return 1; }
    local t0=$SECONDS
    _sc_run_steps >/dev/null
    _sc_finalize >/dev/null
    _check "INFRA stop: RESULT" "$(cat "$SC_RUN/RESULT")" "$(_sc_result_line INFRA 3 selftest 1 0 1)"
    _check "INFRA stop: statuses" "$(tail -n +2 "$SC_RUN/steps.tsv" | cut -f4 | tr '\n' ' ')" "FAIL SKIP SKIP SKIP SKIP "
    _check "INFRA stop: rows name steps.sh lines" "$(tail -n +2 "$SC_RUN/steps.tsv" | cut -f2 | tr '\n' ' ')" "steps.sh:1 steps.sh:2 steps.sh:3 steps.sh:4 steps.sh:5 "
    if (( SECONDS - t0 < 5 )); then _ok "INFRA stop: skipped steps do not run"; else _bad "INFRA stop: skipped steps ran ($((SECONDS-t0))s)"; fi

    # A dead server or client stops the scenario at the next verb (INFRA), not after every cap.
    local dead; sleep 0 & dead=$!; builtin wait "$dead"
    out=$(
        SC_RUN=$t/run4; mkdir -p "$SC_RUN"; SC_RSTAT=(); SC_STEP=0; SC_FINAL=0; SC_INFRA=''
        : > "$SC_RUN/server.log"; RIG_SRV_STDOUT=$SC_RUN/server.log; RIG_SRV=$dead
        printf 'assert server never 5\nassert server never 5\nnote x\n' > "$SC_DIR/steps.sh"
        _sc_run_steps >/dev/null; _sc_finalize >/dev/null
        printf '%s|%s' "$(tail -n +2 "$SC_RUN/steps.tsv" | cut -f4 | tr '\n' ' ')" "$(cut -d' ' -f2 "$SC_RUN/RESULT")"
    )
    _check "dead server: INFRA at the next verb" "$out" "FAIL SKIP SKIP |INFRA"
    out=$(
        SC_RUN=$t/run5; mkdir -p "$SC_RUN"; SC_RSTAT=(); SC_STEP=0; SC_FINAL=0; SC_INFRA=''
        RIG_SRV=''; SC_BOOTED=([a]=1); RIG_CLI=$dead
        printf 'key a Return\nassert server never 5\n' > "$SC_DIR/steps.sh"
        _sc_run_steps >/dev/null; _sc_finalize >/dev/null
        printf '%s|%s' "$(tail -n +2 "$SC_RUN/steps.tsv" | cut -f4 | tr '\n' ' ')" "$(cut -d' ' -f2 "$SC_RUN/RESULT")"
    )
    _check "dead client: INFRA, not FAIL" "$out" "FAIL SKIP |INFRA"

    # -- 6. client probe lines and the server bridge's file protocol (a fake bridge; no game) --
    out=$(scenario_selftest_probe "$t" 2>&1)
    echo "$out"
    fails=$((fails + $(grep -c '^  FAIL' <<<"$out")))

    # -- 7. dry-run: an external command in steps.sh is reported --
    mkdir -p "$t/s4"; printf 'PLAYERS=a\nCONTENT=example\n' > "$t/s4/scenario.conf"
    printf 'boot a\nlogin a\ngrep x y\nassert server ok\n' > "$t/s4/steps.sh"
    out=$(bash "$_SC_LIB_DIR/scenario.sh" _dry-run "$t/s4" 2>&1); rc=$?
    if [ "$rc" = 1 ] && grep -q "steps.sh:3: 'grep' is not a verb" <<<"$out"; then _ok "dry-run: external command rejected with its line"
    else _bad "dry-run: external command rejected" "rc=$rc $out"; fi
    printf 'boot a\nlogin a\nassert server ok\n' > "$t/s4/steps.sh"
    if bash "$_SC_LIB_DIR/scenario.sh" _dry-run "$t/s4" >/dev/null 2>&1; then _ok "dry-run: clean steps pass"; else _bad "dry-run: clean steps pass"; fi
    local case want
    mkdir -p "$t/s4/setup"; printf '# ok\nset x to 1\nset y to 2\t; trailing\n' > "$t/s4/setup/tab.console"
    for case in "assert count server x >= 2|wrote '='" "shot a s1 12x12|is not WxH+X+Y" "settle 3|give the reason" \
                "assert server ok --since m9|no earlier 'mark m9'" "wait --since m client zz foo|unknown player 'zz'" \
                "assert server|no ERE" "assert json player/a.json d[0] == 1|at most 3" "scroll a 1 until server x|scroll: expected" \
                "echo \$P_TYPO|unset variable" "probe a bogus|not a probe kind" "assert probe a nearby|expected <p> <kind>" \
                "assert probe a nearby dist<400|unquoted < or >" "assert probe-delta a stats fat x 1|operator 'x'" \
                "assert probe-delta a stats fat '<' 0 7|two request seqs" "console-object a cell 12 disable|not <refnum>-<mpnum>" \
                "wait probe a|no ERE" "assert probe-count a nearby 1|operator '1'" "assert probe-count a nearby = x|is not a count" "console-file a setup/tab.console|tab.console:3: the command holds a tab"; do
        want=${case#*|}
        printf 'boot a\n%s\n' "${case%%|*}" > "$t/s4/steps.sh"
        out=$(cd "$t" && bash "$_SC_LIB_DIR/scenario.sh" _dry-run "$t/s4" 2>&1); rc=$?
        if [ "$rc" != 0 ] && grep -qF -- "$want" <<<"$out"; then _ok "dry-run rejects: ${case%%|*}"
        else _bad "dry-run rejects: ${case%%|*}" "rc=$rc $(tail -3 <<<"$out")"; fi
    done
    [ -e "$t/=" ] && _bad "dry-run: redirection escaped the scratch cwd"
    printf 'boot a\nmark m1\nscroll a 1 none until server x 5 tries 2\nassert server --since m1 ok\nsettle 1 "why"\nprobe a dump\nassert probe a nearby actor=b '"'"'dist<400'"'"' anim~idle\nassert probe-delta a stats fat '"'"'<'"'"' -20 2 3\nprobe a items\nassert probe-count a items = 0 obj=x\nconsole-object a "0, -7" 0-12 disable\n' > "$t/s4/steps.sh"
    if bash "$_SC_LIB_DIR/scenario.sh" _dry-run "$t/s4" >/dev/null 2>&1; then _ok "dry-run: known mark, scroll close key, settle reason, probe verbs"
    else _bad "dry-run: known mark, scroll close key, settle reason, probe verbs"; fi

    rm -rf "$t"
    echo "selftest done (fails=$fails)"
    return "$fails"
}

# scenario_selftest_probe <tmpdir> — the probe and bridge cases of the selftest, in their own process
# state (called in a subshell). A background fake bridge answers the runner's command files the way
# overlay/scripts/custom/rig-bridge.lua does and, for probe requests, appends the lines the client
# probe would print to the client log.
scenario_selftest_probe() {
    local t=$1 out srv cli fb dir pre=$'L@0x1[scripts/rig/probe.lua]:\t'
    local -i fails=0
    _ok()  { echo "  ok   [$1]"; }
    _bad() { echo "  FAIL [$1] ${2:-}"; fails=$((fails+1)); }
    _check() { if [ "$2" = "$3" ]; then _ok "$1"; else _bad "$1" "got '$2' want '$3'"; fi; }
    SC_RUN=$t/run7; mkdir -p "$SC_RUN/bridge" "$t/s7/setup"; SC_DIR=$t/s7; SC_NAME=selftest
    SC_RSTAT=(); SC_STEP=0; SC_FINAL=0; SC_INFRA=''; SC_OFF=(); SC_NAMED=(); SC_DRY=0
    SC_PLAYERS=(a b); SC_SLOT=([a]=1 [b]=2); PROBE=1; RIG_BRIDGE_CAP=2; RIG_PROBE_CAP=2
    sleep 120 & srv=$!; sleep 120 & cli=$!
    RIG_SRV=$srv RIG_CLI=$cli RIG_CLI2=$cli
    SC_BOOTED=([a]=1 [b]=1); SC_IN=([a]=1 [b]=1)
    : > "$SC_RUN/server.log"; RIG_SRV_STDOUT=$SC_RUN/server.log
    rig_grab_region() { : > "$3"; }
    _sc_define_verbs

    # Probe-log sync: complete [rigprobe:*] lines only, the print prefix dropped, partial line deferred.
    printf 'noise line\n%s[rigprobe:ready] p=a t=1 seq=0 probe=1 version=1 caps=cell,stats,stance,nearby,anim\n%s[rigprobe:stats] p=a t=2' \
        "$pre" "$pre" > "$SC_RUN/client-a.log"
    printf '%s[rigprobe:ready] p=b t=1 seq=0 probe=1 version=1 caps=cell,stats\n' "$pre" > "$SC_RUN/client-b.log"
    _sc_probe_sync a
    _check "probe log: complete lines only" "$(wc -l < "$SC_RUN/probe-a.log")" 1
    printf ' seq=0 hp=5\n' >> "$SC_RUN/client-a.log"
    _sc_probe_sync a
    _check "probe log: a partial line is taken once complete" "$(tail -1 "$SC_RUN/probe-a.log")" "[rigprobe:stats] p=a t=2 seq=0 hp=5"
    _check "probe: caps from the ready line" "$(_sc_probe_caps a)" "cell,stats,stance,nearby,anim"
    _sc_mark_all
    printf '%s[rigprobe:stats] p=a t=7 seq=0 hp=4\n' "$pre" >> "$SC_RUN/client-a.log"
    wait probe a 'rigprobe:stats\] .*hp=4' 1 >/dev/null; _check "wait probe: a line after the mark" "$SC_LAST_STATUS" PASS
    wait probe a 'rigprobe:stats\] .*hp=5' 0 >/dev/null; _check "wait probe: a line before the mark" "$SC_LAST_STATUS" FAIL

    # A ready line that reached only the client log (no sync since) still makes the probe usable.
    printf '%s[rigprobe:ready] p=b t=1 seq=0 probe=1 version=1 caps=cell,stats\n' "$pre" > "$SC_RUN/client-b.log"
    rm -f "$SC_RUN/probe-b.log" "$SC_RUN/.probe-b.off"
    if _sc_probe_usable b; then _ok "probe: usable reads a fresh probe log"; else _bad "probe: usable reads a fresh probe log" "$SC_PROBE_WHY"; fi

    # The fake bridge: answers cmd-<seq>.meta in seq order.
    dir=$SC_RUN/bridge
    (
        n=1
        while :; do
            if [ -f "$dir/cmd-$n.meta" ]; then
                IFS=$'\t' read -r verb who arg _ < "$dir/cmd-$n.meta"
                cl=$SC_RUN/client-$who.log; ok=1; det="sent to pid 0"
                case $verb in
                    probe)
                        case $arg in
                            nearby) printf '%s[rigprobe:nearby] p=%s t=9 seq=%s actor=b rec=$dynamic2 dist=256 kind=npc anim=idle hp=50\n' "$pre" "$who" "$n" >> "$cl"
                                    printf '%s[rigprobe:nearby] p=%s t=9 seq=%s obj=door_01 name="Old Door" kind=door dist=900\n' "$pre" "$who" "$n" >> "$cl"
                                    printf '%s[rigprobe:done] p=%s t=9 seq=%s kind=nearby lines=2\n' "$pre" "$who" "$n" >> "$cl" ;;
                            stats)  [ -f "$dir/silent" ] && { echo "$det" > "$dir/done-$n"; n=$((n + 1)); continue; }   # sent, never answered
                                    printf '%s[rigprobe:stats] p=%s t=9 seq=%s hp=50 fat=%s\n' "$pre" "$who" "$n" "$((150 - 10 * n))" >> "$cl"
                                    printf '%s[rigprobe:done] p=%s t=9 seq=%s kind=stats lines=1\n' "$pre" "$who" "$n" >> "$cl" ;;
                            dump)   printf '%s[rigprobe:cell] p=%s t=9 seq=%s cell="Big Hall" x=1\n' "$pre" "$who" "$n" >> "$cl"
                                    printf '%s[rigprobe:done] p=%s t=9 seq=%s kind=dump lines=1 missing=weather\n' "$pre" "$who" "$n" >> "$cl" ;;
                            quest)  ;;      # a client that never answers
                        esac ;;
                    console) [ "$arg" = refuse ] && { ok=0; det="player $who is not logged in"; } ;;
                    lua) [ -f "$dir/cmd-$n.lua" ] && det="returned $(cat "$dir/cmd-$n.lua")" ;;
                esac
                if [ "$ok" = 1 ]; then echo "$det" > "$dir/done-$n"; else echo "$det" > "$dir/err-$n"; fi
                n=$((n + 1))
            fi
            sleep 0.1
        done
    ) &
    fb=$!

    console a 'ModCurrentFatigue -50' >/dev/null
    _check "bridge: console -> OK with the bridge's answer" "$SC_LAST_STATUS|${SC_RDET[SC_STEP]}" "OK|bridge 1: sent to pid 0"
    _check "bridge: the command file (tab-separated, renamed into place)" "$(cat "$dir/cmd-1.meta")" $'console\ta\tModCurrentFatigue -50'
    if compgen -G "$dir/.cmd-*" >/dev/null; then _bad "bridge: no temp file left"; else _ok "bridge: no temp file left"; fi
    server a 'return player.accountName' >/dev/null
    _check "bridge: server <p> <lua> -> body file + answer" "$SC_LAST_STATUS|$(cat "$dir/cmd-2.lua")|$(cut -f1,2 "$dir/cmd-2.meta")" $'OK|return player.accountName|lua\ta'
    console a refuse >/dev/null
    _check "bridge: err-<seq> -> FAIL naming the reason" "$SC_LAST_STATUS|${SC_RDET[SC_STEP]}" "FAIL|bridge 3 refused: player a is not logged in"
    printf '# setup\n\nset x to 1\nset y to 2\n' > "$SC_DIR/setup/two.console"
    console-file a setup/two.console >/dev/null
    _check "bridge: console-file sends each command line" "$SC_LAST_STATUS|${SC_RDET[SC_STEP]}" "OK|2 command(s) from setup/two.console (bridge 4-5)"
    printf 'set x to 1\t; a comment after a tab\n' > "$SC_DIR/setup/tab.console"
    console-file a setup/tab.console >/dev/null
    case $SC_LAST_STATUS/${SC_RDET[SC_STEP]} in "FAIL/console-file setup/tab.console:1: the command holds a tab"*) _ok "bridge: console-file with a tab in a command -> FAIL, nothing sent";;
        *) _bad "bridge: console-file with a tab in a command -> FAIL, nothing sent" "$SC_LAST_STATUS ${SC_RDET[SC_STEP]}";; esac
    save a >/dev/null; save cell "0, -7" >/dev/null
    _check "bridge: save cell has no player" "$(cat "$dir/cmd-7.meta")" $'savecell\t-\t0, -7'

    # Probe requests: the seq the bridge assigned is the seq the probe echoes.
    probe a nearby >/dev/null
    _check "probe: request answered by its seq" "$SC_LAST_STATUS|${SC_RDET[SC_STEP]}" "OK|seq 8: 2 line(s) in probe-a.log"
    assert probe a nearby actor=b 'dist<400' 'anim~^idle' >/dev/null; _check "assert probe: all conditions on one line" "$SC_LAST_STATUS" PASS
    assert probe a nearby actor=b 'dist>400' >/dev/null;              _check "assert probe: a failing comparison" "$SC_LAST_STATUS" FAIL
    assert probe a nearby name="Old Door" kind=door >/dev/null;       _check "assert probe: a quoted value" "$SC_LAST_STATUS" PASS
    assert probe a nearby actor=zzz >/dev/null
    case ${SC_RDET[SC_STEP]} in *"seq 8: no nearby line with actor=zzz among 2 line(s): actor=b"*) _ok "assert probe: FAIL quotes the request's line set";;
        *) _bad "assert probe: FAIL quotes the request's line set" "${SC_RDET[SC_STEP]}";; esac
    printf '%s[rigprobe:nearby] p=a t=9 seq=0 actor=zzz dist=1\n' "$pre" >> "$SC_RUN/client-a.log"
    assert probe a nearby actor=zzz >/dev/null;   _check "assert probe: heartbeat lines (seq=0) are not read" "$SC_LAST_STATUS" FAIL
    assert probe a nearby 'lock=0' >/dev/null
    _check "assert probe: a missing field cap -> SKIP naming it" "$SC_LAST_STATUS|${SC_RDET[SC_STEP]}" "SKIP|probe: client a lacks cap 'lock' (caps=cell,stats,stance,nearby,anim)"
    assert probe a weather weather=clear >/dev/null
    _check "assert probe: a missing kind cap -> SKIP naming it" "$SC_LAST_STATUS|${SC_RDET[SC_STEP]}" "SKIP|probe: client a lacks cap 'weather' (caps=cell,stats,stance,nearby,anim)"
    assert probe b cell cell=x >/dev/null
    case ${SC_RDET[SC_STEP]} in *"no 'probe b cell'"*) _ok "assert probe: no request before it -> FAIL";; *) _bad "assert probe: no request before it -> FAIL" "${SC_RDET[SC_STEP]}";; esac
    probe a stats >/dev/null; probe a stats >/dev/null
    assert probe-delta a stats fat '<' -5 >/dev/null
    _check "probe-delta: last two requests" "$SC_LAST_STATUS|${SC_RDET[SC_STEP]}" "PASS|fat: 60 (seq 9) -> 50 (seq 10), delta -10 < -5"
    assert probe-delta a stats fat '>' 0 >/dev/null;           _check "probe-delta: failing comparison" "$SC_LAST_STATUS" FAIL
    assert probe-count a nearby = 1 'rec~^\$dynamic' >/dev/null; _check "probe-count: exactly one matching line" "$SC_LAST_STATUS" PASS
    assert probe-count a nearby = 0 actor=zzz >/dev/null;       _check "probe-count: absence" "$SC_LAST_STATUS" PASS
    assert probe-count a nearby '>=' 3 >/dev/null
    case $SC_LAST_STATUS/${SC_RDET[SC_STEP]} in "FAIL/seq 8: 2 nearby line(s), wanted >= 3"*) _ok "probe-count: no conditions counts every line; FAIL names the count";;
        *) _bad "probe-count: no conditions counts every line; FAIL names the count" "$SC_LAST_STATUS ${SC_RDET[SC_STEP]}";; esac
    assert probe a nearby actor=b weapon=none >/dev/null
    _check "assert probe: weapon needs cap equip -> SKIP" "$SC_LAST_STATUS|${SC_RDET[SC_STEP]}" "SKIP|probe: client a lacks cap 'equip' (caps=cell,stats,stance,nearby,anim)"
    assert probe-delta a stats fat = -10 hp=50 9 10 >/dev/null; _check "probe-delta: explicit seqs and a selector" "$SC_LAST_STATUS" PASS
    probe a dump >/dev/null
    assert probe a cell cell="Big Hall" >/dev/null; _check "assert probe: a dump answers every kind" "$SC_LAST_STATUS" PASS
    _check "probe: missing caps reported on the row" "${SC_RDET[SC_STEP-1]}" "seq 11: 1 line(s) in probe-a.log; not available on this client: weather"
    probe a quest >/dev/null
    case $SC_LAST_STATUS/${SC_RDET[SC_STEP]} in "FAIL/"*"did not answer seq 12"*) _ok "probe: a silent client -> FAIL naming the seq";;
        *) _bad "probe: a silent client -> FAIL naming the seq" "$SC_LAST_STATUS ${SC_RDET[SC_STEP]}";; esac
    checkpoint c1 >/dev/null
    _check "checkpoint: probe dumps by seq" "$SC_LAST_STATUS|$(grep -c 'seq=13 ' "$SC_RUN/checkpoints/c1/a.probe")|$(grep -c 'seq=14 ' "$SC_RUN/checkpoints/c1/b.probe")" "OK|2|2"

    # A request the client never answers must not leave the previous request's lines to be read.
    touch "$dir/silent"
    probe a stats >/dev/null
    _check "probe: an unanswered request -> FAIL" "$SC_LAST_STATUS" FAIL
    assert probe a stats hp=50 >/dev/null
    case $SC_LAST_STATUS/${SC_RDET[SC_STEP]} in "FAIL/"*"(seq 15) was not answered"*) _ok "assert probe: after an unanswered request -> FAIL, not the older lines";;
        *) _bad "assert probe: after an unanswered request -> FAIL, not the older lines" "$SC_LAST_STATUS ${SC_RDET[SC_STEP]}";; esac
    assert probe-delta a stats fat '<' 0 >/dev/null
    _check "probe-delta: an unanswered last request -> FAIL" "$SC_LAST_STATUS" FAIL
    assert probe a cell cell="Big Hall" >/dev/null
    _check "assert probe: another kind's last request (the checkpoint dump) is unaffected" "$SC_LAST_STATUS" PASS
    rm -f "$dir/silent"
    probe a stats >/dev/null
    assert probe a stats hp=50 >/dev/null
    _check "assert probe: a new answered request clears it" "$SC_LAST_STATUS" PASS
    assert probe-delta a stats fat '<' 0 >/dev/null
    _check "probe-delta: the unanswered request is still one of the last two -> FAIL" "$SC_LAST_STATUS" FAIL

    kill "$fb" 2>/dev/null; builtin wait "$fb" 2>/dev/null
    local t0=$SECONDS
    console a 'x' >/dev/null; note after >/dev/null
    _check "bridge: no answer -> INFRA, later steps SKIP" "$(_sc_row_text $((SC_STEP-1)) | cut -f4,7 | cut -c1-40)|$SC_LAST_STATUS" $'FAIL\tINFRA: the server bridge did not an|SKIP'
    if (( SECONDS - t0 <= RIG_BRIDGE_CAP + 2 )); then _ok "bridge: INFRA within RIG_BRIDGE_CAP"; else _bad "bridge: INFRA within RIG_BRIDGE_CAP" "$((SECONDS - t0))s"; fi
    kill "$srv" "$cli" 2>/dev/null
    return "$fails"
}

# CLI dispatch only when executed directly.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    case "${1:-}" in
        selftest) scenario_selftest; exit $? ;;
        _run-one) shift; _sc_run_one "$@" ;;
        _dry-run) shift; _sc_dry_run "$@"; exit $? ;;
        run)      shift; scenario_run "$@"; exit $? ;;
        *) echo "usage: lib/scenario.sh selftest   (runs go through bin/rig run)" >&2; exit 64 ;;
    esac
fi
