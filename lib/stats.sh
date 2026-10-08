#!/usr/bin/env bash
# stats.sh — host load recording and run statistics. A test on a shared or software-rendered box is
# sometimes non-deterministic; this file makes that measurable instead of something to wait out.
#
#   rig_load_snapshot <file> start|end   append the host's load to a key=value file (load.txt): the
#                                        runner calls it around every run set and scenario attempt
#   rig_stats [flags]                    bin/rig stats: per-scenario pass/retry/fail counts, durations,
#                                        recent failures against the long-run rate, pass rate by load
#   lib/stats.sh selftest                proves both on synthetic run directories (no game, no display)
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
# bin/rig stats
# ================================================================================================
_st_usage() {
    cat <<'USAGE'
usage: bin/rig stats [--runs N | --days D] [--scenario NAME]... [--window W] [--root DIR] [--json]
  Statistics over the run sets under RIG_RUNS (every dir with a RESULTS file; `bin/rig up` worlds are
  left out). Per scenario: RUNS (scenario runs, SKIP left out), ATT (attempts, retries included),
  PASS (first-attempt passes), RETRY (PASS-RETRY), FAIL/REG/INFRA (final verdicts by exit code 1/2/3),
  FAIL% (failed attempts / attempts), FLAKE% (runs that failed and then passed on a retry / runs),
  mean and max attempt duration, the last W attempts (oldest first: P pass, F fail, R regression,
  I infra) and a judgment of those W attempts against all earlier attempts of the same scenario:
    ok                   no failure in the window
    unlucky (p=..)       failures in the window are likely at the earlier rate
    suspicious (p=..)    p < 0.05: re-run it and look at what changed
    likely regression    p < 0.01: the failure rate went up
    too few runs         fewer than 10 earlier attempts to compare against
  p is the binomial chance of at least that many failures in W attempts at the earlier failure rate
  ((failures+1)/(attempts+2)). Then the pass rate of all selected attempts by the CPU-busy sample at
  attempt start (load.txt; the 1-minute load average per core for attempts recorded without one).
  --runs N        only the newest N run sets      --days D    only run sets of the last D days
  --scenario S    only scenario S (repeatable)    --window W  the recent window (default 10 attempts)
  --root DIR      read DIR instead of RIG_RUNS    --json      one JSON document instead of tables
  Exit 0, 1 when no run set is found, 64 usage.
USAGE
}
rig_stats() {
    local root=${RIG_RUNS:-} runs=0 days=0 window=10 json=0
    local -a scen=()
    while [ $# -gt 0 ]; do
        case $1 in
            --runs)     [[ ${2:-} =~ ^[1-9][0-9]*$ ]] || { echo "rig stats: --runs needs a positive count" >&2; return 64; }; runs=$2; shift ;;
            --days)     [[ ${2:-} =~ ^[0-9]+(\.[0-9]+)?$ ]] || { echo "rig stats: --days needs a number" >&2; return 64; }; days=$2; shift ;;
            --window)   [[ ${2:-} =~ ^[1-9][0-9]*$ ]] || { echo "rig stats: --window needs a positive count" >&2; return 64; }; window=$2; shift ;;
            --scenario) [ -n "${2:-}" ] || { echo "rig stats: --scenario needs a name" >&2; return 64; }; scen+=("$2"); shift ;;
            --root)     [ -n "${2:-}" ] || { echo "rig stats: --root needs a directory" >&2; return 64; }; root=$2; shift ;;
            --json)     json=1 ;;
            -h|--help)  _st_usage; return 0 ;;
            *)          echo "rig stats: unknown argument $1" >&2; _st_usage >&2; return 64 ;;
        esac
        shift
    done
    [ "$runs" = 0 ] || [ "$days" = 0 ] || { echo "rig stats: --runs and --days exclude each other" >&2; return 64; }
    [ -n "$root" ] && [ -d "$root" ] || { echo "rig stats: no run directory '$root' (RIG_RUNS or --root)" >&2; return 1; }
    command -v python3 >/dev/null 2>&1 || { echo "rig stats: needs python3" >&2; return 1; }
    python3 -I - "$root" "$runs" "$days" "$window" "$json" "${scen[@]+"${scen[@]}"}" <<'PY'
