#!/usr/bin/env bash
# cli.sh — the authoring and diagnosis subcommands of bin/rig: list, new, lint, explain, rerun-failed,
# up, down, and the per-subcommand help. bin/rig sources this after lib/rig.sh and lib/scenario.sh;
# each rig_cli_<cmd> returns the subcommand's exit code (64 = usage error). Not meant to be run.
#
# Everything here reads what the runner writes (docs/SCENARIO-FORMAT.md §4-§5): scenario.conf without
# sourcing it, a run set's RESULT/steps.tsv/env.txt/run.log files, attempt-<k>/ trees.
_CLI_ROOT=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)

# ================================================================================================
# Help — one block per subcommand; `bin/rig help <cmd>` and `bin/rig <cmd> --help` print it
# ================================================================================================
rig_cli_help() {
    case ${1:-} in
        '') cat <<'EOF'
usage: bin/rig <command> [args]     (bin/rig help <command> for one command)

  doctor                   check rig.conf and the host; every problem names the key or package to fix
  list [dir...]            the scenarios: name, players, cost, content, references, tags
  new <dir>                scaffold a scenario directory from templates/scenario/
  lint <dir>...            check scenarios without booting: conf keys, verbs and arguments, shellcheck
  run <dir>...             run scenarios and write one verdict per scenario
  explain [run|latest]     the failing steps of a run and the file to open for each
  rerun-failed [run|latest]  run again the scenarios that failed in a run
  up <dir> [player...]     boot a scenario's server and clients, log the players in, leave them running
  down                     stop everything `up` or a killed run left running

Exit codes: 0 ok, 1 fail, 2 regression, 3 infrastructure, 4 content missing, 64 usage error.
Config: rig.conf next to bin/ (or $RIG_CONF); an environment variable wins over the file.
Docs: README.md (quickstart), docs/SCENARIO-FORMAT.md (scenario format, verbs, run directory).
EOF
            ;;
        doctor) cat <<'EOF'
usage: bin/rig doctor
  Check rig.conf and the host: the build, the server scripts, content profiles, displays, tools.
  Every problem line names the rig.conf key (or the package) to fix.
  Exit 0 = a run can start (warnings allowed), 1 = something must be fixed.
EOF
            ;;
        run) _sc_usage ;;
        list) cat <<'EOF'
usage: bin/rig list [--tag T]... [--content C] [--long] [dir...]
  List the scenarios under each dir (default: RIG_SCENARIOS, which defaults to <rig>/scenarios).
  Columns: NAME, PLAYERS, COST (approximate minutes), CONTENT (the content profile; "(absent)" when
  rig.conf does not configure it, so a run would SKIP), REFS (BLESSED with the count of reference
  images and log signatures, or unblessed), TAGS.
  --tag T      only scenarios whose TAGS hold T (repeatable: all must match)
  --content C  only scenarios on content profile C
  --long       also PURPOSE, the scenario directory and its P_* parameters
EOF
            ;;
        new) cat <<'EOF'
usage: bin/rig new <dir> --content <profile> [--players "a b"] [--tags "t1 t2"] [--name NAME]
  Create <dir> from templates/scenario/: scenario.conf, steps.sh (with the verb table at its top) and
  README.md. <dir> must not exist or be empty.
  --content    the content profile (RIG_CONTENT_<profile>_* in rig.conf), e.g. example   (required)
  --players    login names in slot order, at most 3 (default "a")
  --tags       free-form words for `run --tag` and `list --tag`
  --name       the scenario NAME (default: the directory name)
  Next: add a fixture (docs/WRITING-SCENARIOS.md §1-2), edit steps.sh, bin/rig lint <dir>, bin/rig run <dir>.
EOF
            ;;
        lint) cat <<'EOF'
usage: bin/rig lint <dir>...
  Check each scenario without booting anything (a dir without scenario.conf is searched):
    scenario.conf  every key is known (docs/SCENARIO-FORMAT.md §2); SETTINGS/OVERLAY/FIXTURE paths exist
    steps.sh       bash -n; every call is a verb with valid arguments; no external command, eval,
                   exec, source or redirection; every --since names an earlier mark (bin/rig run --dry-run)
    shellcheck     steps.sh and hooks.sh at warning level, when shellcheck is installed
  A content profile this box lacks is a note, not a failure. Exit 0 clean, 1 problems, 64 usage.
EOF
            ;;
        explain) cat <<'EOF'
usage: bin/rig explain [<run-dir>|latest]
  For each scenario of a run (a run-set dir from `bin/rig run`, one scenario's dir inside it, or
  `latest` = the newest run set under RIG_RUNS; the default), print the RESULT and every failing step
  of every attempt: its steps.sh line, the verb, the detail, and what to open: the log file with the
  byte window and line range the step searched (and the window's last lines), the shot, reference and
  diff image, the signature diff, or the log a lifecycle failure names. Exit 0, 1 if no run is found.
EOF
            ;;
        rerun-failed) cat <<'EOF'
