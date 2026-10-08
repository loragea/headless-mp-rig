#!/usr/bin/env bash
# repro-template.sh — replaced by scenario directories. A targeted feature or bug repro is now a
# scenario: scenario.conf + steps.sh, run and judged by the runner.
#   bin/rig new scenarios/local/my-repro --content <profile> --players "a b"   # scaffold (templates/scenario/)
#   bin/rig lint scenarios/local/my-repro && bin/rig run scenarios/local/my-repro
# The method (server-side setup, drive a real client, assert from the logs): docs/FEATURE-TESTS.md.
# The format and verbs: docs/SCENARIO-FORMAT.md. Library calls (lib/rig.sh) remain for custom tooling.
echo "repro-template.sh is replaced by: bin/rig new <dir> --content <profile> (see the header of $0)" >&2
exit 64
