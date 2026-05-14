-- ui/actionlist.lua
--
-- Renders the action list against the choiceWindow the server published.
-- Buttons are enabled iff the server listed that action in `valid.actions`.

local ActionList = {}

local Locale = require('locale.init')

function ActionList.render(widget, hudState)
  if not widget then return end
  local valid = hudState:validActions()
  local actions = { move = false, item = false, switch = false, surrender = false }
  if valid then
    for _, a in ipairs(valid) do actions[a] = true end
  end
  -- These widget calls are the OTCv8 path; in the headless harness the
  -- widget shim records the call and we observe via the log.
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
