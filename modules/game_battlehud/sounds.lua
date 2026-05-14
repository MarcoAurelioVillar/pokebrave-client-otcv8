-- sounds.lua
--
-- Sound hook table + playback helper for battle VFX.
-- Wraps g_sounds with a nil-guard so the battle never crashes if the
-- OTCv8 fork does not expose the audio API.
-- All sound keys are local constants; no English strings or hardcoded paths
-- outside this file.

local Log = require('log')

local Sounds = {}

-- Asset path map. Use a silent placeholder .ogg if real files are absent.
local ASSETS = {
  hit    = 'sfx/hit.ogg',
  crit   = 'sfx/crit.ogg',
  miss   = 'sfx/miss.ogg',
  faint  = 'sfx/faint.ogg',
  status = 'sfx/status.ogg',
  -- level_up deferred: event not in v1 contract. Wire when Phase f adds it.
}

-- Play the sound keyed by soundKey. Logs the call for observability.
-- No-ops silently if the key is unknown or g_sounds is unavailable.
function Sounds.play(soundKey)
  Log.text('sfx:play', { key = soundKey })
  local path = ASSETS[soundKey]
  if not path then return end
  if g_sounds and g_sounds.play then
    local ok, err = pcall(g_sounds.play, g_sounds, path)
    if not ok then
      Log.decode_error({ code = 'sfx_error', key = soundKey, err = tostring(err) })
    end
  end
end

-- No-op: placeholder for future audio context teardown (e.g. stop looping SFX).
function Sounds.reset()
end

return Sounds
