#!/usr/bin/env bash
# rig.sh — the headless OpenMW-multiplayer (TES3MP-lineage) driving rig. Boots a real dedicated
# server + one-to-three real clients under Xvfb and drives them with xdotool. Source this; don't run
# it. Binary names and paths are configurable (see rig.conf.example / the Config block below), so it
# works against any TES3MP-lineage build — set RIG_CLIENT_BIN / RIG_SERVER_BIN / RIG_BUILD for yours.
#
# Everything in here was learned the painful way on a headless CI box; the comments are load-bearing:
#   * Xvfb + llvmpipe software GL — world load takes ~30s, DON'T tighten the sleeps.
#   * SDL_MOUSE_RELATIVE_MODE_WARP=1 — SDL relative mode ignores XTest motion; warp mode reads
#     absolute positions, so synthetic mouse-look (xdotool mousemove) actually turns the camera.
#   * LD_LIBRARY_PATH=$RIG_MYGUI_FIXED — Debian's MyGUI (built without CMAKE_BUILD_TYPE) renders
#     NOTHING: all UI invisible but still focusable. Headless tiers can't see it; only a human (or a
#     screenshot) catches it. Point RIG_MYGUI_FIXED at a Release MyGUI under the Debian filename; it is
#     never auto-detected.
#   * Isolated XDG profile — the shared ~/.config/openmw carries another engine version's
#     input_v3.xml/settings.cfg/shaders.yaml; sharing it breaks this build's bindings/shaders.
#   * Nothing outside the run is written: content goes into each client profile's openmw.cfg, the
#     server reads a run-scoped tes3mp-server.cfg (its XDG_CONFIG_HOME), and server state lives in a
#     throwaway CoreScripts work copy (rig_corescripts_overlay). $RIG_BUILD and $RIG_CORESCRIPTS are
#     only read.
#   * Use `pgrep -x` / `pkill -x`, never `-f`: `-f` self-matches the shell wrapper.
#   * A stale ${RIG_SERVER_BIN} holds the port and silently services the client with old config.
#   * A stale Xvfb on the display (carrying an Xauthority) makes the auth-less Xvfb lose the race
#     and xdotool gets "Authorization required" — kill it + rm the lock first.
#
# Per-display model: each client gets its OWN Xvfb display, because a shared
# Xvfb has no window manager (so `xdotool windowactivate` fails — there is no _NET_ACTIVE_WINDOW) and
# two 800x600 windows overlap (the occluded one captures as garbage, X11 has no backing store without a
# compositor). One window per display ⇒ input/capture target it by setting DISPLAY=, with NO focus
# juggling. Both displays use the SAME screen size so the window-geometry math (centre 640,360 of an
# 800x600 SDL-centred window in 1280x720; the chargen class-list click at ~640,348) holds on each.
#
# Config (override via env before sourcing, set the RIG_* vars after, or edit rig.conf).
# Load rig.conf (copy it from rig.conf.example) if present — it sets binary names, build dir, paths.
# A variable already set when the rig is sourced (e.g. `RIG_BUILD=/other/build ./your-test.sh`) wins
# over the same key in rig.conf, so a one-off override never needs a conf edit.
_RIG_LIB_DIR=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)
_rig_load_conf() {
    local conf=$1 key keep=()
    while IFS= read -r key; do
        [ -n "${!key+x}" ] && keep+=("$key=${!key}")
    done < <(sed -nE 's/^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)=.*/\2/p' "$conf")
    # shellcheck source=/dev/null  # the user's rig.conf, located at run time
    source "$conf"
    for key in "${keep[@]+"${keep[@]}"}"; do printf -v "${key%%=*}" '%s' "${key#*=}"; done
}
[ -f "${RIG_CONF:-$_RIG_LIB_DIR/../rig.conf}" ] && _rig_load_conf "${RIG_CONF:-$_RIG_LIB_DIR/../rig.conf}"
RIG_ROOT=${RIG_ROOT:-$(cd "$_RIG_LIB_DIR/.." && pwd)}
RIG_BUILD=${RIG_BUILD:-$RIG_ROOT/build}                      # dir holding the client + server binaries (SET THIS)
RIG_CLIENT_BIN=${RIG_CLIENT_BIN:-tes3mp}                     # client executable name inside $RIG_BUILD
RIG_SERVER_BIN=${RIG_SERVER_BIN:-tes3mp-server}              # dedicated-server executable name inside $RIG_BUILD
RIG_SERVER_CFG=${RIG_SERVER_CFG:-tes3mp-server-default.cfg}  # server default-config filename inside $RIG_BUILD (read only)
RIG_CORESCRIPTS=${RIG_CORESCRIPTS:-$RIG_ROOT/CoreScripts}    # server-side Lua scripts (TES3MP CoreScripts or a fork)
RIG_MASTER_ANNOUNCE=${RIG_MASTER_ANNOUNCE:-0}                # 1 = leave master-server announce as the cfg has it
RIG_MYGUI_FIXED=${RIG_MYGUI_FIXED:-}                         # Release MyGUI dir (LD_LIBRARY_PATH); empty = none
RIG_RUNS=${RIG_RUNS:-$RIG_ROOT/runs}                         # parent of the per-run directories (rig_run_dir)
RIG_CONTENT_TARGET=${RIG_CONTENT_TARGET:-profile}            # profile (default) | build (fallback, see rig_add_content)
RIG_KEEP_WORK=${RIG_KEEP_WORK:-0}                            # 1 = keep the CoreScripts work copy after the run
RIG_DISPLAY=${RIG_DISPLAY:-:99}                              # client 1's display (single-client repros use this)
RIG_DISPLAY2=${RIG_DISPLAY2:-:100}                           # client 2's display (2-player runs)
RIG_DISPLAY3=${RIG_DISPLAY3:-:101}                           # client 3's display (3-player scenarios)
RIG_SCREEN=${RIG_SCREEN:-1280x720x24}                        # same on ALL displays (window-geometry math)
RIG_PROFILE=${RIG_PROFILE:-/tmp/mp-rig-profile}              # isolated XDG profile (client 1). Keep profiles on a
RIG_PROFILE2=${RIG_PROFILE2:-/tmp/mp-rig-profile2}           # RAM-backed /tmp: client disk writes on a slow
RIG_PROFILE3=${RIG_PROFILE3:-/tmp/mp-rig-profile3}           # filesystem shift frame timing and screenshot values
RIG_SETTINGS_SRC=${RIG_SETTINGS_SRC:-}                       # optional settings.cfg to seed the profile
RIG_SHOTDIR=${RIG_SHOTDIR:-/tmp/mp-rig-shots}                # where capture() writes PNGs + captures.tsv
RIG_SERVER_LOAD=${RIG_SERVER_LOAD:-3}                        # seconds to let the server bind the port
RIG_WORLD_LOAD=${RIG_WORLD_LOAD:-35}                         # seconds for llvmpipe world load — the BLIND
                                                             # fallback (rig_login waitfirst=1); scenario
                                                             # boots are event-gated via rig_wait_boot
RIG_BOOT_CAP=${RIG_BOOT_CAP:-75}                             # rig_wait_boot: max secs to see the milestone
RIG_BOOT_SETTLE=${RIG_BOOT_SETTLE:-6}                        # ...then settle (milestone -> name box drawn)
RIG_CHARGEN_PWBOX=${RIG_CHARGEN_PWBOX:-4}                     # secs for the "create password" box after name
RIG_CHARGEN_DLG=${RIG_CHARGEN_DLG:-5}                         # secs for each chargen dialog to render (llvmpipe)
RIG_WIGGLE_INTERVAL=${RIG_WIGGLE_INTERVAL:-20}               # idle-wiggler period (s); MUST be < fVanityDelay (30s)

RIG_XVFB='' RIG_XVFB2='' RIG_XVFB3='' RIG_SRV='' RIG_CLI='' RIG_CLI2='' RIG_CLI3='' RIG_WIGGLER=''
# Per-run state (set by rig_run_dir / rig_corescripts_overlay / rig_set_server_home / rig_add_content).
RIG_RUN_DIR=${RIG_RUN_DIR:-} RIG_CORESCRIPTS_WORK='' RIG_SRV_HOME='' RIG_CONTENT_LABEL='' RIG_CONTENT_LINES=()

rig_die()  { echo "rig: $*" >&2; exit 1; }
rig_note() { echo ">>> rig: $*" >&2; }

