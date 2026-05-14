-- locale/init.lua
--
-- Tiny localization helper. Loads the English table by default and exposes
-- t(key, args) with %{name} substitution. Future languages drop their own
-- table beside `en.lua` and call Locale.load('fr', table).

local Locale = {}

local tables = {
  en = require('locale.en'),
}

local active = 'en'

function Locale.load(code, tbl)
  tables[code] = tbl
end

function Locale.use(code)
  if tables[code] == nil then error('locale not loaded: ' .. tostring(code)) end
  active = code
end

local function interpolate(template, args)
  if type(args) ~= 'table' then return template end
  return (template:gsub('%%{(%w+)}', function(name)
    local v = args[name]
    if v == nil then return '%{' .. name .. '}' end
    return tostring(v)
  end))
end

function Locale.t(key, args)
  local tbl = tables[active] or tables.en
  local template = tbl[key]
  if template == nil then return '[' .. tostring(key) .. ']' end
  return interpolate(template, args)
end

function Locale.has(key)
  local tbl = tables[active] or tables.en
  return tbl[key] ~= nil
end

return Locale
