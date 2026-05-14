#!/usr/bin/env python3
"""
stub_server.py — emits the frozen v1 battle contract per DEV-3.

Speaks NDJSON over stdin/stdout: one envelope per line, both directions.
The headless Lua harness in tools/harness.lua drives this script as a
subprocess; the same script can be wired to a real WebSocket for manual
play with no code changes (just swap the readline/print loop).

Usage:
    python3 tools/stub_server.py --scenario turn_loop
    python3 tools/stub_server.py --scenario reconnect

Scenarios:
    turn_loop  — battle:start → choices → resolve → choices → resolve(KO) → end
    reconnect  — battle:start → resolve → simulate disconnect → battle:snapshot → finish

The server is dumb — it does not implement the resolver. It only emits the
locked envelope shapes from §3 and §8 of the battle contract. That is
enough to prove the HUD wires up to opcodes and not to hardcoded state.
"""
from __future__ import annotations

import argparse
import json
import sys
import time
import uuid

V = 1
SESSION = "01HZP3K0R2A5N4VK7BX2Y2BTQD"
EXT_OPCODE = 60


def now_ms() -> int:
    return int(time.time() * 1000)


def make_id() -> str:
    return uuid.uuid4().hex[:26].upper()


def send(envelope: dict) -> None:
    sys.stdout.write(json.dumps(envelope, separators=(",", ":")) + "\n")
    sys.stdout.flush()


def envelope(op: str, body: dict) -> dict:
    return {
        "v": V,
        "op": op,
        "id": make_id(),
        "session": SESSION,
        "ts": now_ms(),
        "body": body,
    }


def battle_start_body() -> dict:
    return {
        "session": SESSION,
        "turn": 1,
        "you": {"slot": "A", "userId": 12345},
        "opponent": {"slot": "B", "kind": "npc", "label": "Trainer Joey", "userId": None},
        "arena": {"id": "arena_pewter_gym", "lockTeleport": True},
        "participants": [
            {
                "slot": "A",
                "active": {
                    "pid": "p_A_0",
                    "speciesId": 25,
                    "speciesName": "Pikachu",
                    "level": 50,
                    "hp": {"current": 145, "max": 145},
                    "status": None,
                    "fainted": False,
                    "moves": [
                        {
                            "moveId": "thunderbolt",
                            "name": "Thunderbolt",
                            "pp": {"current": 15, "max": 15},
                            "priority": 0,
                            "target": "opponent_active",
                        },
                        {
                            "moveId": "quick_attack",
                            "name": "Quick Attack",
                            "pp": {"current": 30, "max": 30},
                            "priority": 1,
                            "target": "opponent_active",
                        },
                    ],
                },
                "bench": [],
            },
            {
                "slot": "B",
                "active": {
                    "pid": "p_B_0",
                    "speciesId": 19,
                    "speciesName": "Rattata",
                    "level": 14,
                    "hp": {"current": 50, "max": 50},
                    "status": None,
                    "fainted": False,
                },
                "bench": [],
            },
        ],
        "rules": {
            "format": "1v1",
            "turnTimeoutMs": 30000,
            "forcedSwitchTimeoutMs": 15000,
            "reconnectGraceMs": 60000,
            "allowSurrender": True,
            "maxTurns": 200,
        },
        "choiceWindow": {
            "turn": 1,
            "deadline": now_ms() + 30_000,
            "valid": {"slot": "A", "actions": ["move", "switch", "surrender"]},
        },
    }


