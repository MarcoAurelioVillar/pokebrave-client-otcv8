#!/usr/bin/env python3
"""
stub_fixture.py — generates the full NDJSON exchange for a scenario, with
pre-scripted client choices (slot A always picks thunderbolt, turn by turn).
Writes to stdout; the Lua harness reads from stdin.

This avoids the bidirectional fifo problem by baking in both sides of the
dialog. The point is to prove the HUD decode/state/reconcile pipeline fires
correctly against real contract payloads — not to test that the stub server
handles arbitrary client input (that belongs in server-side tests).

Usage:
    python3 tools/stub_fixture.py --scenario turn_loop
    python3 tools/stub_fixture.py --scenario reconnect
"""
from __future__ import annotations
import argparse, json, sys, time, uuid

V = 1
SESSION = "S1"
BASE_TS = 1715623200000

def ts(offset_ms: int = 0) -> int:
    return BASE_TS + offset_ms

def make_id(n: int) -> str:
    return f"ID{n:04d}"

def envelope(n: int, op: str, body: dict, offset_ms: int = 0) -> str:
    return json.dumps({"v": V, "op": op, "id": make_id(n), "session": SESSION, "ts": ts(offset_ms), "body": body}, separators=(",", ":"))

def start_body(deadline_offset: int = 30000) -> dict:
    return {
        "session": SESSION, "turn": 1,
        "you": {"slot": "A", "userId": 12345},
        "opponent": {"slot": "B", "kind": "npc", "label": "Trainer Joey", "userId": None},
        "arena": {"id": "arena_pewter_gym", "lockTeleport": True},
        "participants": [
            {"slot": "A", "active": {
                "pid": "p_A_0", "speciesId": 25, "speciesName": "Pikachu", "level": 50,
                "hp": {"current": 145, "max": 145}, "status": None, "fainted": False,
                "moves": [
                    {"moveId": "thunderbolt", "name": "Thunderbolt", "pp": {"current": 15, "max": 15}, "priority": 0, "target": "opponent_active"},
                    {"moveId": "quick_attack", "name": "Quick Attack", "pp": {"current": 30, "max": 30}, "priority": 1, "target": "opponent_active"},
                ]}, "bench": []},
            {"slot": "B", "active": {
                "pid": "p_B_0", "speciesId": 19, "speciesName": "Rattata", "level": 14,
                "hp": {"current": 50, "max": 50}, "status": None, "fainted": False}, "bench": []},
        ],
        "rules": {"format": "1v1", "turnTimeoutMs": 30000, "forcedSwitchTimeoutMs": 15000, "reconnectGraceMs": 60000, "allowSurrender": True, "maxTurns": 200},
        "choiceWindow": {"turn": 1, "deadline": ts(deadline_offset), "valid": {"slot": "A", "actions": ["move", "switch", "surrender"]}},
    }

def client_choice(n: int, turn: int, nonce: str, offset: int = 0) -> str:
    return json.dumps({"v": V, "op": "battle:choices", "id": make_id(n), "session": SESSION, "ts": ts(offset), "body": {
        "session": SESSION, "turn": turn, "slot": "A",
        "choice": {"kind": "move", "moveId": "thunderbolt", "target": "B:active"},
        "clientNonce": nonce,
    }}, separators=(",", ":"))

def resolve_t1(client_nonce: str, offset: int = 0) -> dict:
    return {
        "session": SESSION, "turn": 1, "ordered": True,
        "events": [
            {"seq": 0, "kind": "choices_locked",
             "bySlot": {"A": {"kind": "move", "moveId": "thunderbolt", "target": "B:active", "clientNonce": client_nonce},
                        "B": {"kind": "move", "moveId": "tackle", "target": "A:active", "clientNonce": None}},
             "order": [{"slot": "A", "priority": 0, "effectiveSpeed": 90}, {"slot": "B", "priority": 0, "effectiveSpeed": 60}],
             "tieBreak": None},
            {"seq": 1, "kind": "action_start", "slot": "A", "action": {"kind": "move", "moveId": "thunderbolt", "target": "B:active"}},
            {"seq": 2, "kind": "damage", "source": "A:active", "target": "B:active", "amount": 32, "after": {"hp": 18}, "crit": False, "effectiveness": 1.0},
            {"seq": 3, "kind": "status_inflict", "target": "B:active", "status": {"name": "paralysis", "stacks": 1, "remainingTurns": None}},
            {"seq": 4, "kind": "action_start", "slot": "B", "action": {"kind": "move", "moveId": "tackle", "target": "A:active"}},
            {"seq": 5, "kind": "action_skipped", "slot": "B", "reason": "paralysis_full"},
            {"seq": 6, "kind": "turn_end_tick", "slot": "B", "effect": "status:paralysis", "delta": None},
        ],
        "publicState": {
            "A:active": {"hp": {"current": 145, "max": 145}, "status": None, "fainted": False},
            "B:active": {"hp": {"current": 18, "max": 50}, "status": {"name": "paralysis", "stacks": 1, "remainingTurns": None}, "fainted": False},
        },
        "next": {"kind": "awaiting_choices", "choiceWindow": {"turn": 2, "deadline": ts(60000), "valid": {"slot": "A", "actions": ["move", "switch", "surrender"]}}},
    }

