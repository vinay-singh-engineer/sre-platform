#!/usr/bin/env python3
"""
Automated health check script.

Polls the service health endpoints and API, reports current SLO metrics,
and exits non-zero if the service is unhealthy.

Usage:
    python3 runbooks/scripts/check_health.py --base-url http://ALB_DNS
    python3 runbooks/scripts/check_health.py --base-url http://ALB_DNS --duration 120
"""
import argparse
import sys
import time
import urllib.request
import urllib.error
import json
from datetime import datetime, timezone


def _now() -> str:
    return datetime.now(timezone.utc).strftime("%H:%M:%S")


def _get(url: str, timeout: int = 5) -> tuple[int, dict]:
    try:
        with urllib.request.urlopen(url, timeout=timeout) as r:
            return r.status, json.loads(r.read())
    except urllib.error.HTTPError as e:
        try:
            return e.code, json.loads(e.read())
        except Exception:
            return e.code, {}
    except Exception as e:
        return 0, {"error": str(e)}


def check_once(base_url: str) -> dict:
    results = {}

    # Liveness
    status, body = _get(f"{base_url}/health/live")
    results["liveness"] = {"ok": status == 200, "status": status, "body": body}

    # Readiness
    status, body = _get(f"{base_url}/health/ready")
    results["readiness"] = {"ok": status == 200, "status": status, "checks": body.get("checks", {})}

    # List items (app functional check)
    start = time.monotonic()
    status, body = _get(f"{base_url}/api/items")
    latency_ms = (time.monotonic() - start) * 1000
    results["api"] = {
        "ok": status == 200,
        "status": status,
        "latency_ms": round(latency_ms, 1),
        "slo_latency_ok": latency_ms < 500,
    }

    results["overall_ok"] = all(r["ok"] for r in results.values() if isinstance(r, dict) and "ok" in r)
    return results


def print_results(results: dict) -> None:
    icon = "✓" if results["overall_ok"] else "✗"
    print(f"[{_now()}] {icon} Health check")

    liveness = results["liveness"]
    print(f"  Liveness:   {'OK' if liveness['ok'] else 'FAIL'} (HTTP {liveness['status']})")

    readiness = results["readiness"]
    checks = readiness.get("checks", {})
    checks_str = ", ".join(f"{k}={v}" for k, v in checks.items())
    print(f"  Readiness:  {'OK' if readiness['ok'] else 'FAIL'} (HTTP {readiness['status']}) [{checks_str}]")

    api = results["api"]
    latency_flag = "" if api["slo_latency_ok"] else " ⚠ LATENCY SLO BREACH"
    print(f"  API:        {'OK' if api['ok'] else 'FAIL'} (HTTP {api['status']}, {api['latency_ms']}ms){latency_flag}")


def main() -> int:
    parser = argparse.ArgumentParser(description="SRE Platform health check")
    parser.add_argument("--base-url", required=True, help="Service base URL (e.g. http://my-alb.amazonaws.com)")
    parser.add_argument("--duration", type=int, default=0, help="Watch for N seconds (0 = single check)")
    parser.add_argument("--interval", type=int, default=10, help="Poll interval in seconds (default 10)")
    args = parser.parse_args()

    base_url = args.base_url.rstrip("/")

    if args.duration == 0:
        results = check_once(base_url)
        print_results(results)
        return 0 if results["overall_ok"] else 1

    deadline = time.monotonic() + args.duration
    failures = 0
    checks = 0

    print(f"Watching {base_url} for {args.duration}s (interval={args.interval}s)")
    while time.monotonic() < deadline:
        results = check_once(base_url)
        print_results(results)
        checks += 1
        if not results["overall_ok"]:
            failures += 1
        time.sleep(args.interval)

    error_rate = failures / checks if checks > 0 else 0
    print(f"\nSummary: {checks} checks, {failures} failures ({error_rate:.1%} error rate)")
    slo_ok = error_rate < 0.001
    print(f"SLO (availability <0.1% errors): {'PASS' if slo_ok else 'FAIL'}")
    return 0 if slo_ok else 1


if __name__ == "__main__":
    sys.exit(main())