def resolve_turn1_body(client_nonce: str | None) -> dict:
    return {
        "session": SESSION,
        "turn": 1,
        "ordered": True,
        "events": [
            {
                "seq": 0,
                "kind": "choices_locked",
                "bySlot": {
                    "A": {
                        "kind": "move",
                        "moveId": "thunderbolt",
                        "target": "B:active",
                        "clientNonce": client_nonce,
                    },
                    "B": {
                        "kind": "move",
                        "moveId": "tackle",
                        "target": "A:active",
                        "clientNonce": None,
                    },
                },
                "order": [
                    {"slot": "A", "priority": 0, "effectiveSpeed": 90},
                    {"slot": "B", "priority": 0, "effectiveSpeed": 60},
                ],
                "tieBreak": None,
            },
            {
                "seq": 1,
                "kind": "action_start",
                "slot": "A",
                "action": {"kind": "move", "moveId": "thunderbolt", "target": "B:active"},
            },
            {
                "seq": 2,
                "kind": "damage",
                "source": "A:active",
                "target": "B:active",
                "amount": 32,
                "after": {"hp": 18},
                "crit": False,
                "effectiveness": 1.0,
            },
            {
                "seq": 3,
                "kind": "status_inflict",
                "target": "B:active",
                "status": {"name": "paralysis", "stacks": 1, "remainingTurns": None},
            },
            {
                "seq": 4,
                "kind": "action_start",
                "slot": "B",
                "action": {"kind": "move", "moveId": "tackle", "target": "A:active"},
            },
            {
                "seq": 5,
                "kind": "action_skipped",
                "slot": "B",
                "reason": "paralysis_full",
            },
            {
                "seq": 6,
                "kind": "turn_end_tick",
                "slot": "B",
                "effect": "status:paralysis",
                "delta": None,
            },
        ],
        "publicState": {
            "A:active": {"hp": {"current": 145, "max": 145}, "status": None, "fainted": False},
            "B:active": {
                "hp": {"current": 18, "max": 50},
                "status": {"name": "paralysis", "stacks": 1, "remainingTurns": None},
                "fainted": False,
            },
        },
        "next": {
            "kind": "awaiting_choices",
            "choiceWindow": {
                "turn": 2,
                "deadline": now_ms() + 30_000,
                "valid": {"slot": "A", "actions": ["move", "switch", "surrender"]},
            },
        },
    }


def resolve_turn2_ko_body(client_nonce: str | None) -> dict:
    return {
        "session": SESSION,
        "turn": 2,
        "ordered": True,
        "events": [
            {
                "seq": 0,
                "kind": "choices_locked",
                "bySlot": {
                    "A": {
                        "kind": "move",
                        "moveId": "thunderbolt",
                        "target": "B:active",
                        "clientNonce": client_nonce,
                    },
                    "B": {
                        "kind": "move",
                        "moveId": "tackle",
                        "target": "A:active",
                        "clientNonce": None,
                    },
                },
                "order": [
                    {"slot": "A", "priority": 0, "effectiveSpeed": 90},
                    {"slot": "B", "priority": 0, "effectiveSpeed": 30},
                ],
                "tieBreak": None,
            },
            {
                "seq": 1,
                "kind": "action_start",
                "slot": "A",
                "action": {"kind": "move", "moveId": "thunderbolt", "target": "B:active"},
            },
            {
                "seq": 2,
                "kind": "damage",
                "source": "A:active",
                "target": "B:active",
                "amount": 18,
                "after": {"hp": 0},
                "crit": False,
                "effectiveness": 1.0,
            },
            {"seq": 3, "kind": "faint", "target": "B:active", "reason": "hp_zero"},
        ],
        "publicState": {
            "A:active": {"hp": {"current": 145, "max": 145}, "status": None, "fainted": False},
            "B:active": {"hp": {"current": 0, "max": 50}, "status": None, "fainted": True},
        },
        "next": {"kind": "battle_end"},
    }


def battle_end_body() -> dict:
    return {
        "session": SESSION,
        "turn": 2,
        "outcome": {"winner": "A"},
        "reason": "ko",
        "finalState": {
            "A:active": {"hp": {"current": 145, "max": 145}, "status": None, "fainted": False},
            "B:active": {"hp": {"current": 0, "max": 50}, "status": None, "fainted": True},
        },
        "rewards": {"xp": {"A": 1200, "B": 0}},
        "logRef": "battle:" + SESSION,
    }


