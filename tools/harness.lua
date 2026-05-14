-- tools/harness.lua
--
-- Headless harness. Reads NDJSON from stdin (piped from stub_fixture.py)
-- and drives the game_battlehud modules through every message, recording
-- every observable HUD event to --out.
--
-- Usage (from repo root):
--   python3 tools/stub_fixture.py --scenario turn_loop | \
--     lua tools/harness.lua --scenario turn_loop --out recordings/turn_loop.log
--
--   python3 tools/stub_fixture.py --scenario reconnect | \
--     lua tools/harness.lua --scenario reconnect --out recordings/reconnect.log

local script = arg[0] or 'tools/harness.lua'
local script_dir = script:gsub('/[^/]+$', '')
if script_dir == script then script_dir = '.' end
local repo_root = script_dir:gsub('/tools$', '')
if repo_root == script_dir then repo_root = '.' end

package.path = table.concat({
  repo_root .. '/modules/game_battlehud/?.lua',
  repo_root .. '/modules/game_battlehud/?/init.lua',
  repo_root .. '/tools/?.lua',
  package.path,
}, ';')

local json = require('json')
local Protocol = require('protocol')
Protocol.setJson(json.encode, json.decode)

-- ---- OTCv8 shims ----------------------------------------------------------
local sent_payloads = {}
g_game = { sendExtendedOpcode = function(_op, payload)
  sent_payloads[#sent_payloads + 1] = payload
end }
ProtocolGame = nil
g_clock = { millis = function() return os.time() * 1000 end }
g_ui = nil; g_modules = nil
function connect() end; function disconnect() end

-- ---- recording sink --------------------------------------------------------
local recording = {}
local Log = require('log')
Log.setSink(function(e) recording[#recording + 1] = e end)
Log.setClock(function() return os.time() * 1000 end)

-- ---- module init -----------------------------------------------------------
local BattleHud = require('battlehud')
BattleHud.init()

local evts = BattleHud._internal.getEvents()
local state = BattleHud._internal.getState()
local LifeBars = BattleHud._internal.LifeBars
local TurnOrder = BattleHud._internal.TurnOrder
local TextLog   = BattleHud._internal.TextLog

local function snapshot_hud(kind, envelope)
  local r = { tag = 'hud:' .. kind, ts = os.time() * 1000,
    turn = state.turn, lifecycle = state.lifecycle,
    valid_actions = state:validActions(),
    lifebars = { A = LifeBars.modelFor(state,'A'), B = LifeBars.modelFor(state,'B') } }
  if envelope and envelope.body then
    if kind == 'resolve' then
      r.turn_order = TurnOrder.fromResolveBody(envelope.body)
      r.text_log   = TextLog.linesForResolve(state, envelope.body)
    end
    if kind == 'start' or kind == 'snapshot' then
      r.choice_window = state.choiceWindow
    end
  end
  recording[#recording + 1] = r
end

evts:subscribe(function(kind, envelope)
  snapshot_hud(kind, envelope)
end)

-- ---- argv ------------------------------------------------------------------
local args = { scenario = 'turn_loop', out = repo_root .. '/recordings/turn_loop.log' }
local i = 1
while i <= #arg do
  if arg[i] == '--scenario' then args.scenario = arg[i+1]; i = i+2
  elseif arg[i] == '--out' then args.out = arg[i+1]; i = i+2
  else i = i+1 end
end

-- ---- drive -----------------------------------------------------------------
for line in io.lines() do
  line = line:match('^%s*(.-)%s*$') -- trim
  if #line == 0 then goto continue end
  local ok, decoded = pcall(json.decode, line)
  if not ok or type(decoded) ~= 'table' then goto continue end

  -- Disconnect marker: simulate connection drop.
  if decoded._meta == 'disconnect' then
    BattleHud._onConnectionDrop()
    recording[#recording + 1] = { tag = 'hud:disconnect', ts = os.time() * 1000 }
    sent_payloads = {}
    goto continue
  end

  -- Client→server messages: feed back through Events.receive so the HUD
  -- decodes its own outbound choices (proves round-trip encode/decode).
  if decoded.op and Protocol.CLIENT_OPS[decoded.op] then
    -- Just record that the client sent it; don't re-process through server.
    recording[#recording + 1] = { tag = 'client:' .. decoded.op, ts = os.time() * 1000,
      id = decoded.id, session = decoded.session, turn = decoded.body and decoded.body.turn }
    goto continue
  end

  -- Server→client messages: process through Events.receive.
  if decoded.op then
    evts:receive(line)
    -- If this was battle:start or battle:snapshot, submit a move choice to
    -- exercise the outbound path. This simulates a player picking thunderbolt.
    if decoded.op == 'battle:start' or decoded.op == 'battle:snapshot' then
      local choice = { kind = 'move', moveId = 'thunderbolt', target = 'B:active' }
      local predicted = { hint = 'thunderbolt_anim' }
      local nonce, err = evts:submitChoice(choice, predicted)
      if nonce then
        recording[#recording + 1] = { tag = 'client:choice_submitted', ts = os.time() * 1000,
          nonce = nonce, choice = choice }
      else
        recording[#recording + 1] = { tag = 'client:choice_error', ts = os.time() * 1000,
          err = err }
      end
    end
  end

  ::continue::
end

-- ---- write recording -------------------------------------------------------
local out_path = args.out
if out_path:sub(1,1) ~= '/' then out_path = repo_root .. '/' .. out_path end
local fh = io.open(out_path, 'w')
if not fh then error('harness: cannot open ' .. out_path) end
for _, entry in ipairs(recording) do
  fh:write(json.encode(entry), '\n')
end
fh:close()
io.stderr:write(string.format('harness: wrote %d entries -> %s\n', #recording, out_path))