usage: bin/rig rerun-failed [<run-dir>|latest] [run flags...]
  Run again, as a new run set, the scenarios whose RESULT was FAIL, REGRESSION or INFRA in a run
  (default: latest). Flags after the run dir go to `bin/rig run` (e.g. --strict-refs, --retry-failed 1).
  Exit: the new run's code; 0 with a note when nothing failed.
EOF
            ;;
        up) cat <<'EOF'
usage: bin/rig up <dir> [player...]
  Bring a scenario's world up and leave it running for exploration: its fixture, overlay, settings
  and content profile, then `boot <p>` + `login <p>` for each player (default: every player in
  PLAYERS, in order; a FIXTURE=- scenario logs in fresh). Prints the display, pid and log of every
  process, and how to drive and capture a display. Refuses when a server is already running.
  Stop everything with: bin/rig down. Exit 0 up, 3 the world did not come up (it is torn down).
EOF
            ;;
        down) cat <<'EOF'
usage: bin/rig down
  Stop every rig process on this box: a world left by `bin/rig up`, a run killed mid-way (kill -9),
  and their idle wigglers: `bin/rig run`/`up` processes, the runner's scenario processes, the server
  (RIG_SERVER_BIN), clients (RIG_CLIENT_BIN), Xvfb, xdotool; then clear the display locks of
  RIG_DISPLAY*. Run directories are kept. Exit 0 when nothing is left running, 1 otherwise.
EOF
            ;;
        *) echo "rig help: unknown command '$1'" >&2; rig_cli_help >&2; return 64 ;;
    esac
    return 0
}
_cli_usage_err() { echo "rig $1: $2" >&2; echo "  (bin/rig help $1)" >&2; return 64; }

# ================================================================================================
# Shared helpers
# ================================================================================================
# _cli_scenarios <dir>... — scenario dirs (absolute, sorted): a dir with scenario.conf, or found under it.
_cli_scenarios() {
    local a d
    for a in "$@"; do
        if [ -f "$a/scenario.conf" ]; then (cd "$a" && pwd)
        else while IFS= read -r d; do (cd "$d" && pwd); done < <(_sc_find "$a"); fi
    done
}
# _cli_refs <scenario dir> — "BLESSED (n img, m sig)" or "unblessed".
_cli_refs() {
    local n m
    n=$(find "$1/reference-images" -maxdepth 1 -name '*.png' 2>/dev/null | wc -l)
    m=$(find "$1/reference-logs" -maxdepth 1 -name '*.events' 2>/dev/null | wc -l)
    if [ $((n + m)) -gt 0 ]; then printf 'BLESSED(%s img,%s sig)' "$n" "$m"; else printf 'unblessed'; fi
}
# _cli_run_set <arg> — resolve `latest`/empty to the newest run set under RIG_RUNS; echo an absolute dir.
_cli_run_set() {
    local a=${1:-latest} d
    if [ "$a" = latest ]; then
        d=$(find "$RIG_RUNS" -mindepth 2 -maxdepth 2 -name RESULTS -printf '%h\n' 2>/dev/null | sort | tail -1)
        [ -n "$d" ] || { echo "no run set with a RESULTS file under RIG_RUNS=$RIG_RUNS" >&2; return 1; }
        printf '%s' "$d"; return 0
    fi
    [ -d "$a" ] || { echo "no such run directory: $a" >&2; return 1; }
    (cd "$a" && pwd)
}
# _cli_scenario_runs <run dir> — the scenario run dirs in a run set (or the dir itself if it is one).
_cli_scenario_runs() {
    if [ -f "$1/RESULT" ] || [ -f "$1/steps.tsv" ]; then printf '%s\n' "$1"; return; fi
    find "$1" -mindepth 2 -maxdepth 2 -name RESULT -not -path '*/attempt-*' -printf '%h\n' | sort
}
# _cli_source_dir <scenario run dir> — the scenario directory a run came from (env.txt, else run.log).
_cli_source_dir() {
    local r=$1 f d
    for f in "$r/env.txt" "$r"/attempt-*/env.txt; do
        [ -f "$f" ] || continue
        d=$(sed -n 's/^scenario_dir=//p' "$f" | head -1)
        [ -n "$d" ] && { printf '%s' "$d"; return 0; }
    done
    for f in "$r/run.log" "$r"/attempt-*/run.log; do
        [ -f "$f" ] || continue
        d=$(sed -nE '1s/^== [^ ]+ \((.*)\) attempt [0-9]+ -> .*/\1/p' "$f")
        [ -n "$d" ] && { printf '%s' "$d"; return 0; }
    done
    return 1
}

