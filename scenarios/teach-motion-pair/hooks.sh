# shellcheck shell=bash disable=SC2148
# hooks.sh — custom verbs for this scenario (docs/SCENARIO-FORMAT.md §3.8). A function verb_<name>
# becomes the verb <name>; return 0 records OK, anything else FAIL. Unlike steps.sh, a hook may run
# external commands. RIG_RUN_DIR is this attempt's run directory.

# still <A> <B> <ceiling> — the inverse of `pair`: shots A and B must NOT differ (RMSE <= ceiling).
# A control: it shows the frames are quiet when nothing happens, so a `pair` that passes measured
# the event, not idle noise.
verb_still() {
    local a="$RIG_RUN_DIR/shots/$1.png" b="$RIG_RUN_DIR/shots/$2.png" ceiling=$3 v
    [ -f "$a" ] && [ -f "$b" ] || { echo "still: take the shots $1 and $2 first"; return 2; }
    v=$(magick compare -metric RMSE "$a" "$b" null: 2>&1 | grep -oE '\([0-9.eE+-]+\)' | head -1 | tr -d '()')
    echo "still $1 vs $2: RMSE=${v:-?} (ceiling $ceiling)"
    awk -v v="$v" -v c="$ceiling" 'BEGIN { exit !(v != "" && v + 0 <= c + 0) }'
}
