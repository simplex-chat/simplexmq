#!/usr/bin/env python3
"""Sync progress for the Reth + Nimbus stack.

Usage:
  ./progress.py           # continuous (Ctrl-C to exit, auto-exits when synced)
  ./progress.py --once    # single snapshot

Requires Nimbus REST port exposed at 127.0.0.1:5052 (add --rest flag in compose).
"""

import json
import sys
import time
from collections import deque
from datetime import timedelta
from urllib.error import URLError
from urllib.request import Request, urlopen

RETH = "http://127.0.0.1:8545"
NIMBUS = "http://127.0.0.1:5052"
INTERVAL = 5
WINDOW = 60
BAR_W = 40

# ANSI helpers
def c(s, code): return f"\033[{code}m{s}\033[0m"
GREEN, YELLOW, RED, DIM, BOLD = "32", "33", "31", "2;37", "1"


def rpc(method):
    body = json.dumps({"jsonrpc": "2.0", "method": method, "params": [], "id": 1}).encode()
    req = Request(RETH, data=body, headers={"Content-Type": "application/json"})
    return json.loads(urlopen(req, timeout=5).read())["result"]


def get_reth():
    try:
        r = rpc("eth_syncing")
        try:
            peers = int(rpc("net_peerCount"), 16)
        except Exception:
            peers = -1            # net namespace not exposed
        if r is False:
            head = int(rpc("eth_blockNumber"), 16)
            return {"state": "synced", "current": head, "target": head, "peers": peers,
                    "stage": None, "stages": {}, "err": None}
        current = int(r["currentBlock"], 16)
        highest = int(r["highestBlock"], 16)
        # Build stage map (name -> block).
        stages = {s["name"]: int(s["block"], 16) for s in r.get("stages", [])}
        active_stages = {k: v for k, v in stages.items() if v > 0}
        # Headers download phase: nothing has progressed yet.
        if current == 0 and highest == 0 and not active_stages:
            return {"state": "headers", "current": 0, "target": 0, "peers": peers,
                    "stage": "Headers", "stages": stages, "err": None}
        # Derive progress from the stages pipeline.
        # Bottleneck (rate-limiting stage) = stage with lowest non-zero block.
        # Target = leading stage block (typically Headers = chain tip).
        # Reth's top-level currentBlock/highestBlock are unreliable during initial
        # sync (often 0 until execution stage runs), so prefer stages-derived values.
        if active_stages:
            bottleneck = min(active_stages, key=active_stages.get)
            stage_current = active_stages[bottleneck]
            stage_target = max(stages.values()) if stages else 0
            # Trust the stages-derived values if highest is unset or stages tip is higher.
            if highest <= 0 or stage_target > highest:
                current = stage_current
                highest = stage_target
            elif current <= 0:
                current = stage_current
        else:
            bottleneck = None
        return {"state": "syncing", "current": current, "target": highest,
                "peers": peers, "stage": bottleneck, "stages": stages, "err": None}
    except URLError as e:
        return {"state": "down", "current": 0, "target": 0, "peers": 0,
                "stage": None, "stages": {}, "err": str(e.reason)}
    except Exception as e:
        return {"state": "error", "current": 0, "target": 0, "peers": 0,
                "stage": None, "stages": {}, "err": str(e)}


def get_nimbus():
    try:
        d = json.loads(urlopen(f"{NIMBUS}/eth/v1/node/syncing", timeout=5).read())["data"]
        peers_d = json.loads(urlopen(f"{NIMBUS}/eth/v1/node/peer_count", timeout=5).read())["data"]
        head = int(d["head_slot"])
        dist = int(d["sync_distance"])
        peers = int(peers_d.get("connected", "0"))
        return {"state": "synced" if not d["is_syncing"] else "syncing",
                "current": head, "target": head + dist, "peers": peers,
                "optimistic": bool(d.get("is_optimistic", False)),
                "el_offline": bool(d.get("el_offline", False)),
                "err": None}
    except URLError as e:
        return {"state": "down", "current": 0, "target": 0, "peers": 0,
                "optimistic": False, "el_offline": False, "err": str(e.reason)}
    except Exception as e:
        return {"state": "error", "current": 0, "target": 0, "peers": 0,
                "optimistic": False, "el_offline": False, "err": str(e)}


def format_num(n): return f"{n:,}"


def format_eta(seconds):
    if seconds is None: return "?"
    if seconds < 0: return "?"
    if seconds < 60: return f"{int(seconds)}s"
    if seconds < 3600:
        return f"{int(seconds // 60)}m {int(seconds % 60)}s"
    if seconds < 86400:
        return f"{int(seconds // 3600)}h {int((seconds % 3600) // 60)}m"
    return f"{int(seconds // 86400)}d {int((seconds % 86400) // 3600)}h"


def rate_per_sec(history):
    if len(history) < 2: return None
    t0, c0 = history[0]
    t1, c1 = history[-1]
    if t1 <= t0: return None
    return (c1 - c0) / (t1 - t0)


