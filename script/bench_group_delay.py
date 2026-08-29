#!/usr/bin/env python3
"""Measure the whole-group delay endpoint against the per-node fan-out it replaced (roadmap A6).

ClashMax's batch delay run used to issue one `GET /proxies/{name}/delay` per node. On the
maintainer's own profile that is ~1600 requests, and the jank it produced is where issues #10,
#11 and #18 all originate. A6 collapses a group past the promotion floor into a single
`GET /group/{name}/delay`. This script is the evidence for that trade, and it is committed so the
numbers quoted in docs/ROADMAP.md can be reproduced from a clone rather than taken on trust.

It is entirely self-contained and touches nothing outside its own temporary directory:

  * writes two configs — a "bench" core holding the synthetic group, and an "upstream" core in
    `mode: direct` that stands in for a reachable proxy, so no traffic leaves the machine;
  * starts both cores on high ports (17891/19090 and 18081/19091 by default), bound to 127.0.0.1;
  * measures the group endpoint three times, then the per-node fan-out at ClashMax's own
    concurrency limit;
  * kills both cores and removes the directory on the way out, including on Ctrl-C.

The synthetic group deliberately mixes three kinds of member, because a delay run on a real
subscription is mostly failures and the cost of a failure is what dominates the wall time:

  * `ok-*`    reach the upstream core and answer immediately;
  * `dead-*`  point at a closed port and fail with a connection refusal;
  * `hole-*`  point at an unroutable address and fail only when the timeout expires.

usage: script/bench_group_delay.py [options]
  --nodes N         members in the synthetic group (default 1200)
  --core PATH       mihomo binary (default Resources/Core/mihomo)
  --concurrency N   per-node fan-out concurrency (default 6, AppModel.proxyDelayBatchConcurrencyLimit)
  --timeout-ms N    delay-test timeout handed to the core (default 5000)
  --keep            leave the working directory in place for inspection
"""

import argparse
import json
import os
import pathlib
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor

REPO_ROOT = pathlib.Path(__file__).resolve().parent.parent
TEST_URL = "https://www.gstatic.com/generate_204"


def parse_args():
    parser = argparse.ArgumentParser(add_help=True, description=__doc__)
    parser.add_argument("--nodes", type=int, default=1200)
    parser.add_argument("--core", default=str(REPO_ROOT / "Resources/Core/mihomo"))
    parser.add_argument("--concurrency", type=int, default=6)
    parser.add_argument("--timeout-ms", type=int, default=5000)
    parser.add_argument("--bench-controller-port", type=int, default=19090)
    parser.add_argument("--bench-mixed-port", type=int, default=17891)
    parser.add_argument("--upstream-controller-port", type=int, default=19091)
    parser.add_argument("--upstream-mixed-port", type=int, default=18081)
    parser.add_argument("--keep", action="store_true")
    return parser.parse_args()


