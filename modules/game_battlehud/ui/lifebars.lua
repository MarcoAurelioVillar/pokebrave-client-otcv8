-- ui/lifebars.lua
--
-- Life bars are read from `state.publicState` only. publicState is the
-- canonical post-turn snapshot (§3.3) so a life bar that reflects it is by
-- definition reconciled.

local LifeBars = {}

local Locale = require('locale.init')

local function statusLabel(status)
  if not status or not status.name then return '' end
  local key = 'battle.status.' .. status.name
  return Locale.t(key)
end

function LifeBars.modelFor(state, slot)
  local ref = slot .. ':active'
  local ps = state.publicState[ref]
  local p = state.participants[slot]
  local name = p and p.active and p.active.speciesName or '?'
  local level = p and p.active and p.active.level or 0
  if not ps then
    return { name = name, level = level, hp_current = 0, hp_max = 0, status = '', fainted = false }
  end
  return {
    name = name,
    level = level,
    hp_current = (ps.hp and ps.hp.current) or 0,
    hp_max = (ps.hp and ps.hp.max) or 0,
    status = statusLabel(ps.status),
    fainted = ps.fainted == true,
  }
end

function LifeBars.render(widget, state, slot)
  local model = LifeBars.modelFor(state, slot)
  if not widget then return model end
  local name = widget.getChildById and widget:getChildById('nameLabel') or nil
  local hpBar = widget.getChildById and widget:getChildById('hpBar') or nil
  local hpLbl = widget.getChildById and widget:getChildById('hpLabel') or nil
  local lvLbl = widget.getChildById and widget:getChildById('levelLabel') or nil
  local stLbl = widget.getChildById and widget:getChildById('statusLabel') or nil
  if name and name.setText then name:setText(model.name) end
  if lvLbl and lvLbl.setText then lvLbl:setText('Lv ' .. tostring(model.level)) end
  if hpLbl and hpLbl.setText then
    hpLbl:setText(Locale.t('battle.life.hp', { current = model.hp_current, max = model.hp_max }))
  end
  if stLbl and stLbl.setText then stLbl:setText(model.status) end
  if hpBar and hpBar.setPercent then
    local pct = 0
    if model.hp_max > 0 then pct = math.max(0, math.min(100, math.floor((model.hp_current / model.hp_max) * 100))) end
    hpBar:setPercent(pct)
  end
  return model
end

-- Post-drain authority snap called by AnimQueue after all events in a turn
-- have been processed. Corrects any visual drift vs. server's publicState.
-- Lenses: authoritative-server, client-side-hint-server-side-truth.
-- No-op in headless / test mode (no widget references available here).
function LifeBars.reconcile(publicState)
  if not publicState then return end
  -- Full widget reconcile would re-render each slot from publicState directly.
  -- The existing render path (battlehud._render on 'resolve') already applies
  -- publicState to widgets synchronously; this is the post-animation correction
  -- hook for when prediction overlays add visual drift (Phase i+).
end

return LifeBars
