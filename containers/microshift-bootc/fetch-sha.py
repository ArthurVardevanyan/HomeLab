#!/usr/bin/env python3
"""Fetch latest stream10 SHA from quay.io"""

import json
import sys
import urllib.request

def main():
    url = "https://quay.io/api/v1/repository/centos-bootc/centos-bootc/tag/?pageSize=1&specificTag=stream10"
    try:
        response = urllib.request.urlopen(url, timeout=30)
        data = json.loads(response.read())
        tags = data.get("tags", [])
        stream10 = [t for t in tags if t.get("name", "") == "stream10"]
        if stream10:
            print(stream10[0]["manifest_digest"].replace("sha256:", ""))
        else:
            print("ERROR: No stream10 tag found", file=sys.stderr)
            sys.exit(1)
    except Exception as e:
        print(f"ERROR: Failed to fetch SHA: {e}", file=sys.stderr)
        sys.exit(1)

if __name__ == "__main__":
    main()
