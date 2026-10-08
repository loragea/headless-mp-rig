#!/usr/bin/env bash
# run-example.sh — run the free-content example scenario (scenarios/example) through the runner.
# Same as `bin/rig run scenarios/example [flags]`; see scenarios/example/README.md and
# docs/SCENARIO-FORMAT.md.
exec "$(dirname "$(readlink -f "$0")")/rig" run "$(dirname "$(readlink -f "$0")")/../scenarios/example" "$@"