import json, math, os, re, sys, time

root, runs, days, window, as_json = sys.argv[1], int(sys.argv[2]), float(sys.argv[3]), int(sys.argv[4]), sys.argv[5] == "1"
want = set(sys.argv[6:])
RESULT = re.compile(r"^RESULT (\S+) (\d) (\S+) (\d+) (\d+) (\d+)")
LETTER = {0: "P", 1: "F", 2: "R", 3: "I"}

def kv(path):
    d = {}
    try:
        with open(path, errors="replace") as fh:
            for line in fh:
                if "=" in line and not line.startswith("#"):
                    k, v = line.rstrip("\n").split("=", 1)
                    d[k] = v
    except OSError:
        pass
    return d

def num(v):
    try:
        return float(v)
    except (TypeError, ValueError):
        return None

def first_fail(d):
    """The first failing step of an attempt: '<steps.sh line> <verb and arguments>'."""
    try:
        with open(os.path.join(d, "steps.tsv"), errors="replace") as fh:
            for line in fh:
                c = line.rstrip("\n").split("\t")
                if len(c) >= 4 and not c[0].startswith("#") and c[3] in ("FAIL", "REGRESSION", "NO-REFERENCE"):
                    return (c[1] + " " + c[2])[:80]
    except OSError:
        pass
    return None

def duration(d, load):
    v = num(load.get("duration"))
    if v is not None:
        return v
    last = None
    try:
        with open(os.path.join(d, "run.log"), errors="replace") as fh:
            for line in fh:
                m = re.match(r"^\[t\+(\d+)s\]", line)
                if m:
                    last = int(m.group(1))
    except OSError:
        pass
    return last

def attempt(d, set_time):
    try:
        with open(os.path.join(d, "RESULT")) as fh:
            m = RESULT.match(fh.readline())
    except OSError:
        return None
    if not m:
        return None
    load = kv(os.path.join(d, "load.txt"))
    busy = num(load.get("start_busy"))
    if busy is None:
        la, cores = (load.get("start_loadavg") or "").split()[:1], num(load.get("cores"))
        if la and cores and num(la[0]) is not None:
            busy = 100.0 * num(la[0]) / cores
    t = num(load.get("start_epoch"))
    if t is None:
        try:
            t = os.path.getmtime(os.path.join(d, "RESULT"))
        except OSError:
            t = set_time
    return {"name": m.group(3), "status": m.group(1), "code": int(m.group(2)), "time": t,
            "duration": duration(d, load), "busy": busy, "first_fail": first_fail(d), "dir": d}

# Run sets: direct subdirs of root with RESULTS, not a `bin/rig up` world.
sets = []
for e in os.scandir(root):
    if not e.is_dir() or not os.path.isfile(os.path.join(e.path, "RESULTS")):
        continue
    if os.path.exists(os.path.join(e.path, "up-steps.sh")):
        continue
    t = num(kv(os.path.join(e.path, "load.txt")).get("start_epoch")) or os.path.getmtime(os.path.join(e.path, "RESULTS"))
    sets.append((t, e.path))
sets.sort()
if days > 0:
    sets = [s for s in sets if s[0] >= time.time() - days * 86400]

# Scenario runs: per set, each subdir with RESULT; its attempts are attempt-<k>/ (in k order) + itself.
records = []   # (set_time, set_path, name, [attempts], final)
for st, sp in sets:
    for e in sorted(os.scandir(sp), key=lambda x: x.name):
        if not e.is_dir() or e.name.startswith("attempt-") or not os.path.isfile(os.path.join(e.path, "RESULT")):
            continue
        final = attempt(e.path, st)
        if final is None or (want and final["name"] not in want):
            continue
        ks = sorted((int(x.name[8:]), x.path) for x in os.scandir(e.path)
                    if x.is_dir() and re.fullmatch(r"attempt-\d+", x.name))
        atts = [a for a in (attempt(p, st) for _, p in ks) if a is not None] + [final]
        records.append((st, sp, final["name"], atts, final))
