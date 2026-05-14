-- ui_actionlist.lua  (was ui/actionlist.lua — flattened for OTCv8 compatibility)
--
-- Renders the action list against the choiceWindow the server published.

local ActionList = {}

local Locale = require('locale')

function ActionList.render(widget, hudState)
  if not widget then return end
  local valid = hudState:validActions()
  local actions = { move = false, item = false, switch = false, surrender = false }
  if valid then
    for _, a in ipairs(valid) do actions[a] = true end
  end
  local function setEnabled(id, enabled)
    local child = widget.getChildById and widget:getChildById(id) or nil
    if child and child.setEnabled then child:setEnabled(enabled) end
  end
  setEnabled('moveBtn', actions.move == true)
  setEnabled('itemBtn', actions.item == true)
  setEnabled('switchBtn', actions.switch == true)
  setEnabled('surrenderBtn', actions.surrender == true)
end

function ActionList.label(actionKind)
  return Locale.t('battle.action.' .. actionKind)
end

return ActionList
