-- ui/turnorder.lua
--
-- Renders the turn-order bar from `events[0].order` (§3.7). Raw stats are
-- never visible — only the server-computed `effectiveSpeed` and `priority`.

local TurnOrder = {}

local Locale = require('locale.init')

local function clear(widget)
  if widget and widget.destroyChildren then widget:destroyChildren() end
end

-- Build the visual model the UI should display. Returns a list of rows;
-- the test harness inspects this directly without an OTCv8 widget.
function TurnOrder.fromResolveBody(body)
  local rows = {}
  if type(body) ~= 'table' or type(body.events) ~= 'table' then return rows end
  local first = body.events[1]
  if not first or first.kind ~= 'choices_locked' or type(first.order) ~= 'table' then
    return rows
  end
  for i, o in ipairs(first.order) do
    rows[#rows + 1] = {
      index = i,
      slot = o.slot,
      priority = o.priority,
      effectiveSpeed = o.effectiveSpeed,
      label = Locale.t('battle.turnorder.slot', { slot = o.slot })
        .. '  ' .. Locale.t('battle.turnorder.speed', { speed = o.effectiveSpeed }),
    }
  end
  return rows
end

function TurnOrder.render(widget, body)
  local container = widget and widget.getChildById and widget:getChildById('slots') or nil
  if not container then return TurnOrder.fromResolveBody(body) end
  clear(container)
  local rows = TurnOrder.fromResolveBody(body)
  for _, row in ipairs(rows) do
    local slot = g_ui and g_ui.createWidget('TurnOrderSlot', container) or nil
    if slot and slot.setText then slot:setText(row.label) end
  end
  return rows
end

return TurnOrder