if runs > 0:
    keep = sorted({sp for st, sp, *_ in records}, key=lambda p: dict((b, a) for a, b in sets)[p])[-runs:]
    records = [r for r in records if r[1] in keep]
if not records:
    print(f"rig stats: no scenario runs under {root}" + (f" for {' '.join(sorted(want))}" if want else ""), file=sys.stderr)
    sys.exit(1)

def tail(n, k, p):
    """P(X >= k) for X ~ Binomial(n, p)."""
    return sum(math.comb(n, i) * p ** i * (1 - p) ** (n - i) for i in range(k, n + 1))

def judge(atts):
    win, base = atts[-window:], atts[:-window]
    k = sum(1 for a in win if a["code"] != 0)
    if k == 0:
        return "ok", None
    if len(base) < 10:
        return "too few runs", None
    fb = sum(1 for a in base if a["code"] != 0)
    p = tail(len(win), k, (fb + 1) / (len(base) + 2))
    if p < 0.01:
        return "likely regression", p
    if p < 0.05:
        return "suspicious", p
    return "unlucky", p

BUCKETS = [("<10%", 0, 10), ("10-30%", 10, 30), ("30-60%", 30, 60), (">=60%", 60, 1e9)]
def bucket(b):
    if b is None:
        return "unknown"
    for name, lo, hi in BUCKETS:
        if lo <= b < hi:
            return name
    return "unknown"
def buckets(atts):
    out = {}
    for a in atts:
        c = out.setdefault(bucket(a["busy"]), [0, 0])
        c[0] += 1
        c[1] += a["code"] == 0
    order = [b[0] for b in BUCKETS] + ["unknown"]
    return [{"busy": b, "attempts": out[b][0], "pass": out[b][1], "pass_rate": round(out[b][1] / out[b][0], 3)}
            for b in order if b in out]

per = {}
for st, sp, name, atts, final in records:
    s = per.setdefault(name, {"runs": 0, "skipped": 0, "atts": [], "pass": 0, "retry": 0, "fail": {1: 0, 2: 0, 3: 0}})
    if final["code"] == 4:
        s["skipped"] += 1
        continue
    s["runs"] += 1
    s["atts"].extend(a for a in atts if a["code"] != 4)
    if final["code"] == 0:
        s["pass" if len(atts) == 1 else "retry"] += 1
    elif final["code"] in s["fail"]:
        s["fail"][final["code"]] += 1

out = {"root": root, "run_sets": len({r[1] for r in records}), "window": window, "scenarios": {}}
all_atts = []
for name in sorted(per):
    s = per[name]
    atts = sorted(s["atts"], key=lambda a: a["time"])
    all_atts += atts
    durs = [a["duration"] for a in atts if a["duration"] is not None]
    nf = sum(1 for a in atts if a["code"] != 0)
    j, p = judge(atts) if atts else ("no runs", None)
    fails = [a for a in atts if a["code"] != 0]
    out["scenarios"][name] = {
        "runs": s["runs"], "skipped": s["skipped"], "attempts": len(atts), "pass": s["pass"], "pass_retry": s["retry"],
        "fail": s["fail"][1], "regression": s["fail"][2], "infra": s["fail"][3],
        "attempt_fail_rate": round(nf / len(atts), 3) if atts else None,
        "flake_rate": round(s["retry"] / s["runs"], 3) if s["runs"] else None,
        "duration_mean": round(sum(durs) / len(durs), 1) if durs else None,
        "duration_max": max(durs) if durs else None,
        "recent": "".join(LETTER.get(a["code"], "?") for a in atts[-window:]),
        "judgment": j, "p": None if p is None else round(p, 4),
        "last_failure": None if not fails else {"dir": fails[-1]["dir"], "step": fails[-1]["first_fail"],
                                                "busy_at_start": fails[-1]["busy"]},
        "by_busy": buckets(atts),
    }
out["by_busy"] = buckets(all_atts)

if as_json:
    json.dump(out, sys.stdout, indent=1, sort_keys=True)
    print()
    sys.exit(0)

def pct(v):
    return "-" if v is None else f"{100 * v:.0f}"
def secs(v):
    return "-" if v is None else f"{v:.0f}s"
