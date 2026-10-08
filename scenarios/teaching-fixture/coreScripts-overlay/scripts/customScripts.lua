-- customScripts.lua — the server-side scripts every teaching scenario loads (OVERLAY= in their
-- scenario.conf). The rig layers this over a throwaway copy of your CoreScripts; your clone is
-- never written. The rig's own bridge is appended after these lines.
require("custom/example-suite-compat")   -- stock CoreScripts assume Morrowind; this keeps them alive
require("custom/teaching-breath")        -- water breathing at login: the free world is underwater
