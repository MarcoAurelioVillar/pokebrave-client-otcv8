-- animqueue.lua
--
-- Serialized VFX drain for battle:resolve events.
-- Events from a battle:resolve body are buffered in a FIFO sorted by seq
-- and drained one-at-a-time so animations always play in resolver order,
-- even when rapid resolve bursts arrive or network reorders delivery.
--
-- Design invariants (§3.2 of Phase h spec):
--   • drainNext() never double-fires: only called when draining==false.
--   • flush() sets flushed=true; any scheduled drainNext callback is a no-op.
--   • flush() MUST be called before arena teardown (battle:end, disconnect).
--   • reset() clears flushed so a new battle can start.
--   • publicState reconciliation fires exactly once per turn, after last event.

local Log     = require('log')
local HitFX   = require('hitfx')
local Sounds  = require('sounds')
local LifeBars = require('ui_lifebars')

local AnimQueue = {}

-- Tunable durations (ms). One constant per event kind; not scattered inline.
local VFX_DURATION_MS = {
  choices_locked  = 600,
  action_start    = 400,
  damage          = 500,
  heal            = 500,
  status_inflict  = 400,
  status_clear    = 300,
  stat_change     = 350,
  switch          = 700,
  item_used       = 400,
  action_skipped  = 350,
  faint           = 800,
  turn_end_tick   = 350,
  text            = 300,
  _default        = 300,
}

-- Injectable scheduler: function(delayMs, callback).
-- Default: use OTCv8 scheduleEvent when available; call immediately otherwise.
-- Override via AnimQueue.setScheduler() for tests (synchronous) or OTCv8 (async).
local scheduler = nil

function AnimQueue.setScheduler(fn)
  assert(type(fn) == 'function', 'animqueue: scheduler must be a function')
  scheduler = fn
end

local function defaultScheduler(delayMs, callback)
  -- scheduleEvent(callback, delayMs) is the OTCv8 global for deferred calls.
  if scheduleEvent then
    scheduleEvent(callback, delayMs)
  else
    -- Headless / test fallback: call synchronously so tests are deterministic.
    callback()
  end
end

-- Queue state. Reset by AnimQueue.reset().
local queue             = {}   -- array of event objects, sorted by seq
local draining          = false
local flushed           = false
local pendingPublicState = nil  -- publicState to reconcile after last event

-- ---- VFX handler table -----------------------------------------------------
-- One entry per event kind. Each handler fires synchronously before the
-- inter-event timer is started. Handlers must not depend on drain order
-- (the queue guarantees seq order) and must pcall-guard risky calls.

local handlers = {}

handlers['damage'] = function(ev)
  local target = ev.target or 'B:active'
  local slot   = target:match('^(%a+):') or target
  local isCrit = ev.crit == true
  local eff    = ev.effectiveness or 1.0
  HitFX.damageNumber(slot, ev.amount or 0, isCrit, eff, false)
  HitFX.spriteFlash(slot, 'red', VFX_DURATION_MS.damage)
  HitFX.cameraShake(isCrit and 6 or 3, VFX_DURATION_MS.damage, 4)
  Sounds.play(isCrit and 'crit' or 'hit')
end

handlers['heal'] = function(ev)
  local target = ev.target or 'A:active'
  local slot   = target:match('^(%a+):') or target
  HitFX.damageNumber(slot, ev.amount or 0, false, 1.0, true)
  HitFX.spriteFlash(slot, 'green', VFX_DURATION_MS.heal)
end

handlers['action_skipped'] = function(_ev)
  Sounds.play('miss')
end

handlers['faint'] = function(ev)
  local target = ev.target or 'A:active'
  local slot   = target:match('^(%a+):') or target
  HitFX.cameraShake(10, VFX_DURATION_MS.faint, 4)
  Sounds.play('faint')
  -- Suppress unused-variable warning for slot in headless mode.
  _ = slot
end

handlers['status_inflict'] = function(ev)
  local target = ev.target or 'A:active'
  local slot   = target:match('^(%a+):') or target
  HitFX.spriteFlash(slot, 'yellow', VFX_DURATION_MS.status_inflict)
  Sounds.play('status')
end

handlers['text'] = function(ev)
  -- 'battle.move_missed' key maps to a miss sound (§4 event→feedback table).
  if ev.key == 'battle.move_missed' then
    Sounds.play('miss')
  end
end

-- ---- Drain loop ------------------------------------------------------------

local function drainNext()
  if flushed then
    -- flush() was called while a timer was in flight; this is the no-op path.
    draining = false
    return
  end

  if #queue == 0 then
    draining = false
    -- Post-drain authority snap: reconcile life bars to server's publicState.
    -- This corrects any visual drift from prediction overlays. Lens:
    -- client-side-hint-server-side-truth, authoritative-server.
    if pendingPublicState then
      local ps = pendingPublicState
      pendingPublicState = nil
      LifeBars.reconcile(ps)
    end
    return
  end

  draining = true
  local ev = table.remove(queue, 1)

  Log.text('vfx:dispatch', { seq = ev.seq, kind = ev.kind })

  local handler = handlers[ev.kind]
  if handler then
    local ok, err = pcall(handler, ev)
    if not ok then
      Log.decode_error({ code = 'vfx_handler_error', kind = ev.kind, err = tostring(err) })
    end
  end

  local duration = VFX_DURATION_MS[ev.kind] or VFX_DURATION_MS._default
  local sched = scheduler or defaultScheduler
  sched(duration, function()
    if not flushed then
      drainNext()
    else
      -- flush() raced with the timer; ensure draining flag is clear.
      draining = false
    end
  end)
end

-- ---- Public API ------------------------------------------------------------

-- Push a batch of events from a battle:resolve body.
-- events:      array in server seq order (already sorted; we sort again for safety).
-- publicState: the post-turn publicState snapshot from the resolve body.
-- If a drain is already in progress, new events are appended and will be
-- processed automatically — no double-drain.
function AnimQueue.push(events, publicState)
  if flushed then return end

  -- Sort by seq so out-of-order network delivery cannot reorder animations.
  local sorted = {}
  for _, ev in ipairs(events or {}) do
    sorted[#sorted + 1] = ev
  end
  table.sort(sorted, function(a, b) return (a.seq or 0) < (b.seq or 0) end)

  for _, ev in ipairs(sorted) do
    queue[#queue + 1] = ev
  end
  pendingPublicState = publicState

  if not draining then
    drainNext()
  end
end

-- Cancel any in-flight timer; make every future drainNext callback a no-op.
-- MUST be called before arena teardown on battle:end and on disconnect.
function AnimQueue.flush()
  flushed  = true
  draining = false
  queue    = {}
  pendingPublicState = nil
end

-- Reset after flush so a new battle (battle:start / battle:snapshot) can use
-- the queue. Calling reset() without a prior flush() is safe but unusual.
function AnimQueue.reset()
  flushed  = false
  draining = false
  queue    = {}
  pendingPublicState = nil
end

return AnimQueue