# ================================================================================================
# list
# ================================================================================================
rig_cli_list() {
    local long=0 content='' d f name players cost c tags refs purpose
    local -a tags_want=() roots=()
    while [ $# -gt 0 ]; do
        case $1 in
            --tag)     [ -n "${2:-}" ] || { _cli_usage_err list "--tag needs a word"; return 64; }; tags_want+=("$2"); shift ;;
            --content) [ -n "${2:-}" ] || { _cli_usage_err list "--content needs a profile name"; return 64; }; content=$2; shift ;;
            --long)    long=1 ;;
            -h|--help) rig_cli_help list; return 0 ;;
            -*)        _cli_usage_err list "unknown flag $1"; return 64 ;;
            *)         [ -d "$1" ] || { _cli_usage_err list "no such directory: $1"; return 64; }; roots+=("$1") ;;
        esac
        shift
    done
    [ "${#roots[@]}" -gt 0 ] || read -r -a roots <<<"$RIG_SCENARIOS"
    local n=0
    printf '%-24s %-10s %-5s %-16s %-24s %s\n' NAME PLAYERS COST CONTENT REFS TAGS
    while IFS= read -r d; do
        f=$d/scenario.conf
        if [ "${#tags_want[@]}" -gt 0 ] && ! _sc_has_tags "$d" "${tags_want[@]}"; then continue; fi
        c=$(_sc_conf_get "$f" CONTENT)
        [ -z "$content" ] || [ "$c" = "$content" ] || continue
        name=$(_sc_scenario_name "$d"); players=$(_sc_conf_get "$f" PLAYERS); cost=$(_sc_conf_get "$f" COST)
        tags=$(_sc_conf_get "$f" TAGS); refs=$(_cli_refs "$d")
        if [ -n "$c" ] && ! rig_content_check "$c" >/dev/null 2>&1; then c="$c(absent)"; fi
        printf '%-24s %-10s %-5s %-16s %-24s %s\n' "$name" "${players// /,}" "${cost:--}" "${c:-?}" "$refs" "$tags"
        if [ "$long" = 1 ]; then
            purpose=$(_sc_conf_get "$f" PURPOSE)
            printf '    purpose: %s\n    dir:     %s\n' "${purpose:--}" "$d"
            local params; params=$(sed -nE 's/^[[:space:]]*(export[[:space:]]+)?(P_[A-Z0-9_]+)=.*/\2/p' "$f" | sort -u | tr '\n' ' ')
            [ -n "$params" ] && printf '    params:  %s\n' "${params% }"
            local problems; problems=$(_sc_conf_check "$f" 2>&1) || printf '    conf:    %s\n' "${problems//$'\n'/; }"
        fi
        n=$((n+1))
    done < <(_cli_scenarios "${roots[@]}")
    [ "$n" -gt 0 ] || echo "(no scenarios under ${roots[*]}${tags_want[*]:+ with tags ${tags_want[*]}}${content:+ on content $content})"
    return 0
}

