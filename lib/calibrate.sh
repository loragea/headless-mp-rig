#!/usr/bin/env bash
# calibrate.sh — measure a scenario's run-to-run spread and bless its references. A STATIC reference
# is only as good as the tolerance next to it; this file replaces hand-tuning with a measurement and
# turns the manual copy into one checked command.
#
#   rig_calibrate <scenario> [flags]   bin/rig calibrate: N capture runs, one after another; per shot the
#                                      pairwise spread (RMSE and PHASH, as lib/compare.sh measures), a
#                                      proposed tolerance, freak frames, the medoid and a contact sheet;
#                                      per signature whether the runs agree. Writes calibration.json.
#   rig_bless <src> <scenario> [names] bin/rig bless: copy the chosen candidates into the scenario's
#                                      reference-images/ and reference-logs/, write the manifest rows.
#                                      Human-invoked only: bin/rig run never blesses.
#   lib/calibrate.sh selftest          proves the spread, tolerance, freak and medoid logic and bless's
#                                      copy, manifest and refuse-to-overwrite on synthetic PNGs and logs
#
# The tolerance rule, freak rule and hard limits are policy: docs/VERIFICATION.md §3 states them, the
# CAL_* constants below implement them. bin/rig sources this after lib/scenario.sh.
set -uo pipefail
_CAL_LIB_DIR=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)
if ! declare -F _sc_scenario_name >/dev/null; then
    # shellcheck source=scenario.sh
    source "$_CAL_LIB_DIR/scenario.sh"
fi

CAL_MARGIN=1.5          # proposed tolerance = max(floor, max pairwise spread x margin, rounded up to 2 significant digits)
CAL_FLOOR_RMSE=0.01     # the smallest tolerance proposed: below it a tolerance only measures capture noise
CAL_FLOOR_PHASH=8
CAL_LIMIT_RMSE=0.05     # a proposed tolerance above the hard limit is not blessable: the frame is not static
CAL_LIMIT_PHASH=25
CAL_FREAK=3             # a candidate is a freak when its distance to every other candidate exceeds the floor
                        # and CAL_FREAK x the largest distance among the other candidates

# ================================================================================================
# Help
# ================================================================================================
_cal_usage() {
    cat <<'USAGE'
usage: bin/rig calibrate <scenario dir> [--runs N] [--out DIR] [--from RUN]...
  Run the scenario N times (default 3, at least 2) with `bin/rig run --capture`, one run after
  another, then measure its candidates. Per `shot` (pair inputs left out): RMSE and PHASH between every
  two runs, the metric that will gate it (its manifest row, else RMSE for a crop and PHASH for a full
  frame), freak frames (one run far from all the others; excluded), the spread of the rest, the
  proposed tolerance and the recommended candidate (the medoid: least total distance to the others).
  Per `signature`: whether every run produced the same event signature, and the lines that vary.
  The rule (docs/VERIFICATION.md §3): tolerance = max(floor, spread x 1.5 rounded up to 2 significant
  digits); floors RMSE 0.01, PHASH 8; hard limits RMSE 0.05, PHASH 25.
  Writes into DIR (default RIG_RUNS/<YYYYmmdd-HHMMSS>-calibrate-<name>): run-<k>/ (each a run set),
  <shot>.contact.png (the candidates, medoid marked, then the difference image of the farthest pair),
  <signature>.sigdiff when signatures differ, and calibration.json. Prints a table and the bless command.
  --runs N     capture runs (default 3; freaks need 3 or more)
  --out DIR    the calibration directory (must not exist or be empty)
  --from RUN   measure an existing run (a run set or scenario run of this scenario, e.g. a run-<k>/ of
               an earlier calibration) instead of running; repeatable; --runs is then ignored
  Exit 0 every candidate set is blessable, 1 a set is not (spread over the hard limit, sizes differ,
  signatures differ, fewer than 2 candidates) or a run failed an assertion, 3 infrastructure (a run
  did not come up), 4 content missing, 64 usage.
USAGE
}
_bless_usage() {
    cat <<'USAGE'
usage: bin/rig bless <calibration.json | calibration dir | run dir> <scenario dir> [name...]
                     [--tolerance V] [--metric RMSE|PHASH] [--note "text"] [--replace]
  Copy candidates into the scenario as its references: a shot to reference-images/<name>.png with the
  row `<name> <metric> <tolerance> - <description>` in reference-images/manifest.tsv (the comparer
  reads metric and threshold from it), a signature to reference-logs/<name>.events with a row in
  reference-logs/manifest.tsv. Each row records the date, the build id and the note.
  From a calibration: every blessable candidate set, or only the named ones, with its recommended
  candidate and proposed tolerance. From a run dir (a run set or one scenario run): the named shots
  and signatures (default: all), with the tolerance from --tolerance or the existing manifest row.
  Human-invoked only: bin/rig run never blesses, and no script should call this unattended.
  --tolerance V  the threshold for the one selected shot (overrides the proposal)
  --metric M     its metric (default: the proposal, the manifest row, else RMSE crop / PHASH full frame)
  --note TEXT    why this reference is right, recorded in the manifest row
  --replace      overwrite existing references. Re-blessing is never a response to a failing test;
                 only a verified, intended behaviour change.
  Without --replace an existing reference refuses the whole bless; nothing is copied. Prints the
  git add command for the written files. Exit 0 blessed, 1 refused, 64 usage.
USAGE
}