# Kill our children + any leftovers. Consumers: `trap rig_cleanup EXIT`.
rig_cleanup() {
    kill "${RIG_WIGGLER:-}" "${RIG_CLI:-}" "${RIG_CLI2:-}" "${RIG_CLI3:-}" "${RIG_SRV:-}" \
         "${RIG_XVFB:-}" "${RIG_XVFB2:-}" "${RIG_XVFB3:-}" 2>/dev/null || true
    # A busy-spinning ${RIG_CLIENT_BIN} client can ignore the SIGTERM above and get reparented to init
    # (PPID 1, ~300% CPU), inflating box load for every later run and causing load-flakes.
    # Force-sweep survivors by name — safe because the rig is the sole runner of these binaries
    # (same rationale as `pkill -x Xvfb` below; rig_require_clean refuses to start against a
    # stray ${RIG_SERVER_BIN}). pkill -x (exact name), never -f.
    pkill -9 -x "${RIG_CLIENT_BIN}" 2>/dev/null || true
    pkill -x    "${RIG_SERVER_BIN}" 2>/dev/null || true
    # Fallback mode only (RIG_CONTENT_TARGET=build): strip the content block from the build's
    # openmw.cfg. A leftover block there duplicates a later run's content, and since OpenMW 0.49
    # (main.cpp "Content file specified more than once. Aborting") that hard-aborts the client.
    # In the default profile mode the build cfg is never written, so a crash cannot leave one.
    if [ "$RIG_CONTENT_TARGET" = build ] && [ -n "${RIG_BUILD:-}" ] \
       && grep -q '^# RIG-CONTENT BEGIN' "$RIG_BUILD/openmw.cfg" 2>/dev/null; then
        sed -i '/^# RIG-CONTENT BEGIN/,/^# RIG-CONTENT END/d' "$RIG_BUILD/openmw.cfg" 2>/dev/null || true
    fi
    # Drop the CoreScripts work copy (it is a throwaway copy; RIG_KEEP_WORK=1 keeps it for a post-mortem).
    if [ -n "$RIG_CORESCRIPTS_WORK" ] && [ "$RIG_KEEP_WORK" != 1 ] && [ -f "$RIG_CORESCRIPTS_WORK/.rig-workcopy" ]; then
        rm -rf "${RIG_CORESCRIPTS_WORK:?}"
    fi
}

# Refuse to run against a stale server (it would silently serve old config); clear stale Xvfb on either
# of our displays. A stale Xvfb carrying an Xauthority makes our auth-less Xvfb lose the race, so
# xdotool gets "Authorization required" and everything past connect fails — kill all Xvfb + rm both
# locks. (pkill -x Xvfb is broad on purpose: this box only runs Xvfb for the rig.)
rig_require_clean() {
    if pgrep -x ${RIG_SERVER_BIN} >/dev/null; then
        rig_die "a ${RIG_SERVER_BIN} is already running — kill it first (pkill -x ${RIG_SERVER_BIN})"
    fi
    local d stale=
    for d in "$RIG_DISPLAY" "$RIG_DISPLAY2" "$RIG_DISPLAY3"; do
        [ -e "/tmp/.X${d#:}-lock" ] && stale=1
    done
    if [ -n "$stale" ] && pgrep -x Xvfb >/dev/null; then
        rig_note "clearing stale Xvfb on $RIG_DISPLAY / $RIG_DISPLAY2 / $RIG_DISPLAY3"
        pkill -x Xvfb 2>/dev/null || true
        rm -f "/tmp/.X${RIG_DISPLAY#:}-lock" "/tmp/.X${RIG_DISPLAY2#:}-lock" "/tmp/.X${RIG_DISPLAY3#:}-lock" 2>/dev/null || true
        sleep 1
    fi
}

rig_check_prereqs() {
    [ -x "$RIG_BUILD/${RIG_CLIENT_BIN}" ]  || rig_die "no client binary at $RIG_BUILD/${RIG_CLIENT_BIN} (set RIG_BUILD/RIG_CLIENT_BIN in rig.conf)"
    [ -x "$RIG_BUILD/${RIG_SERVER_BIN}" ]  || rig_die "no server binary at $RIG_BUILD/${RIG_SERVER_BIN} (set RIG_BUILD/RIG_SERVER_BIN in rig.conf)"
    [ -d "$RIG_CORESCRIPTS" ]              || rig_die "no server scripts at $RIG_CORESCRIPTS (set RIG_CORESCRIPTS; clone TES3MP CoreScripts or your fork's)"
    command -v Xvfb    >/dev/null || rig_die "Xvfb not installed"
    command -v xdotool >/dev/null || rig_die "xdotool not installed"
    command -v import  >/dev/null || rig_die "ImageMagick 'import' not installed"
}

# Force a clean slate between back-to-back rig sessions: a prior session's EXIT-trap kill is ASYNC (the
# server/clients can still be tearing down RakNet + GL state), so without this the next session's
# rig_require_clean refuses ("server already running") or boots into a contended, degraded state. Kills
# every rig process by exact name, drops the X locks of our displays, waits up to 15s for them to die,
# then settles 4s. Broad on purpose (same rationale as rig_require_clean): the rig is the sole runner of
# these binaries and of Xvfb on this box.
rig_clean_slate() {
    pkill -x "${RIG_SERVER_BIN}" 2>/dev/null; pkill -x "${RIG_CLIENT_BIN}" 2>/dev/null; pkill -x Xvfb 2>/dev/null
    rm -f "/tmp/.X${RIG_DISPLAY#:}-lock" "/tmp/.X${RIG_DISPLAY2#:}-lock" "/tmp/.X${RIG_DISPLAY3#:}-lock" 2>/dev/null
    local w=0
    while { pgrep -x "${RIG_SERVER_BIN}" >/dev/null 2>&1 || pgrep -x "${RIG_CLIENT_BIN}" >/dev/null 2>&1 \
            || pgrep -x Xvfb >/dev/null 2>&1; } && [ "$w" -lt 15 ]; do sleep 1; w=$((w+1)); done
    sleep 4
}
_rig_clean_slate() { rig_clean_slate "$@"; }    # older name, kept for existing consumers