# ================================================================================================
# new
# ================================================================================================
rig_cli_new() {
    local dir='' players=a content='' tags='' name='' tpl=$_CLI_ROOT/templates/scenario p f line out
    while [ $# -gt 0 ]; do
        case $1 in
            --players) players=${2:-}; shift ;;
            --content) content=${2:-}; shift ;;
            --tags)    tags=${2:-}; shift ;;
            --name)    name=${2:-}; shift ;;
            -h|--help) rig_cli_help new; return 0 ;;
            -*)        _cli_usage_err new "unknown flag $1"; return 64 ;;
            *)         [ -z "$dir" ] || { _cli_usage_err new "one directory only (got '$dir' and '$1')"; return 64; }; dir=$1 ;;
        esac
        shift
    done
    [ -n "$dir" ] || { _cli_usage_err new "name the new scenario directory"; return 64; }
    [ -n "$content" ] || { _cli_usage_err new "--content <profile> is required (a RIG_CONTENT_<profile>_* set in rig.conf, e.g. example)"; return 64; }
    [[ $content =~ ^[A-Za-z0-9_]+$ ]] || { _cli_usage_err new "--content '$content': a profile name is letters, digits or _"; return 64; }
    local -a pl=(); read -r -a pl <<<"$players"
    [ "${#pl[@]}" -ge 1 ] && [ "${#pl[@]}" -le 3 ] || { _cli_usage_err new "--players takes 1 to 3 names (got ${#pl[@]})"; return 64; }
    for p in "${pl[@]}"; do [[ $p =~ ^[A-Za-z0-9_]+$ ]] || { _cli_usage_err new "--players: '$p' must be letters, digits or _"; return 64; }; done
    [ -z "$name" ] || [[ $name =~ ^[A-Za-z0-9._-]+$ ]] || { _cli_usage_err new "--name '$name': letters, digits, . _ - only"; return 64; }
    [[ $tags != *[\"\'\$\`\\]* ]] || { _cli_usage_err new "--tags: plain words only"; return 64; }
    if [ -e "$dir" ] && [ -n "$(ls -A "$dir" 2>/dev/null)" ]; then echo "rig new: $dir exists and is not empty; choose a new directory" >&2; return 1; fi
    for f in scenario.conf steps.sh README.md; do [ -f "$tpl/$f" ] || { echo "rig new: template missing: $tpl/$f" >&2; return 1; }; done
    mkdir -p "$dir" || { echo "rig new: cannot create $dir" >&2; return 1; }
    [ -n "$name" ] || name=$(basename "$(cd "$dir" && pwd)")
    # Placeholders: @NAME@ @PLAYERS@ @CONTENT@ @TAGS@ @FIRST@. A run of consecutive lines starting @EACH@
    # is repeated as a block per player, with @P@ replaced.
    local -a block=()
    _cli_new_sub() { local l=$1; l=${l//@NAME@/$name}; l=${l//@PLAYERS@/${pl[*]}}; l=${l//@CONTENT@/$content}
                     l=${l//@TAGS@/$tags}; l=${l//@FIRST@/${pl[0]}}; printf '%s\n' "$l"; }
    _cli_new_flush() { local q b; for q in "${pl[@]}"; do for b in "${block[@]+"${block[@]}"}"; do _cli_new_sub "${b//@P@/$q}"; done; done; block=(); }
    for f in scenario.conf steps.sh README.md; do
        out=$dir/$f
        {
            while IFS= read -r line || [ -n "$line" ]; do
                if [[ $line == @EACH@* ]]; then block+=("${line#@EACH@}"); continue; fi
                _cli_new_flush
                _cli_new_sub "$line"
            done < "$tpl/$f"
            _cli_new_flush
        } > "$out"
    done
    echo "rig new: created $dir (players: ${pl[*]}; content: $content)"
    rig_content_check "$content" >/dev/null 2>&1 \
        || echo "rig new: note: content profile '$content' is not configured here (rig.conf RIG_CONTENT_${content}_DATA/_FILES); a run would SKIP"
    cat <<EOF
next:
  1. give it a fixture: player/<name>.json per player (docs/WRITING-SCENARIOS.md §1-2), or set FIXTURE=-
     in scenario.conf and log in with 'login <p> fresh'
  2. write the steps:   \$EDITOR $dir/steps.sh        (verbs: the table at its top; docs/SCENARIO-FORMAT.md §3)
  3. check, then run:   bin/rig lint $dir && bin/rig run $dir
  4. on a red run:      bin/rig explain latest
EOF
}

# ================================================================================================
# lint
# ================================================================================================
_cli_lint_one() {
    local d=$1 f=$1/scenario.conf name bad=0 msg v c line
    name=$(_sc_scenario_name "$d")
    echo "== lint $name ($d)"
    if ! msg=$(_sc_conf_check "$f"); then
        while IFS= read -r line; do echo "FAIL $d/$line"; done <<<"$msg"; bad=1
    fi
    for v in SETTINGS OVERLAY FIXTURE; do
        c=$(_sc_conf_get "$f" "$v")
        case $c in ''|-|*'$'*) continue ;; esac
        case $v in
            SETTINGS) [ -f "$d/$c" ] || { echo "FAIL $f: SETTINGS=$c: no such file in the scenario dir"; bad=1; } ;;
            *)        [ -d "$d/$c" ] || { echo "FAIL $f: $v=$c: no such directory in the scenario dir"; bad=1; } ;;
        esac
    done
    if [ "$bad" = 0 ]; then
        if ! msg=$(bash "$_SC_LIB_DIR/scenario.sh" _dry-run "$d" 2>&1); then
            grep -E -- '-> FAIL|^FAIL|unbound variable|syntax error' <<<"$msg" | sed -E 's/^\[t\+[0-9]+s\] //; s/^FAIL //; s/^/FAIL /'
            bad=1
        fi
    fi
    if command -v shellcheck >/dev/null 2>&1; then
        # Verbs and $P_*/$RIG_* come from the runner: SC2148 (no shebang) and SC2154 (unassigned) do not apply.
        for v in steps.sh hooks.sh; do
            [ -f "$d/$v" ] || continue
            if ! msg=$(shellcheck -S warning -s bash -e SC2148,SC2154 -f gcc "$d/$v" 2>&1); then
                while IFS= read -r line; do echo "FAIL shellcheck $line"; done <<<"$msg"; bad=1
            fi
        done
    else
        echo "note: shellcheck not installed; steps.sh/hooks.sh were not shell-linted"
    fi
    c=$(_sc_conf_get "$f" CONTENT)
    if [ -n "$c" ] && ! rig_content_check "$c" >/dev/null 2>&1; then
        echo "note: content profile '$c' is not configured on this box (rig.conf RIG_CONTENT_${c}_*): a run here would SKIP"
    fi
    if [ "$bad" = 0 ]; then echo "lint $name: ok"; else echo "lint $name: FAILED"; fi
    return "$bad"
}
rig_cli_lint() {
    local a d bad=0 n=0
    local -a args=()
    for a in "$@"; do
        case $a in
            -h|--help) rig_cli_help lint; return 0 ;;
            -*) _cli_usage_err lint "unknown flag $a"; return 64 ;;
            *)  [ -d "$a" ] || { _cli_usage_err lint "no such directory: $a"; return 64; }; args+=("$a") ;;
        esac
    done
    [ "${#args[@]}" -gt 0 ] || { _cli_usage_err lint "name at least one scenario directory"; return 64; }
    while IFS= read -r d; do
        _cli_lint_one "$d" || bad=1
        n=$((n+1))
    done < <(_cli_scenarios "${args[@]}")
    [ "$n" -gt 0 ] || { echo "rig lint: no scenario.conf under ${args[*]}" >&2; return 1; }
    return "$bad"
}

