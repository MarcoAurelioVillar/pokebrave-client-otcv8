-- ui_targetselector.lua  (was ui/targetselector.lua — flattened for OTCv8 compatibility)
--
-- Renders selectable targets for a move/item choice.

local TargetSelector = {}

local Locale = require('locale')

local function nameFor(state, ref)
  local slot, kind = ref:match('^(%a):(%a+)$')
  local benchIdx = nil
  if not slot then
    slot, kind, benchIdx = ref:match('^(%a):(%a+):(%d+)$')
  end
  if slot then
    local p = state.participants[slot]
    if p then
      if kind == 'active' and p.active then
        if p.active.speciesName then return p.active.speciesName end
      elseif kind == 'bench' and p.bench then
        local idx = tonumber(benchIdx) + 1
        local b = p.bench[idx]
        if b and b.speciesName then return b.speciesName end
      end
    end
  end
  return ref
end

function TargetSelector.optionsFor(state, move)
  if not move then return {} end
  local out = {}
  local t = move.target
  if t == 'opponent_active' then
    local opponentSlot = (state.you and state.you.slot == 'A') and 'B' or 'A'
    out[#out + 1] = {
      ref = opponentSlot .. ':active',
      label = Locale.t('battle.target.opponent_active', { name = nameFor(state, opponentSlot .. ':active') }),
    }
  elseif t == 'self' then
    out[#out + 1] = { ref = 'self', label = Locale.t('battle.target.self') }
  elseif t == 'all_enemies' then
    out[#out + 1] = { ref = 'all_enemies', label = Locale.t('battle.target.all_enemies') }
  elseif t == 'all_allies' then
    out[#out + 1] = { ref = 'all_allies', label = Locale.t('battle.target.all_allies') }
  elseif t == 'all' then
    out[#out + 1] = { ref = 'all', label = Locale.t('battle.target.all') }
  end
  return out
end

function TargetSelector.switchOptions(state)
  local out = {}
  local p = state.you and state.participants and state.participants[state.you.slot] or nil
  if not p or type(p.bench) ~= 'table' then return out end
  for i, b in ipairs(p.bench) do
    if not b.fainted then
      out[#out + 1] = {
        ref = state.you.slot .. ':bench:' .. (i - 1),
        label = Locale.t('battle.target.bench', { name = b.speciesName or ('#' .. i) }),
      }
    end
  end
  return out
end

return TargetSelector