# rig_run_dir [name] — create this run's directory $RIG_RUNS/<YYYYmmdd-HHMMSS>-<name>/ and set
# RIG_RUN_DIR to it (also echoed). Idempotent within one shell: if RIG_RUN_DIR already names an existing
# directory it is reused, so call it directly (not in $(...), which would lose the variable). Not
# exported: a child rig session creates its own run dir. Layout written by the library so far:
#   server.log            the server's captured stdout (rig_start_server; server-2.log on a restart)
#   server/config/openmw/ the run-scoped tes3mp-server.cfg (+ the server's own timestamped log)
#   server/data/          the server's XDG_DATA_HOME
#   corescripts/          the CoreScripts work copy, when the consumer builds it here (removed at
#                         cleanup unless RIG_KEEP_WORK=1)
# Consumers put their client logs, shots/ and review/ next to these.
rig_run_dir() {
    local name=${1:-run} base dir n=1
    if [ -n "$RIG_RUN_DIR" ] && [ -d "$RIG_RUN_DIR" ]; then echo "$RIG_RUN_DIR"; return 0; fi
    name=${name//[^A-Za-z0-9._-]/_}
    mkdir -p "$RIG_RUNS" 2>/dev/null || rig_die "RIG_RUNS: cannot create $RIG_RUNS (set RIG_RUNS in rig.conf to a writable dir)"
    base=$RIG_RUNS/$(date +%Y%m%d-%H%M%S)-$name; dir=$base
    while [ -e "$dir" ]; do n=$((n+1)); dir=$base-$n; done
    mkdir -p "$dir" || rig_die "RIG_RUNS: cannot create $dir"
    RIG_RUN_DIR=$(cd "$dir" && pwd)
    echo "$RIG_RUN_DIR"
}

# rig_corescripts_overlay <workdir> [overlay-dir]...
#   Build a throwaway CoreScripts work copy at <workdir> from $RIG_CORESCRIPTS and point RIG_CORESCRIPTS
#   at it for the rest of the run, so the server's state, requiredDataFiles.json and any test hooks are
#   written there and the user's clone is only read.
#   * copies every top-level entry except data/ and .git (scripts/, lib/, docs ...);
#   * creates data/ with the six empty state subdirs ($RIG_STATE_SUBDIRS), and copies banlist.json
#     (or writes []) and requiredDataFiles.json from the source;
#   * layers the rig's own overlay/ (the server bridge), then each overlay-dir in order: every file is
#     copied over the work copy at the same relative path, except files named <file>.append, whose
#     lines are appended to <file> after ALL overlays are copied (lines already present are skipped).
#     So scripts/customScripts.lua.append holding `require("custom/my-hook")` loads a hook without
#     replacing the user's customScripts.lua, and still applies when a later overlay replaces it.
#   <workdir> is removed first if it holds an earlier work copy (marker file .rig-workcopy); any other
#   existing non-empty dir is refused. rig_cleanup removes the work copy unless RIG_KEEP_WORK=1.
#   Calling it again in the same run rebuilds from the original source, not from the work copy.
rig_corescripts_overlay() {
    local work=${1:?rig_corescripts_overlay: need a workdir} src ov e f rel tgt line sub
    shift
    src=${RIG_CORESCRIPTS_SRC:-$RIG_CORESCRIPTS}
    [ -d "$src/scripts" ] || rig_die "RIG_CORESCRIPTS: no scripts/ in $src (point RIG_CORESCRIPTS at a CoreScripts clone)"
    for ov in "$@"; do [ -d "$ov" ] || rig_die "rig_corescripts_overlay: overlay dir $ov does not exist"; done
    if [ -e "$work" ]; then
        if [ -f "$work/.rig-workcopy" ]; then rm -rf "${work:?}"
        elif [ -n "$(ls -A "$work" 2>/dev/null)" ]; then rig_die "rig_corescripts_overlay: $work exists and is not a rig work copy — refusing to overwrite"
        fi
    fi
    case "$(readlink -f "$work")/" in "$(readlink -f "$src")"/*) rig_die "rig_corescripts_overlay: workdir $work is inside RIG_CORESCRIPTS ($src)";; esac
    mkdir -p "$work/data" || rig_die "rig_corescripts_overlay: cannot create $work"
    : > "$work/.rig-workcopy"
    for e in "$src"/* "$src"/.[!.]*; do
        [ -e "$e" ] || continue
        case "${e##*/}" in data|.git) continue;; esac
        cp -a "$e" "$work/"
    done
    for sub in $RIG_STATE_SUBDIRS; do mkdir -p "$work/data/$sub"; done
    if [ -f "$src/data/banlist.json" ]; then cp "$src/data/banlist.json" "$work/data/"; else echo '[]' > "$work/data/banlist.json"; fi
    [ -f "$src/data/requiredDataFiles.json" ] && cp "$src/data/requiredDataFiles.json" "$work/data/"
    local -a ovs=()
    [ -d "$RIG_ROOT/overlay" ] && ovs+=("$RIG_ROOT/overlay")
    ovs+=("$@")
    for ov in "${ovs[@]+"${ovs[@]}"}"; do
        tar -C "$ov" --exclude='*.append' -cf - . | tar -C "$work" -xf - \
            || rig_die "rig_corescripts_overlay: copying overlay $ov failed"
    done
    for ov in "${ovs[@]+"${ovs[@]}"}"; do
        while IFS= read -r -d '' f; do
            rel=${f#"$ov"/}; tgt=$work/${rel%.append}
            [ -f "$tgt" ] || rig_die "rig_corescripts_overlay: $f appends to ${rel%.append}, which the work copy does not have"
            [ -n "$(tail -c1 "$tgt")" ] && echo >> "$tgt"
            while IFS= read -r line || [ -n "$line" ]; do
                grep -qxF -- "$line" "$tgt" || printf '%s\n' "$line" >> "$tgt"
            done < "$f"
        done < <(find "$ov" -type f -name '*.append' -print0 | sort -z)
    done
    RIG_CORESCRIPTS_SRC=$src
    RIG_CORESCRIPTS_WORK=$(cd "$work" && pwd)
    RIG_CORESCRIPTS=$RIG_CORESCRIPTS_WORK
    rig_note "CoreScripts work copy: $RIG_CORESCRIPTS (from $src; overlays: ${ovs[*]:-none})"
}

# Point the server at the server-scripts dir and, unless RIG_MASTER_ANNOUNCE=1, turn OFF master-server
# announce — by writing a RUN-SCOPED user config, never the build's default cfg. The server loads
# $RIG_BUILD/tes3mp-server-default.cfg, then overlays <user-config>/tes3mp-server.cfg, where the user
# config dir is $XDG_CONFIG_HOME/openmw (apps/openmw-mp/main.cpp loadSettings; components/files/
# linuxpath.cpp). rig_start_server starts the server with XDG_CONFIG_HOME=<run>/server/config and
# XDG_DATA_HOME=<run>/server/data, so the two keys below win for this run only and the server's own
# timestamped log lands in the run dir too. Creates the run dir (rig_run_dir) if the consumer did not.
# Announce OFF matters beyond hygiene: with it on, the server tries to DEREGISTER from the master on
# shutdown and BLOCKS ~10s on the connect timeout (there is no master in a headless test env), which
# delays the OnServerExit a shutdown check waits for.
rig_set_server_home() {
    [ -n "$RIG_RUN_DIR" ] && [ -d "$RIG_RUN_DIR" ] || rig_run_dir "${RIG_RUN_NAME:-$(basename "${0%.sh}")}" >/dev/null
    RIG_SRV_HOME=$RIG_RUN_DIR/server
    _rig_write_server_cfg
}
# (Re)write the run-scoped tes3mp-server.cfg from the current RIG_CORESCRIPTS; rig_start_server calls it
# again, so a work copy built after rig_set_server_home is still the one the server uses.
_rig_write_server_cfg() {
    mkdir -p "$RIG_SRV_HOME/config/openmw" "$RIG_SRV_HOME/data"
    {
        echo "# Run-scoped server config written by headless-mp-rig (rig_set_server_home)."
        echo "[Plugins]"
        echo "home = $RIG_CORESCRIPTS"
        if [ "$RIG_MASTER_ANNOUNCE" != 1 ]; then
            echo "[MasterServer]"
            echo "enabled = false"
        fi
    } > "$RIG_SRV_HOME/config/openmw/tes3mp-server.cfg"
}

# Write a permissive server requiredDataFiles.json matching exactly the client's content list, with an
# EMPTY checksum list per file (= accept any edition/build). The rig controls the data, so "any
# checksum" is robust and harmless — this only gates connection, not in-world behaviour, so it does not
# affect reference screenshots. $@ = content filenames in the SAME order as the client's content= lines.
#
# IMPORTANT — the list must match the client's plugin list ENTRY-FOR-ENTRY or every client is rejected
# with an index-shifted mismatch ("X is past the number of plugins used by the server", then disconnect
# BEFORE login — so the player never reaches the world and every in-world log-assert silently fails).
#
# builtin.omwscripts: an OpenMW 0.48+ client AUTO-LOADS builtin.omwscripts as content **entry 0** (the
# engine ships it in resources/vfs and injects it ahead of the .esm list), so the server's required list
# must put {"builtin.omwscripts": []} FIRST — it is prepended here unconditionally. Without it a 0.48+
# client is rejected with "<last plugin> is past the number of plugins used by the server"; with it,
# login + chargen + cell authority succeed. $@ = the .esm/.esp content filenames in the SAME order as
# the client's content= lines (builtin is added for you).
# RIG_RDF_BUILTIN=0 omits the prepend — required when driving an OpenMW 0.47-based client, which does
# NOT auto-load builtin.omwscripts and is index-shift-rejected by a list that leads with it.
# Default 1 (the 0.48+ behaviour).
rig_set_required_datafiles() {
    local rdf=$RIG_CORESCRIPTS/data/requiredDataFiles.json f entries='' sep=''
    if [ "${RIG_RDF_BUILTIN:-1}" = 1 ]; then
        entries='    {"builtin.omwscripts": []}'   # 0.48+ client auto-loads this as content entry 0
        sep=','$'\n'
    fi
    for f in "$@"; do
        entries="$entries$sep    {\"$f\": []}"
        sep=','$'\n'
    done
    printf '[\n%s\n]\n' "$entries" > "$rdf"
}

# The 6 stateful server-data subdirs every scenario fixture is made of. A fixture is JUST these — never
# the non-stateful top-level files (banlist.json, requiredDataFiles.json): requiredDataFiles is set
# per-scenario by rig_set_required_datafiles, and banlist is irrelevant to a scenario.
RIG_STATE_SUBDIRS="player cell world map recordstore custom"

# Load an authored save-state scenario into the server's CoreScripts data dir, so RETURNING players
# resume into a hand-built situation instead of driving chargen. $1 = a scenario dir holding the
# server data subtree (the 6 RIG_STATE_SUBDIRS, as produced by playing a session on a server).
# Restored fresh each run (playing mutates it), so runs are deterministic — and the rm -rf below means
# loading a fixture CLEARS whatever the previous run left (stale players/cells don't leak). Leaves
# server config files (banlist etc.) alone — only the stateful subdirs are replaced.
rig_load_scenario() {
    local fix=$1 d=$RIG_CORESCRIPTS/data sub
    [ -d "$fix" ] || rig_die "no scenario fixture at $fix"
    for sub in $RIG_STATE_SUBDIRS; do
        rm -rf "${d:?}/$sub"
        if [ -d "$fix/$sub" ]; then cp -a "$fix/$sub" "$d/$sub"; else mkdir -p "$d/$sub"; fi   # the server expects all six
    done
}

# IMPORT a freshly-authored server state into a scenario fixture (the human→script state handoff, see
# docs/WRITING-SCENARIOS.md §2a). Copies ONLY the 6 stateful subdirs, REPLACING the fixture's (so a
# re-import cleanly clears stale state — e.g. players removed in the new authoring vanish). Accepts a
# server data/ dir OR a .zip of one (data.zip): a zip is unpacked to a temp dir and the dir holding
# player/ is found automatically. $1 = source data dir or .zip; $2 = destination fixture dir.
rig_import_fixture() {
    local src=$1 dest=$2 sub tmp=
    if [ "${src##*.}" = zip ]; then
        tmp=$(mktemp -d); unzip -q "$src" -d "$tmp" || rig_die "rig_import_fixture: unzip $src failed"
        src=$(dirname "$(find "$tmp" -type d -name player | head -1)")
    fi
    [ -n "$src" ] && [ -d "$src/player" ] || rig_die "rig_import_fixture: no player/ in $1 (point at a server data/ dir or its .zip)"
    mkdir -p "$dest"
    for sub in $RIG_STATE_SUBDIRS; do
        rm -rf "${dest:?}/$sub"
        [ -d "$src/$sub" ] && cp -a "$src/$sub" "$dest/$sub"
    done
    [ -n "$tmp" ] && rm -rf "$tmp"
    rig_note "imported $1 -> fixture $dest ($(ls "$dest/player"/*.json 2>/dev/null | wc -l) players; non-stateful top-level files ignored)"
}

# CLEAR the LIVE server state to a blank slate — the 6 stateful subdirs emptied (dirs kept). For a run
# that starts from NOTHING, or to scrub a prior scenario's residue. Normal runs don't need this:
# rig_load_scenario already clears+reloads from a fixture. Leaves server config (banlist/requiredDataFiles)
# alone. No arg (operates on the CoreScripts data dir).
rig_clear_state() {
    local d=$RIG_CORESCRIPTS/data sub
    for sub in $RIG_STATE_SUBDIRS; do rm -rf "${d:?}/$sub"; mkdir -p "$d/$sub"; done
    rig_note "cleared live server state ($d: $RIG_STATE_SUBDIRS emptied)"
}

# Set the clients' game-content block (data= / fallback-archive= / content= lines). REPLACES any prior
# block rather than appending. $1 = a label (for the block comment); $2... = the cfg lines. NOTE for
# content that ships BSA archives: you MUST pass them as `fallback-archive=` lines (OpenMW does not
# auto-load .bsa from a data dir) or the client boots with no textures/meshes/GUI and dies.
# Where the block goes (RIG_CONTENT_TARGET):
#   profile (default) — remembered here and written into each client profile's own openmw.cfg
#     ($prof/config/openmw/openmw.cfg) when that client boots. The client reads the build's local
#     openmw.cfg first, then the user cfg its `config="?userconfig?"` line names (= the profile, through
#     XDG_CONFIG_HOME); data=/content=/fallback-archive= are composing options, so the profile's lines
#     are APPENDED after the build's (components/files/configurationmanager.cpp). Requirement: the
#     build's openmw.cfg carries no content= lines of its own, or they come first and shift the plugin
#     order the server checks (rig_doctor fails on this). 0.47-era builds read the user cfg too.
#   build (fallback) — the block is written between '# RIG-CONTENT' markers into $RIG_BUILD/openmw.cfg
#     and stripped by rig_cleanup. Only for a build whose client does not read a user openmw.cfg; it
#     writes into the build dir, and a crash (kill -9) leaves the block behind.
# Prefer rig_use_content <profile>, which builds the lines and requiredDataFiles.json from rig.conf.
rig_add_content() {
    local label=$1; shift
    RIG_CONTENT_LABEL=$label
    RIG_CONTENT_LINES=("$@")
    if [ "$RIG_CONTENT_TARGET" = build ]; then
        local cfg=$RIG_BUILD/openmw.cfg
        sed -i '/^# RIG-CONTENT BEGIN/,/^# RIG-CONTENT END/d' "$cfg"
        { echo "# RIG-CONTENT BEGIN ($label)"; printf '%s\n' "$@"; echo "# RIG-CONTENT END"; } >> "$cfg"
    fi
}

# Write the remembered content block into one profile's openmw.cfg (profile mode), replacing an earlier
# rig block and keeping any other lines a consumer seeded there. $1 = profile dir.
_rig_profile_content() {
    local prof=$1 cfg=$1/config/openmw/openmw.cfg
    [ "$RIG_CONTENT_TARGET" = build ] && return 0
    mkdir -p "$prof/config/openmw"
    [ -f "$cfg" ] && sed -i '/^# RIG-CONTENT BEGIN/,/^# RIG-CONTENT END/d' "$cfg"
    [ "${#RIG_CONTENT_LINES[@]}" -gt 0 ] || return 0
    { echo "# RIG-CONTENT BEGIN ($RIG_CONTENT_LABEL)"; printf '%s\n' "${RIG_CONTENT_LINES[@]}"; echo "# RIG-CONTENT END"; } >> "$cfg"
}

# Content profiles. rig.conf names each content set once:
#   RIG_CONTENT_<name>_DATA      the data directory (required)
#   RIG_CONTENT_<name>_ARCHIVES  space-separated .bsa files under DATA, loaded as fallback-archive= (optional)
#   RIG_CONTENT_<name>_FILES     space-separated content files under DATA, in load order (required)
# The profile "example" falls back to the older EXAMPLE_SUITE key with FILES=template.omwgame.
# Names with spaces in DATA are fine; ARCHIVES/FILES entries cannot contain spaces.
_rig_content_get() {   # _rig_content_get <name> <DATA|ARCHIVES|FILES>
    local key="RIG_CONTENT_${1}_$2"
    if [ -n "${!key:-}" ]; then printf '%s' "${!key}"; return; fi
    if [ "$1" = example ]; then
        case $2 in DATA) printf '%s' "${EXAMPLE_SUITE:-}";; FILES) [ -n "${EXAMPLE_SUITE:-}" ] && printf '%s' template.omwgame;; esac
    fi
}
# rig_content_check <name> — print one line per problem, each naming the rig.conf key; return 1 if any.
rig_content_check() {
    local n=$1 data files arch f bad=0
    data=$(_rig_content_get "$n" DATA); files=$(_rig_content_get "$n" FILES); arch=$(_rig_content_get "$n" ARCHIVES)
    if [ -z "$data" ]; then echo "RIG_CONTENT_${n}_DATA: not set (content profile '$n' needs its data directory)"; return 1; fi
    [ -d "$data" ] || { echo "RIG_CONTENT_${n}_DATA: no such directory: $data"; return 1; }
    [ -n "$files" ] || { echo "RIG_CONTENT_${n}_FILES: not set (list the content files under $data in load order)"; bad=1; }
    for f in $files; do
        [ -n "$(find "$data/" -maxdepth 1 -iname "$f" -print -quit 2>/dev/null)" ] \
            || { echo "RIG_CONTENT_${n}_FILES: $f not found under RIG_CONTENT_${n}_DATA ($data)"; bad=1; }
    done
    for f in $arch; do
        [ -n "$(find "$data/" -maxdepth 1 -iname "$f" -print -quit 2>/dev/null)" ] \
            || { echo "RIG_CONTENT_${n}_ARCHIVES: $f not found under RIG_CONTENT_${n}_DATA ($data)"; bad=1; }
    done
    return "$bad"
}
# rig_use_content <name> — select a content profile for this run: writes the server's
# requiredDataFiles.json (rig_set_required_datafiles, FILES in order) and the clients' content block
# (rig_add_content). Dies with the offending rig.conf key if the profile is incomplete. Returns 4
# instead of dying when RIG_CONTENT_SOFT=1, so a runner can report "content missing" as a skip.
rig_use_content() {
    local n=${1:?rig_use_content: need a content profile name} msg data f
    local -a lines=() files=()
    if ! msg=$(rig_content_check "$n"); then
        [ "${RIG_CONTENT_SOFT:-0}" = 1 ] && { echo "$msg" >&2; return 4; }
        rig_die "content profile '$n': ${msg//$'\n'/; }"
    fi
    data=$(_rig_content_get "$n" DATA)
    read -r -a files <<<"$(_rig_content_get "$n" FILES)"
    lines+=("data=\"$data\"")
    for f in $(_rig_content_get "$n" ARCHIVES); do lines+=("fallback-archive=$f"); done
    for f in "${files[@]}"; do lines+=("content=$f"); done
    rig_set_required_datafiles "${files[@]}"
    rig_add_content "$n" "${lines[@]}"
}

