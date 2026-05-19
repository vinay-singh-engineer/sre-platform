#!/usr/bin/env python3
"""
Scale an ECS service to a target desired count with safety rails.

Usage:
    python3 runbooks/scripts/scale_ecs_service.py \\
        --cluster sre-platform-prod \\
        --service sre-platform-prod \\
        --desired-count 4

Safety rails:
    - Will not scale above MAX_COUNT without --force flag.
    - Will not scale to 0 without --force flag (prevents accidental outage).
    - Waits for service to become stable before exiting.
"""
import argparse
import sys
import time
import boto3
from datetime import datetime, timezone


MAX_COUNT = 20
STABILITY_TIMEOUT_SECS = 600


def _now() -> str:
    return datetime.now(timezone.utc).strftime("%H:%M:%S")


def main() -> int:
    parser = argparse.ArgumentParser(description="Scale ECS service")
    parser.add_argument("--cluster",       required=True)
    parser.add_argument("--service",       required=True)
    parser.add_argument("--desired-count", required=True, type=int)
    parser.add_argument("--region",        default="us-east-1")
    parser.add_argument("--force",         action="store_true", help="Bypass safety limits")
    parser.add_argument("--no-wait",       action="store_true", help="Don't wait for stable")
    args = parser.parse_args()

    desired = args.desired_count

    if desired == 0 and not args.force:
        print("ERROR: refusing to scale to 0 without --force (would cause total outage)", file=sys.stderr)
        return 1

    if desired > MAX_COUNT and not args.force:
        print(f"ERROR: desired count {desired} exceeds maximum {MAX_COUNT}. Use --force to override.", file=sys.stderr)
        return 1

    ecs = boto3.client("ecs", region_name=args.region)

    # Get current state
    svc = ecs.describe_services(cluster=args.cluster, services=[args.service])["services"][0]
    current = svc["desiredCount"]
    running = svc["runningCount"]
    print(f"[{_now()}] Current state: desired={current}, running={running}")
    print(f"[{_now()}] Scaling to:    desired={desired}")

    ecs.update_service(cluster=args.cluster, service=args.service, desiredCount=desired)
    print(f"[{_now()}] Scale request sent.")

    if args.no_wait:
        print("Skipping stability wait (--no-wait).")
        return 0

    print(f"[{_now()}] Waiting for service to stabilise (timeout {STABILITY_TIMEOUT_SECS}s)...")
    waiter = ecs.get_waiter("services_stable")
    try:
        waiter.wait(
            cluster=args.cluster,
            services=[args.service],
            WaiterConfig={"Delay": 15, "MaxAttempts": STABILITY_TIMEOUT_SECS // 15},
        )
        svc = ecs.describe_services(cluster=args.cluster, services=[args.service])["services"][0]
        print(f"[{_now()}] Stable. running={svc['runningCount']}, desired={svc['desiredCount']}")
        return 0
    except Exception as e:
        print(f"[{_now()}] ERROR waiting for stability: {e}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
