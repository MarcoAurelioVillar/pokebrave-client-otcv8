-- tools/json.lua
--
-- Minimal pure-Lua JSON encode/decode for the headless harness and tests.
-- Sufficient for the contract's body shapes (objects, arrays, strings,
-- numbers, booleans, null). NOT a hardened library — OTCv8 builds rely on
-- cjson or rxi/json.lua in production.

local json = {}

local null_marker = {}
json.null = null_marker

-- ---- encode ---------------------------------------------------------------

local encode_value

local function is_array(t)
  local n = 0
  for k, _ in pairs(t) do
    if type(k) ~= 'number' then return false end
    if k > n then n = k end
  end
  for i = 1, n do if t[i] == nil then return false end end
  return n > 0 or next(t) == nil
end

local function encode_string(s)
  s = s:gsub('\\', '\\\\')
  s = s:gsub('"', '\\"')
  s = s:gsub('\n', '\\n')
  s = s:gsub('\r', '\\r')
  s = s:gsub('\t', '\\t')
  s = s:gsub('[%z\1-\31]', function(c)
    return string.format('\\u%04x', string.byte(c))
  end)
  return '"' .. s .. '"'
end

local function encode_table(t, seen)
  if seen[t] then error('json: circular reference') end
  seen[t] = true
  if is_array(t) then
    local parts = {}
    for _, v in ipairs(t) do parts[#parts + 1] = encode_value(v, seen) end
    seen[t] = nil
    return '[' .. table.concat(parts, ',') .. ']'
  end
  local parts = {}
  local keys = {}
  for k, _ in pairs(t) do keys[#keys + 1] = k end
  table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
  for _, k in ipairs(keys) do
    parts[#parts + 1] = encode_string(tostring(k)) .. ':' .. encode_value(t[k], seen)
  end
  seen[t] = nil
  return '{' .. table.concat(parts, ',') .. '}'
end

function encode_value(v, seen)
  local t = type(v)
  if v == null_marker then return 'null' end
  if t == 'nil' then return 'null' end
  if t == 'boolean' then return v and 'true' or 'false' end
  if t == 'number' then
    if v ~= v then return 'null' end -- NaN
    if v == math.huge or v == -math.huge then return 'null' end
    if math.floor(v) == v then return tostring(math.floor(v)) end
    return tostring(v)
  end
  if t == 'string' then return encode_string(v) end
  if t == 'table' then return encode_table(v, seen or {}) end
  error('json: cannot encode ' .. t)
end

function json.encode(v) return encode_value(v) end

-- ---- decode ---------------------------------------------------------------

local pos
local src

local function skip_ws()
  while pos <= #src do
    local c = src:sub(pos, pos)
    if c == ' ' or c == '\t' or c == '\n' or c == '\r' then
      pos = pos + 1
    else
      break
    end
  end
end

local function err(msg)
  error('json decode at ' .. pos .. ': ' .. msg)
end

local parse_value

local function parse_string()
  if src:sub(pos, pos) ~= '"' then err('expected "') end
  pos = pos + 1
  local out = {}
  while pos <= #src do
    local c = src:sub(pos, pos)
    if c == '"' then pos = pos + 1; return table.concat(out) end
    if c == '\\' then
      local nx = src:sub(pos + 1, pos + 1)
      if nx == '"' then out[#out + 1] = '"'
      elseif nx == '\\' then out[#out + 1] = '\\'
      elseif nx == '/' then out[#out + 1] = '/'
      elseif nx == 'n' then out[#out + 1] = '\n'
      elseif nx == 'r' then out[#out + 1] = '\r'
      elseif nx == 't' then out[#out + 1] = '\t'
      elseif nx == 'b' then out[#out + 1] = '\b'
      elseif nx == 'f' then out[#out + 1] = '\f'
      elseif nx == 'u' then
        local hex = src:sub(pos + 2, pos + 5)
        local code = tonumber(hex, 16) or err('bad \\u')
        if code < 0x80 then
          out[#out + 1] = string.char(code)
        elseif code < 0x800 then
          out[#out + 1] = string.char(0xC0 + math.floor(code / 0x40)) .. string.char(0x80 + (code % 0x40))
        else
          out[#out + 1] = string.char(0xE0 + math.floor(code / 0x1000))
            .. string.char(0x80 + (math.floor(code / 0x40) % 0x40))
            .. string.char(0x80 + (code % 0x40))
        end
        pos = pos + 6
        goto continue
      else err('bad escape \\' .. nx) end
      pos = pos + 2
      goto continue
    end
    out[#out + 1] = c
    pos = pos + 1
    ::continue::
  end
  err('unterminated string')
end

local function parse_number()
  local start = pos
  if src:sub(pos, pos) == '-' then pos = pos + 1 end
  while pos <= #src and src:sub(pos, pos):match('[0-9eE%.%+%-]') do pos = pos + 1 end
  local s = src:sub(start, pos - 1)
  local n = tonumber(s)
  if not n then err('bad number ' .. s) end
  return n
end

local function parse_keyword(word, value)
  if src:sub(pos, pos + #word - 1) == word then
    pos = pos + #word
    return value
  end
  err('expected ' .. word)
end

local function parse_array()
  pos = pos + 1
  skip_ws()
  local out = {}
  if src:sub(pos, pos) == ']' then pos = pos + 1; return out end
  while true do
    skip_ws()
    out[#out + 1] = parse_value()
    skip_ws()
    local c = src:sub(pos, pos)
    if c == ',' then pos = pos + 1
    elseif c == ']' then pos = pos + 1; return out
    else err('expected , or ]') end
  end
end

local function parse_object()
  pos = pos + 1
  skip_ws()
  local out = {}
  if src:sub(pos, pos) == '}' then pos = pos + 1; return out end
  while true do
    skip_ws()
    local key = parse_string()
    skip_ws()
    if src:sub(pos, pos) ~= ':' then err('expected :') end
    pos = pos + 1
    skip_ws()
    out[key] = parse_value()
    skip_ws()
    local c = src:sub(pos, pos)
    if c == ',' then pos = pos + 1
    elseif c == '}' then pos = pos + 1; return out
    else err('expected , or }') end
  end
end

function parse_value()
  skip_ws()
  local c = src:sub(pos, pos)
  if c == '"' then return parse_string() end
  if c == '{' then return parse_object() end
  if c == '[' then return parse_array() end
  if c == 't' then return parse_keyword('true', true) end
  if c == 'f' then return parse_keyword('false', false) end
  if c == 'n' then return parse_keyword('null', null_marker) end
  if c == '-' or c:match('[0-9]') then return parse_number() end
  err('unexpected ' .. tostring(c))
end

function json.decode(s)
  if type(s) ~= 'string' then error('json.decode: expected string') end
  src = s
  pos = 1
  skip_ws()
  local v = parse_value()
  skip_ws()
  -- Trailing junk allowed (NDJSON consumers strip per-line).
  return v
end

return json