rig_start_xvfb() {
    Xvfb "$RIG_DISPLAY" -screen 0 "$RIG_SCREEN" >/dev/null 2>&1 & RIG_XVFB=$!
    sleep 1
}
# Second display for 2-player runs (client 2 boots here). Same screen size as display 1.
rig_start_xvfb2() {
    Xvfb "$RIG_DISPLAY2" -screen 0 "$RIG_SCREEN" >/dev/null 2>&1 & RIG_XVFB2=$!
    sleep 1
}
# Third display for 3-player scenarios (client 3 boots here).
rig_start_xvfb3() {
    Xvfb "$RIG_DISPLAY3" -screen 0 "$RIG_SCREEN" >/dev/null 2>&1 & RIG_XVFB3=$!
    sleep 1
}

rig_start_server() {
    # Capture the server's stdout to a fresh, run-scoped file and treat THAT as the server log.
    # The server Tee's its cout to stdout even when its own timestamped logfile fails to open (the
    # std::filesystem leading-slash log-path bug in apps/openmw-mp/main.cpp — a real server
    # regression), so stdout is the only reliable, always-fresh source. This
    # also kills the stale-log hazard: rig_server_log used to `ls -t` a shared glob and could serve
    # a PRIOR run's log — the false-RED that masked a passing scenario ().
    # In a run dir it is <run>/server.log (server-2.log, ... on a restart within the run).
    local -a srvenv=()
    if [ -n "$RIG_RUN_DIR" ] && [ -d "$RIG_RUN_DIR" ]; then
        local n=1; RIG_SRV_STDOUT=$RIG_RUN_DIR/server.log
        while [ -e "$RIG_SRV_STDOUT" ]; do n=$((n+1)); RIG_SRV_STDOUT=$RIG_RUN_DIR/server-$n.log; done
    else
        RIG_SRV_STDOUT=$(mktemp "${TMPDIR:-/tmp}/mp-rig-server-XXXXXX.log")
    fi
    # Run-scoped server config (rig_set_server_home): the server reads its user cfg and writes its own
    # log under XDG_CONFIG_HOME/openmw — both inside the run dir, never the user's ~/.config.
    if [ -n "$RIG_SRV_HOME" ]; then
        _rig_write_server_cfg
        srvenv=("XDG_CONFIG_HOME=$RIG_SRV_HOME/config" "XDG_DATA_HOME=$RIG_SRV_HOME/data")
    fi
    env "${srvenv[@]+"${srvenv[@]}"}" "$RIG_BUILD/${RIG_SERVER_BIN}" >"$RIG_SRV_STDOUT" 2>&1 & RIG_SRV=$!
    sleep "$RIG_SERVER_LOAD"
}

