-- battlehud.lua
--
-- Entry point for the OTCv8 `game_battlehud` module. Bound by
-- battlehud.otmod via @onLoad/@onUnload.
--
-- This file is the only place that touches OTCv8 globals (g_game, g_ui,
-- g_modules, connect/disconnect, scheduleEvent). All actual decoding,
-- session state, prediction, and HUD rendering live in pure-Lua modules
-- under this directory so they can be unit-tested without OTCv8.

BattleHud = {}

-- OTCv8's built-in module resolver treats dots as literal characters, not as
-- directory separators, so require('locale.init') and require('ui.X') fail
-- unless the module directory is in package.path. Add it here when running
-- inside OTCv8 (g_modules is non-nil); the headless harness injects the
-- correct paths itself before calling require('battlehud').
if g_modules then
  local p = g_modules.getModule('game_battlehud'):getPath()
  package.path = p .. '/?.lua;' .. p .. '/?/init.lua;' .. package.path
end

local Protocol    = require('protocol')
local State       = require('state')
local Prediction  = require('prediction')
local Events      = require('events')
local Log         = require('log')
local Locale      = require('locale.init')
local ActionList     = require('ui.actionlist')
local TurnOrder      = require('ui.turnorder')
local TargetSelector = require('ui.targetselector')
local LifeBars       = require('ui.lifebars')
local TextLog        = require('ui.textlog')
local AnimQueue      = require('animqueue')
local HitFX          = require('hitfx')
local Sounds         = require('sounds')

local window = nil
local state = nil
local prediction = nil
local events = nil
local pendingTarget = nil -- when the user picked a move but hasn't picked a target

local function makeIdProvider()
  -- ULID-ish ids; OTCv8 doesn't have a built-in ULID library. We compose
  -- a high-entropy id from a monotonic counter and the current ms clock.
  local counter = 0
  return function()
    counter = counter + 1
    return string.format('%013d%06d', os.time() * 1000, counter)
  end
end

local function nowMs()
  if g_clock and g_clock.millis then return g_clock.millis() end
  return os.time() * 1000
end

local function sendExtendedOpcode(payload)
  if g_game and g_game.sendExtendedOpcode then
    g_game.sendExtendedOpcode(Protocol.EXTENDED_OPCODE, payload)
  end
end

local function bindJson()
  -- OTCv8's vendored json lib varies by fork. We try a few names and
  -- fall back to a small embedded one for tests via tools/json.lua.
  local cjson_ok, cjson = pcall(require, 'cjson')
  if cjson_ok and cjson then
    Protocol.setJson(cjson.encode, cjson.decode)
    return
  end
  local rxi_ok, rxi = pcall(require, 'vendor.json')
  if rxi_ok and rxi then
    Protocol.setJson(rxi.encode, rxi.decode)
    return
  end
  -- Last resort: the harness injects its own json before init().
  error('battlehud: no JSON provider available; tools/harness.lua injects one')
end

function BattleHud.init()
  state = State.new()
  prediction = Prediction.new()
  Log.setClock(nowMs)
  pcall(bindJson)
  events = Events.new({
    state = state,
    prediction = prediction,
    send = sendExtendedOpcode,
    idProvider = makeIdProvider(),
    clock = nowMs,
    locale = Locale,
  })

  -- Wire the OTCv8 scheduler so AnimQueue delays real animation durations.
  if scheduleEvent then
    AnimQueue.setScheduler(function(delayMs, cb) scheduleEvent(cb, delayMs) end)
  end
  AnimQueue.reset()

  if g_ui and g_ui.loadUI then
    window = g_ui.displayUI('ui/battlehud.otui')
    if window and window.hide then window:hide() end
    HitFX.setRoot(window)
  end

  if ProtocolGame and ProtocolGame.registerExtendedOpcode then
    ProtocolGame.registerExtendedOpcode(Protocol.EXTENDED_OPCODE, function(_, payload)
      BattleHud._onExtendedOpcode(payload)
    end)
  end

  if connect and g_game then
    connect(g_game, {
      onGameEnd = BattleHud._onGameEnd,
      onConnectionError = BattleHud._onConnectionDrop,
    })
  end

  -- Observer: dispatch VFX unconditionally, then render widgets.
  -- VFX dispatch must NOT be gated by window so it works in headless/test mode.
  events:subscribe(function(kind, envelope)
    BattleHud._onEvent(kind, envelope)
  end)
end

function BattleHud.terminate()
  if window and window.destroy then window:destroy() end
  window = nil
  if ProtocolGame and ProtocolGame.unregisterExtendedOpcode then
    ProtocolGame.unregisterExtendedOpcode(Protocol.EXTENDED_OPCODE)
  end
  if disconnect and g_game then
    disconnect(g_game, {
      onGameEnd = BattleHud._onGameEnd,
      onConnectionError = BattleHud._onConnectionDrop,
    })
  end
  events = nil
  state = nil
  prediction = nil