def resolve_t2_ko(client_nonce: str, offset: int = 0) -> dict:
    return {
        "session": SESSION, "turn": 2, "ordered": True,
        "events": [
            {"seq": 0, "kind": "choices_locked",
             "bySlot": {"A": {"kind": "move", "moveId": "thunderbolt", "target": "B:active", "clientNonce": client_nonce},
                        "B": {"kind": "move", "moveId": "tackle", "target": "A:active", "clientNonce": None}},
             "order": [{"slot": "A", "priority": 0, "effectiveSpeed": 90}, {"slot": "B", "priority": 0, "effectiveSpeed": 30}],
             "tieBreak": None},
            {"seq": 1, "kind": "action_start", "slot": "A", "action": {"kind": "move", "moveId": "thunderbolt", "target": "B:active"}},
            {"seq": 2, "kind": "damage", "source": "A:active", "target": "B:active", "amount": 18, "after": {"hp": 0}, "crit": False, "effectiveness": 1.0},
            {"seq": 3, "kind": "faint", "target": "B:active", "reason": "hp_zero"},
        ],
        "publicState": {
            "A:active": {"hp": {"current": 145, "max": 145}, "status": None, "fainted": False},
            "B:active": {"hp": {"current": 0, "max": 50}, "status": None, "fainted": True},
        },
        "next": {"kind": "battle_end"},
    }

def end_body(turn: int = 2) -> dict:
    return {
        "session": SESSION, "turn": turn,
        "outcome": {"winner": "A"}, "reason": "ko",
        "finalState": {
            "A:active": {"hp": {"current": 145, "max": 145}, "status": None, "fainted": False},
            "B:active": {"hp": {"current": 0, "max": 50}, "status": None, "fainted": True},
        },
        "rewards": {"xp": {"A": 1200, "B": 0}},
        "logRef": "battle:" + SESSION,
    }

def snapshot_body() -> dict:
    return {
        "session": SESSION, "snapshotId": "snap_RECONNECT", "turn": 2,
        "state": "awaiting_choices",
        "you": {"slot": "A", "userId": 12345},
        "opponent": {"slot": "B", "kind": "npc", "label": "Trainer Joey", "userId": None},
        "arena": {"id": "arena_pewter_gym", "lockTeleport": True},
        "rules": {"format": "1v1", "turnTimeoutMs": 30000, "forcedSwitchTimeoutMs": 15000, "reconnectGraceMs": 60000, "allowSurrender": True, "maxTurns": 200},
        "participants": [
            {"slot": "A", "active": {
                "pid": "p_A_0", "speciesId": 25, "speciesName": "Pikachu", "level": 50,
                "hp": {"current": 145, "max": 145}, "status": None, "fainted": False,
                "moves": [{"moveId": "thunderbolt", "name": "Thunderbolt", "pp": {"current": 14, "max": 15}, "priority": 0, "target": "opponent_active"}]},
             "bench": []},
            {"slot": "B", "active": {
                "pid": "p_B_0", "speciesId": 19, "speciesName": "Rattata", "level": 14,
                "hp": {"current": 18, "max": 50}, "status": {"name": "paralysis", "stacks": 1, "remainingTurns": None}, "fainted": False},
             "bench": []},
        ],
        "publicState": {
            "A:active": {"hp": {"current": 145, "max": 145}, "status": None, "fainted": False},
            "B:active": {"hp": {"current": 18, "max": 50}, "status": {"name": "paralysis", "stacks": 1, "remainingTurns": None}, "fainted": False},
        },
        "history": {"from": 1, "to": 1, "truncated": False, "items": []},
        "choiceWindow": {"turn": 2, "deadline": ts(90000), "valid": {"slot": "A", "actions": ["move", "switch", "surrender"]}},
        "specVersion": "1",
    }

def emit(line: str) -> None:
    sys.stdout.write(line + "\n")
    sys.stdout.flush()

def run_turn_loop() -> None:
    # S→C start
    emit(envelope(1, "battle:start", start_body()))
    # C→S choice t1 (pre-scripted)
    emit(client_choice(2, 1, "c_0001", 5000))
    # S→C resolve t1
    emit(envelope(3, "battle:resolve", resolve_t1("c_0001", 6500)))
    # C→S ack (optional)
    emit(json.dumps({"v":1,"op":"battle:ack","id":"ID0004","session":SESSION,"ts":ts(7000),"body":{"session":SESSION,"ref":"ID0003","kind":"applied"}}, separators=(",",":")))
    # C→S choice t2
    emit(client_choice(5, 2, "c_0002", 36000))
    # S→C resolve t2 KO
    emit(envelope(6, "battle:resolve", resolve_t2_ko("c_0002", 37000)))
    # S→C end
    emit(envelope(7, "battle:end", end_body(), 37500))

def run_reconnect() -> None:
    # S→C start
    emit(envelope(1, "battle:start", start_body()))
    # C→S choice t1
    emit(client_choice(2, 1, "c_0001", 5000))
    # S→C resolve t1
    emit(envelope(3, "battle:resolve", resolve_t1("c_0001", 6500)))
    # --- DISCONNECT marker (the Lua harness watches for this tag) ---
    emit(json.dumps({"_meta": "disconnect"}, separators=(",",":")))
    # S→C snapshot on reconnect
    emit(envelope(4, "battle:snapshot", snapshot_body(), 66500))
    # C→S choice t2 (after reconnect)
    emit(client_choice(5, 2, "c_0002", 70000))
    # S→C resolve t2 KO
    emit(envelope(6, "battle:resolve", resolve_t2_ko("c_0002", 71000)))
    # S→C end
    emit(envelope(7, "battle:end", end_body(), 71500))

def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--scenario", choices=["turn_loop", "reconnect"], default="turn_loop")
    args = ap.parse_args()
    if args.scenario == "turn_loop":
        run_turn_loop()
    else:
        run_reconnect()
    return 0

if __name__ == "__main__":
    sys.exit(main())