# Fresh isolated profile; optionally seed a settings.cfg (model remaps etc.). $1 = profile dir
# (default RIG_PROFILE; pass RIG_PROFILE2 for the second client).
rig_make_profile() {
    local prof=${1:-$RIG_PROFILE}
    [ -n "$prof" ] || rig_die "rig_make_profile: no profile dir (RIG_PROFILE is empty)"
    rm -rf "$prof"
    mkdir -p "$prof/config/openmw" "$prof/data"
    [ -n "$RIG_SETTINGS_SRC" ] && [ -f "$RIG_SETTINGS_SRC" ] && \
        cp "$RIG_SETTINGS_SRC" "$prof/config/openmw/settings.cfg"
}

# Boot a client headlessly with the warp-mouse + fixed-MyGUI + isolated-profile env.
# _rig_boot <logfile> <profiledir> <display> echoes the PID; rig_start_client / rig_start_client2 assign it.
_rig_boot() {
    local clilog=$1 prof=$2 disp=$3
    local -a libenv=()
    _rig_profile_content "$prof"
    [ -n "$RIG_MYGUI_FIXED" ] && [ -d "$RIG_MYGUI_FIXED" ] && libenv=("LD_LIBRARY_PATH=$RIG_MYGUI_FIXED")
    # OpenMW 0.49's OSG plugin checker aborts the client unless OSG_LIBRARY_PATH lets
    # osgDB::listAllAvailablePlugins() see the plugins (its default path list omits Debian's
    # multiarch dir); OSG appends "osgPlugins-<ver>" per entry, so point at the parent lib dir.
    # See a known engine issue (mid-MR OSG checker); mirrors build.sh's boot check.
    local osgplug
    osgplug=$(find /usr/lib /lib -maxdepth 4 -type d -name 'osgPlugins-*' 2>/dev/null | head -1 || true)
    [ -n "$osgplug" ] && libenv+=("OSG_LIBRARY_PATH=$(dirname "$osgplug"):$osgplug")
    DISPLAY="$disp" env "${libenv[@]}" \
        SDL_MOUSE_RELATIVE_MODE_WARP=1 \
        XDG_CONFIG_HOME="$prof/config" XDG_DATA_HOME="$prof/data" \
        "$RIG_BUILD/${RIG_CLIENT_BIN}" > "$clilog" 2>&1 &
    echo $!
}
# $1 = client log path. Sets RIG_CLI (RIG_PROFILE on RIG_DISPLAY). Single-client repros use this.
rig_start_client()  { RIG_CLI=$(_rig_boot "$1" "$RIG_PROFILE" "$RIG_DISPLAY"); }
# Second client for 2-player runs: own profile, its OWN display (RIG_DISPLAY2). Sets RIG_CLI2.
rig_start_client2() { rig_make_profile "$RIG_PROFILE2"; RIG_CLI2=$(_rig_boot "$1" "$RIG_PROFILE2" "$RIG_DISPLAY2"); }
# Third client for 3-player scenarios: own profile + display (RIG_DISPLAY3). Sets RIG_CLI3.
rig_start_client3() { rig_make_profile "$RIG_PROFILE3"; RIG_CLI3=$(_rig_boot "$1" "$RIG_PROFILE3" "$RIG_DISPLAY3"); }
# Log a client out (disconnect) by killing its process. $1 = the PID var's value (e.g. "$RIG_CLI").
# The server then transfers cell authority to a remaining visitor — a thing scenarios test.
rig_logout() { kill "$1" 2>/dev/null || true; sleep 2; }

# Start a background IDLE-WIGGLER that keeps every active client non-idle, so the engine never reaches
# fVanityDelay (30s) and the auto-VANITY (idle) camera never activates. That camera is the long-standing
# "camera mode / view angle is non-deterministic" red herring: after 30s of no input OpenMW swings into a
# slowly-orbiting third-person vanity view (and HIDES the crosshair — see camera.cpp showCrosshair), which
# breaks centre-screen ray actions (activate/pick-up) and the framing of any screenshot. It is fully
# DETERMINISTIC once you stop it triggering. Any input dismisses it; this just feeds a heartbeat. Every
# RIG_WIGGLE_INTERVAL (<30s) it nudges the mouse 1px and back on each booted display; the nudge DIRECTION
# alternates each tick so the warp-mode yaw it injects (~0.13°) cancels over pairs (net ~0 drift), and it
# returns the cursor to screen centre so GUI flows that mousemove-then-click are unaffected. Call AFTER the
# players are in-world; rig_cleanup kills it. No-op (returns) if no display is booted.
rig_start_idle_wiggler() {
    local pair d disps=() xpids=()
    for pair in "$RIG_XVFB|$RIG_DISPLAY" "$RIG_XVFB2|$RIG_DISPLAY2" "$RIG_XVFB3|$RIG_DISPLAY3"; do
        [ -n "${pair%%|*}" ] && { disps+=("${pair#*|}"); xpids+=("${pair%%|*}"); }   # displays whose Xvfb we started
    done
    [ "${#disps[@]}" -eq 0 ] && return 0
    # Wiggle IMMEDIATELY then every interval: a returning player can enter the world with the idle timer
    # already expired (it accrues at the connect screen, where typing doesn't reset it), so vanity can
    # show within seconds of login — the first wiggle must not wait a full period.
    # It exits on its own once none of its Xvfb servers is alive, so a wiggler orphaned by a killed run or
    # a kept-up world never injects motion into the next run's displays.
    ( dir=1
      while true; do
          alive=0; for x in "${xpids[@]}"; do kill -0 "$x" 2>/dev/null && alive=1; done
          [ "$alive" = 1 ] || break
          for d in "${disps[@]}"; do
              DISPLAY="$d" xdotool mousemove $((640 + dir)) 360 2>/dev/null
              DISPLAY="$d" xdotool mousemove 640 360 2>/dev/null
          done
          dir=$(( -dir ))
          sleep "$RIG_WIGGLE_INTERVAL"
      done ) & RIG_WIGGLER=$!
    rig_note "idle-wiggler started (every ${RIG_WIGGLE_INTERVAL}s on ${disps[*]}) — suppresses the vanity camera"
}

# Type the login name (and, for a fresh account, the second "Create new password:" box that appears
# ~4s later — type it FAST; some start cells drown the player within seconds of login).
# $1 = display, $2 = player name, $3 = password (omit/empty to skip the password box, e.g. a returning
# player), $4 = wait-for-world-load first (default 1; pass 0 in 2-player runs where you've already
# waited for both clients to boot together), $5 = the client's log file (optional): event-gates the
# password box on its 'ID_GUI_MESSAGEBOX, Type 3' line (fires for both "Enter your password:" and
# "Create new password:") instead of the blind 3s sleep.
rig_login() {
    local disp=$1 name=$2 pass=${3:-} waitfirst=${4:-1} clilog=${5:-}
    [ "$waitfirst" = 1 ] && sleep "$RIG_WORLD_LOAD"
    DISPLAY="$disp" xdotool type --delay 80 "$name"; sleep 1
    DISPLAY="$disp" xdotool key Return
    if [ -n "$pass" ]; then
        if [ -n "$clilog" ]; then
            rig_wait_event "$clilog" 'ID_GUI_MESSAGEBOX, Type 3' 6 0.3 || true
            sleep 1        # box drawn a beat after the packet logs
        else
            sleep 3
        fi
        DISPLAY="$disp" xdotool type --delay 50 "$pass"
        DISPLAY="$disp" xdotool key Return
    fi
}

