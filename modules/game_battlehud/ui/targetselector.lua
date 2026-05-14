-- ui/targetselector.lua
--
-- Renders selectable targets for a move/item choice. The contract §3.6
-- enumerates the legal target-ref strings; the HUD never invents extras.

local TargetSelector = {}

local Locale = require('locale.init')

-- For an opponent active mon, name comes from publicState.<slot>:active
-- only if revealed; otherwise we use a generic "Opposing Pokémon".
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
        if p.active.speciesName then
          return p.active.speciesName
        end
      elseif kind == 'bench' and p.bench then
        local idx = tonumber(benchIdx) + 1
        local b = p.bench[idx]
        if b and b.speciesName then return b.speciesName end
      end
    end
  end
  return ref
end

-- Build the list of targetable refs for a given move definition. v1 ships
-- single-target only; multi-target keywords come straight from the move's
-- `target` field (§3.1.active_mon.moves[].target).
function TargetSelector.optionsFor(state, move)
  if not move then return {} end
  local out = {}
  local t = move.target
  if t == 'opponent_active' then
    -- v1 is 1v1, so the only opponent active is the other slot.
    local opponentSlot = (state.you and state.you.slot == 'A') and 'B' or 'A'
    out[#out + 1] = {
      ref = opponentSlot .. ':active',
      label = Locale.t('battle.target.opponent_active', { name = nameFor(state, opponentSlot .. ':active') }),
    }
  elseif t == 'self' then
    local ownSlot = state.you and state.you.slot or 'A'
    out[#out + 1] = {
      ref = 'self',
      label = Locale.t('battle.target.self'),
    }
  elseif t == 'all_enemies' then
    out[#out + 1] = { ref = 'all_enemies', label = Locale.t('battle.target.all_enemies') }
  elseif t == 'all_allies' then
    out[#out + 1] = { ref = 'all_allies', label = Locale.t('battle.target.all_allies') }
  elseif t == 'all' then
    out[#out + 1] = { ref = 'all', label = Locale.t('battle.target.all') }
  else
    -- Unknown target keyword — be permissive and present nothing rather
    -- than guess. Server will reject `invalid_choice` if we ever sent
    -- something off-contract.
  end
  return out
end

-- Bench switch targets for `switch` kind. Restricted to own bench (§3.2).
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