print(f"rig stats: {len(all_atts)} attempts of {len(per)} scenario(s) in {out['run_sets']} run set(s) under {root}")
print(f"{'SCENARIO':<26} {'RUNS':>4} {'ATT':>4} {'PASS':>4} {'RETRY':>5} {'FAIL':>4} {'REG':>3} {'INFRA':>5} "
      f"{'FAIL%':>5} {'FLAKE%':>6} {'MEAN':>5} {'MAX':>5}  {'LAST ' + str(window):<{max(window, 7)}}  JUDGMENT")
for name, s in out["scenarios"].items():
    j = s["judgment"] + (f" (p={s['p']:.3f})" if s["p"] is not None else "")
    print(f"{name:<26} {s['runs']:>4} {s['attempts']:>4} {s['pass']:>4} {s['pass_retry']:>5} {s['fail']:>4} "
          f"{s['regression']:>3} {s['infra']:>5} {pct(s['attempt_fail_rate']):>5} {pct(s['flake_rate']):>6} "
          f"{secs(s['duration_mean']):>5} {secs(s['duration_max']):>5}  {s['recent']:<{max(window, 7)}}  {j}")
    if s["last_failure"] and s["judgment"] not in ("ok",):
        lf = s["last_failure"]
        busy = "busy unknown" if lf["busy_at_start"] is None else f"busy {lf['busy_at_start']:.0f}%"
        print(f"{'':<26}   last failure: {lf['step'] or '(no failing step recorded)'}  {busy}  {lf['dir']}")
print()
print("pass rate by CPU busy at attempt start (% of all cores):")
print(f"  {'BUSY':<8} {'ATTEMPTS':>8} {'PASS':>5} {'PASS%':>6}")
for b in out["by_busy"]:
    print(f"  {b['busy']:<8} {b['attempts']:>8} {b['pass']:>5} {pct(b['pass_rate']):>6}")
PY
}