# ================================================================================================
# explain
# ================================================================================================
# _cli_logfile <scenario run dir> <log key> — server -> server.log, <p> -> client-<p>.log.
_cli_logfile() { if [ "$2" = server ]; then printf '%s/server.log' "$1"; else printf '%s/client-%s.log' "$1" "$2"; fi; }
# _cli_window <file> <start> <end> — the window as a line range plus its last lines (aligned to lines).
_cli_window() {
    local file=$1 s=$2 e=$3 a b
    [ -f "$file" ] || { echo "    open: $file (missing)"; return; }
    a=$(( $(head -c "$s" "$file" | wc -l) + 1 ))
    b=$(head -c "$e" "$file" | wc -l); [ "$b" -ge "$a" ] || b=$a
    echo "    open: $file  bytes $s-$e = lines $a-$b"
    echo "          sed -n '${a},${b}p' $file      (bytes: tail -c +$((s+1)) $file | head -c $((e-s)))"
    if [ "$e" -gt "$s" ]; then
        echo "          last lines of the window:"
        sed -n "${a},${b}p" "$file" | tail -n 6 | cut -c1-160 | sed 's/^/            | /'
    else
        echo "          (the window is empty: nothing was logged there)"
    fi
}
_cli_tail() {   # _cli_tail <file> — the last lines of a log a failure names
    [ -f "$1" ] || return 0
    echo "    open: $1  (last lines:)"
    tail -n 5 "$1" | cut -c1-160 | sed 's/^/            | /'
}
# _cli_explain_row <run dir> <source dir> <line> <verb text> <status> <offsets> <detail>
_cli_explain_row() {
    local r=$1 src=$2 line=$3 desc=$4 st=$5 off=$6 det=$7 verb kind w k p f
    read -r verb kind _ <<<"$desc"
    printf '  %-16s %s\n    -> %s %s\n' "$line" "$desc" "$st" "$det"
    # A searched window: offsets "log:start-end".
    if [[ $off =~ ^([A-Za-z0-9_]+):([0-9]+)-([0-9]+)$ ]]; then
        k=${BASH_REMATCH[1]}
        _cli_window "$(_cli_logfile "$r" "$k")" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}"
    fi
    case $verb in
        shot)
            read -r _ p w _ <<<"$desc"
            [ -n "$w" ] || return 0
            echo "    open: $r/shots/$w.png (this run)"
            [ -f "$src/reference-images/$w.png" ] && echo "          $src/reference-images/$w.png (reference)"
            [ -f "$r/review/$w.diff.png" ] && echo "          $r/review/$w.diff.png (difference image)"
            case $st in NO-REFERENCE|UNBLESSED) echo "    bless (a human decision): cp $r/shots/$w.png $src/reference-images/$w.png";; esac ;;
        signature)
            w=$kind; [ -n "$w" ] || w=$(_sc_scenario_name "$src" 2>/dev/null)
            [ -f "$r/review/$w.logdiff" ] && echo "    open: $r/review/$w.logdiff (reference vs this run's signature)"
            [ -f "$r/review/$w.events" ] && echo "          $r/review/$w.events (this run's signature)"
            [ -f "$src/reference-logs/$w.events" ] && echo "          $src/reference-logs/$w.events (reference)"
            case $st in NO-REFERENCE|UNBLESSED) echo "    bless (a human decision): cp $r/review/$w.events $src/reference-logs/$w.events";; esac ;;
        pair)
            read -r _ _ p w _ <<<"$desc"
            echo "    open: $r/shots/$p.png and $r/shots/$w.png (the two frames that must differ)" ;;
        assert)
            [ "$kind" = json ] && echo "    the document lived in the CoreScripts work copy: re-run with --keep-work and open $r/corescripts/data/$(read -r _ _ w _ <<<"$desc"; printf '%s' "$w")" ;;
    esac
    # A file the detail names: "see client-a.log", "at server.log:12:", "diff /path".
    for f in $(grep -oE '(client-[A-Za-z0-9_]+|server(-[0-9]+)?|run)\.log' <<<"$det" | sort -u); do
        [ "$off" ] && [[ $off =~ ^[A-Za-z0-9_]+:[0-9]+-[0-9]+$ ]] && continue
        _cli_tail "$r/$f"
    done
    if [[ $det =~ at\ ([A-Za-z0-9_.-]+\.log):([0-9]+): ]]; then
        echo "    open: $r/${BASH_REMATCH[1]} line ${BASH_REMATCH[2]}  (sed -n '${BASH_REMATCH[2]}p' $r/${BASH_REMATCH[1]})"
    fi
    if [ "$line" = runner ] || [ "$line" = setup ]; then _cli_tail "$r/run.log"; fi
    return 0
}
# _cli_explain_attempt <run dir> <source dir> <label> — the failing rows of one attempt; 0 if any.
_cli_explain_attempt() {
    local r=$1 src=$2 label=$3 step line desc st off det n=0 u=0
    [ -f "$r/steps.tsv" ] || { echo " $label: no steps.tsv (see $r/run.log)"; _cli_tail "$r/run.log"; return 0; }
    echo " $label: $(cat "$r/RESULT" 2>/dev/null || echo 'no RESULT')  ($r)"
    while IFS=$'\t' read -r step line desc st _ off det; do
        case $step in '#'*|'') continue ;; esac
        case $st in
            FAIL|REGRESSION|NO-REFERENCE) _cli_explain_row "$r" "$src" "$line" "$desc" "$st" "$off" "$det"; n=$((n+1)) ;;
            UNBLESSED) u=$((u+1)) ;;
        esac
    done < "$r/steps.tsv"
    [ "$n" -gt 0 ] || echo "   no failing step"
    [ "$u" -gt 0 ] && echo "   $u unblessed reference(s): grep UNBLESSED $r/steps.tsv (candidates in shots/ and review/)"
    return 0
}
rig_cli_explain() {
    local arg='' set r src k code infra=0 failed=0
    for k in "$@"; do
        case $k in
            -h|--help) rig_cli_help explain; return 0 ;;
            -*) _cli_usage_err explain "unknown flag $k"; return 64 ;;
            *)  [ -z "$arg" ] || { _cli_usage_err explain "one run directory only"; return 64; }; arg=$k ;;
        esac
    done
    set=$(_cli_run_set "$arg") || return 1
    echo "run: $set"
    [ -f "$set/RESULTS" ] && sed 's/^/  /' "$set/RESULTS"
    while IFS= read -r r; do
        src=$(_cli_source_dir "$r") || src='?'
        echo
        echo "== $(basename "$r")  (scenario $src)"
        for k in $(find "$r" -mindepth 1 -maxdepth 1 -type d -name 'attempt-*' -printf '%f\n' | sort -t- -k2 -n); do
            _cli_explain_attempt "$r/$k" "$src" "$k"
        done
        _cli_explain_attempt "$r" "$src" "final attempt"
        code=$(cut -d' ' -f3 "$r/RESULT" 2>/dev/null)
        case $code in 1|2) failed=1;; 3) failed=1; infra=1;; esac
    done < <(_cli_scenario_runs "$set")
    echo
    if [ "$failed" = 1 ]; then
        echo "next:"
        [ "$infra" = 1 ] && echo "  INFRA = the world did not come up or died: check the setup with bin/rig doctor"
        echo "  re-run what failed:  bin/rig rerun-failed $set"
        echo "  explore by hand:     bin/rig up <scenario dir>   (then bin/rig down)"
    fi
    return 0
}

