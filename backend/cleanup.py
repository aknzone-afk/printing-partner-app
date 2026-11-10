"""
Printing Partner — disk cleanup (runs daily via systemd timer on the Oracle VM).

Owner 10-Nov-2026 chose Oracle-only storage (photos downloaded via the merchant
dashboard), so this keeps the free VM disk from ever filling:

  * deletes each  "Printing Partner/<date>"  order folder older than
    RETENTION_DAYS (default 30) — by then the merchant has downloaded it;
  * NEVER touches the _payments ledger (tiny, kept for reconciliation);
  * logs every removal, and logs a loud WARNING if the disk is still >85%
    (so the owner can download sooner or expand the free block volume to 200GB)
    — it does NOT silently delete recent, possibly-uncollected orders.

Env:
  DATA_ROOT        base dir (same as app.py; default /opt/printing-partner-backend/data)
  RETENTION_DAYS   age after which an order date-folder is deleted (default 30)
  DISK_WARN_PCT    warn above this disk usage percent (default 85)
"""
from __future__ import annotations

import os
import shutil
import time

ROOT = os.environ.get("DATA_ROOT", "/opt/printing-partner-backend/data")
RETENTION_DAYS = int(os.environ.get("RETENTION_DAYS", "30"))
DISK_WARN_PCT = int(os.environ.get("DISK_WARN_PCT", "85"))


def log(msg: str) -> None:
    print(time.strftime("%Y-%m-%d %H:%M:%S"), msg, flush=True)


def main() -> None:
    base = os.path.join(ROOT, "Printing Partner")
    root_real = os.path.realpath(ROOT)
    cutoff = time.time() - RETENTION_DAYS * 86400
    removed = 0
    if os.path.isdir(base):
        for name in os.listdir(base):
            folder = os.path.join(base, name)
            # Defence in depth: never delete anything outside DATA_ROOT, and
            # never the payments ledger.
            real = os.path.realpath(folder)
            if not real.startswith(root_real + os.sep):
                continue
            if name.startswith("_") or not os.path.isdir(folder):
                continue
            if os.path.getmtime(folder) < cutoff:
                try:
                    shutil.rmtree(folder)
                    removed += 1
                    log(f"removed old order folder: {name}")
                except Exception as e:  # pragma: no cover
                    log(f"ERROR removing {name}: {e}")
    log(f"cleanup done: {removed} folder(s) older than {RETENTION_DAYS}d removed")

    try:
        usage = shutil.disk_usage(ROOT)
        pct = round(usage.used * 100 / usage.total)
        free_gb = usage.free / (1024 ** 3)
        if pct >= DISK_WARN_PCT:
            log(f"WARNING: disk {pct}% full ({free_gb:.1f} GB free). Download orders "
                f"from the dashboard, or expand the Oracle free block volume (up to 200GB).")
        else:
            log(f"disk {pct}% used, {free_gb:.1f} GB free — healthy")
    except Exception as e:  # pragma: no cover
        log(f"disk check failed: {e}")


if __name__ == "__main__":
    main()
