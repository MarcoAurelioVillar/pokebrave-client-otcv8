-- tests/test_all.lua
--
-- Unit tests for protocol, state, and prediction modules.
-- Run with: lua tests/test_all.lua  (from repo root)

local script = arg[0] or 'tests/test_all.lua'
local repo_root = script:gsub('/tests/[^/]+$', '')
if repo_root == script then repo_root = '.' end

package.path = table.concat({
  repo_root .. '/modules/game_battlehud/?.lua',
  repo_root .. '/modules/game_battlehud/?/init.lua',
  repo_root .. '/tools/?.lua',
  package.path,
}, ';')

local json = require('json')
local Protocol = require('protocol')
Protocol.setJson(json.encode, json.decode)
local State = require('state')
local Prediction = require('prediction')

local passed = 0
local failed = 0

local function test(name, fn)
  local ok, err = pcall(fn)
  if ok then
    io.write('  PASS  ' .. name .. '\n')
    passed = passed + 1
  else
    io.write('  FAIL  ' .. name .. '\n        ' .. tostring(err) .. '\n')
    failed = failed + 1
  end
end

-- ============================================================
io.write('\n--- protocol ---\n')

test('decode: valid envelope round-trip', function()
  local enc = json.encode({ v=1, op='battle:start', id='abc', session='S1', ts=1, body={} })
  local env = assert(Protocol.decode(enc))
  assert(env.op == 'battle:start')
  assert(env.id == 'abc')
  assert(type(env.body) == 'table')
end)

test('decode: unknown top-level field rejected (strict envelope §1.2)', function()
  local enc = json.encode({ v=1, op='battle:start', id='x', session='S1', ts=1, body={}, extra_top=true })
  local _, err = Protocol.decode(enc)
  assert(err and err.code == 'bad_envelope', 'expected bad_envelope, got ' .. tostring(err and err.code))
end)

test('decode: unknown body field tolerated (additive rule §9.1)', function()
  local enc = json.encode({ v=1, op='battle:start', id='x', session='S1', ts=1, body={ future_field=42 } })
  local env = assert(Protocol.decode(enc))
  assert(env.body.future_field == 42)
end)

test('decode: version mismatch returns version_mismatch code', function()
  local enc = json.encode({ v=2, op='battle:start', id='x', session='S1', ts=1, body={} })
  local _, err = Protocol.decode(enc)
  assert(err and err.code == 'version_mismatch', tostring(err and err.code))
end)

test('decode: payload exceeding 32KB rejected', function()
  local big = string.rep('a', 33000)
  local _, err = Protocol.decode(big)
  assert(err and err.code == 'bad_envelope', tostring(err and err.code))
end)

test('decode: missing required field "op" rejected', function()
  local enc = json.encode({ v=1, id='x', session='S1', ts=1, body={} })
  local _, err = Protocol.decode(enc)
  assert(err and err.code == 'bad_envelope', tostring(err and err.code))
end)

test('decode: missing body rejected', function()
  local enc = '{"v":1,"op":"battle:start","id":"x","session":"S1","ts":1}'
  local _, err = Protocol.decode(enc)
  assert(err and err.code == 'bad_envelope', tostring(err and err.code))
end)

test('encode: valid envelope encode', function()
  local idp = function() return 'TESTID' end
  local clk = function() return 12345 end
  local env = Protocol.makeChoiceEnvelope('S1', { kind='move', moveId='thunderbolt', target='B:active' }, idp, clk)
  local encoded = assert(Protocol.encode(env))
  local decoded = json.decode(encoded)
  assert(decoded.op == 'battle:choices')
  assert(decoded.id == 'TESTID')
  assert(decoded.ts == 12345)
end)

test('encode: unknown top-level field rejected', function()
  local _, err = Protocol.encode({ v=1, op='battle:choices', id='x', session='S1', ts=1, body={}, bad=true })
  assert(err and err.code == 'bad_envelope', tostring(err and err.code))
end)

-- ============================================================
io.write('\n--- state ---\n')

