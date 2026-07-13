#!/usr/bin/env bash
# lib-compare.sh — screenshot regression comparison for the MP scenario gate (TESTING.md Layer 2).
#
# WHY this shape: in-world captures are never byte-identical run to run (animation pose, water/
# particle motion, sub-pixel camera jitter, capture timing). So we DON'T do exact-pixel diffs — we
# compare each capture to a known-good reference with `magick compare -metric` and a *tolerance*.
# This library is POLICY-NEUTRAL: `compare_shot` returns 0 (within tolerance) / 1 (over) / 2 (error);
# the CALLER decides severity. The scenario gate treats "over tolerance" as a CI-red REGRESSION —
# fix the bug, or deliberately re-bless the new capture (see `promote_shot` / scenario.sh --update-refs)
# if the change is intended (graphics or actor-AI behaviour do change upstream sometimes).
#
# Tolerance is PER IMAGE, read from reference-images/manifest.tsv, because a crisp menu wants a tight
# check while a windy exterior wants a loose one. One metric never fits both — the manifest owns the
# metric+threshold choice; this file just executes it.
#
# Use as a library:   source lib-compare.sh ;  compare_shot <name> <candidate.png>
# Use as a CLI:       lib-compare.sh compare <name> <candidate.png>
#                     lib-compare.sh promote <name> <candidate.png>
#                     lib-compare.sh selftest          # proves the compare/tolerance/diff logic
set -uo pipefail

_LC_DIR=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)
REF_DIR=${RIG_REF_DIR:-$_LC_DIR/reference-images}
MANIFEST=${RIG_REF_MANIFEST:-$REF_DIR/manifest.tsv}
REVIEW_DIR=${RIG_REVIEW_DIR:-/tmp/mp-rig-shot-review}

# Default metric+threshold for any capture NOT listed in the manifest (so an unknown new capture is
# still reviewable rather than crashing). RMSE normalized, fairly loose — tune per-image in manifest.
DEFAULT_METRIC=${RIG_DEFAULT_METRIC:-RMSE}
DEFAULT_THRESHOLD=${RIG_DEFAULT_THRESHOLD:-0.05}
DEFAULT_FUZZ=${RIG_DEFAULT_FUZZ:--}

_have_magick() { command -v magick >/dev/null 2>&1; }

# Look up a capture's metric/threshold/fuzz from the manifest. Echoes "METRIC<TAB>THRESHOLD<TAB>FUZZ".
# Manifest columns (tab-separated): name  metric  threshold  fuzz  description   (# comments / blanks ignored)
manifest_lookup() {
    local name=$1 line
    if [ -f "$MANIFEST" ]; then
        line=$(awk -F'\t' -v n="$name" '$1==n {print; exit}' "$MANIFEST")
        if [ -n "$line" ]; then
            awk -F'\t' '{printf "%s\t%s\t%s", $2, $3, ($4==""?"-":$4)}' <<<"$line"
            return 0
        fi
    fi
    printf '%s\t%s\t%s' "$DEFAULT_METRIC" "$DEFAULT_THRESHOLD" "$DEFAULT_FUZZ"
}

# Extract the comparable scalar from `magick compare -metric` output. IM prints either a bare number
# (AE pixel count, PHASH, DSSIM) or "absolute (normalized)" (RMSE/MAE/MSE/NCC) — we prefer the
# normalized value in parentheses when present, else the leading number. Portable (grep -oE; no
# gawk-only 3-arg match, which mawk/busybox reject).
_extract_value() {
    local s paren
    s=$(cat)
    paren=$(printf '%s\n' "$s" | grep -oE '\([0-9.eE+-]+\)' | head -1 | tr -d '()') || true
    if [ -n "$paren" ]; then printf '%s' "$paren"; return 0; fi
    printf '%s\n' "$s" | grep -oE '[0-9.eE+-]+' | head -1 || true
}

