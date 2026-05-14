-- state.lua
--
-- Session state for the battle HUD. The server is the source of truth
-- (authoritative-server lens). This module never decides resolution; it
-- only stores what the server has told us and reconciles to publicState
-- on resolve, and rebuilds from scratch on snapshot.

local State = {}
State.__index = State

local function deepcopy(value)
  if type(value) ~= 'table' then return value end
  local out = {}
  for k, v in pairs(value) do
    out[k] = deepcopy(v)
  end
  return out
end

function State.new()
  local self = setmetatable({}, State)
  self:reset()
  return self
end

function State:reset()
  self.sessionId = nil
  self.turn = 0
  self.lifecycle = 'idle' -- §5: idle, preparing, awaiting_choices, forced_switch, resolving, paused_for_reconnect, ending, ended
  self.you = nil
  self.opponent = nil
  self.arena = nil
  self.rules = nil
  self.participants = {} -- keyed by slot
  self.publicState = {} -- keyed by target ref string (e.g. "A:active")
  self.choiceWindow = nil
  self.lastSnapshotId = nil
  self.history = {}
  self.outcome = nil
end

local function indexParticipants(participants)
  local out = {}
  for _, p in ipairs(participants or {}) do
    if type(p) == 'table' and type(p.slot) == 'string' then
      out[p.slot] = deepcopy(p)
    end
  end
  return out
end

-- Apply a `battle:start` body. Per §3.1, this is a snapshot-equivalent at
-- turn 1 — full reset and rebuild.
function State:applyStart(body)
  self:reset()
  self.sessionId = body.session
  self.turn = body.turn or 1
  self.lifecycle = body.choiceWindow and 'awaiting_choices' or 'preparing'
  self.you = deepcopy(body.you)
  self.opponent = deepcopy(body.opponent)
  self.arena = deepcopy(body.arena)
  self.rules = deepcopy(body.rules)
  self.participants = indexParticipants(body.participants)
  -- Seed publicState from active mons so life bars have something to render
  -- before the first resolve.
  for slot, p in pairs(self.participants) do
    if p.active then
      self.publicState[slot .. ':active'] = {
        hp = deepcopy(p.active.hp),
        status = deepcopy(p.active.status),
        fainted = p.active.fainted or false,
      }
    end
  end
  self.choiceWindow = deepcopy(body.choiceWindow)
end

-- Apply a `battle:resolve` body. The HUD applies events for animation, then
-- reconciles to `publicState` (server authority wins on drift, §3.3).
function State:applyResolve(body)
  self.turn = body.turn or self.turn
  -- Reconcile authoritatively from publicState.
  if type(body.publicState) == 'table' then
    for ref, ps in pairs(body.publicState) do
      self.publicState[ref] = deepcopy(ps)
    end
  end
  -- Mirror the next state hint.
  local nxt = body.next
  if type(nxt) == 'table' then
    if nxt.kind == 'awaiting_choices' then
      self.lifecycle = 'awaiting_choices'
      self.choiceWindow = deepcopy(nxt.choiceWindow)
    elseif nxt.kind == 'forced_switch' then
      self.lifecycle = 'forced_switch'
      self.choiceWindow = deepcopy(nxt.choiceWindow)
    elseif nxt.kind == 'battle_end' then
      self.lifecycle = 'ending'
      self.choiceWindow = nil
    end
  end
  -- Keep a compact history window for the text log.
  self.history[#self.history + 1] = {
    turn = body.turn,
    events = deepcopy(body.events or {}),
  }
  if #self.history > 32 then table.remove(self.history, 1) end
end

-- Apply a `battle:snapshot` body. Per §3.4 the HUD MUST drop pre-existing
-- state and rebuild from this message.
function State:applySnapshot(body)
  local prevSnapshotId = self.lastSnapshotId
  if prevSnapshotId ~= nil and prevSnapshotId == body.snapshotId then
    -- Idempotent retransmission; nothing to do.
    return false
  end
  self:reset()
  self.sessionId = body.session
  self.turn = body.turn
  self.lifecycle = body.state or 'awaiting_choices'
  self.you = deepcopy(body.you)
  self.opponent = deepcopy(body.opponent)
  self.arena = deepcopy(body.arena)
  self.rules = deepcopy(body.rules)
  self.participants = indexParticipants(body.participants)
  self.publicState = deepcopy(body.publicState or {})
  self.choiceWindow = deepcopy(body.choiceWindow)
  self.lastSnapshotId = body.snapshotId
  if type(body.history) == 'table' and type(body.history.items) == 'table' then
    self.history = deepcopy(body.history.items)
  end
  return true
end

-- Apply a `battle:end` body. Captures the terminal outcome and transitions
-- to `ended`. After this, all further opcodes on this session are dead.
function State:applyEnd(body)
  self.lifecycle = 'ended'
  self.choiceWindow = nil
  self.outcome = deepcopy(body.outcome)
  self.outcomeReason = body.reason
  if type(body.finalState) == 'table' then
    for ref, ps in pairs(body.finalState) do
      self.publicState[ref] = deepcopy(ps)
    end
  end
  self.rewards = deepcopy(body.rewards)
  self.logRef = body.logRef
end

function State:enterPausedForReconnect()
  self.lifecycle = 'paused_for_reconnect'
end

function State:isActive()
  return self.lifecycle ~= 'idle'
    and self.lifecycle ~= 'ended'
    and self.lifecycle ~= 'ending'
end

-- Returns the list of actions the local player may legally choose this
-- choiceWindow, or nil if it isn't the player's turn. The contract guarantees
-- this set in `choiceWindow.valid.actions` (§3.1) — the HUD does not invent.
function State:validActions()
  local cw = self.choiceWindow
  if not cw or not cw.valid then return nil end
  if not self.you or cw.valid.slot ~= self.you.slot then return nil end
  return cw.valid.actions or {}
end

return State