def snapshot_body() -> dict:
    return {
        "session": SESSION,
        "snapshotId": "snap_" + make_id(),
        "turn": 2,
        "state": "awaiting_choices",
        "you": {"slot": "A", "userId": 12345},
        "opponent": {"slot": "B", "kind": "npc", "label": "Trainer Joey", "userId": None},
        "arena": {"id": "arena_pewter_gym", "lockTeleport": True},
        "rules": {
            "format": "1v1",
            "turnTimeoutMs": 30000,
            "forcedSwitchTimeoutMs": 15000,
            "reconnectGraceMs": 60000,
            "allowSurrender": True,
            "maxTurns": 200,
        },
        "participants": [
            {
                "slot": "A",
                "active": {
                    "pid": "p_A_0",
                    "speciesId": 25,
                    "speciesName": "Pikachu",
                    "level": 50,
                    "hp": {"current": 145, "max": 145},
                    "status": None,
                    "fainted": False,
                    "moves": [
                        {
                            "moveId": "thunderbolt",
                            "name": "Thunderbolt",
                            "pp": {"current": 14, "max": 15},
                            "priority": 0,
                            "target": "opponent_active",
                        },
                        {
                            "moveId": "quick_attack",
                            "name": "Quick Attack",
                            "pp": {"current": 30, "max": 30},
                            "priority": 1,
                            "target": "opponent_active",
                        },
                    ],
                },
                "bench": [],
            },
            {
                "slot": "B",
                "active": {
                    "pid": "p_B_0",
                    "speciesId": 19,
                    "speciesName": "Rattata",
                    "level": 14,
                    "hp": {"current": 18, "max": 50},
                    "status": {"name": "paralysis", "stacks": 1, "remainingTurns": None},
                    "fainted": False,
                },
                "bench": [],
            },
        ],
        "publicState": {
            "A:active": {"hp": {"current": 145, "max": 145}, "status": None, "fainted": False},
            "B:active": {
                "hp": {"current": 18, "max": 50},
                "status": {"name": "paralysis", "stacks": 1, "remainingTurns": None},
                "fainted": False,
            },
        },
        "history": {"from": 1, "to": 1, "truncated": False, "items": []},
        "choiceWindow": {
            "turn": 2,
            "deadline": now_ms() + 30_000,
            "valid": {"slot": "A", "actions": ["move", "switch", "surrender"]},
        },
        "specVersion": "1",
    }


def read_envelope() -> dict | None:
    line = sys.stdin.readline()
    if not line:
        return None
    line = line.strip()
    if not line:
        return None
    try:
        return json.loads(line)
    except json.JSONDecodeError:
        return None


def expect_choice(timeout_s: float = 5.0) -> dict | None:
    deadline = time.time() + timeout_s
    while time.time() < deadline:
        env = read_envelope()
        if env is None:
            time.sleep(0.01)
            continue
        if env.get("op") == "battle:choices":
            return env
        # Ignore acks and other client-side noise.
    return None


def run_turn_loop() -> None:
    send(envelope("battle:start", battle_start_body()))
    choice = expect_choice()
    nonce_t1 = (choice or {}).get("body", {}).get("clientNonce")
    send(envelope("battle:resolve", resolve_turn1_body(nonce_t1)))
    choice = expect_choice()
    nonce_t2 = (choice or {}).get("body", {}).get("clientNonce")
    send(envelope("battle:resolve", resolve_turn2_ko_body(nonce_t2)))
    send(envelope("battle:end", battle_end_body()))


def run_reconnect() -> None:
    send(envelope("battle:start", battle_start_body()))
    choice = expect_choice()
    nonce_t1 = (choice or {}).get("body", {}).get("clientNonce")
    send(envelope("battle:resolve", resolve_turn1_body(nonce_t1)))
    # Simulate disconnect: harness will signal it dropped, then read snapshot.
    line = sys.stdin.readline().strip()
    if line != "__DISCONNECT__":
        # Tolerant: any sentinel triggers snapshot. Empty line => give up.
        if not line:
            return
    send(envelope("battle:snapshot", snapshot_body()))
    choice = expect_choice()
    nonce_t2 = (choice or {}).get("body", {}).get("clientNonce")
    send(envelope("battle:resolve", resolve_turn2_ko_body(nonce_t2)))
    send(envelope("battle:end", battle_end_body()))


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument(
        "--scenario",
        choices=["turn_loop", "reconnect"],
        default="turn_loop",
    )
    args = ap.parse_args()
    if args.scenario == "turn_loop":
        run_turn_loop()
    else:
        run_reconnect()
    return 0


if __name__ == "__main__":
    sys.exit(main())