end

-- --- inbound -----------------------------------------------------------------

function BattleHud._onExtendedOpcode(payload)
  if not events then return end
  events:receive(payload)
end

function BattleHud._onConnectionDrop()
  -- Flush before any arena teardown so pending drainNext callbacks are no-ops.
  -- Lenses: anti-desync, arena-isolation.
  AnimQueue.flush()
  HitFX.reset()
  Sounds.reset()
  if events then events:onDisconnect() end
  if window and state then
    local statusLbl = window.getChildById and window:getChildById('statusLabel') or nil
    if statusLbl and statusLbl.setText then
      statusLbl:setText(Locale.t('battle.hud.paused'))
    end
  end
end

function BattleHud._onGameEnd()
  -- Game-level disconnect, not just a socket blip.
  BattleHud._onConnectionDrop()
end

-- --- outbound ---------------------------------------------------------------

function BattleHud.onAction(actionKind)
  if not events or not state then return end
  if actionKind == 'move' then
    -- Pick the player's first available move for the MVP "pick move" path;
    -- richer move pickers come in DEV-10 polish. The HUD never sends an
    -- arbitrary move — only ones the server gave us in active.moves.
    local own = state.you and state.participants[state.you.slot] or nil
    if not own or not own.active or not own.active.moves or #own.active.moves == 0 then
      return
    end
    -- Choose the move via a one-of buttons in a richer build; for the MVP
    -- we open the target selector for moves[1]. The selector publishes the
    -- final `battle:choices`.
    pendingTarget = own.active.moves[1]
    BattleHud._openTargetSelector(pendingTarget)
  elseif actionKind == 'switch' then
    -- Open the switch selector (MVP: skip if no bench).
    local options = TargetSelector.switchOptions(state)
    if #options == 0 then return end
    BattleHud._showSwitchOptions(options)
  elseif actionKind == 'surrender' then
    BattleHud.submit({ kind = 'surrender' })
  elseif actionKind == 'item' then
    -- Items are content-pack; v1 HUD shows the action but no items ship.
  end
end

function BattleHud._openTargetSelector(move)
  if not window then return end
  local panel = window.getChildById and window:getChildById('targetSelector') or nil
  if panel and panel.show then panel:show() end
  local list = panel and panel.getChildById and panel:getChildById('targetList') or nil
  if list and list.destroyChildren then list:destroyChildren() end
  local options = TargetSelector.optionsFor(state, move)
  -- v1 single-target moves only have one option; auto-confirm to keep the
  -- click count low while still going through the same code path.
  if #options == 1 then
    BattleHud.submit({ kind = 'move', moveId = move.moveId, target = options[1].ref })
    if panel and panel.hide then panel:hide() end
    return
  end
  for _, opt in ipairs(options) do
    local entry = g_ui and g_ui.createWidget('TargetSelectorEntry', list) or nil
    if entry then
      if entry.setText then entry:setText(opt.label) end
      if entry.onClick then
        entry.onClick = function()
          BattleHud.submit({ kind = 'move', moveId = move.moveId, target = opt.ref })
          if panel and panel.hide then panel:hide() end
        end
      end
    end
  end
end

function BattleHud._showSwitchOptions(options)
  if not window then return end
  local panel = window.getChildById and window:getChildById('targetSelector') or nil
  if panel and panel.show then panel:show() end
  local list = panel and panel.getChildById and panel:getChildById('targetList') or nil
  if list and list.destroyChildren then list:destroyChildren() end
  for _, opt in ipairs(options) do
    local entry = g_ui and g_ui.createWidget('TargetSelectorEntry', list) or nil
    if entry then
      if entry.setText then entry:setText(opt.label) end
      if entry.onClick then
        entry.onClick = function()
          BattleHud.submit({ kind = 'switch', switchTo = opt.ref })
          if panel and panel.hide then panel:hide() end
        end
      end
    end
  end
end

function BattleHud.cancelTargetSelector()
  pendingTarget = nil
  if not window then return end
  local panel = window.getChildById and window:getChildById('targetSelector') or nil
  if panel and panel.hide then panel:hide() end
end

function BattleHud.submit(choice)
  if not events then return end
  -- The visual prediction is just a tag the UI uses to identify its hint;
  -- the actual animation work is in DEV-10 polish.
  local predicted = { choice = choice }
  local nonce, err = events:submitChoice(choice, predicted)
  if not nonce then
    BattleHud._showError(err)
  end
end

function BattleHud.requestSurrender()
  BattleHud.submit({ kind = 'surrender' })
end

-- --- event dispatch (VFX + render) -----------------------------------------

