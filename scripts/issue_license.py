#!/usr/bin/env python3
"""Issue Luma Bar Pro license keys (Surge-style offline HMAC).

Usage:
  python3 scripts/issue_license.py --devices 1
  python3 scripts/issue_license.py --devices 3 --months 12
  python3 scripts/issue_license.py --devices 1 --count 5

Keep LUMA_LICENSE_HMAC in sync with Sources/LumaBar/License.swift
(LumaLicenseSecrets.hmacKey). Rotate before real sales.
"""

from __future__ import annotations

import argparse
import hashlib
import hmac
import os
from datetime import date, datetime, timezone
from calendar import monthrange


DEFAULT_HMAC = "luma-bar-license-v1-change-me-before-sale"


def add_months(d: date, months: int) -> date:
    year = d.year + (d.month - 1 + months) // 12
    month = (d.month - 1 + months) % 12 + 1
    day = min(d.day, monthrange(year, month)[1])
    return date(year, month, day)


def issue(devices: int, months: int, secret: str, start: date | None = None) -> str:
    start = start or datetime.now(timezone.utc).date()
    expiry = add_months(start, months)
    stamp = expiry.strftime("%Y%m%d")
    payload = f"LB1.{devices}.{stamp}"
    digest = hmac.new(secret.encode(), payload.encode(), hashlib.sha256).hexdigest()[:16]
    return f"{payload}.{digest}"


def main() -> None:
    parser = argparse.ArgumentParser(description="Issue Luma Bar license keys")
    parser.add_argument("--devices", type=int, choices=[1, 3, 5], default=1)
    parser.add_argument("--months", type=int, default=12, help="maintenance months")
    parser.add_argument("--count", type=int, default=1, help="how many keys to print")
    parser.add_argument(
        "--secret",
        default=os.environ.get("LUMA_LICENSE_HMAC", DEFAULT_HMAC),
        help="HMAC secret (or env LUMA_LICENSE_HMAC)",
    )
    args = parser.parse_args()

    for _ in range(max(1, args.count)):
        print(issue(args.devices, args.months, args.secret))


if __name__ == "__main__":
    main()
