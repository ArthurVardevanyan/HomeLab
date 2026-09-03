#!/usr/bin/env python3
"""Clean up orphaned Open WebUI file rows.

Deletes files that are:
- Not linked to any KB (not in knowledge_file)
- Not attached to any chat (not in chat_file)

Uses the OWUI API to ensure storage blobs and vector collections
are also cleaned up (raw SQL would strand them).

Usage:
  OWUI_API_TOKEN=<token> python3 cleanup-openwebui-orphans.py [--dry-run]
"""

from __future__ import annotations

import argparse
import os
import sqlite3
import sys
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path
from typing import Any

import requests


def get_orphaned_file_ids(kubeconfig: str | None = None) -> list[str]:
    """Query the Open WebUI postgres to get orphaned file IDs."""
    os.environ["KUBECONFIG"] = kubeconfig or os.path.join(
        os.environ.get("HOME", ""), ".kube", "okd"
    )

    # Get file IDs linked to KBs
    linked = run_sql(
        "SELECT DISTINCT file_id FROM knowledge_file;",
    )

    # Get file IDs attached to chats
    chat_files = run_sql(
        "SELECT DISTINCT f.id FROM file f "
        "JOIN chat_file cf ON cf.file_id = f.id;",
    )

    # Get all file IDs
    all_files = run_sql("SELECT id FROM file;")

    linked_set = set(linked)
    chat_set = set(chat_files)

    orphaned = [
        fid for fid in all_files
        if fid not in linked_set and fid not in chat_set
    ]

    return orphaned


def run_sql(query: str) -> list[str]:
    """Run a SQL query against the Open WebUI postgres container."""
    import subprocess

    result = subprocess.run(
        [
            "kubectl",
            "exec",
            "-n",
            "llm",
            "open-webui-2",
            "--",
            "psql",
            "-U",
            "postgres",
            "-d",
            "openwebui",
            "-t",
            "-c",
            query,
        ],
        capture_output=True,
        text=True,
        check=False,
    )

    if result.returncode != 0:
        print(f"SQL error: {result.stderr.strip()}", file=sys.stderr)
        sys.exit(1)

    return [row.strip() for row in result.stdout.strip().split("\n") if row.strip()]


def delete_file(file_id: str, session: requests.Session, api_url: str) -> tuple[str, str]:
    """Delete a single file via the OWUI API.

    Returns (file_id, status).
    """
    url = f"{api_url}/api/v1/files/{file_id}"
    try:
        resp = session.delete(url)
        if resp.status_code == 200:
            return (file_id, "deleted")
        elif resp.status_code == 404:
            return (file_id, "already gone")
        else:
            return (file_id, f"error {resp.status_code}: {resp.text[:200]}")
    except requests.RequestException as e:
        return (file_id, f"exception: {e}")


def cleanup(
    orphaned_ids: list[str],
    api_url: str,
    api_token: str,
    concurrency: int = 5,
    dry_run: bool = False,
) -> tuple[int, int, int]:
    """Delete orphaned files via the OWUI API.

    Returns (deleted, skipped, failed).
    """
    session = requests.Session()
    session.headers.update({"Authorization": f"Bearer {api_token}"})

    print(f"\nFound {len(orphaned_ids)} orphaned files.")

    if dry_run:
        print("DRY RUN — nothing will be deleted.\n")
        print("First 10 files that would be deleted:")
        for fid in orphaned_ids[:10]:
            print(f"  {fid}")
        if len(orphaned_ids) > 10:
            print(f"  ... and {len(orphaned_ids) - 10} more")
        return (0, len(orphaned_ids), 0)

    print(f"\nDeleting {len(orphaned_ids)} files with {concurrency} workers...\n")

    deleted = 0
    skipped = 0
    failed = 0

    with ThreadPoolExecutor(max_workers=concurrency) as pool:
        futures = {
            pool.submit(delete_file, fid, session, api_url): fid
            for fid in orphaned_ids
        }
        for future in as_completed(futures):
            fid, status = future.result()
            if status == "deleted" or status == "already gone":
                deleted += 1
            else:
                failed += 1
                if failed <= 20:
                    print(f"  FAIL: {fid} — {status}", file=sys.stderr)

            if deleted % 500 == 0 and deleted > 0:
                print(f"  Processed: {deleted} deleted, {failed} failed so far...", file=sys.stderr)

    return (deleted, skipped, failed)


def main() -> None:
    parser = argparse.ArgumentParser(description="Clean up orphaned Open WebUI files")
    parser.add_argument("--dry-run", action="store_true", help="Show what would be deleted without deleting")
    parser.add_argument("--concurrency", type=int, default=5, help="Number of concurrent deletes (default: 5)")
    parser.add_argument("--api-url", default=None, help="Open WebUI API URL (default: from K8s port-forward)")
    args = parser.parse_args()

    api_token = os.environ.get("OWUI_API_TOKEN")
    if not api_token:
        print("Error: OWUI_API_TOKEN environment variable is required.", file=sys.stderr)
        print("Create one in the OWUI admin panel or via the API.", file=sys.stderr)
        sys.exit(1)

    api_url = args.api_url or "http://localhost:8080"

    # Get orphaned file IDs
    print("Querying postgres for orphaned files...")
    orphaned_ids = get_orphaned_file_ids()
    print(f"Found {len(orphaned_ids)} orphaned files.\n")

    if not orphaned_ids:
        print("No orphaned files found. Nothing to do.")
        return

    if len(orphaned_ids) < 100:
        print("Warning: very few orphaned files found. Check if the query is correct.")

    # Delete
    deleted, skipped, failed = cleanup(
        orphaned_ids, api_url, api_token, args.concurrency, args.dry_run,
    )

    print(f"\n{'DRY RUN' if args.dry_run else 'Done'}:")
    print(f"  Deleted (or already gone): {deleted}")
    print(f"  Skipped: {skipped}")
    print(f"  Failed: {failed}")


if __name__ == "__main__":
    main()
