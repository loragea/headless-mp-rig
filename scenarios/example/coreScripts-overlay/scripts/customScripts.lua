-- customScripts.lua — OVERLAY for the example scenario's runtime CoreScripts work-copy.
--
-- The example runner (bin/run-example.sh) builds a throwaway copy of the shared CoreScripts and
-- drops this file over its scripts/customScripts.lua so the server loads ONLY the example-suite
-- compatibility shim — not the Morrowind-specific playtest hook the shared tree loads. Keeping this
-- minimal is deliberate: the example must run on free content alone, with no Morrowind assumptions.

require("custom/example-suite-compat")
