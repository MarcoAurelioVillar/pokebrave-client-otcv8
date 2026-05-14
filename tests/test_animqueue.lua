-- tests/test_animqueue.lua
--
-- Unit tests for animqueue.lua, hitfx.lua, and sounds.lua.
-- Run with: lua tests/test_animqueue.lua  (from repo root)
--
-- The synchronous scheduler (calls callbacks immediately) is installed so
-- drain runs are deterministic without real timers.

local script = arg[0] or 'tests/test_animqueue.lua'
local repo_root = script:gsub('/tests/[^/]+$', '')
if repo_root == script then repo_root = '.' end

package.path = table.concat({
  repo_root .. '/modules/game_battlehud/?.lua',
  repo_root .. '/modules/game_battlehud/?/init.lua',
  repo_root .. '/tools/?.lua',
  package.path,
}, ';')

-- ---- OTCv8 stubs -----------------------------------------------------------
-- g_sounds is intentionally set to a table with a play method so most tests
-- exercise the normal guarded path. Individual tests nil it to test the guard.
g_sounds = { play = function(_self, _path) end }
g_ui     = nil
g_game   = nil

-- ---- harness setup ---------------------------------------------------------
local json = require('json')
local Log  = require('log')

-- Collect log entries for test assertions.
local log_entries = {}
Log.setSink(function(e) log_entries[#log_entries + 1] = e end)
Log.setClock(function() return 0 end)

local Protocol = require('protocol')
Protocol.setJson(json.encode, json.decode)

-- Fresh require of each module every test via module reload helper.
-- Lua caches modules in package.loaded; we reset selectively.
local function reload(name)
  package.loaded[name] = nil
  return require(name)
end

local function fresh_animqueue()
  -- Reload AnimQueue and its deps so state is clean between tests.
  package.loaded['animqueue'] = nil
  package.loaded['hitfx']    = nil
  package.loaded['sounds']   = nil
  -- ui.lifebars is stateless; no need to reload it.
  local aq = require('animqueue')
  aq.setScheduler(function(_ms, cb) cb() end) -- synchronous drain
  aq.reset()
  return aq
end

local function clear_log()
  log_entries = {}
end

-- Log.text(key, args) stores entries as { tag='text', payload={ key=key, args=args } }.
-- This helper returns the args tables for every 'text' entry whose key matches.
local function log_payloads(key)
  local out = {}
  for _, e in ipairs(log_entries) do
    if e.tag == 'text' and e.payload and e.payload.key == key then
      out[#out + 1] = e.payload.args or {}
    end
  end
  return out
end

-- ---- test runner -----------------------------------------------------------
local passed = 0
local failed = 0

local function test(name, fn)
  clear_log()
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
io.write('\n--- animqueue: ordering ---\n')

test('drains events in seq order even when pushed in reverse seq order', function()
  local AQ = fresh_animqueue()
  -- Push events with seq 2, 1, 0 — backwards.
  local events = {
    { seq = 2, kind = 'turn_end_tick', slot = 'B', effect = 'status:paralysis' },
    { seq = 1, kind = 'action_skipped', slot = 'B', reason = 'paralysis_full' },
    { seq = 0, kind = 'choices_locked', bySlot = {}, order = {}, tieBreak = json.null },
  }
  AQ.push(events, {})
  local dispatched = log_payloads('vfx:dispatch')
  assert(#dispatched == 3, 'expected 3 dispatched, got ' .. #dispatched)
  assert(dispatched[1].seq == 0, 'first dispatched must be seq=0, got ' .. tostring(dispatched[1].seq))
  assert(dispatched[2].seq == 1, 'second dispatched must be seq=1, got ' .. tostring(dispatched[2].seq))
  assert(dispatched[3].seq == 2, 'third dispatched must be seq=2, got ' .. tostring(dispatched[3].seq))
end)

test('appending events mid-drain continues drain without double-firing', function()
  -- With synchronous scheduler, a push while draining would only double-drain
  -- if the guard (not draining) check is absent. We simulate it by pushing
  -- two separate batches and verifying total dispatch count equals total events.
  local AQ = fresh_animqueue()
  local batch1 = {
    { seq = 0, kind = 'action_start', slot = 'A', action = { kind = 'move' } },
    { seq = 1, kind = 'damage', source = 'A:active', target = 'B:active', amount = 32, after = { hp = 18 }, crit = false, effectiveness = 1.0 },
  }
  local batch2 = {
    { seq = 2, kind = 'faint', target = 'B:active', reason = 'hp_zero' },
  }
  AQ.push(batch1, {})
  -- With synchronous scheduler batch1 is already fully drained.
  -- batch2 starts a fresh drain from the empty queue.
  AQ.push(batch2, {})
  local dispatched = log_payloads('vfx:dispatch')
  assert(#dispatched == 3, 'expected 3 total dispatched, got ' .. #dispatched)
end)

-- ============================================================
io.write('\n--- animqueue: flush / reset ---\n')

test('flush prevents any new push from enqueueing events', function()
  local AQ = fresh_animqueue()
  AQ.flush()
  AQ.push({ { seq = 0, kind = 'damage', target = 'B:active', amount = 10, after = { hp = 0 }, crit = false, effectiveness = 1.0 } }, {})
  local dispatched = log_payloads('vfx:dispatch')
  assert(#dispatched == 0, 'expected 0 dispatched after flush, got ' .. #dispatched)
end)

test('flush then reset allows new events to drain normally', function()
  local AQ = fresh_animqueue()
  AQ.flush()
  AQ.reset()
  AQ.push({ { seq = 0, kind = 'action_start', slot = 'A', action = {} } }, {})
  local dispatched = log_payloads('vfx:dispatch')
  assert(#dispatched == 1, 'expected 1 dispatched after reset, got ' .. #dispatched)
end)

test('flush with in-flight timer: callback fired after flush is a no-op', function()
  -- Simulate an in-flight callback by using a deferred scheduler that we
  -- fire manually after flush(). The drainNext should be a no-op.
  package.loaded['animqueue'] = nil
  package.loaded['hitfx']    = nil
  package.loaded['sounds']   = nil
  local AQ = require('animqueue')
  AQ.reset()

  local deferred_cb = nil
  AQ.setScheduler(function(_ms, cb)
    deferred_cb = cb  -- capture but don't call yet
  end)

  AQ.push({ { seq = 0, kind = 'damage', target = 'B:active', amount = 5,
    after = { hp = 45 }, crit = false, effectiveness = 1.0 } }, {})
  -- First event drains synchronously up to the scheduler call; cb is deferred.
  -- Now flush:
  AQ.flush()
  -- Fire the deferred callback; it should be a no-op.
  local before = #log_payloads('vfx:dispatch')
  if deferred_cb then deferred_cb() end
  local after_count = #log_payloads('vfx:dispatch')
  -- The initial damage event was dispatched before flush, so before==1.
  -- After firing the deferred cb, no additional dispatch should occur.
  assert(after_count == before, 'deferred cb after flush should not dispatch additional events')
end)

-- ============================================================
io.write('\n--- animqueue: publicState reconciliation ---\n')

test('reconcile fires exactly once per turn, after last event drains', function()
  local AQ = fresh_animqueue()
  local LifeBars = require('ui_lifebars')

  local reconcile_calls = 0
  local orig_reconcile = LifeBars.reconcile
  LifeBars.reconcile = function(_ps) reconcile_calls = reconcile_calls + 1 end

  local ps = { ['A:active'] = { hp = { current = 145, max = 145 }, fainted = false } }
  local events = {
    { seq = 0, kind = 'choices_locked', bySlot = {}, order = {} },
    { seq = 1, kind = 'damage', target = 'B:active', amount = 32, after = { hp = 18 }, crit = false, effectiveness = 1.0 },
  }
  AQ.push(events, ps)

  LifeBars.reconcile = orig_reconcile  -- restore

  assert(reconcile_calls == 1, 'expected exactly 1 reconcile call, got ' .. reconcile_calls)
end)

test('reconcile not called if flush occurs before drain completes', function()
  package.loaded['animqueue'] = nil
  package.loaded['hitfx']    = nil
  package.loaded['sounds']   = nil
  local AQ = require('animqueue')
  AQ.reset()

  local deferred_cb = nil
  AQ.setScheduler(function(_ms, cb) deferred_cb = cb end)

  local LifeBars = require('ui_lifebars')
  local reconcile_calls = 0
  local orig_reconcile = LifeBars.reconcile
  LifeBars.reconcile = function(_ps) reconcile_calls = reconcile_calls + 1 end

  local ps = { ['A:active'] = { hp = { current = 145, max = 145 }, fainted = false } }
  AQ.push({ { seq = 0, kind = 'action_start', slot = 'A', action = {} } }, ps)
  AQ.flush()
  if deferred_cb then deferred_cb() end

  LifeBars.reconcile = orig_reconcile
  assert(reconcile_calls == 0, 'expected 0 reconcile calls after flush, got ' .. reconcile_calls)
end)

-- ============================================================
io.write('\n--- sounds: event mapping ---\n')

test('damage event triggers hit sound once', function()
  local AQ = fresh_animqueue()
  AQ.push({ { seq = 0, kind = 'damage', target = 'B:active', amount = 20,
    after = { hp = 30 }, crit = false, effectiveness = 1.0 } }, {})
  local sfx = log_payloads('sfx:play')
  assert(#sfx == 1, 'expected 1 sfx:play for damage, got ' .. #sfx)
  assert(sfx[1].key == 'hit', 'expected "hit" sound for non-crit damage, got ' .. tostring(sfx[1].key))
end)

test('crit damage event triggers crit sound', function()
  local AQ = fresh_animqueue()
  AQ.push({ { seq = 0, kind = 'damage', target = 'B:active', amount = 55,
    after = { hp = 0 }, crit = true, effectiveness = 1.0 } }, {})
  local sfx = log_payloads('sfx:play')
  assert(#sfx == 1, 'expected 1 sfx:play for crit, got ' .. #sfx)
  assert(sfx[1].key == 'crit', 'expected "crit" sound, got ' .. tostring(sfx[1].key))
end)

test('action_skipped event triggers miss sound', function()
  local AQ = fresh_animqueue()
  AQ.push({ { seq = 0, kind = 'action_skipped', slot = 'B', reason = 'paralysis_full' } }, {})
  local sfx = log_payloads('sfx:play')
  assert(#sfx == 1, 'expected 1 sfx:play for action_skipped, got ' .. #sfx)
  assert(sfx[1].key == 'miss', 'expected "miss" sound for action_skipped, got ' .. tostring(sfx[1].key))
end)

test('faint event triggers faint sound', function()
  local AQ = fresh_animqueue()
  AQ.push({ { seq = 0, kind = 'faint', target = 'B:active', reason = 'hp_zero' } }, {})
  local sfx = log_payloads('sfx:play')
  assert(#sfx == 1, 'expected 1 sfx:play for faint, got ' .. #sfx)
  assert(sfx[1].key == 'faint', 'expected "faint" sound, got ' .. tostring(sfx[1].key))
end)

test('status_inflict event triggers status sound', function()
  local AQ = fresh_animqueue()
  AQ.push({ { seq = 0, kind = 'status_inflict', target = 'B:active',
    status = { name = 'paralysis', stacks = 1, remainingTurns = json.null } } }, {})
  local sfx = log_payloads('sfx:play')
  assert(#sfx == 1, 'expected 1 sfx:play for status_inflict, got ' .. #sfx)
  assert(sfx[1].key == 'status', 'expected "status" sound, got ' .. tostring(sfx[1].key))
end)

-- ============================================================
io.write('\n--- sounds: g_sounds guard ---\n')

test('Sounds.play does not throw when g_sounds is nil', function()
  package.loaded['sounds'] = nil
  local saved = g_sounds
  g_sounds = nil
  local Sounds = require('sounds')
  local ok = pcall(Sounds.play, 'hit')
  g_sounds = saved
  assert(ok, 'Sounds.play must not throw when g_sounds is nil')
end)

test('Sounds.play does not throw when g_sounds lacks play method', function()
  package.loaded['sounds'] = nil
  local saved = g_sounds
  g_sounds = {}  -- table without .play
  local Sounds = require('sounds')
  local ok = pcall(Sounds.play, 'hit')
  g_sounds = saved
  assert(ok, 'Sounds.play must not throw when g_sounds.play is absent')
end)

-- ============================================================
io.write('\n--- hitfx: vfx log events ---\n')

test('damage handler emits vfx:damage_number and vfx:sprite_flash', function()
  local AQ = fresh_animqueue()
  AQ.push({ { seq = 0, kind = 'damage', target = 'B:active', amount = 32,
    after = { hp = 18 }, crit = false, effectiveness = 1.0 } }, {})
  local dn = log_payloads('vfx:damage_number')
  local sf = log_payloads('vfx:sprite_flash')
  assert(#dn == 1, 'expected 1 vfx:damage_number, got ' .. #dn)
  assert(#sf == 1, 'expected 1 vfx:sprite_flash, got ' .. #sf)
  assert(dn[1].slot == 'B', 'damage_number slot must be B, got ' .. tostring(dn[1].slot))
  assert(sf[1].color == 'red', 'sprite_flash for damage must be red, got ' .. tostring(sf[1].color))
end)

test('heal handler emits green sprite_flash and no sound', function()
  local AQ = fresh_animqueue()
  AQ.push({ { seq = 0, kind = 'heal', target = 'A:active', amount = 20, after = { hp = 100 } } }, {})
  local sf = log_payloads('vfx:sprite_flash')
  local sfx = log_payloads('sfx:play')
  assert(#sf == 1, 'expected 1 vfx:sprite_flash for heal, got ' .. #sf)
  assert(sf[1].color == 'green', 'sprite_flash for heal must be green, got ' .. tostring(sf[1].color))
  assert(#sfx == 0, 'expected no sound for heal, got ' .. #sfx)
end)

-- ============================================================
io.write(string.format('\n%d passed, %d failed\n', passed, failed))
if failed > 0 then os.exit(1) end