# Drive a FRESH player through login + the full TES3MP character generation on its display, ending
# in-world. Driving chargen creates the player from scratch, so no pre-baked returning-player json is
# needed.
# The validated sequence (TES3MP MP-chargen, where Return activates each dialog's default/OK button —
# only the class-METHOD picker has no default and needs the one mouse click):
#   name -> Return  (fresh acct: -> "create password" box)
#   password -> Return  (-> race dialog)
#   Return  (race OK -> class-method picker)
#   CLICK "Pick from Class List"  (screen ~640,348 for an 800x600 window centred in 1280x720)
#   Return  (class OK -> birthsign)
#   Return  (birth OK -> in-world)  ; EndCharGen then writes the player's CoreScripts json.
# Assumes the caller already waited RIG_WORLD_LOAD for the client to boot to the Name box.
# $1 = display, $2 = name, $3 = password (default "test").
rig_register_player() {
    local disp=$1 name=$2 pass=${3:-test}
    rig_type "$disp" "$name"; sleep 1; rig_key "$disp" Return            # name -> password box
    sleep "$RIG_CHARGEN_PWBOX"; rig_type "$disp" "$pass" 50; rig_key "$disp" Return  # password -> race
    sleep "$RIG_CHARGEN_DLG"; rig_key "$disp" Return                     # race OK -> class-method picker
    sleep "$RIG_CHARGEN_DLG"; rig_click "$disp" 640 348                  # "Pick from Class List"
    sleep "$RIG_CHARGEN_DLG"; rig_key "$disp" Return                     # class OK -> birthsign
    sleep "$RIG_CHARGEN_DLG"; rig_key "$disp" Return                     # birth OK -> in-world
}

# Type a server chat command on a client. TES3MP opens the chat input with keySay (Y by default),
# focuses the command line, then Return submits (GUIController.cpp/GUIChat.cpp). Only works in normal
# gameplay (no menu/console open). $1 = display, $2 = command incl. leading slash, e.g. "/coloc".
rig_chat_command() {
    local disp=$1 cmd=$2
    rig_key "$disp" y; sleep 0.6        # keySay opens + focuses the chat input (the Y is consumed)
    rig_type "$disp" "$cmd" 40; sleep 0.3
    rig_key "$disp" Return; sleep 0.6   # submit -> customCommandHooks dispatch
}

# Poll a log file for a pattern. $1 log, $2 pattern, $3 max polls (default 40), $4 interval s (default 2).
rig_wait_log() {
    local log=$1 pat=$2 max=${3:-40} iv=${4:-2} i
    for ((i=0; i<max; i++)); do
        grep -qF "$pat" "$log" 2>/dev/null && return 0
        sleep "$iv"
    done
    return 1
}

# EVENT-GATE a wait on a log line (the "poll, don't blanket-sleep" pattern of cookbook recipe
# KB-14-cast-during-combat-pre-melee-window, generalized): poll a log for an ERE up to a SECONDS cap.
# Replaces blind post-login/action sleeps — the caller waits exactly as long as the event takes (plus
# its own settle margin), and a degraded run just waits up to the cap instead of desyncing.
# $1 log, $2 ERE, $3 cap secs (default 10), $4 interval (default 0.5).
# Returns 0 on hit, 1 on cap (caller proceeds; the phase asserts catch a genuinely missing event).
rig_wait_event() {
    local log=$1 pat=$2 cap=${3:-10} iv=${4:-0.5} t0=$SECONDS
    while (( SECONDS - t0 < cap )); do
        grep -qiE "$pat" "$log" 2>/dev/null && return 0
        sleep "$iv"
    done
    rig_note "wait_event TIMEOUT (${cap}s): '$pat' not in $(basename "$log")"
    return 1
}

# EVENT-GATE the client boot: wait for each client log's world-load milestone instead of a blind
# RIG_WORLD_LOAD sleep. Milestone = 'Sending ID_PLAYER_MAP' — the client emits it once, right as the
# initial world load completes; the connect/name box is up within a few seconds of it (measured by
# polling screenshots: the milestone arrives 6-9s after launch even with 3 clients booting in
# parallel, and the name box is visible 4-7s later, where a fixed boot sleep needs ~50s). After ALL milestones, settle RIG_BOOT_SETTLE.
# On a milestone timeout (cap RIG_BOOT_CAP) warn and proceed — the phase asserts catch a dead client.
# $@ = the client log files.
rig_wait_boot() {
    local t0=$SECONDS log left
    for log in "$@"; do
        left=$(( RIG_BOOT_CAP - (SECONDS - t0) )); (( left > 0 )) || left=1
        if rig_wait_event "$log" 'Sending ID_PLAYER_MAP' "$left" 1; then
            rig_note "boot milestone in $(basename "$log") at +$((SECONDS-t0))s"
        else
            rig_note "boot milestone MISSING in $(basename "$log") after ${RIG_BOOT_CAP}s — proceeding"
        fi
    done
    sleep "$RIG_BOOT_SETTLE"
}

# Normalized RMSE between two images (the value magick prints in parens). Empty on error/size mismatch.
_rig_rmse() { magick compare -metric RMSE "$1" "$2" null: 2>&1 | grep -oE '\([0-9.eE+-]+\)' | head -1 | tr -d '()'; }

# Grab a (cropped) region to a file — the pre-keystroke baseline for rig_wait_stable's change-gate.
# $1 disp, $2 geom WxH+X+Y | FULL, $3 out file.
rig_grab_region() {
    local disp=$1 geom=${2:-FULL} out=$3
    DISPLAY="$disp" import -window root "$out" 2>/dev/null
    if [ "$geom" != FULL ]; then magick "$out" -crop "$geom" +repage "$out" 2>/dev/null; fi
}

# SCREEN-STABILITY wait (KB-15-screen-stability-wait): return once the (optionally cropped) frame has SETTLED — two
# consecutive grabs matching within eps (normalized RMSE) — and, unless delta='-', only after the
# region has first CHANGED from the at-call baseline by >= delta. The change-gate stops a slow
# transition from being declared "ready" while still showing the PREVIOUS content (the blind-keystroke
# chargen desync); the stability gate rides out fade-ins/partial renders. Cap-bounded: on timeout it
# warns and returns 1 — the caller proceeds, so a degraded run just waited the cap (like the old
# blind sleep) instead of desyncing.
#   $1 disp  $2 geom WxH+X+Y | FULL  $3 cap secs (default 8)  $4 interval (default 0.7)
#   $5 eps (default 0.004 — 2D GUI regions settle to ~0)  $6 delta (default 0.05; '-' = no change-gate)
#   $7 baseline png (optional): a region grab taken BEFORE the triggering keystroke (rig_grab_region).
#      Without it the baseline is grabbed at call time — and a transition FASTER than that first grab
#      makes the change-gate unsatisfiable (it baselines the NEW content) so the wait burns its cap.
rig_wait_stable() {
    local disp=$1 geom=${2:-FULL} cap=${3:-8} iv=${4:-0.7} eps=${5:-0.004} delta=${6:-0.05} basefile=${7:-}
    local t0=$SECONDS tdir d s changed=0
    [ "$delta" = "-" ] && changed=1
    tdir=$(mktemp -d /tmp/rig-stable.XXXXXX)
    _rs_grab() { DISPLAY="$disp" import -window root "$1" 2>/dev/null
                 if [ "$geom" != FULL ]; then magick "$1" -crop "$geom" +repage "$1" 2>/dev/null; fi; }
    if [ -n "$basefile" ] && [ -f "$basefile" ]; then cp "$basefile" "$tdir/base.png"
    else _rs_grab "$tdir/base.png"; fi
    cp "$tdir/base.png" "$tdir/prev.png"
    while (( SECONDS - t0 < cap )); do
        sleep "$iv"
        _rs_grab "$tdir/cur.png"
        if [ "$changed" = 0 ]; then
            d=$(_rig_rmse "$tdir/base.png" "$tdir/cur.png")
            [ -n "$d" ] && awk -v v="$d" -v t="$delta" 'BEGIN{exit !(v+0>=t+0)}' && changed=1
        fi
        if [ "$changed" = 1 ]; then
            s=$(_rig_rmse "$tdir/prev.png" "$tdir/cur.png")
            if [ -n "$s" ] && awk -v v="$s" -v t="$eps" 'BEGIN{exit !(v+0<=t+0)}'; then
                echo "    (stable at +$((SECONDS-t0))s: frame-diff $s <= $eps)"
                rm -rf "$tdir"; return 0
            fi
        fi
        mv -f "$tdir/cur.png" "$tdir/prev.png"
    done
    rm -rf "$tdir"
    rig_note "wait_stable TIMEOUT (${cap}s) on $disp $geom (changed=$changed) — proceeding"
    return 1
}