# ================================================================================================
# selftest — synthetic run directories; no game binary, no display
# ================================================================================================
stats_selftest() {
    local t fails=0 out rc
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

    # -- 2. synthetic run sets: <root>/<set>/RESULTS, <scenario>/RESULT [+ attempt-<k>/] [+ load.txt] --
    local root=$t/runs i s
    _set() {   # _set <index> <scenario> <code...> — one run set holding one scenario run; codes = attempts in order
        local n=$1 name=$2 sd k=1 c status; shift 2
        sd=$root/$(printf 'set%03d' "$n"); mkdir -p "$sd/$name"
        printf 'start_epoch=%s\n' "$((1700000000 + n * 600))" > "$sd/load.txt"
        for c in "$@"; do
            local d=$sd/$name; [ "$k" -lt "$#" ] && d=$sd/$name/attempt-$k
            mkdir -p "$d"
            case $c in 0) status=PASS; [ "$k" -gt 1 ] && status=PASS-RETRY ;; 1) status=FAIL ;; 2) status=REGRESSION ;; 3) status=INFRA ;; 4) status=SKIP ;; esac
            echo "RESULT $status $c $name 0 0 $k" > "$d/RESULT"
            printf 'cores=4\nstart_epoch=%s\nstart_loadavg=%s 0 0\nstart_busy=%s\nduration=%s\n' \
                "$((1700000000 + n * 600 + k))" "${SYN_LOAD:-0.2}" "${SYN_BUSY:-5.0}" "$((100 + k))" > "$d/load.txt"
            printf 'step\tline\tverb\tstatus\tt\toffsets\tdetail\n1\tsteps.sh:7\twait server x\t%s\t3\t\td\n' \
                "$([ "$c" = 0 ] && echo PASS || echo FAIL)" > "$d/steps.tsv"
            k=$((k+1))
        done
        grep -h '^RESULT' "$sd/$name/RESULT" > "$sd/RESULTS"
    }
    # alpha: 30 clean runs, then 3 failures in the last 10 -> likely regression
    for i in $(seq 1 30); do _set "$i" alpha 0; done
    for i in $(seq 31 40); do if [ $((i % 3)) = 0 ]; then _set "$i" alpha 1; else _set "$i" alpha 0; fi; done
    # beta: one failure in 40 earlier attempts and one in the last 10 -> unlucky; one PASS-RETRY run
    for i in $(seq 41 80); do if [ "$i" = 50 ]; then _set "$i" beta 1; else _set "$i" beta 0; fi; done
    for i in $(seq 81 87); do _set "$i" beta 0; done
    _set 88 beta 1 0
    for i in $(seq 89 90); do _set "$i" beta 0; done
    # gamma: two runs only, one INFRA, one SKIP (left out), at high busy
    SYN_BUSY=75.0 _set 91 gamma 3
    _set 92 gamma 4
    # delta: no busy sample, load average 3 on 4 cores -> bucket >=60%
    SYN_BUSY=- SYN_LOAD=3.0 _set 93 delta 1
    # a `bin/rig up` world: ignored
    mkdir -p "$root/up-x/alpha"; : > "$root/up-x/up-steps.sh"; echo "RESULT FAIL 1 alpha 1 0 1" > "$root/up-x/alpha/RESULT"; cp "$root/up-x/alpha/RESULT" "$root/up-x/RESULTS"

    out=$(rig_stats --root "$root" 2>&1); rc=$?
    [ "$rc" = 0 ] && _ok "stats: exit 0" || _bad "stats: exit 0" "rc=$rc $out"
    _has "stats: alpha counts (40 runs, 3 FAIL, an up world left out)" "$out" '^alpha +40 +40 +37 +0 +3 +0 +0 +8 +0 '
    _has "stats: alpha -> likely regression" "$out" '^alpha .*PPFPPFPPFP +likely regression \(p=0\.00'
    _has "stats: beta PASS-RETRY counted" "$out" '^beta +50 +51 +48 +1 +1 +0 +0 +4 +2 '
    _has "stats: beta -> unlucky" "$out" '^beta .*unlucky \(p=0\.[1-9]'
    _has "stats: gamma INFRA, SKIP left out" "$out" '^gamma +1 +1 +0 +0 +0 +0 +1 '
    _has "stats: few earlier attempts -> too few runs" "$out" '^gamma .*too few runs'
    _has "stats: failing step named" "$out" 'last failure: steps.sh:7 wait server x'
    _has "stats: duration mean and max" "$out" '^beta .* 101s +102s '
    _has "stats: busy bucket <10%" "$out" '^  <10% +91 +86 +9[45]$'
    _has "stats: load average per core when no busy sample" "$out" '^  >=60% +2 +0 +0$'
    out=$(rig_stats --root "$root" --scenario beta --json 2>&1)
    if python3 -I -c 'import json,sys; d=json.load(sys.stdin); assert list(d["scenarios"])==["beta"]; assert d["scenarios"]["beta"]["pass_retry"]==1; assert d["scenarios"]["beta"]["judgment"]=="unlucky"' <<<"$out"; then
        _ok "stats: --json with --scenario"; else _bad "stats: --json with --scenario" "$out"; fi
    out=$(rig_stats --root "$root" --runs 5 2>&1)
    _has "stats: --runs keeps the newest sets" "$out" 'in 5 run set'
    out=$(rig_stats --root "$root" --scenario nosuch 2>&1); rc=$?
    [ "$rc" = 1 ] && _ok "stats: nothing found -> exit 1" || _bad "stats: nothing found -> exit 1" "rc=$rc"
    rig_stats --runs x >/dev/null 2>&1; rc=$?
    [ "$rc" = 64 ] && _ok "stats: usage error -> 64" || _bad "stats: usage error -> 64" "rc=$rc"
    rig_stats --root "$root" --runs 2 --days 1 >/dev/null 2>&1; rc=$?
    [ "$rc" = 64 ] && _ok "stats: --runs with --days -> 64" || _bad "stats: --runs with --days -> 64" "rc=$rc"

    rm -rf "$t"
    echo "selftest done (fails=$fails)"
    return "$fails"
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    case "${1:-}" in
        selftest) stats_selftest; exit $? ;;
        stats)    shift; rig_stats "$@"; exit $? ;;
        *) echo "usage: lib/stats.sh selftest   (statistics go through bin/rig stats)" >&2; exit 64 ;;
    esac
fi
