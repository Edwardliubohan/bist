"""Shared app storage convention; keep in sync with BistDataLocation in Swift."""
import fcntl
import os
from pathlib import Path
import shutil
import tempfile


def default_directory():
    override = os.environ.get("BIST_DATA_DIR")
    return Path(override) if override is not None else Path.home() / "Library/Application Support/bist"


def prepare_default(directory, legacy=None):
    """Copy the complete legacy store once, leaving its original files untouched."""
    directory = Path(directory)
    legacy = Path(legacy) if legacy is not None else Path(__file__).resolve().parents[1] / ".local-data"
    directory.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    lock_path = directory.parent / f".{directory.name}-migration.lock"
    descriptor = os.open(lock_path, os.O_CREAT | os.O_RDWR, 0o600)
    with os.fdopen(descriptor, "a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        if directory.exists():
            if not directory.is_dir():
                raise ValueError("the local data path must be a folder")
            return
        if legacy.exists():
            if not legacy.is_dir() or legacy.is_symlink():
                raise ValueError("the legacy data path must be a folder")
            staging = Path(tempfile.mkdtemp(prefix=f".{directory.name}-migration-", dir=directory.parent))
            try:
                shutil.copytree(legacy, staging, dirs_exist_ok=True, symlinks=True)
                staging.chmod(0o700)
                staging.rename(directory)
            finally:
                if staging.exists():
                    shutil.rmtree(staging)
        else:
            directory.mkdir(mode=0o700)