def write_configs(root, args):
    """Three thirds: reachable, refused, and black-holed until the timeout expires."""
    third = max(args.nodes // 3, 1)
    names = []
    proxies = []
    for index in range(args.nodes):
        if index < third:
            name = f"ok-{index:04d}"
            server, port = "127.0.0.1", args.upstream_mixed_port
        elif index < 2 * third:
            name = f"dead-{index:04d}"
            # A port nothing listens on: refused immediately.
            server, port = "127.0.0.1", 19999
        else:
            name = f"hole-{index:04d}"
            # Unroutable RFC 1918 address: fails only when the timeout expires.
            server, port = "10.255.255.1", 8080
        names.append(name)
        proxies.append(f'  - {{name: "{name}", type: http, server: {server}, port: {port}}}')

    bench_dir = root / "bench"
    upstream_dir = root / "upstream"
    bench_dir.mkdir(parents=True)
    upstream_dir.mkdir(parents=True)

    members = "\n".join(f"      - {name}" for name in names)
    (bench_dir / "config.yaml").write_text(
        f"mixed-port: {args.bench_mixed_port}\n"
        f"external-controller: 127.0.0.1:{args.bench_controller_port}\n"
        "mode: rule\n"
        "log-level: silent\n"
        "find-process-mode: off\n"
        "proxies:\n" + "\n".join(proxies) + "\n"
        "proxy-groups:\n"
        "  - name: Bench\n"
        "    type: select\n"
        "    proxies:\n" + members + "\n"
        "rules:\n"
        "  - MATCH,DIRECT\n",
        encoding="utf-8",
    )
    (upstream_dir / "config.yaml").write_text(
        f"mixed-port: {args.upstream_mixed_port}\n"
        f"external-controller: 127.0.0.1:{args.upstream_controller_port}\n"
        "mode: direct\n"
        "log-level: silent\n"
        "find-process-mode: off\n",
        encoding="utf-8",
    )
    return bench_dir, upstream_dir


def start_core(core, directory, log_path):
    log = open(log_path, "w", encoding="utf-8")
    process = subprocess.Popen(
        [core, "-d", str(directory)],
        stdout=log,
        stderr=subprocess.STDOUT,
        start_new_session=True,
    )
    return process, log


def wait_for_controller(port, process, timeout=30):
    base = f"http://127.0.0.1:{port}"
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise SystemExit(f"core on port {port} exited with {process.returncode}")
        try:
            with urllib.request.urlopen(base + "/version", timeout=1) as response:
                response.read()
                return
        except Exception:
            time.sleep(0.1)
    raise SystemExit(f"core on port {port} never answered /version")


def make_getter(base):
    def get(path, timeout):
        try:
            with urllib.request.urlopen(base + path, timeout=timeout) as response:
                return json.loads(response.read().decode())
        except urllib.error.HTTPError as error:
            try:
                return json.loads(error.read().decode())
            except Exception:
                return {"message": f"HTTP {error.code}"}
        except Exception as error:
            return {"message": str(error)}

    return get


def measure(get, members, query, concurrency):
    # Warm DNS/TLS to the probe host so neither path pays first-connection cost.
    for name in members[:5]:
        get(f"/proxies/{urllib.parse.quote(name)}/delay?{query}", 15)

    print("\n== group endpoint: GET /group/Bench/delay ==", flush=True)
    group_times = []
    for run in range(3):
        started = time.monotonic()
        body = get(f"/group/Bench/delay?{query}", 300)
        elapsed = time.monotonic() - started
        answered = len(body) if isinstance(body, dict) and "message" not in body else -1
        group_times.append(elapsed)
        print(
            f"  run {run + 1}: {elapsed:7.2f}s   nodes with a delay: {answered}"
            f"   omitted: {len(members) - answered}",
            flush=True,
        )

    print(
        f"\n== per-node fan-out: {len(members)} x GET /proxies/<name>/delay,"
        f" concurrency {concurrency} ==",
        flush=True,
    )

    def one(name):
        return "delay" in get(f"/proxies/{urllib.parse.quote(name)}/delay?{query}", 60)

    started = time.monotonic()
    succeeded = 0
    with ThreadPoolExecutor(max_workers=concurrency) as pool:
        for ok in pool.map(one, members):
            succeeded += 1 if ok else 0
    node_elapsed = time.monotonic() - started
    print(
        f"  {node_elapsed:7.2f}s   succeeded: {succeeded}"
        f"   failed: {len(members) - succeeded}",
        flush=True,
    )

    best = min(group_times)
    print("\n== result ==")
    print(f"  nodes                 {len(members)}")
    print(f"  group endpoint        {best:.2f}s (best of 3; median {sorted(group_times)[1]:.2f}s)")
    print(f"  per-node fan-out      {node_elapsed:.2f}s")
    print(f"  speedup               {node_elapsed / best:.1f}x  ({node_elapsed - best:.0f}s saved)")


def main():
    args = parse_args()
    core = os.path.abspath(args.core)
    if not os.access(core, os.X_OK):
        raise SystemExit(
            f"mihomo core not found or not executable at {core}.\n"
            "The bundled core is gitignored; run script/install_mihomo_core.sh first, "
            "or pass --core PATH."
        )

    root = pathlib.Path(tempfile.mkdtemp(prefix="clashmax-a6bench-"))
    processes = []
    logs = []

    def shutdown(*_):
        for process in processes:
            if process.poll() is None:
                process.terminate()
        for process in processes:
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
        for log in logs:
            log.close()
        if args.keep:
            print(f"\nworking directory kept at {root}")
        else:
            shutil.rmtree(root, ignore_errors=True)

    signal.signal(signal.SIGINT, lambda *_: (shutdown(), sys.exit(130)))

    try:
        bench_dir, upstream_dir = write_configs(root, args)
        for directory, port, label in (
            (upstream_dir, args.upstream_controller_port, "upstream"),
            (bench_dir, args.bench_controller_port, "bench"),
        ):
            process, log = start_core(core, directory, root / f"{label}.log")
            processes.append(process)
            logs.append(log)
            wait_for_controller(port, process)

        get = make_getter(f"http://127.0.0.1:{args.bench_controller_port}")
        query = urllib.parse.urlencode({"url": TEST_URL, "timeout": args.timeout_ms})
        group = get("/proxies/Bench", 10)
        members = group.get("all") if isinstance(group, dict) else None
        if not members:
            raise SystemExit(f"could not read the Bench group: {group}")
        print(f"group members: {len(members)}", flush=True)
        measure(get, members, query, args.concurrency)
    finally:
        shutdown()


if __name__ == "__main__":
    main()
