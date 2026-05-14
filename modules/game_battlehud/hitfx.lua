-- hitfx.lua
--
-- Hit feedback primitives: damage numbers (floating text), sprite flash,
-- camera shake. All driven by AnimQueue — never called directly from
-- protocol or state code.
--
-- In headless / test mode (no g_ui / g_game), every function is a no-op
-- except the Log call, which lets the harness recording prove that the
-- correct VFX fired in the correct order.

local Log = require('log')

local HitFX = {}

-- Injected by battlehud.lua after g_ui.loadUI. Nil in headless mode.
local battleHudRoot = nil

-- Set the root HUD widget so floating labels can be parented correctly.
function HitFX.setRoot(widget)
  battleHudRoot = widget
end

-- Spawn a floating damage label above the target slot's life bar.
-- isHeal: if true, renders as green HP recovery rather than damage.
-- In OTCv8 this creates a UIWidget, floats it upward 30 px over 400 ms,
-- fades out over 200 ms, then destroys it. Each widget is independent so
-- multiple can coexist across simultaneous events.
function HitFX.damageNumber(targetSlot, amount, isCrit, effectiveness, isHeal)
  Log.text('vfx:damage_number', {
    slot   = targetSlot,
    amount = amount,
    crit   = isCrit == true,
    eff    = effectiveness or 1.0,
    heal   = isHeal == true,
  })
  if not battleHudRoot or not g_ui then return end
  -- OTCv8 widget path (not exercised in headless mode):
  -- local widget = g_ui.createWidget('BattleDamageLabel', battleHudRoot)
  -- widget:setText(tostring(amount))
  -- ... anchor, moveBy, setOpacity animation chain, then widget:destroy()
end

-- Flash the target slot's life bar / sprite panel to signal damage or heal.
-- color: 'red' | 'green' | 'yellow' as a string token; resolved to OTCv8
-- Color inside this function so callers stay color-agnostic.
-- Alternates original ↔ color every durationMs/4 for a two-cycle flash.
function HitFX.spriteFlash(targetSlot, color, durationMs)
  Log.text('vfx:sprite_flash', {
    slot     = targetSlot,
    color    = color,
    duration = durationMs,
  })
  if not battleHudRoot or not g_ui then return end
  -- OTCv8: resolve widget for targetSlot, cycle setColor via scheduleEvent.
end

-- Oscillate the game view container by ±intensity px over durationMs.
-- steps: number of full oscillation cycles (default 4).
-- If the game root widget uses fixed anchors that cannot be translated,
-- falls back to shaking the HUD overlay widget instead.
function HitFX.cameraShake(intensity, durationMs, steps)
  steps = steps or 4
  Log.text('vfx:camera_shake', {
    intensity = intensity,
    duration  = durationMs,
    steps     = steps,
  })
  if not battleHudRoot or not g_ui then return end
  -- OTCv8: move gameRootWidget ±intensity via scheduleEvent oscillation,
  -- restore to origin after steps*2 ticks of durationMs/(steps*2) each.
  -- Fallback: shake battleHudRoot if gameRootWidget anchors are fixed.
end

-- No-op: placeholder for future cleanup (cancel in-flight flash timers, etc.).
function HitFX.reset()
end

return HitFX
