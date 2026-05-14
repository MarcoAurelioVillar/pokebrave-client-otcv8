-- protocol.lua
--
-- Envelope encode/decode for the frozen v1 battle contract (DEV-3).
-- Strict at the envelope (§1.2): unknown top-level fields are rejected.
-- Permissive in body (§9.1 additive rule): unknown body fields are ignored.
--
-- This file does NOT depend on OTCv8 globals so it can be unit-tested under
-- plain lua5.3. JSON encode/decode is injected via setJson() at init time.

local Protocol = {}

Protocol.V = 1
Protocol.MAX_PAYLOAD_BYTES = 32768
Protocol.EXTENDED_OPCODE = 60

-- Allowed top-level envelope keys (§1.2).
local ENVELOPE_KEYS = {
  v = true, op = true, id = true, session = true, ts = true, body = true,
}

-- Direction matrix (§1.3). Client may only emit a small set of opcodes.
Protocol.CLIENT_OPS = {
  ["battle:choices"] = true,
  ["battle:ack"] = true,
  ["battle:error"] = true,
}

-- All known v1 server-to-client opcodes (§2). Unknown opcodes are still
-- accepted by decode; dispatch decides whether to handle them.
Protocol.SERVER_OPS = {
  ["battle:start"] = true,
  ["battle:resolve"] = true,
  ["battle:snapshot"] = true,
  ["battle:end"] = true,
  ["battle:error"] = true,
}

local json_encode = nil
local json_decode = nil

function Protocol.setJson(encode, decode)
  assert(type(encode) == 'function', 'protocol: json encoder must be a function')
  assert(type(decode) == 'function', 'protocol: json decoder must be a function')
  json_encode = encode
  json_decode = decode
end

local function badEnvelope(detail)
  return nil, { code = 'bad_envelope', message = detail }
end

-- Decode an extended-opcode payload string into a validated envelope table.
-- Returns (envelope, nil) on success or (nil, errInfo) on failure.
function Protocol.decode(payload)
  if json_decode == nil then
    return badEnvelope('json provider not configured')
  end
  if type(payload) ~= 'string' then
    return badEnvelope('payload must be a string')
  end
  if #payload > Protocol.MAX_PAYLOAD_BYTES then
    return badEnvelope('payload exceeds ' .. Protocol.MAX_PAYLOAD_BYTES .. ' bytes')
  end

  local ok, decoded = pcall(json_decode, payload)
  if not ok or type(decoded) ~= 'table' then
    return badEnvelope('payload is not valid JSON object')
  end

  -- Required fields and types.
  if decoded.v == nil then return badEnvelope('missing v') end
  if type(decoded.v) ~= 'number' or math.floor(decoded.v) ~= decoded.v then
    return badEnvelope('v must be an integer')
  end
  if decoded.v ~= Protocol.V then
    return nil, { code = 'version_mismatch', message = 'unsupported v=' .. tostring(decoded.v) }
  end
  if type(decoded.op) ~= 'string' then return badEnvelope('missing op') end
  if type(decoded.id) ~= 'string' then return badEnvelope('missing id') end
  if type(decoded.session) ~= 'string' then return badEnvelope('missing session') end
  if type(decoded.ts) ~= 'number' then return badEnvelope('missing ts') end
  if type(decoded.body) ~= 'table' then return badEnvelope('missing body') end

  -- Strict envelope: reject unknown top-level keys.
  for k, _ in pairs(decoded) do
    if not ENVELOPE_KEYS[k] then
      return badEnvelope('unknown envelope field: ' .. tostring(k))
    end
  end

  return decoded, nil
end

-- Encode an envelope table into a JSON string. Validates required fields
-- and the payload size cap. Callers may omit `id`/`ts` and have them filled
-- by the caller's id/clock providers — this function only encodes.
function Protocol.encode(envelope)
  if json_encode == nil then
    return nil, { code = 'bad_envelope', message = 'json provider not configured' }
  end
  if type(envelope) ~= 'table' then
    return badEnvelope('envelope must be a table')
  end
  envelope.v = envelope.v or Protocol.V
  if envelope.v ~= Protocol.V then
    return nil, { code = 'version_mismatch', message = 'unsupported v=' .. tostring(envelope.v) }
  end
  if type(envelope.op) ~= 'string' then return badEnvelope('missing op') end
  if type(envelope.id) ~= 'string' then return badEnvelope('missing id') end
  if type(envelope.session) ~= 'string' then return badEnvelope('missing session') end
  if type(envelope.ts) ~= 'number' then return badEnvelope('missing ts') end
  if type(envelope.body) ~= 'table' then return badEnvelope('missing body') end

  for k, _ in pairs(envelope) do
    if not ENVELOPE_KEYS[k] then
      return badEnvelope('unknown envelope field: ' .. tostring(k))
    end
  end

  local ok, encoded = pcall(json_encode, envelope)
  if not ok or type(encoded) ~= 'string' then
    return badEnvelope('failed to JSON-encode envelope')
  end
  if #encoded > Protocol.MAX_PAYLOAD_BYTES then
    return nil, { code = 'bad_envelope', message = 'encoded payload exceeds 32KB' }
  end
  return encoded, nil
end

-- Build a client→server choice envelope. The caller supplies `idProvider`
-- (sender-generated id, §1.2) and `clock` (epoch ms). `body` is the per-§3.2
-- choice body.
function Protocol.makeChoiceEnvelope(session, body, idProvider, clock)
  return {
    v = Protocol.V,
    op = 'battle:choices',
    id = idProvider(),
    session = session,
    ts = clock(),
    body = body,
  }
end

function Protocol.makeAckEnvelope(session, refId, kind, idProvider, clock)
  return {
    v = Protocol.V,
    op = 'battle:ack',
    id = idProvider(),
    session = session,
    ts = clock(),
    body = { session = session, ref = refId, kind = kind },
  }
end

function Protocol.makeErrorEnvelope(session, refId, code, message, idProvider, clock)
  return {
    v = Protocol.V,
    op = 'battle:error',
    id = idProvider(),
    session = session,
    ts = clock(),
    body = {
      session = session,
      ref = refId,
      code = code,
      message = message,
      retriable = false,
      details = {},
    },
  }
end

return Protocol
