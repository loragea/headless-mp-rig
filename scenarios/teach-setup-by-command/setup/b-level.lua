-- b-level.lua — a multi-line server Lua chunk, sent with `server-file b setup/b-level.lua`.
-- It runs inside the server with `pid` and `player` bound to b. `$P_LEVEL` is replaced by the
-- scenario.conf value before it is sent; nothing else is substituted.
-- Change the server's record, then send it to the client: the CoreScripts Load* methods do both.
player.data.stats.level = $P_LEVEL
player:LoadLevel()
return player.data.stats.level      -- a returned value shows in the step's detail ("returned 5")