# ================================================================================================
# rerun-failed
# ================================================================================================
rig_cli_rerun_failed() {
    local arg='' set r code src
    local -a flags=() dirs=() names=()
    if [ $# -gt 0 ] && [[ $1 != -* ]]; then arg=$1; shift; fi
    for r in "$@"; do case $r in -h|--help) rig_cli_help rerun-failed; return 0;; esac; done
    flags=("$@")
    set=$(_cli_run_set "$arg") || return 1
    while IFS= read -r r; do
        code=$(cut -d' ' -f3 "$r/RESULT" 2>/dev/null)
        case $code in 1|2|3) ;; *) continue ;; esac
        src=$(_cli_source_dir "$r") || { echo "rig rerun-failed: cannot tell which scenario $r ran (no env.txt or run.log)" >&2; return 1; }
        [ -f "$src/scenario.conf" ] || { echo "rig rerun-failed: scenario dir $src (from $r) no longer exists" >&2; return 1; }
        dirs+=("$src"); names+=("$(basename "$r")")
    done < <(_cli_scenario_runs "$set")
    if [ "${#dirs[@]}" -eq 0 ]; then echo "rig rerun-failed: nothing failed in $set"; return 0; fi
    echo "rig rerun-failed: ${#dirs[@]} scenario(s) from $set: ${names[*]}"
    scenario_run "${dirs[@]}" "${flags[@]+"${flags[@]}"}"
}