# The server log for THIS run. When we started the server (rig_start_server), its captured stdout
# is authoritative and always fresh; fall back to the newest on-disk timestamped log only for
# callers that did not start a server here.
rig_server_log() {
    if [ -n "${RIG_SRV_STDOUT:-}" ] && [ -f "$RIG_SRV_STDOUT" ]; then echo "$RIG_SRV_STDOUT"; return; fi
    ls -t ${RIG_SRV_HOME:+"$RIG_SRV_HOME"/config/openmw/"${RIG_SERVER_BIN}"-*.log} \
          ${RIG_PROFILE:+"$RIG_PROFILE"/data/openmw/"${RIG_SERVER_BIN}"-*.log} ~/.config/openmw/"${RIG_SERVER_BIN}"-*.log 2>/dev/null | head -1
}

# Screenshot the whole root window of a display to $RIG_SHOTDIR/<name>.png, record the wall-clock
# capture time to captures.tsv (so screenshot times line up with the raw log timestamps when
# investigating a flagged run), and echo the path. $1 = display, $2 = name, $3 = out dir.
capture() {
    local disp=$1 name=$2 out=${3:-$RIG_SHOTDIR}
    mkdir -p "$out"
    DISPLAY="$disp" import -window root "$out/$name.png"
    printf '%s\t%s\n' "$name" "$(date +%s.%N)" >> "$out/captures.tsv"
    echo "$out/$name.png"
}

# Target a specific client window by its PID (the rig execs the binary directly, so _NET_WM_PID is the
# client's). With one client per display there is a single window, but PID-targeting is still more
# robust than assuming it. NOTE: there is no window manager under bare Xvfb, so window FOCUS is neither
# possible nor needed — each display has exactly one client window, so input goes to it by setting
# DISPLAY (no `windowactivate`; that errored "no _NET_ACTIVE_WINDOW", the reason rig_focus_pid was
# removed). $1 = display, $2 = pid.
rig_window_of() { DISPLAY="$1" xdotool search --pid "$2" 2>/dev/null | head -1; }
# capture_win <display> <name> <pid> [out] — shoot just that client's window (falls back to root).
capture_win() {
    local disp=$1 name=$2 pid=$3 out=${4:-$RIG_SHOTDIR} w; w=$(rig_window_of "$disp" "$pid")
    mkdir -p "$out"
    if [ -n "$w" ]; then DISPLAY="$disp" import -window "$w" "$out/$name.png"
    else DISPLAY="$disp" import -window root "$out/$name.png"; fi
    printf '%s\t%s\n' "$name" "$(date +%s.%N)" >> "$out/captures.tsv"
    echo "$out/$name.png"
}

# Input helpers — all take the target DISPLAY as the first arg (no focus needed; one window/display).
# Synthetic mouse-look, relative to the screen centre of an 800x600 SDL-centred window in 1280x720
# (centre 640,360). $1 display, $2 dx, $3 dy from centre.
rig_look()  { DISPLAY="$1" xdotool mousemove $((640 + ${2:-0})) $((360 + ${3:-0})); sleep 0.25; }
# Turn the camera by repeated horizontal mouse deltas (warp mode reads offset-from-centre each frame
# and applies it as yaw). $1 display, $2 per-step dx (sign = direction), $3 steps (default 4). Used to
# swing a client's view around toward the other player when a forced server rotation didn't stick.
rig_turn()  { local d=$1 dx=$2 n=${3:-4} i; for ((i=0;i<n;i++)); do DISPLAY="$d" xdotool mousemove $((640+dx)) 360; sleep 0.2; done; }
# rig_type <display> <text> [delay-ms]   rig_key <display> <keys...>
rig_type()  { local d=$1 t=$2 dl=${3:-80}; DISPLAY="$d" xdotool type --delay "$dl" "$t"; }
rig_key()   { local d=$1; shift; DISPLAY="$d" xdotool key "$@"; }
# Hold a key (movement). rig_tap <display> <key> [hold-secs]
rig_tap()   { local d=$1 k=$2 hold=${3:-0.5}; DISPLAY="$d" xdotool keydown "$k"; sleep "$hold"; DISPLAY="$d" xdotool keyup "$k"; }
# Absolute left-click at screen (x,y) — for the one chargen mouse click ("Pick from Class List").
# rig_click <display> <x> <y>
rig_click() { DISPLAY="$1" xdotool mousemove "$2" "$3"; sleep 0.3; DISPLAY="$1" xdotool click 1; sleep 0.3; }
# Right-click — OpenMW's A_Inventory is the RIGHT mouse button (not a key), so this opens/closes the
# inventory/map/stats menu. rig_rmb <display>
rig_rmb()   { DISPLAY="$1" xdotool click 3; sleep 0.3; }