# ================================================================================================
# Shared helpers
# ================================================================================================
# _cal_value <metric> <a.png> <b.png> — the comparer's scalar; empty and rc 1 when compare errors
# (commonly a size mismatch).
_cal_value() {
    local raw rc=0
    raw=$(magick compare -metric "$1" "$2" "$3" null: 2>&1) || rc=$?
    [ "$rc" -ge 2 ] && return 1
    _extract_value <<<"$raw"
}
# _cal_scenario_run <dir> <name> — the scenario run of <name> in a run set, or <dir> itself.
_cal_scenario_run() {
    if [ -f "$1/steps.tsv" ]; then (cd "$1" && pwd); return 0; fi
    [ -f "$1/$2/steps.tsv" ] && { (cd "$1/$2" && pwd); return 0; }
    return 1
}
# _cal_items <scenario run> <scenario name> — "shot<TAB>name" and "signature<TAB>name" per row of
# steps.tsv, in step order; a shot that is a pair input is left out (it is never blessed).
_cal_items() {
    awk -F'\t' -v def="$2" '
        $1 ~ /^#/ || $1 == "step" { next }
        { n = split($3, a, " ") }
        a[1] == "shot" && n >= 3 { if (!(a[3] in seen)) { seen[a[3]] = 1; order[++k] = "shot\t" a[3] } }
        a[1] == "pair" && n >= 4 { pin[a[3]] = 1; pin[a[4]] = 1 }
        a[1] == "signature" { s = (n >= 2 ? a[2] : def); if (!(("sig " s) in seen)) { seen["sig " s] = 1; order[++k] = "signature\t" s } }
        END { for (i = 1; i <= k; i++) { split(order[i], b, "\t"); if (b[1] == "shot" && (b[2] in pin)) continue; print order[i] } }
    ' "$1/steps.tsv"
}
_cal_build_id() { sed -n 's/^build_id=//p' "$1/env.txt" 2>/dev/null | head -1; }
_cal_screen() { local s=${RIG_SCREEN:-1280x720x24}; printf '%s' "${s%x*}"; }

# ================================================================================================
# bin/rig calibrate
# ================================================================================================
rig_calibrate() {
    local sdir='' runs=3 out='' name k rc set r
    local -a from=() rdirs=()
    while [ $# -gt 0 ]; do
        case $1 in
            --runs)    [[ ${2:-} =~ ^[0-9]+$ ]] && [ "$2" -ge 2 ] || { _cli_usage_err calibrate "--runs needs a count of 2 or more"; return 64; }; runs=$2; shift ;;
            --out)     [ -n "${2:-}" ] || { _cli_usage_err calibrate "--out needs a directory"; return 64; }; out=$2; shift ;;
            --from)    [ -d "${2:-}" ] || { _cli_usage_err calibrate "--from needs an existing run directory"; return 64; }; from+=("$2"); shift ;;
            -h|--help) _cal_usage; return 0 ;;
            -*)        _cli_usage_err calibrate "unknown flag $1"; return 64 ;;
            *)         [ -z "$sdir" ] || { _cli_usage_err calibrate "one scenario only"; return 64; }; sdir=$1 ;;
        esac
        shift
    done
    [ -n "$sdir" ] || { _cli_usage_err calibrate "name a scenario directory"; return 64; }
    [ -f "$sdir/scenario.conf" ] || { _cli_usage_err calibrate "no scenario.conf in $sdir"; return 64; }
    sdir=$(cd "$sdir" && pwd); name=$(_sc_scenario_name "$sdir")
    command -v magick >/dev/null 2>&1 || { echo "rig calibrate: needs ImageMagick 7 (magick)" >&2; return 3; }
    command -v python3 >/dev/null 2>&1 || { echo "rig calibrate: needs python3" >&2; return 3; }
    [ -n "$out" ] || out=${RIG_RUNS:-$RIG_ROOT/runs}/$(date +%Y%m%d-%H%M%S)-calibrate-$name
    if [ -e "$out" ] && [ -n "$(ls -A "$out" 2>/dev/null)" ]; then
        _cli_usage_err calibrate "--out $out exists and is not empty"; return 64
    fi
    mkdir -p "$out" || { echo "rig calibrate: cannot create $out" >&2; return 3; }
    out=$(cd "$out" && pwd)
    echo "rig calibrate: $name ($sdir) -> $out"

    if [ "${#from[@]}" -gt 0 ]; then
        for set in "${from[@]}"; do
            r=$(_cal_scenario_run "$set" "$name") || { echo "rig calibrate: no run of $name in $set (no steps.tsv)" >&2; return 64; }
            rdirs+=("$r")
        done
    else
        for k in $(seq 1 "$runs"); do
            echo "rig calibrate: capture run $k of $runs"
            rc=0; "$RIG_ROOT/bin/rig" run --capture --out "$out/run-$k" "$sdir" || rc=$?
            case $rc in
                0) ;;
                3|4) echo "rig calibrate: run $k did not complete (exit $rc): bin/rig explain $out/run-$k" >&2; return "$rc" ;;
                *) echo "rig calibrate: run $k failed an assertion (exit $rc); calibrate a scenario that passes: bin/rig explain $out/run-$k" >&2; return 1 ;;
            esac
            rdirs+=("$out/run-$k/$name")
        done
    fi
    _cal_analyze "$out" "$sdir" "$name" "${rdirs[@]}"
}

