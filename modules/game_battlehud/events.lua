-- events.lua
--
-- Opcode dispatcher. Receives raw extended-opcode payload strings, decodes
-- them through `protocol`, mutates session state through `state`, runs the
-- visual reconcile through `prediction`, and notifies the UI layer through
-- a small observer list.
--
-- This module never decides resolution. It only routes server words into
-- HUD state and back out.

local Protocol = require('protocol')
local Log = require('log')

local Events = {}
Events.__index = Events

function Events.new(deps)
  -- deps: { state, prediction, send, idProvider, clock, locale }
  -- `send` is a function(payload_string) that publishes a client→server
  -- envelope onto the extended-opcode slot. In OTCv8 it wraps
  -- g_game.sendExtendedOpcode(60, payload).
  assert(type(deps) == 'table', 'Events.new: deps required')
  assert(deps.state, 'Events.new: deps.state required')
  assert(deps.prediction, 'Events.new: deps.prediction required')
  assert(type(deps.send) == 'function', 'Events.new: deps.send required')
  assert(type(deps.idProvider) == 'function', 'Events.new: deps.idProvider required')
  assert(type(deps.clock) == 'function', 'Events.new: deps.clock required')

  local self = setmetatable({}, Events)
  self.state = deps.state
  self.prediction = deps.prediction
  self.send = deps.send
  self.idProvider = deps.idProvider
  self.clock = deps.clock
  self.locale = deps.locale
  self.observers = {}
  self.desyncStrikes = 0
  return self
end

function Events:subscribe(fn)
  self.observers[#self.observers + 1] = fn
end

function Events:notify(kind, payload)
  for _, fn in ipairs(self.observers) do
    pcall(fn, kind, payload)
  end
end

-- Receive a payload string off the extended-opcode slot. Returns
-- (true, opcode) on success or (false, errCode) on failure.
function Events:receive(payload)
  local envelope, err = Protocol.decode(payload)
  if not envelope then
    Log.decode_error(err)
    self:_sendAck(self.state.sessionId or '', err and err.ref or nil, 'rejected_decode')
    return false, (err and err.code) or 'bad_envelope'
  end

  Log.recv(envelope.op, envelope.id, envelope.session)

  if envelope.op == 'battle:start' then
    self.state:applyStart(envelope.body)
    self:notify('start', envelope)
  elseif envelope.op == 'battle:resolve' then
    -- Reconcile predictions against the locked choices, then apply state.
    local reconciles = self.prediction:reconcile(envelope.body)
    for _, r in ipairs(reconciles) do
      if r.kind == 'reconciled' then
        Log.reconcile(r.slot)
      else
        Log.mispredict({ slot = r.slot, reason = r.reason })
      end
    end
    self.state:applyResolve(envelope.body)
    self:notify('resolve', envelope)
    if envelope.body.next and envelope.body.next.kind == 'battle_end' then
      -- battle:end will arrive momentarily; the HUD freezes input.
    end
    -- Optional best-effort ack (§3.8). Cheap and helps observability.
    self:_sendAck(envelope.session, envelope.id, 'applied')
  elseif envelope.op == 'battle:snapshot' then
    self.prediction:dropAll()
    local applied = self.state:applySnapshot(envelope.body)
    if applied then
      Log.reconnect(envelope.body.snapshotId, envelope.body.turn, envelope.body.state)
    end
    self:notify('snapshot', envelope)
  elseif envelope.op == 'battle:end' then
    self.state:applyEnd(envelope.body)
    self:notify('end', envelope)
  elseif envelope.op == 'battle:error' then
    self:notify('error', envelope)
  else
    -- §9.1: tolerate unknown opcodes silently for forward compat.
    Log.decode_error({ code = 'unknown_op', op = envelope.op })
  end

  return true, envelope.op
end

local function deepcopy(value)
  if type(value) ~= 'table' then return value end
  local out = {}
  for k, v in pairs(value) do out[k] = deepcopy(v) end
  return out
end

-- Submit a client choice. Body must conform to §3.2.
-- `predicted` is an optional opaque table the UI uses to identify its own
-- visual hint; we attach a fresh clientNonce and record the prediction.
-- Returns the clientNonce, or nil + errInfo if the choice is illegal locally.
function Events:submitChoice(choice, predicted)
  if not self.state.sessionId then
    return nil, { code = 'session_closed', message = 'no active session' }
  end
  local cw = self.state.choiceWindow
  if not cw then
    return nil, { code = 'expired_turn', message = 'no active choice window' }
  end
  if not self.state.you then
    return nil, { code = 'not_your_slot', message = 'no local slot bound' }
  end
  -- Localized illegal-action check: was this action offered?
  local valid = self.state:validActions()
  if not valid then
    return nil, { code = 'not_your_slot', message = 'not your turn' }
  end
  local ok = false
  for _, a in ipairs(valid) do if a == choice.kind then ok = true break end end
  if not ok then
    return nil, { code = 'invalid_choice', message = 'action not offered: ' .. tostring(choice.kind) }
  end

  local clientNonce = 'c_' .. tostring(self.idProvider())
  local body = deepcopy(choice)
  body.session = self.state.sessionId
  body.turn = cw.turn
  body.slot = self.state.you.slot
  body.clientNonce = clientNonce
  -- Strip envelope-style fields from caller's choice payload.
  body.kind = nil
  local outerChoice = deepcopy(choice)
  outerChoice.kind = choice.kind
  body.choice = outerChoice

  local envelope = {
    v = Protocol.V,
    op = 'battle:choices',
    id = self.idProvider(),
    session = self.state.sessionId,
    ts = self.clock(),
    body = {
      session = self.state.sessionId,
      turn = cw.turn,
      slot = self.state.you.slot,
      choice = outerChoice,
      clientNonce = clientNonce,
    },
  }

  local encoded, err = Protocol.encode(envelope)
  if not encoded then return nil, err end
  Log.send('battle:choices', envelope.id, envelope.session)
  if predicted ~= nil then
    self.prediction:register(clientNonce, cw.turn, choice, predicted)
    Log.predict(clientNonce, choice)
  end
  self.send(encoded)
  return clientNonce
end

function Events:_sendAck(session, refId, kind)
  if not session or session == '' then return end
  local envelope = Protocol.makeAckEnvelope(session, refId, kind, self.idProvider, self.clock)
  local encoded, err = Protocol.encode(envelope)
  if not encoded then return end
  Log.send('battle:ack', envelope.id, envelope.session)
  self.send(encoded)
end

-- Report a client-side desync (could not reconcile). Per §3.4 case 2 and §4,
-- the server will emit a snapshot in response.
function Events:reportDesync(reason)
  Log.desync(reason or 'unknown')
  if not self.state.sessionId then return end
  local envelope = Protocol.makeErrorEnvelope(
    self.state.sessionId,
    nil,
    'desync',
    reason or 'client could not reconcile resolve',
    self.idProvider,
    self.clock
  )
  local encoded, err = Protocol.encode(envelope)
  if encoded then
    Log.send('battle:error', envelope.id, envelope.session)
    self.send(encoded)
  end
  self.desyncStrikes = (self.desyncStrikes or 0) + 1
end

-- Called by the OTCv8 host when the underlying connection drops.
function Events:onDisconnect()
  self.state:enterPausedForReconnect()
  self:notify('paused', {})
end

return Events
