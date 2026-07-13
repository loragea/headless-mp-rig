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
#   * LD_LIBRARY_PATH=$HOME/mygui-fixed-lib — Debian's MyGUI (built without CMAKE_BUILD_TYPE)
#     renders NOTHING: all UI invisible but still focusable. Headless tiers can't see it; only a
#     human (or a screenshot) catches it. The fixed-lib is a Release MyGUI under the Debian filename.
#   * Isolated XDG profile — the shared ~/.config/openmw carries another engine version's
#     input_v3.xml/settings.cfg/shaders.yaml; sharing it breaks this build's bindings/shaders.
#   * Use `pgrep -x` / `pkill -x`, never `-f`: `-f` self-matches the shell wrapper.
#   * A stale ${RIG_SERVER_BIN} holds the port and silently services the client with old config.
#   * A stale Xvfb on the display (carrying an Xauthority) makes the auth-less Xvfb lose the race
#     and xdotool gets "Authorization required" — kill it + rm the lock first.
#
# Per-display model (validated 2026-06-19): each client gets its OWN Xvfb display, because a shared
# Xvfb has no window manager (so `xdotool windowactivate` fails — there is no _NET_ACTIVE_WINDOW) and
# two 800x600 windows overlap (the occluded one captures as garbage, X11 has no backing store without a
# compositor). One window per display ⇒ input/capture target it by setting DISPLAY=, with NO focus
# juggling. Both displays use the SAME screen size so the window-geometry math (centre 640,360 of an
# 800x600 SDL-centred window in 1280x720; the chargen class-list click at ~640,348) holds on each.
#
# Config (override via env before sourcing, set the RIG_* vars after, or edit rig.conf).
# Load rig.conf (copy it from rig.conf.example) if present — it sets binary names, build dir, paths.
_RIG_LIB_DIR=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)
[ -f "${RIG_CONF:-$_RIG_LIB_DIR/../rig.conf}" ] && source "${RIG_CONF:-$_RIG_LIB_DIR/../rig.conf}"
RIG_ROOT=${RIG_ROOT:-$(cd "$_RIG_LIB_DIR/.." && pwd)}
RIG_BUILD=${RIG_BUILD:-$RIG_ROOT/build}                      # dir holding the client + server binaries (SET THIS)
RIG_CLIENT_BIN=${RIG_CLIENT_BIN:-tes3mp}                     # client executable name inside $RIG_BUILD
RIG_SERVER_BIN=${RIG_SERVER_BIN:-tes3mp-server}              # dedicated-server executable name inside $RIG_BUILD
RIG_SERVER_CFG=${RIG_SERVER_CFG:-tes3mp-server-default.cfg}  # server default-config filename inside $RIG_BUILD
RIG_CORESCRIPTS=${RIG_CORESCRIPTS:-$RIG_ROOT/CoreScripts}    # server-side Lua scripts (TES3MP CoreScripts or a fork)
RIG_MYGUI_FIXED=${RIG_MYGUI_FIXED:-$HOME/mygui-fixed-lib}    # Release MyGUI under the Debian soname
RIG_DISPLAY=${RIG_DISPLAY:-:99}                              # client 1's display (single-client repros use this)
RIG_DISPLAY2=${RIG_DISPLAY2:-:100}                           # client 2's display (2-player runs)
RIG_DISPLAY3=${RIG_DISPLAY3:-:101}                           # client 3's display (3-player scenarios)
RIG_SCREEN=${RIG_SCREEN:-1280x720x24}                        # same on ALL displays (window-geometry math)
RIG_PROFILE=${RIG_PROFILE:-/tmp/mp-rig-profile}         # isolated XDG profile (client 1)
RIG_PROFILE2=${RIG_PROFILE2:-/tmp/mp-rig-profile2}      # isolated XDG profile (client 2, 2-player runs)
RIG_PROFILE3=${RIG_PROFILE3:-/tmp/mp-rig-profile3}      # isolated XDG profile (client 3, 3-player runs)
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

RIG_XVFB= RIG_XVFB2= RIG_XVFB3= RIG_SRV= RIG_CLI= RIG_CLI2= RIG_CLI3= RIG_WIGGLER=

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
    pkill -9 -x ${RIG_CLIENT_BIN}        2>/dev/null || true
    pkill -x    ${RIG_SERVER_BIN} 2>/dev/null || true
    # Strip our transient content block from the shared openmw.cfg so it never leaks into a later
    # run's boot check. Since OpenMW 0.49 (main.cpp "Content file specified more than once. Aborting")
    # a leftover template.omwgame here duplicates the boot check's own profile content and hard-aborts
    # the client. (a known engine issue.)
    [ -n "${RIG_BUILD:-}" ] && [ -f "$RIG_BUILD/openmw.cfg" ] \
        && sed -i '/^# RIG-CONTENT BEGIN/,/^# RIG-CONTENT END/d' "$RIG_BUILD/openmw.cfg" 2>/dev/null || true
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