local function make_start_body(session, slot_a_hp)
  slot_a_hp = slot_a_hp or 145
  return {
    session = session or 'S1', turn = 1,
    you = { slot = 'A', userId = 1 },
    opponent = { slot = 'B', kind = 'npc', label = 'Joey', userId = json.null },
    arena = { id = 'a', lockTeleport = true },
    participants = {
      { slot = 'A', active = {
          pid = 'p_A_0', speciesId = 25, speciesName = 'Pikachu', level = 50,
          hp = { current = slot_a_hp, max = 145 }, status = json.null, fainted = false,
          moves = { { moveId = 'thunderbolt', name = 'Thunderbolt', pp = { current = 15, max = 15 }, priority = 0, target = 'opponent_active' } }
        }, bench = {} },
      { slot = 'B', active = {
          pid = 'p_B_0', speciesId = 19, speciesName = 'Rattata', level = 14,
          hp = { current = 50, max = 50 }, status = json.null, fainted = false
        }, bench = {} },
    },
    rules = { format = '1v1', turnTimeoutMs = 30000, forcedSwitchTimeoutMs = 15000, reconnectGraceMs = 60000, allowSurrender = true, maxTurns = 200 },
    choiceWindow = { turn = 1, deadline = 9999999999, valid = { slot = 'A', actions = { 'move', 'switch', 'surrender' } } },
  }
end