# ---- rig_doctor — validate rig.conf and the host before a run -----------------------------------------
# Prints one line per check: `ok   ...`, `warn <KEY>: ...` or `FAIL <KEY>: ...`. Every FAIL and warn names
# the rig.conf key (or the package) to fix, so the message alone says what to edit. Returns 0 when a run
# can start (warnings allowed), 1 if any check failed. Reads only; never writes outside RIG_RUNS.
RIG_KNOWN_KEYS="RIG_BUILD RIG_CLIENT_BIN RIG_SERVER_BIN RIG_SERVER_CFG RIG_CORESCRIPTS RIG_MASTER_ANNOUNCE
RIG_MYGUI_FIXED RIG_RUNS RIG_CONTENT_TARGET RIG_KEEP_WORK RIG_DISPLAY RIG_DISPLAY2 RIG_DISPLAY3 RIG_SCREEN
RIG_GEOM_UNCHECKED RIG_PROFILE RIG_PROFILE2 RIG_PROFILE3 RIG_SETTINGS_SRC RIG_SHOTDIR RIG_SERVER_LOAD
RIG_WORLD_LOAD RIG_BOOT_CAP RIG_BOOT_SETTLE RIG_CHARGEN_PWBOX RIG_CHARGEN_DLG RIG_WIGGLE_INTERVAL
RIG_RDF_BUILTIN RIG_ROOT RIG_REF_DIR RIG_REF_MANIFEST RIG_REVIEW_DIR RIG_LOG_REF_DIR RIG_LOG_REVIEW_DIR
RIG_LOG_MARKERS RIG_DEFAULT_METRIC RIG_DEFAULT_THRESHOLD RIG_DEFAULT_FUZZ RIG_CONTENT_SOFT EXAMPLE_SUITE
RIG_SCENARIOS RIG_BUILD_ID RIG_LOGIN_CAP RIG_CHAT_KEY"
rig_doctor() {
    local fails=0 conf k v n d f prof cfg seen=' '
    _rd_ok()   { echo "ok   $*"; }
    _rd_warn() { echo "warn $*"; }
    _rd_fail() { echo "FAIL $*"; fails=$((fails+1)); }

    # -- the config file itself --
    conf=${RIG_CONF:-$_RIG_LIB_DIR/../rig.conf}
    if [ -f "$conf" ]; then
        _rd_ok "config: $(readlink -f "$conf")"
        while IFS= read -r k; do
            case " $(echo $RIG_KNOWN_KEYS) " in *" $k "*) continue;; esac
            [[ $k =~ ^RIG_CONTENT_.+_(DATA|ARCHIVES|FILES)$ ]] && continue
            if [[ $k =~ ^RIG_CONTENT_ ]]; then _rd_fail "$k: not a content-profile key (use RIG_CONTENT_<name>_DATA / _ARCHIVES / _FILES)"
            else _rd_warn "$k: unknown key in $conf (typo?)"; fi
        done < <(sed -nE 's/^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)=.*/\2/p' "$conf" | sort -u)
    else
        _rd_warn "RIG_CONF: no config file at $conf (cp rig.conf.example rig.conf, or set RIG_CONF) — using defaults/environment"
    fi

    # -- the build --
    if [ ! -d "$RIG_BUILD" ]; then
        _rd_fail "RIG_BUILD: no such directory: $RIG_BUILD (set RIG_BUILD to the dir holding your client + server binaries)"
    else
        _rd_ok "RIG_BUILD: $RIG_BUILD"
        if [ -x "$RIG_BUILD/$RIG_CLIENT_BIN" ]; then _rd_ok "RIG_CLIENT_BIN: $RIG_CLIENT_BIN"
        else _rd_fail "RIG_CLIENT_BIN: no executable $RIG_CLIENT_BIN in RIG_BUILD ($RIG_BUILD)"; fi
        if [ -x "$RIG_BUILD/$RIG_SERVER_BIN" ]; then _rd_ok "RIG_SERVER_BIN: $RIG_SERVER_BIN"
        else _rd_fail "RIG_SERVER_BIN: no executable $RIG_SERVER_BIN in RIG_BUILD ($RIG_BUILD)"; fi
        if [ -f "$RIG_BUILD/$RIG_SERVER_CFG" ]; then _rd_ok "RIG_SERVER_CFG: $RIG_SERVER_CFG (read only; the run's overrides go to a run-scoped tes3mp-server.cfg)"
        else _rd_fail "RIG_SERVER_CFG: no $RIG_SERVER_CFG in RIG_BUILD ($RIG_BUILD) — the server needs its default config next to the binary"; fi
        cfg=$RIG_BUILD/openmw.cfg
        if [ ! -f "$cfg" ]; then
            _rd_fail "RIG_BUILD: no openmw.cfg in $RIG_BUILD (the client's local config)"
        else
            if grep -q '^# RIG-CONTENT BEGIN' "$cfg"; then
                if [ "$RIG_CONTENT_TARGET" = build ]; then _rd_warn "RIG_CONTENT_TARGET: leftover rig content block in $cfg (rig_cleanup strips it at the end of the next run)"
                else _rd_fail "RIG_BUILD: $cfg has a leftover '# RIG-CONTENT' block from an older rig — delete the lines from '# RIG-CONTENT BEGIN' to '# RIG-CONTENT END'"; fi
            elif grep -q '^[[:space:]]*content[[:space:]]*=' "$cfg"; then
                _rd_fail "RIG_BUILD: $cfg has its own content= lines; they load before the rig's per-profile content and shift the plugin list the server checks — remove them (or set RIG_CONTENT_TARGET=build)"
            else
                _rd_ok "RIG_BUILD: openmw.cfg has no content= lines (the rig's per-profile content block applies)"
            fi
            if ! grep -q '^[[:space:]]*config[[:space:]]*=' "$cfg"; then
                _rd_warn "RIG_CONTENT_TARGET: $cfg has no config= line (pre-0.48 layout); the user openmw.cfg is still read by 0.47-era clients — if your client ignores it, set RIG_CONTENT_TARGET=build"
            fi
        fi
    fi
    case $RIG_CONTENT_TARGET in
        profile|build) _rd_ok "RIG_CONTENT_TARGET: $RIG_CONTENT_TARGET" ;;
        *) _rd_fail "RIG_CONTENT_TARGET: '$RIG_CONTENT_TARGET' is not profile or build" ;;
    esac

    # -- server scripts --
    if [ -d "$RIG_CORESCRIPTS/scripts" ]; then _rd_ok "RIG_CORESCRIPTS: $RIG_CORESCRIPTS (only read when a run builds a work copy with rig_corescripts_overlay)"
    else _rd_fail "RIG_CORESCRIPTS: no scripts/ in $RIG_CORESCRIPTS (clone TES3MP CoreScripts or your fork's and point RIG_CORESCRIPTS at it)"; fi
    case $RIG_MASTER_ANNOUNCE in 0|1) ;; *) _rd_fail "RIG_MASTER_ANNOUNCE: '$RIG_MASTER_ANNOUNCE' is not 0 or 1";; esac
    case ${RIG_RDF_BUILTIN:-1} in 0|1) ;; *) _rd_fail "RIG_RDF_BUILTIN: '$RIG_RDF_BUILTIN' is not 0 or 1";; esac

    # -- run directory --
    if mkdir -p "$RIG_RUNS" 2>/dev/null && [ -w "$RIG_RUNS" ]; then _rd_ok "RIG_RUNS: $RIG_RUNS"
    else _rd_fail "RIG_RUNS: cannot create or write $RIG_RUNS"; fi

    # -- MyGUI shadow (never auto-detected) --
    if [ -z "$RIG_MYGUI_FIXED" ]; then _rd_ok "RIG_MYGUI_FIXED: none (distro MyGUI used)"
    elif [ -d "$RIG_MYGUI_FIXED" ]; then _rd_ok "RIG_MYGUI_FIXED: MyGUI shadow $RIG_MYGUI_FIXED"
    else _rd_fail "RIG_MYGUI_FIXED: no such directory: $RIG_MYGUI_FIXED (leave it empty to use the distro MyGUI)"; fi

    # -- displays and screen geometry --
    for k in RIG_DISPLAY RIG_DISPLAY2 RIG_DISPLAY3; do
        v=${!k}
        if ! [[ $v =~ ^:[0-9]+$ ]]; then _rd_fail "$k: '$v' is not a display like :99"; continue; fi
        case $seen in *" $v "*) _rd_fail "$k: $v is used by another RIG_DISPLAY* key (each client needs its own display)"; continue;; esac
        seen="$seen$v "
        if [ -e "/tmp/.X${v#:}-lock" ]; then
            if pgrep -x Xvfb >/dev/null 2>&1; then _rd_warn "$k: display $v is in use (lock /tmp/.X${v#:}-lock; rig_require_clean kills Xvfb before a run)"
            else _rd_warn "$k: display $v has a stale lock /tmp/.X${v#:}-lock (rig_require_clean clears it)"; fi
        fi
    done
    [ -n "$(echo "$seen" | tr -d ' ')" ] && _rd_ok "displays:${seen% }"
    if [ "$RIG_SCREEN" = 1280x720x24 ]; then _rd_ok "RIG_SCREEN: $RIG_SCREEN"
    elif [ "${RIG_GEOM_UNCHECKED:-0}" = 1 ]; then _rd_warn "RIG_SCREEN: $RIG_SCREEN — click/crop coordinates assume 1280x720x24 (RIG_GEOM_UNCHECKED=1)"
    else _rd_fail "RIG_SCREEN: $RIG_SCREEN — the rig's window-centre and click coordinates assume 1280x720x24 (set RIG_GEOM_UNCHECKED=1 to override)"; fi

    # -- numbers --
    for k in RIG_SERVER_LOAD RIG_WORLD_LOAD RIG_BOOT_CAP RIG_BOOT_SETTLE RIG_CHARGEN_PWBOX RIG_CHARGEN_DLG RIG_WIGGLE_INTERVAL; do
        [[ ${!k} =~ ^[0-9]+([.][0-9]+)?$ ]] || _rd_fail "$k: '${!k}' is not a number of seconds"
    done
    if [[ $RIG_WIGGLE_INTERVAL =~ ^[0-9]+$ ]] && [ "$RIG_WIGGLE_INTERVAL" -ge 30 ]; then
        _rd_fail "RIG_WIGGLE_INTERVAL: $RIG_WIGGLE_INTERVAL must stay below the engine's 30s vanity delay"
    fi
    if [ -n "$RIG_SETTINGS_SRC" ] && [ ! -f "$RIG_SETTINGS_SRC" ]; then _rd_fail "RIG_SETTINGS_SRC: no such file: $RIG_SETTINGS_SRC"; fi

    # -- content profiles --
    local -a profs=()
    while IFS= read -r k; do
        [[ $k =~ ^RIG_CONTENT_(.+)_(DATA|ARCHIVES|FILES)$ ]] || continue
        prof=${BASH_REMATCH[1]}
        case " ${profs[*]+"${profs[*]}"} " in *" $prof "*) ;; *) profs+=("$prof");; esac
    done < <(compgen -v RIG_CONTENT_ | sort)
    if [ -n "${EXAMPLE_SUITE:-}" ] && [ -z "${RIG_CONTENT_example_DATA:-}" ]; then
        _rd_warn "EXAMPLE_SUITE: older key — set RIG_CONTENT_example_DATA and RIG_CONTENT_example_FILES=template.omwgame instead"
        case " ${profs[*]+"${profs[*]}"} " in *" example "*) ;; *) profs+=(example);; esac
    fi
    [ "${#profs[@]}" -gt 0 ] || _rd_warn "RIG_CONTENT_<name>_DATA: no content profile configured (the example needs RIG_CONTENT_example_*)"
    for prof in "${profs[@]+"${profs[@]}"}"; do
        if f=$(rig_content_check "$prof"); then _rd_ok "content profile $prof: $(_rig_content_get "$prof" FILES) in $(_rig_content_get "$prof" DATA)"
        else while IFS= read -r v; do _rd_fail "$v"; done <<<"$f"; fi
    done

    # -- host tools --
    for k in "Xvfb:xvfb" "xdotool:xdotool" "import:imagemagick" "magick:imagemagick (version 7 provides magick)" \
             "python3:python3" "tar:tar" "pgrep:procps" "pkill:procps"; do
        if command -v "${k%%:*}" >/dev/null 2>&1; then _rd_ok "tool ${k%%:*}"
        else _rd_fail "${k%%:*}: not installed (package: ${k#*:})"; fi
    done
    command -v unzip >/dev/null 2>&1 || _rd_warn "unzip: not installed (package: unzip) — needed only by rig_import_fixture for .zip saves"
    if ! find /usr/lib /lib -maxdepth 4 -type d -name 'osgPlugins-*' 2>/dev/null | grep -q .; then
        _rd_warn "osgPlugins: no osgPlugins-* dir under /usr/lib or /lib — OpenMW 0.49+ clients abort without the OSG plugins"
    fi
    if pgrep -x "$RIG_SERVER_BIN" >/dev/null 2>&1; then
        _rd_warn "RIG_SERVER_BIN: a $RIG_SERVER_BIN is running now — rig_require_clean will refuse to start (pkill -x $RIG_SERVER_BIN)"
    fi

    if [ "$fails" -gt 0 ]; then echo "doctor: $fails problem(s) — fix the keys named above"; return 1; fi
    echo "doctor: ready"
    return 0
}