# Point the server at our CoreScripts clone. cmake reconfigures clobber this file — call every run.
rig_set_server_home() {
    sed -i "s|^home = .*|home = $RIG_CORESCRIPTS|" "$RIG_BUILD/${RIG_SERVER_CFG}"
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
# builtin.omwscripts: the 0.48 client AUTO-LOADS builtin.omwscripts as content **entry 0** (the engine
# ships it in resources/vfs and injects it ahead of the .esm list), so the server's required list must
# put {"builtin.omwscripts": []} FIRST — we prepend it here unconditionally. (At the 0.47 checkpoint the
# client did NOT load it, so it had to be ABSENT; that flipped at 0.48 — verified by a real Morrowind
# login 2026-06-27: without the prepend the client is rejected with "Bloodmoon.esm is past the number of
# plugins used by the server"; with it, login + chargen + cell-authority all succeed.) $@ = the .esm/.esp
# content filenames in the SAME order as the client's content= lines (builtin is added for you).
# RIG_RDF_BUILTIN=0 omits the prepend — required when driving a 0.47-era client (e.g. the archived
# baseline-audit build), which does NOT auto-load builtin.omwscripts and is index-shift-rejected by a
# list that leads with it. Default 1 (the ≥0.48 behaviour) is unchanged.
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
# server data subtree (the 6 RIG_STATE_SUBDIRS, as produced by playing in the release package).
# Restored fresh each run (playing mutates it), so runs are deterministic — and the rm -rf below means
# loading a fixture CLEARS whatever the previous run left (stale players/cells don't leak). Leaves
# server config files (banlist etc.) alone — only the stateful subdirs are replaced.
rig_load_scenario() {
    local fix=$1 d=$RIG_CORESCRIPTS/data sub
    [ -d "$fix" ] || rig_die "no scenario fixture at $fix"
    for sub in $RIG_STATE_SUBDIRS; do
        rm -rf "$d/$sub"
        [ -d "$fix/$sub" ] && cp -a "$fix/$sub" "$d/$sub"
    done
}

# IMPORT a freshly-authored server state into a scenario fixture (the user→agent state handoff, see
# docs/SCENARIO-WORKFLOW.md §4). Copies ONLY the 6 stateful subdirs, REPLACING the fixture's (so a
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
        rm -rf "$dest/$sub"
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
    for sub in $RIG_STATE_SUBDIRS; do rm -rf "$d/$sub"; mkdir -p "$d/$sub"; done
    rig_note "cleared live server state ($d: $RIG_STATE_SUBDIRS emptied)"
}

# Set the client's openmw.cfg game-content block (data=/fallback-archive=/content= lines). REPLACES any
# prior block rather than appending, so runs don't accumulate stale content (e.g. a smoke run's
# example-suite leaking into a Morrowind run). NOTE for Morrowind: you MUST pass the BSA archives
# as `fallback-archive=` lines (OpenMW does not auto-load .bsa from a data dir) or the client boots with
# no textures/meshes/GUI and dies. $1 = a label (for the block comment); $2... = the cfg lines to set.
rig_add_content() {
    local label=$1; shift
    local cfg=$RIG_BUILD/openmw.cfg
    sed -i '/^# RIG-CONTENT BEGIN/,/^# RIG-CONTENT END/d' "$cfg"
    { echo "# RIG-CONTENT BEGIN ($label)"; printf '%s\n' "$@"; echo "# RIG-CONTENT END"; } >> "$cfg"
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
    RIG_SRV_STDOUT=$(mktemp "${TMPDIR:-/tmp}/mp-rig-server-XXXXXX.log")
    "$RIG_BUILD/${RIG_SERVER_BIN}" >"$RIG_SRV_STDOUT" 2>&1 & RIG_SRV=$!
    sleep "$RIG_SERVER_LOAD"
}

# Fresh isolated profile; optionally seed a settings.cfg (model remaps etc.). $1 = profile dir
# (default RIG_PROFILE; pass RIG_PROFILE2 for the second client).
rig_make_profile() {
    local prof=${1:-$RIG_PROFILE}
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
    [ -d "$RIG_MYGUI_FIXED" ] && libenv=("LD_LIBRARY_PATH=$RIG_MYGUI_FIXED")
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
    local pair d disps=()
    for pair in "$RIG_XVFB|$RIG_DISPLAY" "$RIG_XVFB2|$RIG_DISPLAY2" "$RIG_XVFB3|$RIG_DISPLAY3"; do
        [ -n "${pair%%|*}" ] && disps+=("${pair#*|}")        # only displays whose Xvfb is running
    done
    [ "${#disps[@]}" -eq 0 ] && return 0
    # Wiggle IMMEDIATELY then every interval: a returning player can enter the world with the idle timer
    # already expired (it accrues at the connect screen, where typing doesn't reset it), so vanity can
    # show within seconds of login — the first wiggle must not wait a full period.
    ( dir=1
      while true; do
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
# in-world (decided 2026-06-19: drive chargen every run rather than pre-bake returning-player jsons).
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

# EVENT-GATE a wait on a log line (the KB-14 "poll, don't blanket-sleep" pattern, generalized): poll a
# log for an ERE up to a SECONDS cap. Replaces the blind post-login/action sleeps — the caller waits
# exactly as long as the event takes (plus its own settle margin), and a degraded run just waits up to
# the cap instead of desyncing. $1 log, $2 ERE, $3 cap secs (default 10), $4 interval (default 0.5).
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
# initial world load completes; the connect/name box is up within a few seconds of it (verified by
# screenshot-poll 2026-07-01: milestone at 6-9s even with 3 clients booting in parallel, name box
# visible <=4-7s later; the old fixed sleep was 50s). After ALL milestones, settle RIG_BOOT_SETTLE.
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

# SCREEN-STABILITY wait (KB-15): return once the (optionally cropped) frame has SETTLED — two
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
    ls -t "$RIG_PROFILE"/data/openmw/${RIG_SERVER_BIN}-*.log ~/.config/openmw/${RIG_SERVER_BIN}-*.log 2>/dev/null | head -1
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