# ================================================================================================
# up / down
# ================================================================================================
# _cli_rig_pids <run|up|_run-one>... — pids of the rig's own bash processes by their argv: `bash
# .../bin/rig run|up ...` or `bash .../lib/scenario.sh _run-one ...` (an idle wiggler is a fork of the
# latter). argv is matched exactly, never as a substring: `pgrep -f` would also match any shell whose
# command line merely mentions these words, including the one that called bin/rig down.
_cli_rig_pids() {
    local d pid a0 a1 a2 want
    for d in /proc/[0-9]*; do
        pid=${d#/proc/}
        [ "$pid" = "$$" ] && continue
        { IFS= read -r -d '' a0 && IFS= read -r -d '' a1 && IFS= read -r -d '' a2; } < "$d/cmdline" 2>/dev/null || continue
        [ "${a0##*/}" = bash ] || continue
        for want in "$@"; do
            case $want in
                _run-one) [ "${a1##*/}" = scenario.sh ] && [ "$a2" = _run-one ] && { echo "$pid"; break; } ;;
                *)        [ "${a1##*/}" = rig ] && [ "$a2" = "$want" ] && { echo "$pid"; break; } ;;
            esac
        done
    done
}
_cli_live() {   # return 0 if any rig process is running
    local out=''
    out=$(pgrep -x "$RIG_SERVER_BIN"; pgrep -x "$RIG_CLIENT_BIN"; pgrep -x Xvfb; pgrep -x xdotool; _cli_rig_pids _run-one) 2>/dev/null
    [ -n "$out" ]
}
rig_cli_up() {
    local dir='' a p name set out code fixture conf disp pid i
    local -a want=() pl=()
    for a in "$@"; do
        case $a in
            -h|--help) rig_cli_help up; return 0 ;;
            -*) _cli_usage_err up "unknown flag $a"; return 64 ;;
            *)  if [ -z "$dir" ]; then dir=$a; else want+=("$a"); fi ;;
        esac
    done
    [ -n "$dir" ] || { _cli_usage_err up "name a scenario directory"; return 64; }
    [ -f "$dir/scenario.conf" ] || { _cli_usage_err up "no scenario.conf in $dir"; return 64; }
    dir=$(cd "$dir" && pwd); conf=$dir/scenario.conf
    read -r -a pl <<<"$(_sc_conf_get "$conf" PLAYERS)"
    [ "${#pl[@]}" -gt 0 ] || { echo "rig up: $conf has no PLAYERS" >&2; return 3; }
    [ "${#want[@]}" -gt 0 ] || want=("${pl[@]}")
    for p in "${want[@]}"; do
        case " ${pl[*]} " in *" $p "*) ;; *) _cli_usage_err up "player '$p' is not in PLAYERS (${pl[*]}) of $conf"; return 64;; esac
    done
    if pgrep -x "$RIG_SERVER_BIN" >/dev/null 2>&1; then
        echo "rig up: a $RIG_SERVER_BIN is already running (an earlier bin/rig up, or a killed run); stop it with: bin/rig down" >&2
        return 3
    fi
    name=$(_sc_scenario_name "$dir")
    RIG_RUN_DIR=''; rig_run_dir "up-$name" >/dev/null; set=$RIG_RUN_DIR; RIG_RUN_DIR=''
    fixture=$(_sc_conf_get "$conf" FIXTURE)
    {
        echo "# bin/rig up: bring $name's world up and leave it running"
        for p in "${want[@]}"; do
            echo "boot $p"
            if [ "$fixture" = - ]; then echo "login $p fresh"; else echo "login $p"; fi
        done
    } > "$set/up-steps.sh"
    : > "$set/RESULTS"
    echo "rig up: $name -> $set (booting ${want[*]}; a few minutes on software GL)"
    code=0
    RIG_SET_DIR=$set SC_STEPS_FILE=$set/up-steps.sh SC_KEEP_UP=1 RIG_KEEP_WORK=1 SC_CAPTURE=1 SC_STRICT=0 SC_ATTEMPT=1 \
        bash "$_SC_LIB_DIR/scenario.sh" _run-one "$dir" "$set/$name" 3>&1 </dev/null || code=$?
    out=$set/$name
    cat "$out/RESULT" >> "$set/RESULTS" 2>/dev/null
    if [ "$code" != 0 ]; then
        echo "rig up: the world did not come up (exit $code); tearing down. Why: bin/rig explain $set" >&2
        rig_cli_down >/dev/null
        return 3
    fi
    printf '%s\n' "$out" > "$RIG_RUNS/.rig-up"
    echo
    echo "rig up: $name is up. Run dir: $out"
    printf '  %-8s pid %-8s log %s\n' server "$(pgrep -x "$RIG_SERVER_BIN" | head -1)" "$out/server.log"
    for i in "${!pl[@]}"; do
        p=${pl[i]}
        case " ${want[*]} " in *" $p "*) ;; *) continue;; esac
        case $i in 0) disp=$RIG_DISPLAY;; 1) disp=$RIG_DISPLAY2;; *) disp=$RIG_DISPLAY3;; esac
        pid=''
        for a in $(pgrep -x "$RIG_CLIENT_BIN"); do
            tr '\0' '\n' < "/proc/$a/environ" 2>/dev/null | grep -qx "DISPLAY=$disp" && pid=$a
        done
        printf '  %-8s pid %-8s log %s   display %s   profile %s\n' "$p" "${pid:-?}" "$out/client-$p.log" "$disp" "$out/profiles/$p"
    done
    disp=$RIG_DISPLAY
    cat <<EOF