test('applyStart: sets session, lifecycle, publicState, validActions', function()
  local s = State.new()
  s:applyStart(make_start_body('S1'))
  assert(s.sessionId == 'S1')
  assert(s.lifecycle == 'awaiting_choices')
  assert(s.publicState['A:active'].hp.current == 145)
  local va = s:validActions()
  assert(va and #va == 3)
end)

test('applyResolve: reconciles publicState authoritatively', function()
  local s = State.new()
  s:applyStart(make_start_body('S1'))
  s:applyResolve({
    session = 'S1', turn = 1, ordered = true,
    events = { { seq = 0, kind = 'choices_locked', bySlot = {}, order = {}, tieBreak = json.null } },
    publicState = { ['A:active'] = { hp = { current = 120, max = 145 }, status = json.null, fainted = false },
                    ['B:active'] = { hp = { current = 10, max = 50 }, status = json.null, fainted = false } },
    next = { kind = 'awaiting_choices', choiceWindow = { turn = 2, deadline = 9999999999, valid = { slot = 'A', actions = { 'move' } } } },
  })
  -- Server's publicState wins.
  assert(s.publicState['A:active'].hp.current == 120, 'publicState must update from resolve')
  assert(s.turn == 1)
  assert(s.lifecycle == 'awaiting_choices')
end)

test('applySnapshot: drops all pre-existing state and rebuilds', function()
  local s = State.new()
  s:applyStart(make_start_body('S1'))
  s.publicState['A:active'].hp.current = 999 -- inject dirty state
  local snap = {
    session = 'S2', snapshotId = 'snap42', turn = 5, state = 'forced_switch',
    you = { slot = 'A', userId = 1 },
    opponent = { slot = 'B', kind = 'npc', label = 'Joey', userId = json.null },
    arena = { id = 'a', lockTeleport = false },
    rules = { format = '1v1', turnTimeoutMs = 30000, forcedSwitchTimeoutMs = 15000, reconnectGraceMs = 60000, allowSurrender = true, maxTurns = 200 },
    participants = make_start_body('S2').participants,
    publicState = { ['A:active'] = { hp = { current = 77, max = 145 }, status = json.null, fainted = false } },
    specVersion = '1',
  }
  local changed = s:applySnapshot(snap)
  assert(changed == true)
  assert(s.sessionId == 'S2', 'session must reset')
  assert(s.publicState['A:active'].hp.current == 77, 'publicState must come from snapshot, not dirty value')
  assert(s.lifecycle == 'forced_switch')
end)

test('applySnapshot: idempotent retransmission of same snapshotId returns false', function()
  local s = State.new()
  local snap = {
    session = 'S1', snapshotId = 'idem_snap', turn = 2, state = 'awaiting_choices',
    you = { slot = 'A', userId = 1 },
    opponent = { slot = 'B', kind = 'npc', label = 'Joey', userId = json.null },
    arena = { id = 'a', lockTeleport = true },
    rules = { format = '1v1', turnTimeoutMs = 30000, forcedSwitchTimeoutMs = 15000, reconnectGraceMs = 60000, allowSurrender = true, maxTurns = 200 },
    participants = make_start_body('S1').participants,
    publicState = { ['A:active'] = { hp = { current = 100, max = 145 }, status = json.null, fainted = false } },
    specVersion = '1',
  }
  assert(s:applySnapshot(snap) == true)
  assert(s:applySnapshot(snap) == false)
end)

test('applyEnd: lifecycle becomes ended, outcome recorded', function()
  local s = State.new()
  s:applyStart(make_start_body('S1'))
  s:applyEnd({
    session = 'S1', turn = 2,
    outcome = { winner = 'A' }, reason = 'ko',
    finalState = { ['A:active'] = { hp = { current = 145, max = 145 }, status = json.null, fainted = false } },
  })
  assert(s.lifecycle == 'ended')
  assert(s.outcome and s.outcome.winner == 'A')
  assert(s.outcomeReason == 'ko')
end)

test('validActions: returns nil when not player\'s turn', function()
  local s = State.new()
  s:applyStart(make_start_body('S1'))
  -- Override choiceWindow to another slot.
  s.choiceWindow.valid.slot = 'B'
  assert(s:validActions() == nil)
end)

-- ============================================================
io.write('\n--- prediction ---\n')

test('reconcile: matching nonce produces "reconciled" event', function()
  local p = Prediction.new()
  p:register('n1', 1, { kind = 'move', moveId = 'thunderbolt', target = 'B:active' }, { hint = 'anim' })
  local out = p:reconcile({
    events = { { seq = 0, kind = 'choices_locked',
      bySlot = { A = { kind = 'move', moveId = 'thunderbolt', target = 'B:active', clientNonce = 'n1' } },
      order = {}, tieBreak = json.null } }
  })
  assert(#out == 1 and out[1].kind == 'reconciled')
end)

test('reconcile: different moveId produces "mispredict"', function()
  local p = Prediction.new()
  p:register('n2', 1, { kind = 'move', moveId = 'thunderbolt', target = 'B:active' }, {})
  local out = p:reconcile({
    events = { { seq = 0, kind = 'choices_locked',
      bySlot = { A = { kind = 'move', moveId = 'quick_attack', target = 'B:active', clientNonce = 'n2' } },
      order = {}, tieBreak = json.null } }
  })
  assert(#out == 1 and out[1].kind == 'mispredict', tostring(out[1] and out[1].kind))
  assert(out[1].reason == 'move_or_target')
end)

test('reconcile: no choices_locked event drops pending silently', function()
  local p = Prediction.new()
  p:register('n3', 1, { kind = 'move', moveId = 'thunderbolt', target = 'B:active' }, {})
  local out = p:reconcile({ events = { { seq = 0, kind = 'damage', source='A:active', target='B:active', amount=10 } } })
  assert(#out == 0)
end)

test('dropAll: clears all pending predictions', function()
  local p = Prediction.new()
  p:register('n4', 1, { kind = 'move', moveId = 'thunderbolt', target = 'B:active' }, {})
  p:dropAll()
  local out = p:reconcile({
    events = { { seq = 0, kind = 'choices_locked',
      bySlot = { A = { kind = 'move', moveId = 'thunderbolt', target = 'B:active', clientNonce = 'n4' } },
      order = {}, tieBreak = json.null } }
  })
  -- n4 was dropped, so no reconcile event
  assert(#out == 0, 'expected 0 after dropAll, got ' .. #out)
end)

-- ============================================================
io.write(string.format('\n%d passed, %d failed\n', passed, failed))
if failed > 0 then os.exit(1) end
