# pokebrave-client-otcv8

OTCv8 client module for PokéBrave Phase 1.

This repository contains:

- `modules/game_battlehud/` — the OTCv8 module that draws the battle HUD (action
  list, turn-order bar, target selector, life bars, text log) and speaks the
  frozen battle contract (extended-opcode `60`, see DEV-3 v1).
- `tools/stub_server.py` — a stdlib-only Python stub that drives the contract
  from the §8 examples and supports a disconnect/reconnect scenario.
- `tools/harness.lua` — a headless Lua runner that loads the same module code
  against a fake `g_game` shim and produces structured recordings.
- `tests/` — Lua unit tests for `protocol`, `state`, and `prediction`.
- `recordings/` — proof artifacts (`turn_loop.log`, `reconnect.log`) generated
  by the harness against the stub server.

## Authority and licence posture

- The HUD never authors authoritative state. Damage, status, hit/miss, turn
  order, RNG, and KO decisions come from the server via `battle:resolve` and
  `battle:snapshot`. The HUD only renders.
- This repo does **not** vendor upstream OTCv8 binaries or assets. Packaging
  and redistribution paths are explicitly off-limits while the OTCv8 fork
  licence cleanup tracked in DEV-2 is unresolved.

## Running the proof

```
make harness           # turn loop
make harness-reconnect # disconnect mid-turn → snapshot → finish
make test              # Lua unit tests
```

Recordings land in `recordings/`. They show every observable event tagged
`recv|send|predict|reconcile|mispredict|reconnect|desync|decode_error`.