attach (each player has its own display; no window manager, so no focus is needed):
  drive:    DISPLAY=$disp xdotool key Return          DISPLAY=$disp xdotool mousemove 640 360 click 1
  capture:  DISPLAY=$disp import -window root /tmp/shot.png
  watch:    x11vnc -display $disp -localhost -once    (then a VNC viewer on localhost:5900), if installed
  logs:     tail -f $out/server.log $out/client-${want[0]}.log
  The idle wiggler keeps nudging the pointer every ${RIG_WIGGLE_INTERVAL}s (WIGGLE=0 in scenario.conf turns it off).
stop:       bin/rig down
EOF
    return 0
}
# shellcheck disable=SC2120  # bin/rig passes the user's arguments; rig_cli_up calls it bare
rig_cli_down() {
    local a pids d w=0 n=0 up=''
    for a in "$@"; do case $a in -h|--help) rig_cli_help down; return 0;; *) _cli_usage_err down "takes no arguments"; return 64;; esac; done
    [ -f "$RIG_RUNS/.rig-up" ] && up=$(cat "$RIG_RUNS/.rig-up")
    # Parents first (so none starts the next scenario), then the runner children (each kept-up or
    # orphaned idle wiggler is a fork of one), then the game processes and displays.
    pids=$(_cli_rig_pids run up rerun-failed _run-one)
    if [ -n "$pids" ]; then n=$((n + $(wc -w <<<"$pids"))); kill $pids 2>/dev/null; fi
    for a in "$RIG_CLIENT_BIN" "$RIG_SERVER_BIN" Xvfb xdotool; do
        pids=$(pgrep -x "$a" 2>/dev/null) || continue
        n=$((n + $(wc -w <<<"$pids")))
        if [ "$a" = "$RIG_CLIENT_BIN" ]; then pkill -9 -x "$a" 2>/dev/null; else pkill -x "$a" 2>/dev/null; fi
    done
    while _cli_live && [ "$w" -lt 15 ]; do sleep 1; w=$((w+1)); done
    if _cli_live; then        # a straggler that ignored SIGTERM
        pkill -9 -x "$RIG_SERVER_BIN" 2>/dev/null; pkill -9 -x Xvfb 2>/dev/null; pkill -9 -x xdotool 2>/dev/null
        pids=$(_cli_rig_pids _run-one); [ -z "$pids" ] || kill -9 $pids 2>/dev/null; sleep 1
    fi
    for d in "$RIG_DISPLAY" "$RIG_DISPLAY2" "$RIG_DISPLAY3"; do rm -f "/tmp/.X${d#:}-lock" 2>/dev/null; done
    rm -f "$RIG_RUNS/.rig-up"
    if _cli_live; then
        echo "rig down: still running after SIGKILL:"; _cli_live_list; return 1
    fi
    echo "rig down: stopped $n process(es)${up:+ (the world of bin/rig up in $up)}; nothing rig-owned is running"
    return 0
}
_cli_live_list() {
    local p
    { pgrep -a -x "$RIG_SERVER_BIN"; pgrep -a -x "$RIG_CLIENT_BIN"; pgrep -a -x Xvfb; pgrep -a -x xdotool; } 2>/dev/null
    for p in $(_cli_rig_pids _run-one); do echo "$p $(tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null)"; done
}
