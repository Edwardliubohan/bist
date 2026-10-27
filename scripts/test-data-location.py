"""Exercise CLI migration and precedence without touching the user's home/store."""
from pathlib import Path
import os
import subprocess
import tempfile
from bist_data import prepare_default, default_directory

with tempfile.TemporaryDirectory(prefix="bist-storage-") as temporary:
    root = Path(temporary)
    legacy = root / "old"
    legacy.mkdir()
    (legacy / "state.json").write_text("{untouched legacy}")
    (legacy / "archive").mkdir()
    (legacy / "archive/result.json").write_text("retained")
    destination = root / "new/bist"
    prepare_default(destination, legacy)
    assert (destination / "state.json").read_bytes() == (legacy / "state.json").read_bytes()
    assert (destination / "archive/result.json").read_text() == "retained"
    (destination / "state.json").write_text("new data")
    prepare_default(destination, legacy)
    assert (destination / "state.json").read_text() == "new data"
    bad = root / "bad"
    bad.write_text("file")
    try:
        prepare_default(root / "failed", bad)
        raise AssertionError("bad legacy accepted")
    except ValueError:
        assert not (root / "failed").exists()
    script = Path(__file__).resolve().with_name("bist-propose.py")
    environment = dict(os.environ, BIST_DATA_DIR=str(destination))
    subprocess.run(["python3", str(script), "--title", "Survives CLI"], env=environment, cwd="/", check=True, capture_output=True)
    assert (destination / "inbox.json").exists()
    assert (destination / "state.json").read_text() == "new data"
    explicit = root / "explicit"
    subprocess.run(["python3", str(script), "--title", "Explicit store", "--data-dir", str(explicit)], env=environment, check=True, capture_output=True)
    assert (explicit / "inbox.json").exists()
    environment.pop("BIST_DATA_DIR")
    environment["HOME"] = str(root / "isolated-home")
    subprocess.run(["python3", str(script), "--title", "Default store"], env=environment, cwd="/", check=True, capture_output=True)
    assert (root / "isolated-home/Library/Application Support/bist/inbox.json").exists()
    os.environ["BIST_DATA_DIR"] = str(explicit)
    assert default_directory() == explicit
print("PASS: Python storage migration, CLI and explicit-directory checks")
