-- ui/textlog.lua
--
-- Walks the `events` array of a `battle:resolve` body in `seq` order and
-- emits one localized line per renderable event. Replay-invariant: a
-- post-mortem viewer reading the same events should produce the same
-- lines.

local TextLog = {}

local Locale = require('locale.init')

local function actorName(state, slotOrRef)
  if not slotOrRef then return '?' end
  local slot = slotOrRef:match('^(%a)') or slotOrRef
  local p = state.participants[slot]
  if p and p.active and p.active.speciesName then return p.active.speciesName end
  return slot
end

local function effectivenessKey(amount, effectiveness)
  if effectiveness == nil then return 'battle.event.damage' end
  if effectiveness > 1.0 then return 'battle.event.damage.super' end
  if effectiveness < 1.0 and effectiveness > 0 then return 'battle.event.damage.not_very' end
  return 'battle.event.damage'
end

-- Render a single event into a localized line. Returns nil for events that
-- should not appear in the text log (e.g. choices_locked, action_start of
-- a switch with no narrative).
function TextLog.lineForEvent(state, evt)
  local k = evt.kind
  if k == 'choices_locked' then return nil end
  if k == 'action_start' then
    local sub = (evt.action and evt.action.kind) or 'move'
    local key = 'battle.event.action_start.' .. sub
    local move = evt.action and evt.action.moveId or ''
    local actor = actorName(state, evt.slot)
    if sub == 'move' then
      return Locale.t(key, { actor = actor, move = move })
    elseif sub == 'switch' then
      return Locale.t(key, { actor = actor })
    elseif sub == 'item' then
      return Locale.t(key, { actor = actor, item = evt.action.itemId or '' })
    elseif sub == 'surrender' then
      return Locale.t(key, { actor = actor })
    end
    return Locale.t('battle.event.action_start.move', { actor = actor, move = move })
  end
  if k == 'damage' then
    local key = effectivenessKey(evt.amount, evt.effectiveness)
    if evt.crit then key = 'battle.event.damage.crit' end
    return Locale.t(key, { target = actorName(state, evt.target), amount = evt.amount or 0 })
  end
  if k == 'heal' then
    return Locale.t('battle.event.heal', { target = actorName(state, evt.target), amount = evt.amount or 0 })
  end
  if k == 'status_inflict' then
    local statusName = evt.status and evt.status.name or 'status'
    local localized = Locale.t('battle.status.' .. statusName)
    return Locale.t('battle.event.status_inflict', { target = actorName(state, evt.target), status = localized })
  end
  if k == 'status_clear' then
    local statusName = evt.status and evt.status.name or 'status'
    local localized = Locale.t('battle.status.' .. statusName)
    return Locale.t('battle.event.status_clear', { target = actorName(state, evt.target), status = localized })
  end
  if k == 'stat_change' then
    local dir = (evt.delta or 0) >= 0 and 'up' or 'down'
    return Locale.t('battle.event.stat_change.' .. dir, { target = actorName(state, evt.target), stat = evt.stat or 'stat' })
  end
  if k == 'switch' then
    return Locale.t('battle.event.switch', {
      out_name = actorName(state, evt.out or evt.slot),
      in_name = actorName(state, evt.in_ or evt.slot),
    })
  end
  if k == 'item_used' then
    return Locale.t('battle.event.item_used', { actor = actorName(state, evt.slot), item = evt.itemId or '' })
  end
  if k == 'action_skipped' then
    local key = 'battle.event.action_skipped.' .. (evt.reason or 'interrupt')
    if not Locale.has(key) then key = 'battle.event.action_skipped.interrupt' end
    return Locale.t(key, { actor = actorName(state, evt.slot) })
  end
  if k == 'faint' then
    return Locale.t('battle.event.faint', { target = actorName(state, evt.target) })
  end
  if k == 'turn_end_tick' then
    local key = 'battle.event.turn_end_tick.' .. (evt.effect or '')
    if not Locale.has(key) then return nil end
    return Locale.t(key, { target = actorName(state, evt.slot) })
  end
  if k == 'text' then
    if Locale.has(evt.key or '') then return Locale.t(evt.key, evt.args) end
    return Locale.t('battle.event.text.fallback', { key = evt.key or '?' })
  end
  -- Unknown event kind — log a stub and continue (§9.1 additive rule).
  return nil
end

function TextLog.linesForResolve(state, body)
  local out = {}
  if type(body) ~= 'table' or type(body.events) ~= 'table' then return out end
  -- Sort by seq just to be safe.
  local events = {}
  for _, e in ipairs(body.events) do events[#events + 1] = e end
  table.sort(events, function(a, b) return (a.seq or 0) < (b.seq or 0) end)
  for _, e in ipairs(events) do
    local line = TextLog.lineForEvent(state, e)
    if line then out[#out + 1] = line end
  end
  return out
end

function TextLog.render(widget, lines)
  if not widget then return lines end
  local container = widget.getChildById and widget:getChildById('lines') or nil
  if not container then return lines end
  for _, ln in ipairs(lines) do
    local w = g_ui and g_ui.createWidget('TextLogLine', container) or nil
    if w and w.setText then w:setText(ln) end
  end
  return lines
end

return TextLog