# _cal_analyze <out> <scenario dir> <name> <scenario run>... — measure, write calibration.json, print
# the table; returns calibrate's exit code.
_cal_analyze() {
    local out=$1 sdir=$2 name=$3 meta i j a b ra ph n kind item mrow
    shift 3
    local -a rd=("$@") shots=() sigs=()
    meta=$out/.measure.tsv; : > "$meta"
    for i in "${!rd[@]}"; do printf 'run\t%s\t%s\t%s\n' "$i" "${rd[$i]}" "$(_cal_build_id "${rd[$i]}")" >> "$meta"; done
    # The union of the runs' items, in the first run's order.
    while IFS=$'\t' read -r kind item; do
        case $kind in
            shot)      [[ " ${shots[*]-} " == *" $item "* ]] || shots+=("$item") ;;
            signature) [[ " ${sigs[*]-} " == *" $item "* ]] || sigs+=("$item") ;;
        esac
    done < <(for i in "${!rd[@]}"; do _cal_items "${rd[$i]}" "$name"; done)
    for item in "${shots[@]+"${shots[@]}"}"; do
        mrow=$(awk -F'\t' -v n="$item" '$1==n {print $2; exit}' "$sdir/reference-images/manifest.tsv" 2>/dev/null)
        [ -n "$mrow" ] && printf 'manifest\t%s\t%s\n' "$item" "$mrow" >> "$meta"
        local -a have=()
        for i in "${!rd[@]}"; do
            a=${rd[$i]}/shots/$item.png
            [ -s "$a" ] || continue
            have+=("$i")
            printf 'shot\t%s\t%s\t%s\t%s\n' "$item" "$i" "$a" "$(magick identify -format '%wx%h' "$a" 2>/dev/null)" >> "$meta"
        done
        n=${#have[@]}
        for ((a = 0; a < n; a++)); do
            for ((b = a + 1; b < n; b++)); do
                i=${have[$a]}; j=${have[$b]}
                ra=$(_cal_value RMSE "${rd[$i]}/shots/$item.png" "${rd[$j]}/shots/$item.png") || ra=''
                ph=$(_cal_value PHASH "${rd[$i]}/shots/$item.png" "${rd[$j]}/shots/$item.png") || ph=''
                printf 'pair\t%s\t%s\t%s\t%s\t%s\n' "$item" "$i" "$j" "$ra" "$ph" >> "$meta"
            done
        done
    done
    for item in "${sigs[@]+"${sigs[@]}"}"; do
        for i in "${!rd[@]}"; do
            [ -f "${rd[$i]}/review/$item.events" ] && printf 'sig\t%s\t%s\t%s\n' "$item" "$i" "${rd[$i]}/review/$item.events" >> "$meta"
        done
    done
    python3 -I - "$meta" "$out" "$name" "$sdir" "$(_cal_screen)" "$CAL_MARGIN" "$CAL_FLOOR_RMSE" "$CAL_FLOOR_PHASH" \
        "$CAL_LIMIT_RMSE" "$CAL_LIMIT_PHASH" "$CAL_FREAK" <<'PY'
import datetime, difflib, json, math, os, subprocess, sys

meta, out, name, scen, screen = sys.argv[1:6]
margin = float(sys.argv[6])
floor = {"RMSE": float(sys.argv[7]), "PHASH": float(sys.argv[8])}
limit = {"RMSE": float(sys.argv[9]), "PHASH": float(sys.argv[10])}
freak_factor = float(sys.argv[11])

runs, builds, shots, manifest, pairs, sigs = {}, {}, {}, {}, {}, {}
with open(meta) as fh:
    for line in fh:
        c = line.rstrip("\n").split("\t")
        if c[0] == "run":
            runs[int(c[1])] = c[2]; builds[int(c[1])] = c[3]
        elif c[0] == "manifest":
            manifest[c[1]] = c[2]
        elif c[0] == "shot":
            shots.setdefault(c[1], {})[int(c[2])] = (c[3], c[4])
        elif c[0] == "pair":
            num = lambda v: float(v) if v != "" else None
            pairs.setdefault(c[1], {})[(int(c[2]), int(c[3]))] = {"RMSE": num(c[4]), "PHASH": num(c[5])}
        elif c[0] == "sig":
            sigs.setdefault(c[1], {})[int(c[2])] = c[3]

def up2(x):
    """x rounded up to 2 significant digits."""
    if x <= 0:
        return 0.0
    e = math.floor(math.log10(x)) - 1
    q = 10.0 ** e
    return round(math.ceil(x / q - 1e-9) * q, max(0, -e))

def fmt(v):
    return "-" if v is None else f"{v:.4g}"

def label(i):
    return f"run-{i + 1}"   # the i-th run given; calibrate's own runs live in run-<i+1>/

result = {"scenario": name, "scenario_dir": scen, "date": datetime.datetime.now().astimezone().isoformat(timespec="seconds"),
          "build_id": builds.get(0, ""), "runs": [runs[i] for i in sorted(runs)],
          "rule": {"margin": margin, "floor": floor, "hard_limit": limit, "freak_factor": freak_factor,
                   "tolerance": "max(floor, max pairwise spread of the non-freak candidates x margin, rounded up to 2 significant digits)"},
          "shots": {}, "signatures": {}}
if len(set(builds.values())) > 1:
    result["build_ids"] = [builds[i] for i in sorted(builds)]

for shot, cands in shots.items():
    idx = sorted(cands)
    sizes = sorted({cands[i][1] for i in idx})
    if shot in manifest and manifest[shot] in floor:
        metric, source = manifest[shot], "manifest"
    elif sizes and sizes[0] == screen:
        metric, source = "PHASH", "full frame"
    else:
        metric, source = "RMSE", "crop"
    pm = pairs.get(shot, {})
    entry = {"metric": metric, "metric_source": source, "size": sizes[0] if len(sizes) == 1 else sizes,
             "candidates": [{"run": label(i), "path": cands[i][0]} for i in idx],
             "pairs": [{"a": label(a), "b": label(b), "RMSE": v["RMSE"], "PHASH": v["PHASH"]} for (a, b), v in sorted(pm.items())],
             "spread": {}, "freaks": [], "proposed_tolerance": None, "hard_limit": limit[metric],
             "recommended": None, "recommended_path": None, "contact_sheet": None, "status": "ok", "reason": ""}
    def d(a, b, m=metric):
        return pm.get((min(a, b), max(a, b)), {}).get(m)
    if len(idx) < 2:
        entry["status"], entry["reason"] = "not-blessable", f"{len(idx)} candidate(s); calibration needs 2 or more"
    elif len(sizes) > 1 or any(v["RMSE"] is None or v["PHASH"] is None for v in pm.values()):
        entry["status"], entry["reason"] = "not-blessable", "the candidates differ in size or could not be compared: " + " ".join(sizes)
    else:
        active = list(idx)
        if len(idx) >= 3:
            freaks = []
            for i in idx:
                others = [j for j in idx if j != i]
                dmin = min(d(i, j) for j in others)
                omax = max([d(a, b) for a in others for b in others if a < b] or [0.0])
                if dmin > floor[metric] and dmin > freak_factor * omax:
                    freaks.append(i)
            if len(idx) - len(freaks) >= 2:
                active = [i for i in idx if i not in freaks]
                entry["freaks"] = [label(i) for i in freaks]
        for m in ("RMSE", "PHASH"):
            entry["spread"][m] = max(d(a, b, m) for a in active for b in active if a < b)
        spread = entry["spread"][metric]
        tol = max(floor[metric], up2(spread * margin))
        entry["proposed_tolerance"] = tol
        med = min(active, key=lambda i: (sum(d(i, j) for j in active if j != i), i))
        entry["recommended"], entry["recommended_path"] = label(med), cands[med][0]
        if tol > limit[metric]:
            entry["status"] = "not-blessable"
            entry["reason"] = (f"{metric} spread {spread:.4g} x {margin} exceeds the hard limit {limit[metric]:g}: the frame is not "
                               "static; crop it to the element it asserts, or gate it as a pair")
        # Contact sheet: the candidates (medoid marked), then the difference image of the farthest pair.
        fa, fb = max(((a, b) for a in idx for b in idx if a < b), key=lambda p: d(*p))
        diff = os.path.join(out, f"{shot}.farthest-diff.png")
        subprocess.run(["magick", "compare", "-metric", "RMSE", cands[fa][0], cands[fb][0], diff],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        sheet = os.path.join(out, f"{shot}.contact.png")
        tiles = [(cands[i][0], label(i) + (" medoid" if i == med else "") + (" FREAK" if label(i) in entry["freaks"] else "")) for i in idx]
        if os.path.exists(diff):
            tiles.append((diff, f"diff {label(fa)} vs {label(fb)}"))
        common = ["-tile", f"{len(tiles)}x1", "-geometry", "+4+4", "-background", "#202020"]
        args = ["magick", "montage", "-fill", "white", "-pointsize", "12"]
        for p, lab in tiles:
            args += ["-label", lab, p]
        ok = subprocess.run(args + common + [sheet], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0
        if not ok:   # no font for the labels: the same sheet unlabelled, in the order of contact_order
            ok = subprocess.run(["magick", "montage"] + [p for p, _ in tiles] + common + [sheet],
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0
        if ok:
            entry["contact_sheet"] = sheet
            entry["contact_order"] = [lab for _, lab in tiles]
    result["shots"][shot] = entry

for sig, cands in sigs.items():
    idx = sorted(cands)
    texts = {i: open(cands[i], errors="replace").read().splitlines() for i in idx}
    entry = {"candidates": [{"run": label(i), "path": cands[i]} for i in idx], "events": None,
             "recommended": None, "recommended_path": None, "status": "ok", "reason": "", "varying_lines": [], "diff": None}
    if len(idx) < 2:
        entry["status"], entry["reason"] = "not-blessable", f"{len(idx)} candidate(s); calibration needs 2 or more"
    else:
        first = texts[idx[0]]
        differ = [i for i in idx[1:] if texts[i] != first]
        entry["events"] = len(first)
        if not differ:
            entry["recommended"], entry["recommended_path"] = label(idx[0]), cands[idx[0]]
        else:
            common = set(first).intersection(*(set(texts[i]) for i in idx[1:]))
            vary = sorted({l for i in idx for l in texts[i] if l not in common})
            entry["varying_lines"] = vary
            path = os.path.join(out, f"{sig}.sigdiff")
            with open(path, "w") as fh:
                for i in differ:
                    fh.writelines(l + "\n" for l in difflib.unified_diff(first, texts[i], label(idx[0]), label(i), lineterm=""))
            entry["diff"] = path
            entry["status"] = "not-blessable"
            entry["reason"] = ("the runs disagree on " + (f"{len(vary)} line(s)" if vary else "the order of events") +
                               ": narrow LOG_MARKERS to events that fire every run, or mask the varying token in lib/logcheck.sh _log_normalize")
    result["signatures"][sig] = entry

jpath = os.path.join(out, "calibration.json")
with open(jpath, "w") as fh:
    json.dump(result, fh, indent=1)
    fh.write("\n")

print(f"calibration of {name}: {len(runs)} run(s), build {result['build_id'] or '?'}")
if "build_ids" in result:
    print("  WARNING: the runs came from different builds: " + " ".join(result["build_ids"]))
if not result["shots"] and not result["signatures"]:
    print("  nothing to calibrate: the scenario has no shot (other than pair inputs) and no signature")
if result["shots"]:
    print(f"  {'SHOT':<28} {'METRIC':<6} {'N':>2} {'RMSE-MAX':>9} {'PHASH-MAX':>9} {'FREAKS':<12} {'TOL':>7} {'MEDOID':<8} STATUS")
    for shot, e in result["shots"].items():
        print(f"  {shot:<28} {e['metric']:<6} {len(e['candidates']):>2} {fmt(e['spread'].get('RMSE')):>9} {fmt(e['spread'].get('PHASH')):>9} "
              f"{(','.join(e['freaks']) or '-'):<12} {fmt(e['proposed_tolerance']):>7} {(e['recommended'] or '-'):<8} {e['status']}")
        if e["reason"]:
            print(f"  {'':<28} {e['reason']}")
        if e["contact_sheet"]:
            print(f"  {'':<28} contact sheet: {e['contact_sheet']}")
if result["signatures"]:
    print(f"  {'SIGNATURE':<28} {'N':>2} {'EVENTS':>6} STATUS")
    for sig, e in result["signatures"].items():
        print(f"  {sig:<28} {len(e['candidates']):>2} {('-' if e['events'] is None else e['events']):>6} {e['status']}")
        if e["reason"]:
            print(f"  {'':<28} {e['reason']}" + (f" (diff {e['diff']})" if e["diff"] else ""))
        for l in e["varying_lines"][:5]:
            print(f"  {'':<28}   varies: {l[:100]}")
print(f"  calibration.json: {jpath}")
ok = [k for k, e in list(result["shots"].items()) + list(result["signatures"].items()) if e["status"] == "ok"]
bad = [k for k, e in list(result["shots"].items()) + list(result["signatures"].items()) if e["status"] != "ok"]
if ok:
    names = "" if not bad else " " + " ".join(ok)
    print("next (a human decision; open the contact sheets first):")
    print(f"  bin/rig bless {jpath} {scen}{names} --note \"<why this frame is right>\"")
sys.exit(1 if bad else 0)
PY
    local rc=$?
    rm -f "$meta"
    return "$rc"
}

# ================================================================================================
# bin/rig bless
# ================================================================================================
# _bless_manifest_put <manifest> <header> <row> — replace the row whose first column is the row's,
# or append it; creates the file with <header>.
_bless_manifest_put() {
    local f=$1 header=$2 row=$3 key tmp
    key=${row%%$'\t'*}
    [ -f "$f" ] || printf '%s\n' "$header" > "$f"
    tmp=$(mktemp) || return 1
    awk -F'\t' -v k="$key" '$1 != k' "$f" > "$tmp" && printf '%s\n' "$row" >> "$tmp" && cat "$tmp" > "$f"
    local rc=$?; rm -f "$tmp"; return "$rc"
}
rig_bless() {
    local src='' sdir='' tol='' metric='' note='' replace=0 name kind item path m t bid status reason
    local -a want=() plan=() written=()
    local US=$'\x1f'
    while [ $# -gt 0 ]; do
        case $1 in
            --tolerance) [[ ${2:-} =~ ^[0-9]+(\.[0-9]+)?([eE][-+]?[0-9]+)?$ ]] || { _cli_usage_err bless "--tolerance needs a number"; return 64; }; tol=$2; shift ;;
            --metric)    case ${2:-} in RMSE|PHASH) metric=$2 ;; *) _cli_usage_err bless "--metric is RMSE or PHASH"; return 64 ;; esac; shift ;;
            --note)      [ -n "${2:-}" ] || { _cli_usage_err bless "--note needs a text"; return 64; }; note=$2; shift ;;
            --replace)   replace=1 ;;
            -h|--help)   _bless_usage; return 0 ;;
            -*)          _cli_usage_err bless "unknown flag $1"; return 64 ;;
            *)           if [ -z "$src" ]; then src=$1; elif [ -z "$sdir" ]; then sdir=$1; else want+=("$1"); fi ;;
        esac
        shift
    done
    [ -n "$src" ] && [ -n "$sdir" ] || { _cli_usage_err bless "expected <calibration.json|run dir> <scenario dir> [name...]"; return 64; }
    [ -e "$src" ] || { _cli_usage_err bless "no such file or directory: $src"; return 64; }
    [ -f "$sdir/scenario.conf" ] || { _cli_usage_err bless "no scenario.conf in $sdir"; return 64; }
    [[ $note != *$'\t'* ]] || { _cli_usage_err bless "--note cannot hold a tab"; return 64; }
    sdir=$(cd "$sdir" && pwd); name=$(_sc_scenario_name "$sdir")
    [ -d "$src" ] && [ -f "$src/calibration.json" ] && src=$src/calibration.json

    # The plan, one line per candidate set, fields split by US (\x1f: a tab is IFS whitespace, so read
    # would merge empty fields): kind name candidate metric tolerance build status reason
    if [ -f "$src" ]; then
        command -v python3 >/dev/null 2>&1 || { echo "rig bless: needs python3" >&2; return 1; }
        mapfile -t plan < <(python3 -I - "$src" "$name" <<'PY'
import json, sys
try:
    c = json.load(open(sys.argv[1]))
except Exception as e:
    print(f"ERR\x1fnot a calibration.json: {e}"); sys.exit(0)
if c.get("scenario") != sys.argv[2]:
    print(f"ERR\x1f{sys.argv[1]} calibrated scenario {c.get('scenario')!r}, not {sys.argv[2]!r}"); sys.exit(0)
b = c.get("build_id") or "?"
for n, e in c.get("shots", {}).items():
    print("\x1f".join(["shot", n, e.get("recommended_path") or "", e.get("metric") or "", "" if e.get("proposed_tolerance") is None else f"{e['proposed_tolerance']:g}", b, e.get("status", ""), e.get("reason", "")]))
for n, e in c.get("signatures", {}).items():
    print("\x1f".join(["signature", n, e.get("recommended_path") or "", "", "", b, e.get("status", ""), e.get("reason", "")]))
PY
)
        if [[ ${plan[0]-} == ERR"$US"* ]]; then echo "rig bless: ${plan[0]#ERR"$US"}" >&2; return 1; fi
    else
        local r
        r=$(_cal_scenario_run "$src" "$name") || { echo "rig bless: no run of $name in $src (no steps.tsv)" >&2; return 1; }
        [ "$(basename "$r")" = "$name" ] || [ -f "$src/steps.tsv" ] || { echo "rig bless: $r is not a run of $name" >&2; return 1; }
        bid=$(_cal_build_id "$r"); bid=${bid:-?}
        while IFS=$'\t' read -r kind item; do
            case $kind in
                shot)      plan+=("shot$US$item$US$r/shots/$item.png$US$US$US$bid${US}ok$US") ;;
                signature) plan+=("signature$US$item$US$r/review/$item.events$US$US$US$bid${US}ok$US") ;;
            esac
        done < <(_cal_items "$r" "$name")
    fi

    # Select: the named items, else every blessable one.
    local -a sel=()
    local line found w nshots=0
    for w in "${want[@]+"${want[@]}"}"; do
        found=0
        for line in "${plan[@]+"${plan[@]}"}"; do IFS=$US read -r _ item _ <<<"$line"; [ "$item" = "$w" ] && found=1; done
        [ "$found" = 1 ] || { echo "rig bless: no candidate named '$w' in $src" >&2; return 1; }
    done
    for line in "${plan[@]+"${plan[@]}"}"; do
        IFS=$US read -r kind item path m t bid status reason <<<"$line"
        if [ "${#want[@]}" -gt 0 ]; then [[ " ${want[*]} " == *" $item "* ]] || continue
        elif [ "$status" != ok ]; then echo "rig bless: skipping $kind $item: $status ($reason)"; continue; fi
        if [ "$status" != ok ]; then echo "rig bless: REFUSED $kind $item: $status: $reason" >&2; return 1; fi
        [ -s "$path" ] || { echo "rig bless: REFUSED $kind $item: candidate missing ($path)" >&2; return 1; }
        sel+=("$line"); [ "$kind" = shot ] && nshots=$((nshots + 1))
    done
    [ "${#sel[@]}" -gt 0 ] || { echo "rig bless: nothing to bless in $src" >&2; return 1; }
    if { [ -n "$tol" ] || [ -n "$metric" ]; } && [ "$nshots" != 1 ]; then
        echo "rig bless: --tolerance/--metric apply to one shot; $nshots selected (name the shot)" >&2; return 1
    fi

    # Resolve every shot's metric and tolerance, and refuse before copying anything.
    local -a final=()
    local ref old exists=0 size
    for line in "${sel[@]}"; do
        IFS=$US read -r kind item path m t bid status reason <<<"$line"
        if [ "$kind" = shot ]; then
            ref=$sdir/reference-images/$item.png
            old=$(awk -F'\t' -v n="$item" '$1==n {print $2 "\t" $3; exit}' "$sdir/reference-images/manifest.tsv" 2>/dev/null)
            [ -n "$metric" ] && m=$metric
            [ -n "$tol" ] && t=$tol
            [ -n "$m" ] || m=$(cut -f1 <<<"$old")
            [ -n "$t" ] || { [ "$m" = "$(cut -f1 <<<"$old")" ] && t=$(cut -f2 <<<"$old"); }
            if [ -z "$m" ]; then
                size=$(magick identify -format '%wx%h' "$path" 2>/dev/null)
                if [ "$size" = "$(_cal_screen)" ]; then m=PHASH; else m=RMSE; fi
            fi
            [ -n "$t" ] || { echo "rig bless: REFUSED shot $item: no tolerance (measure one: bin/rig calibrate $sdir; or give --tolerance)" >&2; return 1; }
        else
            ref=$sdir/reference-logs/$item.events
        fi
        if [ -e "$ref" ]; then
            if [ "$replace" = 0 ]; then echo "rig bless: REFUSED $kind $item: a reference exists ($ref); re-blessing needs --replace" >&2; exists=1; fi
        fi
        final+=("$kind$US$item$US$path$US$m$US$t$US$bid$US$ref")
    done
    [ "$exists" = 0 ] || { echo "rig bless: nothing copied" >&2; return 1; }
    if [ "$replace" = 1 ]; then
        echo "rig bless: --replace: re-blessing is never a response to a failing test; only a verified, intended behaviour change."
    fi

    local day desc oldesc
    day=$(date +%F)
    for line in "${final[@]}"; do
        IFS=$US read -r kind item path m t bid ref <<<"$line"
        mkdir -p "$(dirname "$ref")" && cp "$path" "$ref" || { echo "rig bless: copy failed: $path -> $ref" >&2; return 1; }
        written+=("$ref")
        if [ "$kind" = shot ]; then
            oldesc=$(awk -F'\t' -v n="$item" '$1==n { s = $5; for (i = 6; i <= NF; i++) s = s " " $i; print s; exit }' "$sdir/reference-images/manifest.tsv" 2>/dev/null)
            oldesc=$(sed -E 's/ *\[blessed [^]]*\]$//' <<<"$oldesc")
            desc=${note:-${oldesc:--}}
            _bless_manifest_put "$sdir/reference-images/manifest.tsv" $'# name\tmetric\tthreshold\tfuzz\tdescription' \
                "$item"$'\t'"$m"$'\t'"$t"$'\t-\t'"$desc [blessed $day build $bid]" || { echo "rig bless: manifest write failed" >&2; return 1; }
            echo "BLESSED shot $item: $path -> $ref ($m <= $t)"
        else
            _bless_manifest_put "$sdir/reference-logs/manifest.tsv" $'# name\tblessed\tbuild\tnote' \
                "$item"$'\t'"$day"$'\t'"$bid"$'\t'"${note:--}" || { echo "rig bless: manifest write failed" >&2; return 1; }
            echo "BLESSED signature $item: $path -> $ref"
        fi
    done
    local mf
    for mf in "$sdir/reference-images/manifest.tsv" "$sdir/reference-logs/manifest.tsv"; do
        for line in "${final[@]}"; do
            IFS=$US read -r kind _ <<<"$line"
            if { [ "$kind" = shot ] && [[ $mf == */reference-images/* ]]; } || { [ "$kind" = signature ] && [[ $mf == */reference-logs/* ]]; }; then
                written+=("$mf"); break
            fi
        done
    done
    echo "next: review, then commit the references with the change that needs them:"
    echo "  git -C $sdir add ${written[*]#"$sdir/"}"
    return 0
}

# ================================================================================================
# selftest — synthetic PNGs and logs; no game binary, no display
# ================================================================================================
calibrate_selftest() {
    command -v magick >/dev/null 2>&1 || { echo "ImageMagick 7 (magick) not found"; return 2; }
    local t fails=0 out rc i j
    t=$(mktemp -d)
    _ok()  { echo "  ok   $1"; }
    _bad() { echo "  FAIL $1 :: $2"; fails=$((fails+1)); }
    _has() { if grep -qE -- "$3" <<<"$2"; then _ok "$1"; else _bad "$1" "$(head -c 900 <<<"$2")"; fi; }
    _jq()  { python3 -I -c "import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if ($2) else 1)" "$1"; }
    _jok() { if _jq "$2" "$3"; then _ok "$1"; else _bad "$1" "$3 on $(head -c 900 "$2")"; fi; }
    local RIG_SCREEN=96x64x24
    # Scenario: NAME calsynth; signature default name = NAME.
    local sc=$t/scen
    mkdir -p "$sc"; printf 'NAME=calsynth\nPLAYERS="a"\nCONTENT=x\n' > "$sc/scenario.conf"
    # Images. gui (crop 200x120): A, B = A + a dot, C = A + two dots -> B is the medoid.
    magick -seed 3 -size 200x120 plasma:fractal "$t/gA.png"
    magick "$t/gA.png" -fill black -draw 'point 1,1' "$t/gB.png"
    magick "$t/gB.png" -fill black -draw 'point 150,90' "$t/gC.png"
    # freak (crop): two equal frames and one wildly off.
    magick -seed 5 -size 200x120 plasma:fractal "$t/fA.png"
    magick "$t/fA.png" -fill white -draw 'rectangle 20,20 180,100' "$t/fX.png"
    # full frame (96x64 = RIG_SCREEN): identical in all runs -> PHASH, floor 8.
    magick -seed 9 -size 96x64 plasma:fractal "$t/full.png"
    # unstable (crop): three unrelated frames; mismatch: one candidate of another size.
    for i in 1 2 3; do magick -seed "$((20 + i))" -size 200x120 plasma:fractal "$t/u$i.png"; done
    magick -seed 30 -size 200x120 plasma:fractal "$t/m1.png"; magick "$t/m1.png" -resize 150x90! "$t/m2.png"
    # Pair inputs: never candidates.
    magick -size 200x120 xc:gray "$t/p.png"

    # Three synthetic runs (run sets holding calsynth/).
    local steps_ok steps_bad
    steps_ok=$'step\tline\tverb\tstatus\tt\toffsets\tdetail\n1\tsteps.sh:1\tshot a gui 200x120+0+0\tOK\t1\t\tc\n2\tsteps.sh:2\tshot a freak 200x120+0+0\tOK\t1\t\tc\n3\tsteps.sh:3\tshot a full\tOK\t1\t\tc\n4\tsteps.sh:4\tshot a p0\tOK\t1\t\tc\n5\tsteps.sh:5\tshot a p1\tOK\t1\t\tc\n6\tsteps.sh:6\tpair motion p0 p1\tPASS\t1\t\tc\n7\tsteps.sh:7\tsignature\tOK\t1\t\tc'
    steps_bad=$'step\tline\tverb\tstatus\tt\toffsets\tdetail\n1\tsteps.sh:1\tshot a unstable\tOK\t1\t\tc\n2\tsteps.sh:2\tshot a mismatch\tOK\t1\t\tc\n3\tsteps.sh:3\tsignature other\tOK\t1\t\tc'
    for i in 1 2 3; do
        local r=$t/ok/run-$i/calsynth b=$t/bad/run-$i/calsynth
        mkdir -p "$r/shots" "$r/review" "$b/shots" "$b/review"
        printf '%s\n' "$steps_ok" > "$r/steps.tsv"; printf '%s\n' "$steps_bad" > "$b/steps.tsv"
        printf 'build_id=sha256:feed\n' > "$r/env.txt"; printf 'build_id=sha256:feed\n' > "$b/env.txt"
        cp "$t/g$(printf 'ABC' | cut -c"$i").png" "$r/shots/gui.png"
        if [ "$i" = 3 ]; then cp "$t/fX.png" "$r/shots/freak.png"; else cp "$t/fA.png" "$r/shots/freak.png"; fi
        cp "$t/full.png" "$r/shots/full.png"; cp "$t/p.png" "$r/shots/p0.png"; cp "$t/p.png" "$r/shots/p1.png"
        printf 'Adding cell x to Player a\nLoading done\n' > "$r/review/calsynth.events"
        cp "$t/u$i.png" "$b/shots/unstable.png"
        if [ "$i" = 3 ]; then cp "$t/m2.png" "$b/shots/mismatch.png"; else cp "$t/m1.png" "$b/shots/mismatch.png"; fi
        printf 'Adding cell x to Player a\nweather %s\n' "$i" > "$b/review/other.events"
    done

    # -- 1. a consistent candidate set --
    out=$(rig_calibrate "$sc" --out "$t/cal-ok" --from "$t/ok/run-1" --from "$t/ok/run-2" --from "$t/ok/run-3" 2>&1); rc=$?
    local js=$t/cal-ok/calibration.json
    [ "$rc" = 0 ] && _ok "calibrate: consistent set -> exit 0" || _bad "calibrate: consistent set -> exit 0" "rc=$rc $out"
    _jok "calibrate: pair inputs left out" "$js" 'set(d["shots"]) == {"gui", "freak", "full"}'
    _jok "calibrate: a crop gets RMSE, a full frame PHASH" "$js" 'd["shots"]["gui"]["metric"] == "RMSE" and d["shots"]["full"]["metric"] == "PHASH"'
    _jok "calibrate: medoid is the middle candidate" "$js" 'd["shots"]["gui"]["recommended"] == "run-2" and d["shots"]["gui"]["recommended_path"].endswith("run-2/calsynth/shots/gui.png")'
    _jok "calibrate: tolerance floored (RMSE 0.01, PHASH 8)" "$js" 'd["shots"]["gui"]["proposed_tolerance"] == 0.01 and d["shots"]["full"]["proposed_tolerance"] == 8'
    _jok "calibrate: freak flagged and left out of the spread" "$js" 'd["shots"]["freak"]["freaks"] == ["run-3"] and d["shots"]["freak"]["spread"]["RMSE"] == 0 and d["shots"]["freak"]["status"] == "ok"'
    _jok "calibrate: identical signatures -> ok" "$js" 'd["signatures"]["calsynth"]["status"] == "ok" and d["signatures"]["calsynth"]["events"] == 2'
    _jok "calibrate: build id and runs recorded" "$js" 'd["build_id"] == "sha256:feed" and len(d["runs"]) == 3'
    [ -s "$t/cal-ok/gui.contact.png" ] && _ok "calibrate: contact sheet written" || _bad "calibrate: contact sheet written" "$(ls "$t/cal-ok")"
    _has "calibrate: table and bless command printed" "$out" "bin/rig bless $js $sc --note"
    _has "calibrate: table row" "$out" 'gui +RMSE +3 .* 0\.01 +run-2 +ok'
    # -- 2. the margin rule above the floor --
    out=$(python3 -I - <<'PY'
import math
def up2(x):
    e = math.floor(math.log10(x)) - 1; q = 10.0 ** e
    return round(math.ceil(x / q - 1e-9) * q, max(0, -e))
print(up2(0.0123 * 1.5), up2(7.0 * 1.5), up2(0.02 * 1.5))
PY
)
    [ "$out" = "0.019 11.0 0.03" ] && _ok "calibrate: spread x 1.5 rounded up to 2 digits" || _bad "calibrate: spread x 1.5 rounded up to 2 digits" "$out"
    # -- 3. a set that is not blessable --
    out=$(rig_calibrate "$sc" --out "$t/cal-bad" --from "$t/bad/run-1" --from "$t/bad/run-2" --from "$t/bad/run-3" 2>&1); rc=$?
    local jb=$t/cal-bad/calibration.json
    [ "$rc" = 1 ] && _ok "calibrate: unstable set -> exit 1" || _bad "calibrate: unstable set -> exit 1" "rc=$rc $out"
    _jok "calibrate: spread over the hard limit -> not-blessable" "$jb" 'd["shots"]["unstable"]["status"] == "not-blessable" and "hard limit" in d["shots"]["unstable"]["reason"]'
    _jok "calibrate: sizes differ -> not-blessable" "$jb" 'd["shots"]["mismatch"]["status"] == "not-blessable" and "size" in d["shots"]["mismatch"]["reason"]'
    _jok "calibrate: differing signatures -> varying lines" "$jb" 'd["signatures"]["other"]["status"] == "not-blessable" and d["signatures"]["other"]["varying_lines"] == ["weather 1", "weather 2", "weather 3"]'
    [ -s "$t/cal-bad/other.sigdiff" ] && _ok "calibrate: signature diff written" || _bad "calibrate: signature diff written" "$(ls "$t/cal-bad")"
    # -- 4. usage --
    rig_calibrate "$sc" --runs 1 >/dev/null 2>&1; rc=$?
    [ "$rc" = 64 ] && _ok "calibrate: --runs 1 -> 64" || _bad "calibrate: --runs 1 -> 64" "rc=$rc"
    rig_calibrate "$sc" --out "$t/cal-ok" --from "$t/ok/run-1" >/dev/null 2>&1; rc=$?
    [ "$rc" = 64 ] && _ok "calibrate: non-empty --out -> 64" || _bad "calibrate: non-empty --out -> 64" "rc=$rc"

    # -- 5. bless from the calibration --
    out=$(rig_bless "$js" "$sc" --note "synthetic" 2>&1); rc=$?
    [ "$rc" = 0 ] && _ok "bless: exit 0" || _bad "bless: exit 0" "rc=$rc $out"
    cmp -s "$sc/reference-images/gui.png" "$t/gB.png" && _ok "bless: the medoid is copied" || _bad "bless: the medoid is copied" "$out"
    cmp -s "$sc/reference-logs/calsynth.events" "$t/ok/run-1/calsynth/review/calsynth.events" && _ok "bless: the signature is copied" || _bad "bless: the signature is copied" "$out"
    _has "bless: manifest row with tolerance, build and note" "$(cat "$sc/reference-images/manifest.tsv" 2>/dev/null)" $'^gui\tRMSE\t0\\.01\t-\tsynthetic \\[blessed [0-9-]+ build sha256:feed\\]$'
    _has "bless: full frame row" "$(cat "$sc/reference-images/manifest.tsv" 2>/dev/null)" $'^full\tPHASH\t8\t-\t'
    _has "bless: signature manifest row" "$(cat "$sc/reference-logs/manifest.tsv" 2>/dev/null)" $'^calsynth\t[0-9-]+\tsha256:feed\tsynthetic$'
    _has "bless: git add hint" "$out" "git -C $sc add .*reference-images/gui.png"
    # The comparer reads the blessed row: the medoid passes against itself, the freak does not.
    compare_set_refs "$sc/reference-images" "" "$t/review"
    if compare_shot gui "$t/gC.png" >/dev/null 2>&1; then _ok "bless: compare_shot reads the blessed tolerance"; else _bad "bless: compare_shot reads the blessed tolerance" "$(compare_shot gui "$t/gC.png" 2>&1)"; fi
    # -- 6. refuse to overwrite --
    cp "$sc/reference-images/gui.png" "$t/before.png"
    out=$(rig_bless "$t/cal-ok" "$sc" gui 2>&1); rc=$?
    [ "$rc" = 1 ] && _ok "bless: an existing reference refuses (exit 1)" || _bad "bless: an existing reference refuses (exit 1)" "rc=$rc $out"
    _has "bless: refusal names --replace" "$out" 'REFUSED shot gui: a reference exists .*--replace'
    out=$(rig_bless "$t/cal-ok" "$sc" gui --replace --tolerance 0.02 --note again 2>&1); rc=$?
    [ "$rc" = 0 ] && _ok "bless: --replace overwrites" || _bad "bless: --replace overwrites" "rc=$rc $out"
    _has "bless: --replace prints the rule" "$out" 're-blessing is never a response to a failing test; only a verified, intended behaviour change'
    _has "bless: --tolerance overrides, one row per name" "$(grep -c $'^gui\t' "$sc/reference-images/manifest.tsv")$(grep $'^gui\t' "$sc/reference-images/manifest.tsv")" $'^1gui\tRMSE\t0\\.02\t-\tagain'
    # -- 7. other refusals --
    out=$(rig_bless "$jb" "$sc" unstable 2>&1); rc=$?
    [ "$rc" = 1 ] && _ok "bless: a not-blessable set refuses" || _bad "bless: a not-blessable set refuses" "rc=$rc $out"
    out=$(rig_bless "$jb" "$sc" 2>&1); rc=$?
    [ "$rc" = 1 ] && _ok "bless: nothing blessable -> exit 1" || _bad "bless: nothing blessable -> exit 1" "rc=$rc $out"
    out=$(rig_bless "$js" "$sc" gui full --tolerance 0.02 --replace 2>&1); rc=$?
    [ "$rc" = 1 ] && _ok "bless: --tolerance with two shots refuses" || _bad "bless: --tolerance with two shots refuses" "rc=$rc $out"
    local sc2=$t/scen2; mkdir -p "$sc2"; printf 'NAME=othername\nPLAYERS="a"\nCONTENT=x\n' > "$sc2/scenario.conf"
    out=$(rig_bless "$js" "$sc2" 2>&1); rc=$?
    [ "$rc" = 1 ] && _ok "bless: another scenario's calibration refuses" || _bad "bless: another scenario's calibration refuses" "rc=$rc $out"
    # -- 8. bless from a run dir --
    local sc3=$t/scen3; mkdir -p "$sc3"; cp "$sc/scenario.conf" "$sc3/"
    out=$(rig_bless "$t/ok/run-2" "$sc3" gui 2>&1); rc=$?
    [ "$rc" = 1 ] && _ok "bless: run dir without a tolerance refuses" || _bad "bless: run dir without a tolerance refuses" "rc=$rc $out"
    [ ! -e "$sc3/reference-images/gui.png" ] && _ok "bless: a refusal copies nothing" || _bad "bless: a refusal copies nothing" "$(ls -R "$sc3")"
    out=$(rig_bless "$t/ok/run-2" "$sc3" gui --tolerance 0.015 2>&1); rc=$?
    [ "$rc" = 0 ] && cmp -s "$sc3/reference-images/gui.png" "$t/gB.png" && _ok "bless: run dir with --tolerance" || _bad "bless: run dir with --tolerance" "rc=$rc $out"
    out=$(rig_bless "$t/ok/run-2" "$sc3" p0 --tolerance 0.015 2>&1); rc=$?
    [ "$rc" = 1 ] && _ok "bless: a pair input is not a candidate" || _bad "bless: a pair input is not a candidate" "rc=$rc $out"
    rig_bless "$js" >/dev/null 2>&1; rc=$?
    [ "$rc" = 64 ] && _ok "bless: usage error -> 64" || _bad "bless: usage error -> 64" "rc=$rc"

    rm -rf "$t"
    echo "selftest done (fails=$fails)"
    return "$fails"
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    _cli_usage_err() { echo "rig $1: $2" >&2; return 64; }
    case "${1:-}" in
        selftest) calibrate_selftest; exit $? ;;
        *) echo "usage: lib/calibrate.sh selftest   (calibration and blessing go through bin/rig calibrate / bless)" >&2; exit 64 ;;
    esac
fi
