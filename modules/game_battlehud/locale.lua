-- locale.lua
--
-- Localization helper. English strings are inlined so the module is a single
-- file (OTCv8 require() treats dots as literal chars, not path separators).
-- Additional languages call Locale.load(code, tbl) / Locale.use(code).

local Locale = {}

local tables = {
  en = {
    -- HUD chrome
    ['battle.hud.title']               = 'Battle',
    ['battle.hud.turn']                = 'Turn %{turn}',
    ['battle.hud.waiting_opponent']    = 'Waiting for opponent...',
    ['battle.hud.your_turn']           = 'Your turn',
    ['battle.hud.forced_switch']       = 'Choose a Pokémon to switch in',
    ['battle.hud.paused']              = 'Reconnecting...',
    ['battle.hud.deadline']            = '%{seconds}s',

    -- Action list
    ['battle.action.move']             = 'Fight',
    ['battle.action.switch']           = 'Switch',
    ['battle.action.item']             = 'Item',
    ['battle.action.surrender']        = 'Surrender',
    ['battle.action.cancel']           = 'Cancel',

    -- Target selector
    ['battle.target.select']           = 'Select target',
    ['battle.target.opponent_active']  = 'Opposing %{name}',
    ['battle.target.self']             = 'Yourself',
    ['battle.target.bench']            = '%{name} (bench)',
    ['battle.target.all_enemies']      = 'All opposing Pokémon',
    ['battle.target.all_allies']       = 'All allied Pokémon',
    ['battle.target.all']              = 'Everyone',

    -- Turn-order bar
    ['battle.turnorder.title']         = 'Turn order',
    ['battle.turnorder.slot']          = 'Slot %{slot}',
    ['battle.turnorder.speed']         = 'Speed %{speed}',

    -- Life bars
    ['battle.life.hp']                 = 'HP %{current}/%{max}',
    ['battle.life.status']             = 'Status: %{status}',

    -- Outcome / end
    ['battle.outcome.win']             = 'You won!',
    ['battle.outcome.loss']            = 'You lost.',
    ['battle.outcome.draw']            = 'Draw.',
    ['battle.outcome.aborted']         = 'Battle aborted.',
    ['battle.end.reason.ko']           = 'by KO',
    ['battle.end.reason.surrender']    = 'by surrender',
    ['battle.end.reason.timeout']      = 'by timeout',
    ['battle.end.reason.desync']       = 'due to desync',
    ['battle.end.reason.system']       = 'due to a system error',

    -- Status names
    ['battle.status.burn']             = 'Burn',
    ['battle.status.poison']           = 'Poison',
    ['battle.status.toxic']            = 'Toxic',
    ['battle.status.paralysis']        = 'Paralysis',
    ['battle.status.sleep']            = 'Sleep',
    ['battle.status.freeze']           = 'Freeze',
    ['battle.status.confusion']        = 'Confusion',

    -- Event log
    ['battle.event.action_start.move'] = '%{actor} used %{move}!',
    ['battle.event.action_start.switch']  = '%{actor} switches out.',
    ['battle.event.action_start.item']    = '%{actor} uses %{item}.',
    ['battle.event.action_start.surrender'] = '%{actor} surrendered.',
    ['battle.event.damage']            = '%{target} took %{amount} damage.',
    ['battle.event.damage.crit']       = 'A critical hit! %{target} took %{amount} damage.',
    ['battle.event.damage.super']      = 'It\'s super effective! %{target} took %{amount} damage.',
    ['battle.event.damage.not_very']   = 'It\'s not very effective... %{target} took %{amount} damage.',
    ['battle.event.heal']              = '%{target} recovered %{amount} HP.',
    ['battle.event.status_inflict']    = '%{target} is afflicted with %{status}.',
    ['battle.event.status_clear']      = '%{target} is cured of %{status}.',
    ['battle.event.stat_change.up']    = "%{target}'s %{stat} rose.",
    ['battle.event.stat_change.down']  = "%{target}'s %{stat} fell.",
    ['battle.event.switch']            = 'Go, %{in_name}! (%{out_name} returns)',
    ['battle.event.item_used']         = '%{actor} used %{item}.',
    ['battle.event.action_skipped.paralysis_full'] = '%{actor} is paralyzed and can\'t move!',
    ['battle.event.action_skipped.sleep']          = '%{actor} is fast asleep.',
    ['battle.event.action_skipped.freeze']         = '%{actor} is frozen solid.',
    ['battle.event.action_skipped.flinch']         = '%{actor} flinched and couldn\'t move.',
    ['battle.event.action_skipped.confusion_self_hit'] = '%{actor} hurt itself in confusion!',
    ['battle.event.action_skipped.no_target']      = 'There was no target!',
    ['battle.event.action_skipped.interrupt']      = '%{actor} was interrupted.',
    ['battle.event.faint']             = '%{target} fainted.',
    ['battle.event.turn_end_tick.status:paralysis'] = '%{target} is fully paralyzed.',
    ['battle.event.turn_end_tick.status:burn']      = '%{target} was hurt by its burn.',
    ['battle.event.turn_end_tick.status:poison']    = '%{target} was hurt by poison.',
    ['battle.event.turn_end_tick.status:toxic']     = '%{target} was hurt by toxic poison.',
    ['battle.event.text.fallback']     = '%{key}',

    -- Errors / system
    ['battle.error.invalid_choice']    = 'That choice is not legal: %{message}',
    ['battle.error.expired_turn']      = 'That choice expired. Please choose again.',
    ['battle.error.session_paused']    = 'Reconnecting... please wait.',
    ['battle.error.desync']            = 'Re-syncing with the server...',
    ['battle.error.session_closed']    = 'The battle has ended.',
    ['battle.error.internal']          = 'The server hit an internal error.',
    ['battle.error.bad_envelope']      = 'The client and server disagree on protocol shape.',
    ['battle.error.version_mismatch']  = 'Protocol version mismatch.',
    ['battle.error.unknown']           = 'Error: %{code}',
  }
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
