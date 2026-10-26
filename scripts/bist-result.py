#!/usr/bin/env python3
"""Queue one agent output for explicit review in bist. No agent access or sync."""

import argparse
import datetime as dt
import fcntl
import json
import os
from pathlib import Path
import re
import stat
import sys
import tempfile
import uuid
from urllib.parse import urlsplit

MAX_BYTES = 256 * 1024
MAX_RESULTS = 100
UTC = dt.timezone.utc
EPOCH = dt.datetime(1970, 1, 1, tzinfo=UTC)


def canonical_uuid(value):
    if not isinstance(value, str):
        raise ValueError("task, session and result IDs must be UUID strings")
    try:
        return str(uuid.UUID(value))
    except (ValueError, AttributeError):
        raise ValueError("task, session and result IDs must be UUID strings") from None


def observation(value, now):
    if not isinstance(value, str):
        raise ValueError("observedAt must be an ISO 8601 timestamp with a timezone")
    try:
        parsed = dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
        if parsed.tzinfo is None:
            raise ValueError()
        parsed = parsed.astimezone(UTC)
    except (ValueError, OverflowError):
        raise ValueError("observedAt must be an ISO 8601 timestamp with a timezone") from None
    if parsed < EPOCH or parsed > now + dt.timedelta(seconds=60):
        raise ValueError("observedAt must be since 1970 and cannot be in the future")
    return parsed


def safe_url(value):
    if not isinstance(value, str) or len(value) > 4096 or any(c.isspace() or ord(c) < 32 for c in value):
        raise ValueError("artifactURL must be a full http or https URL without account credentials")
    try:
        parsed = urlsplit(value)
        if parsed.scheme.lower() not in ("http", "https") or not parsed.hostname or parsed.username is not None or parsed.password is not None:
            raise ValueError()
        _ = parsed.port
    except ValueError:
        raise ValueError("artifactURL must be a full http or https URL without account credentials") from None
    return value


def validate(document, now):
    if not isinstance(document, dict) or type(document.get("version")) is not int or document["version"] != 1:
        raise ValueError("agent-results.json must use version 1")
    results = document.get("results")
    if not isinstance(results, list) or len(results) > MAX_RESULTS:
        raise ValueError("agent-results.json must contain at most 100 results")
    identifiers = set()
    for item in results:
        if not isinstance(item, dict):
            raise ValueError("each result must be an object")
        try:
            identifier = canonical_uuid(item["id"])
            canonical_uuid(item["taskID"])
            canonical_uuid(item["sessionID"])
            if not isinstance(item["observedAt"], str) or not re.fullmatch(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:Z|[+-]\d{2}:\d{2})", item["observedAt"]):
                raise ValueError("existing observedAt timestamps must use whole-second ISO 8601 with a timezone")
            observed = observation(item["observedAt"], now)
            # Native JSONDecoder uses whole-second ISO 8601. Preserve an
            # incompatible existing inbox instead of silently rewriting it.
            if observed.microsecond:
                raise ValueError("existing observedAt timestamps must use whole seconds")
            safe_url(item["artifactURL"])
            if not isinstance(item["summary"], str) or not item["summary"].strip() or len(item["summary"]) > 2000:
                raise ValueError("summary must be nonblank text of at most 2,000 characters")
        except KeyError:
            raise ValueError("each result needs id, taskID, sessionID, artifactURL, summary and observedAt") from None
        if identifier in identifiers:
            raise ValueError("result IDs must be unique")
        identifiers.add(identifier)
    return document


def read_document(path, now):
    try:
        descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    except FileNotFoundError:
        return {"version": 1, "results": []}
    with os.fdopen(descriptor, "rb") as source:
        if not stat.S_ISREG(os.fstat(source.fileno()).st_mode):
            raise ValueError("agent-results.json must be a regular file")
        contents = source.read(MAX_BYTES + 1)
    if len(contents) > MAX_BYTES:
        raise ValueError("agent-results.json exceeds 256 KB")
    try:
        return validate(json.loads(contents), now)
    except (UnicodeDecodeError, json.JSONDecodeError):
        raise ValueError("agent-results.json contains invalid JSON; it has been preserved") from None


def equivalent(left, right, now):
    return (all(canonical_uuid(left[key]) == canonical_uuid(right[key]) for key in ("id", "taskID", "sessionID"))
            and all(left[key] == right[key] for key in ("artifactURL", "summary"))
            and observation(left["observedAt"], now) == observation(right["observedAt"], now))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--task-id", required=True, help="Exact local task UUID")
    parser.add_argument("--session-id", required=True, help="Exact saved session UUID linked to that task")
    parser.add_argument("--artifact-url", required=True, help="Output http(s) URL; it will not be fetched")
    parser.add_argument("--summary", required=True, help="Nonblank output description (max 2,000 characters)")
    parser.add_argument("--observed-at", required=True, help="Explicit ISO 8601 observation time with timezone")
    parser.add_argument("--id", help="Stable result UUID for safe retries; defaults to a new UUID")
    parser.add_argument("--data-dir", type=Path, default=Path(os.environ.get("BIST_DATA_DIR", Path(__file__).resolve().parents[1] / ".local-data")))
    args = parser.parse_args()
    now = dt.datetime.now(UTC)
    item = {
        "id": canonical_uuid(args.id) if args.id else str(uuid.uuid4()),
        "taskID": canonical_uuid(args.task_id),
        "sessionID": canonical_uuid(args.session_id),
        "artifactURL": safe_url(args.artifact_url),
        "summary": args.summary,
        "observedAt": observation(args.observed_at, now).strftime("%Y-%m-%dT%H:%M:%SZ"),
    }
    validate({"version": 1, "results": [item]}, now)
    args.data_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
    inbox = args.data_dir / "agent-results.json"
    lock_path = args.data_dir / ".agent-results.lock"
    lock_fd = os.open(lock_path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW | os.O_NONBLOCK, 0o600)
    with os.fdopen(lock_fd, "a") as lock:
        if not stat.S_ISREG(os.fstat(lock.fileno()).st_mode):
            raise ValueError("the agent results lock must be a regular file")
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise ValueError("agent results are busy; try again") from None
        document = read_document(inbox, now)
        for existing in document["results"]:
            if canonical_uuid(existing["id"]) == item["id"]:
                if not equivalent(existing, item, now):
                    raise ValueError("this result ID already exists with different content; it has been preserved")
                print(f"Already queued: {item['id']}\nOpen bist and choose Review agent results. No task state was changed.")
                return
        if len(document["results"]) >= MAX_RESULTS:
            raise ValueError("agent-results.json already has 100 results; review them in bist first")
        document["results"].append(item)
        encoded = (json.dumps(document, indent=2, ensure_ascii=False) + "\n").encode("utf-8")
        if len(encoded) > MAX_BYTES:
            raise ValueError("the result would exceed the 256 KB inbox limit")
        temporary = None
        try:
            with tempfile.NamedTemporaryFile(dir=args.data_dir, prefix=".agent-results-", delete=False) as output:
                temporary = Path(output.name)
                output.write(encoded)
                output.flush()
                os.fsync(output.fileno())
            os.replace(temporary, inbox)
            temporary = None
        finally:
            if temporary is not None:
                temporary.unlink(missing_ok=True)
    print(f"Queued result: {item['id']}\nOpen bist and choose Review agent results. No task state was changed.")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError) as error:
        print(f"bist: {error}", file=sys.stderr)
        sys.exit(1)