def eta_seconds(history, target):
    r = rate_per_sec(history)
    if r is None or r <= 0: return None
    remaining = target - history[-1][1]
    if remaining <= 0: return 0
    return remaining / r


def progress_bar(pct):
    pct = max(0.0, min(100.0, pct))
    filled = int(pct / 100 * BAR_W)
    return c("█" * filled, GREEN) + c("░" * (BAR_W - filled), DIM)


def peers_label(peers):
    if peers < 0:
        return c("· peers unknown (enable net namespace)", DIM)
    return c(f"· {peers} peers", DIM)


def stages_summary(stages):
    """One-line view: stages that have progressed, with their block numbers."""
    if not stages:
        return ""
    advanced = [(n, b) for n, b in stages.items() if b > 0]
    if not advanced:
        return c("  stages: all 0 (headers downloading)", DIM)
    advanced.sort(key=lambda kv: kv[1], reverse=True)
    parts = [f"{n}={format_num(b)}" for n, b in advanced[:4]]
    return c("  stages: " + ", ".join(parts), DIM)


def render_one(name, x, hist):
    state = x["state"]
    peers = x.get("peers", 0)
    extras = []
    if name == "Nimbus":
        if x.get("optimistic"):
            extras.append(c("(optimistic head — Reth not yet verifying)", YELLOW))
        if x.get("el_offline"):
            extras.append(c("⚠ EL OFFLINE", RED))
    if state == "synced":
        out = [f"  {c(name, BOLD):<14s} {c('✓ synced', GREEN)}      {c(format_num(x['current']), BOLD)}  {peers_label(peers)}"]
    elif state == "headers":
        out = [
            f"  {c(name, BOLD):<14s} {c('⧗ headers', YELLOW)}    {c('downloading initial chain', DIM)}  {peers_label(peers)}",
            f"                 {c('(per-block progress unavailable until headers validated — see docker logs)', DIM)}",
        ]
    elif state == "syncing" and x["target"] <= 0:
        out = [f"  {c(name, BOLD):<14s} {c('⧗ syncing', YELLOW)}    {c('waiting for fork-choice', DIM)}  {peers_label(peers)}"]
    elif state == "syncing":
        pct = x["current"] / x["target"] * 100
        r = rate_per_sec(hist)
        eta = eta_seconds(hist, x["target"])
        rate_s = f"{format_num(int(r))} /s" if r and r > 0 else c("stalled", RED)
        eta_s = format_eta(eta) if eta is not None else "?"
        stage = x.get("stage")
        stage_s = c(f"[{stage}]", DIM) if stage else ""
        out = [
            f"  {c(name, BOLD):<14s} {c('⧗ syncing', YELLOW)}    {format_num(x['current'])} / {format_num(x['target'])}  {stage_s}  {peers_label(peers)}",
            f"                 {progress_bar(pct)} {c(f'{pct:6.2f}%', BOLD)}",
            f"                 {c(rate_s, DIM)}   ETA {c(eta_s, BOLD)}",
        ]
    else:
        out = [
            f"  {c(name, BOLD):<14s} {c('✗ ' + state, RED)}",
            f"                 {c(x.get('err') or '', DIM)}",
        ]
    # Reth-only: stages summary
    if name == "Reth" and x.get("stages"):
        out.append(f"               {stages_summary(x['stages'])}")
    for e in extras:
        out.append(f"                 {e}")
    return out


def render(reth, nimbus, reth_hist, nim_hist):
    print("\033[2J\033[H", end="")
    width = 64
    title = f"Reth + Nimbus sync"
    ts = time.strftime("%H:%M:%S")
    print()
    print(f"  {c(title, BOLD)}   {c(ts, DIM)}")
    print(f"  {c('─' * width, DIM)}")
    print()
    for line in render_one("Reth", reth, reth_hist):
        print(line)
    print()
    for line in render_one("Nimbus", nimbus, nim_hist):
        print(line)
    print()
    win_s = (len(reth_hist) - 1) * INTERVAL if len(reth_hist) > 1 else 0
    print(f"  {c(f'window {win_s}s · refresh {INTERVAL}s · Ctrl-C to exit', DIM)}")
    print()


def main():
    once = "--once" in sys.argv
    reth_hist = deque(maxlen=WINDOW)
    nim_hist = deque(maxlen=WINDOW)
    try:
        while True:
            r = get_reth()
            n = get_nimbus()
            now = time.time()
            if r["target"] > 0 or r["state"] == "syncing":
                reth_hist.append((now, r["current"]))
            if n["target"] > 0 or n["state"] == "syncing":
                nim_hist.append((now, n["current"]))
            render(r, n, reth_hist, nim_hist)
            if once:
                break
            if r["state"] == "synced" and n["state"] == "synced":
                print(f"  {c('✓ all synced.', GREEN)}\n")
                break
            time.sleep(INTERVAL)
    except KeyboardInterrupt:
        print()


if __name__ == "__main__":
    main()