-- Called for every opcode event. VFX operations run unconditionally so they
-- are observable in headless/test mode. Widget rendering follows and is gated
-- by window as usual.
function BattleHud._onEvent(kind, envelope)
  -- On reconnect: flush orphaned animations before rebuilding HUD from snapshot.
  -- Lenses: anti-desync, arena-isolation.
  if kind == 'snapshot' then
    AnimQueue.flush()
    HitFX.reset()
    Sounds.reset()
    AnimQueue.reset()
  end

  -- Push VFX for all resolve events in seq order. Drain is async in OTCv8
  -- (scheduleEvent) and synchronous in headless/test mode.
  if kind == 'resolve' and envelope and envelope.body then
    AnimQueue.push(envelope.body.events, envelope.body.publicState)
  end

  -- Flush VFX on battle end before freezing input.
  if kind == 'end' then
    AnimQueue.flush()
    HitFX.reset()
    Sounds.reset()
  end

  BattleHud._render(kind, envelope)
end

-- --- rendering -------------------------------------------------------------

function BattleHud._render(kind, envelope)
  if not window then return end
  if window.show and (kind == 'start' or kind == 'snapshot') then window:show() end

  -- Header.
  local turnLbl = window.getChildById and window:getChildById('turnLabel') or nil
  if turnLbl and turnLbl.setText then
    turnLbl:setText(Locale.t('battle.hud.turn', { turn = state.turn }))
  end
  local statusLbl = window.getChildById and window:getChildById('statusLabel') or nil
  if statusLbl and statusLbl.setText then
    if state.lifecycle == 'awaiting_choices' and state:validActions() ~= nil then
      statusLbl:setText(Locale.t('battle.hud.your_turn'))
    elseif state.lifecycle == 'forced_switch' then
      statusLbl:setText(Locale.t('battle.hud.forced_switch'))
    elseif state.lifecycle == 'paused_for_reconnect' then
      statusLbl:setText(Locale.t('battle.hud.paused'))
    else
      statusLbl:setText(Locale.t('battle.hud.waiting_opponent'))
    end
  end

  -- Action list, life bars.
  local actionPanel = window.getChildById and window:getChildById('actionList') or nil
  ActionList.render(actionPanel, state)
  for _, slot in ipairs({'A', 'B'}) do
    local panelId = (state.you and state.you.slot == slot) and 'playerLifeBar' or 'opponentLifeBar'
    local panel = window.getChildById and window:getChildById(panelId) or nil
    LifeBars.render(panel, state, slot)
  end

  -- Turn-order bar + text log only have something fresh on `resolve`.
  if kind == 'resolve' and envelope and envelope.body then
    local toBar = window.getChildById and window:getChildById('turnOrderBar') or nil
    TurnOrder.render(toBar, envelope.body)
    local logPanel = window.getChildById and window:getChildById('textLog') or nil
    local lines = TextLog.linesForResolve(state, envelope.body)
    TextLog.render(logPanel, lines)
  end

  -- End: show outcome line in the text log.
  if kind == 'end' and envelope and envelope.body then
    local outcomeKey = 'battle.outcome.draw'
    if state.outcome and state.outcome.winner then
      if state.you and state.outcome.winner == state.you.slot then outcomeKey = 'battle.outcome.win'
      elseif state.outcome.winner == 'draw' then outcomeKey = 'battle.outcome.draw'
      elseif state.outcome.winner == 'aborted' then outcomeKey = 'battle.outcome.aborted'
      else outcomeKey = 'battle.outcome.loss' end
    end
    local reasonKey = 'battle.end.reason.' .. (state.outcomeReason or 'ko')
    local logPanel = window.getChildById and window:getChildById('textLog') or nil
    local line = Locale.t(outcomeKey) .. ' ' .. Locale.t(reasonKey)
    TextLog.render(logPanel, { line })
  end
end

function BattleHud._showError(err)
  if not err then return end
  local key = 'battle.error.' .. (err.code or 'unknown')
  local line = Locale.has(key) and Locale.t(key, { code = err.code, message = err.message })
                                or Locale.t('battle.error.unknown', { code = err.code or '?' })
  if window then
    local logPanel = window.getChildById and window:getChildById('textLog') or nil
    TextLog.render(logPanel, { line })
  end
end

-- Expose internals for the headless harness and unit tests.
BattleHud._internal = {
  Protocol = Protocol,
  State = State,
  Prediction = Prediction,
  Events = Events,
  Log = Log,
  Locale = Locale,
  ActionList = ActionList,
  TurnOrder = TurnOrder,
  TargetSelector = TargetSelector,
  LifeBars = LifeBars,
  TextLog = TextLog,
  AnimQueue = AnimQueue,
  HitFX = HitFX,
  Sounds = Sounds,
  getState = function() return state end,
  getEvents = function() return events end,
  getWindow = function() return window end,
}

return BattleHud