# compare_shot <name> <candidate.png>
#   0 = within tolerance (PASS).  1 = over tolerance / missing ref / size mismatch (caller's call —
#   the scenario gate treats it as a REGRESSION).  2 = hard error.
compare_shot() {
    local name=$1 cand=$2
    _have_magick || { echo "ERROR: ImageMagick 'magick' not found" >&2; return 2; }
    [ -f "$cand" ] || { echo "ERROR $name: candidate missing ($cand)" >&2; return 2; }

    local mt metric threshold fuzz
    mt=$(manifest_lookup "$name")
    metric=$(cut -f1 <<<"$mt"); threshold=$(cut -f2 <<<"$mt"); fuzz=$(cut -f3 <<<"$mt")

    local ref=$REF_DIR/$name.png
    mkdir -p "$REVIEW_DIR"
    if [ ! -f "$ref" ]; then
        cp "$cand" "$REVIEW_DIR/$name.new.png"
        echo "REVIEW $name: no reference yet — captured $REVIEW_DIR/$name.new.png (promote to bless it)"
        return 1
    fi

    local diff=$REVIEW_DIR/$name.diff.png raw value rc=0
    local -a fuzzarg=(); [ "$fuzz" != "-" ] && fuzzarg=(-fuzz "$fuzz")
    raw=$(magick compare -metric "$metric" "${fuzzarg[@]}" "$ref" "$cand" "$diff" 2>&1) || rc=$?
    if [ "$rc" -ge 2 ]; then
        # exit >=2 from compare == genuine error (commonly a dimension mismatch == geometry changed)
        echo "REVIEW $name: compare error (metric=$metric): $raw — diff $diff"
        return 1
    fi
    value=$(_extract_value <<<"$raw")
    [ -n "$value" ] || { echo "REVIEW $name: could not parse $metric value from '$raw'"; return 1; }

    if awk -v v="$value" -v t="$threshold" 'BEGIN{exit !(v+0 <= t+0)}'; then
        rm -f "$diff"
        echo "PASS   $name: $metric=$value (<= $threshold)"
        return 0
    fi
    echo "REGRESSION $name: $metric=$value (> $threshold) — diff $diff"
    return 1
}

# promote_shot <name> <candidate.png> — bless a capture as the new known-good reference. This is the
# human-approved end of the "flag for reference update" flow; never call it unattended.
promote_shot() {
    local name=$1 cand=$2
    [ -f "$cand" ] || { echo "ERROR: candidate missing ($cand)" >&2; return 2; }
    mkdir -p "$REF_DIR"
    cp "$cand" "$REF_DIR/$name.png"
    echo "PROMOTED $name -> $REF_DIR/$name.png  (record the OpenMW base/checkpoint in manifest + commit)"
}

# selftest — synthetic, deterministic; proves identical->PASS, small change within tol->PASS,
# big change over tol->REVIEW (+ a diff image is written). No game data or binaries needed.
selftest() {
    _have_magick || { echo "ImageMagick not found"; return 2; }
    local t fails=0
    t=$(mktemp -d)
    # Point the comparator's dirs at the temp sandbox (compare_shot reads these globals).
    REF_DIR=$t; MANIFEST=$t/manifest.tsv; REVIEW_DIR=$t/review
    magick -size 320x240 plasma:fractal "$t/scene.png"                                # the reference
    cp "$t/scene.png" "$t/identical.png"
    magick "$t/scene.png" -fill black -draw 'rectangle 0,0 3,3' "$t/tiny.png"          # ~16px: capture jitter
    magick "$t/scene.png" -fill white -draw 'rectangle 16,16 304,224' "$t/big.png"     # ~ UI vanished / garbled
    printf 'scene\tRMSE\t0.05\t-\tselftest synthetic scene\n' > "$t/manifest.tsv"

    _st() {  # $1 desc, $2 expected-rc, $3 candidate
        local desc=$1 want=$2 cand=$3 out rc=0
        out=$(compare_shot scene "$cand") || rc=$?
        if [ "$rc" = "$want" ]; then echo "  ok   [$desc] rc=$rc :: $out"
        else echo "  FAIL [$desc] rc=$rc want=$want :: $out"; fails=$((fails+1)); fi
    }
    _st "identical  -> PASS"    0 "$t/identical.png"
    _st "tiny change-> PASS"    0 "$t/tiny.png"
    _st "big change -> REVIEW"  1 "$t/big.png"
    if [ -f "$t/review/scene.diff.png" ]; then echo "  ok   [diff image written on REVIEW]"
    else echo "  FAIL [no diff image written]"; fails=$((fails+1)); fi

    echo "selftest done (fails=$fails)"
    rm -rf "$t"
    return "$fails"
}

# CLI dispatch only when executed directly (not when sourced).
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    case "${1:-}" in
        compare) shift; compare_shot "$@" ;;
        promote) shift; promote_shot "$@" ;;
        selftest) selftest ;;
        *) echo "usage: lib-compare.sh {compare <name> <png> | promote <name> <png> | selftest}" >&2; exit 2 ;;
    esac
fi
