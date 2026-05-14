-- prediction.lua
--
-- Visual prediction layer. The HUD may render a predicted state between
-- sending a `battle:choices` and receiving the matching `battle:resolve`,
-- but predictions are visual hints only (client-side hint, server-side
-- truth lens). When the resolve arrives, we reconcile to `publicState`;
-- if the prediction was wrong we record a mispredict and snap.

local Prediction = {}
Prediction.__index = Prediction

function Prediction.new()
  local self = setmetatable({}, Prediction)
  self.pending = {} -- map: clientNonce -> { turn, choice, predicted = { ... } }
  self.lastMispredict = nil
  return self
end

-- Register a pending visual prediction. Returns the prediction id (clientNonce)
-- so the UI can correlate. The prediction body is opaque to this module;
-- it is whatever the UI layer wants to remember about the visual hint
-- (e.g. "I started a thunderbolt animation toward B:active").
function Prediction:register(clientNonce, turn, choice, predicted)
  self.pending[clientNonce] = {
    turn = turn,
    choice = choice,
    predicted = predicted,
  }
end

-- Reconcile against a resolve body. Returns a list of structured reconcile
-- events the UI can render: `reconciled` (prediction matched), `mispredict`
-- (server disagreed; snap to authoritative state).
function Prediction:reconcile(resolveBody)
  local out = {}
  local choicesLocked = nil
  for _, evt in ipairs(resolveBody.events or {}) do
    if evt.kind == 'choices_locked' then
      choicesLocked = evt
      break
    end
  end
  if not choicesLocked or type(choicesLocked.bySlot) ~= 'table' then
    -- Nothing to reconcile against; drop pending and return.
    for k in pairs(self.pending) do self.pending[k] = nil end
    return out
  end
  -- Walk pending predictions; match by clientNonce echoed in bySlot.<slot>.clientNonce (§3.2).
  for slot, locked in pairs(choicesLocked.bySlot) do
    local nonce = locked.clientNonce
    if nonce ~= nil and self.pending[nonce] then
      local p = self.pending[nonce]
      local mismatch = false
      local mismatchReason = nil
      if p.choice.kind ~= locked.kind then
        mismatch = true
        mismatchReason = 'kind:' .. tostring(p.choice.kind) .. '->' .. tostring(locked.kind)
      elseif p.choice.kind == 'move' and (p.choice.moveId ~= locked.moveId or p.choice.target ~= locked.target) then
        mismatch = true
        mismatchReason = 'move_or_target'
      elseif p.choice.kind == 'switch' and p.choice.switchTo ~= locked.switchTo then
        mismatch = true
        mismatchReason = 'switchTo'
      elseif p.choice.kind == 'item' and (p.choice.itemId ~= locked.itemId or p.choice.itemTarget ~= locked.itemTarget) then
        mismatch = true
        mismatchReason = 'item_or_target'
      end
      if mismatch then
        out[#out + 1] = {
          kind = 'mispredict',
          slot = slot,
          predicted = p.predicted,
          authoritative = locked,
          reason = mismatchReason,
        }
        self.lastMispredict = out[#out]
      else
        out[#out + 1] = {
          kind = 'reconciled',
          slot = slot,
          predicted = p.predicted,
        }
      end
      self.pending[nonce] = nil
    end
  end
  -- Any pending predictions that didn't correlate to a locked choice are
  -- dropped silently; the server has spoken.
  for k in pairs(self.pending) do
    out[#out + 1] = { kind = 'mispredict', reason = 'no_match', predicted = self.pending[k].predicted }
    self.lastMispredict = out[#out]
    self.pending[k] = nil
  end
  return out
end

function Prediction:dropAll()
  for k in pairs(self.pending) do self.pending[k] = nil end
end

return Prediction
