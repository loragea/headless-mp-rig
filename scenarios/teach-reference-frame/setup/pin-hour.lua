-- pin-hour.lua — set the world clock to $P_HOUR and stop it, for every player (server-file).
-- Lighting follows the hour: a reference frame taken at another hour is a different picture.
-- A time scale of 0 stops the clock, so the light stays the same until the shot.
WorldInstance.data.time.hour = $P_HOUR
WorldInstance.data.time.dayTimeScale = 0
WorldInstance.data.time.nightTimeScale = 0
WorldInstance:UpdateFrametimeMultiplier()
WorldInstance:LoadTime(pid, true)                   -- true: send the time to every player
