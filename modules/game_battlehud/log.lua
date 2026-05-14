-- log.lua
--
-- Structured observability log for the HUD. The contract (and the
-- observable-battles lens) require every recv/send/predict/reconcile/
-- mispredict/reconnect/desync/decode_error to be inspectable so QA can
-- debug without screen recordings.
--
-- Sink is injected; default is a no-op so the OTCv8 client doesn't write
-- to disk unless explicitly enabled.

local Log = {}

local sink = function(_) end -- no-op default
local clock = function() return 0 end

function Log.setSink(fn)
  assert(type(fn) == 'function', 'log: sink must be a function')
  sink = fn
end

function Log.setClock(fn)
  assert(type(fn) == 'function', 'log: clock must be a function')
  clock = fn
end

local function emit(tag, payload)
  sink({
    ts = clock(),
    tag = tag,
    payload = payload or {},
  })
end

function Log.recv(op, id, session) emit('recv', { op = op, id = id, session = session }) end
function Log.send(op, id, session) emit('send', { op = op, id = id, session = session }) end
function Log.predict(clientNonce, choice) emit('predict', { clientNonce = clientNonce, choice = choice }) end
function Log.reconcile(slot) emit('reconcile', { slot = slot }) end
function Log.mispredict(info) emit('mispredict', info) end
function Log.reconnect(snapshotId, turn, state) emit('reconnect', { snapshotId = snapshotId, turn = turn, state = state }) end
function Log.desync(reason) emit('desync', { reason = reason }) end
function Log.decode_error(info) emit('decode_error', info) end
function Log.text(key, args) emit('text', { key = key, args = args }) end

return Log
