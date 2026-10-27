#!/usr/bin/env python3
"""Append a proposal for explicit in-app review. No running sync or external access."""

from bist_data import default_directory, prepare_default

import argparse
import datetime as dt
import fcntl
import json
import os
from pathlib import Path
import sys
import tempfile
import uuid

MAX_BYTES = 256 * 1024
MAX_PROPOSALS = 100


def validate(document):
    if not isinstance(document, dict) or document.get("version") != 1:
        raise ValueError("inbox.json must use version 1")
    proposals = document.get("proposals")
    if not isinstance(proposals, list) or len(proposals) > MAX_PROPOSALS:
        raise ValueError("inbox.json must contain at most 100 proposals")
    ids = set()
    for item in proposals:
        if not isinstance(item, dict):
            raise ValueError("each proposal must be an object")
        try:
            identifier = str(uuid.UUID(item["id"]))
            observed = dt.datetime.fromisoformat(item["createdAt"].replace("Z", "+00:00"))
            if observed.tzinfo is None:
                raise ValueError("timestamp needs a timezone")
        except (KeyError, TypeError, ValueError, AttributeError):
            raise ValueError("each proposal needs a UUID and an ISO 8601 date") from None
        if identifier in ids:
            raise ValueError("proposal IDs must be unique")
        ids.add(identifier)
        for field, limit in (("title", 200), ("nextAction", 600), ("source", 160)):
            value = item.get(field)
            if not isinstance(value, str) or len(value) > limit:
                raise ValueError(f"{field} must be text of at most {limit} characters")
        if not item["title"].strip():
            raise ValueError("title cannot be blank")
    return document


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--title", required=True, help="Proposed task title (max 200 characters)")
    parser.add_argument("--next-action", default="", help="Optional next action (max 600 characters)")
    parser.add_argument("--source", default="Local proposal", help="Human-readable source (max 160 characters)")
    parser.add_argument("--data-dir", type=Path, default=None)
    args = parser.parse_args()
    item = {
        "id": str(uuid.uuid4()),
        "title": args.title.strip(),
        "nextAction": args.next_action.strip(),
        "source": args.source.strip(),
        "createdAt": dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    }
    validate({"version": 1, "proposals": [item]})
    if args.data_dir is None:
        args.data_dir = default_directory()
        if "BIST_DATA_DIR" not in os.environ:
            prepare_default(args.data_dir)
    args.data_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
    inbox = args.data_dir / "inbox.json"
    lock_path = args.data_dir / ".inbox.lock"
    lock_fd = os.open(lock_path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    with os.fdopen(lock_fd, "a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise ValueError("local updates are busy; try again") from None
        if inbox.is_symlink():
            raise ValueError("inbox.json must be a regular file, not a symbolic link")
        if inbox.exists():
            with inbox.open("rb") as source:
                contents = source.read(MAX_BYTES + 1)
            if len(contents) > MAX_BYTES:
                raise ValueError("inbox.json exceeds 256 KB")
            document = validate(json.loads(contents))
        else:
            document = {"version": 1, "proposals": []}
        if len(document["proposals"]) >= MAX_PROPOSALS:
            raise ValueError("inbox.json already has 100 proposals; review them in bist first")
        document["proposals"].append(item)
        encoded = (json.dumps(document, indent=2, ensure_ascii=False) + "\n").encode("utf-8")
        if len(encoded) > MAX_BYTES:
            raise ValueError("the proposal would exceed the 256 KB inbox limit")
        temporary = None
        try:
            with tempfile.NamedTemporaryFile(dir=args.data_dir, prefix=".inbox-", delete=False) as output:
                temporary = Path(output.name)
                output.write(encoded)
                output.flush()
                os.fsync(output.fileno())
            os.replace(temporary, inbox)
            temporary = None
        finally:
            if temporary is not None:
                temporary.unlink(missing_ok=True)
    print(f"Proposed: {item['title']}\nOpen bist and choose Review local updates to approve it.")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError) as error:
        print(f"bist: {error}", file=sys.stderr)
        sys.exit(1)
