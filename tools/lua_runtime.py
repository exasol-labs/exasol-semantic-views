"""Install and locate the repository-pinned Lua runtime."""

from __future__ import annotations

import argparse
import hashlib
import platform
import shutil
import subprocess
import sys
import tarfile
import tempfile
import time
import urllib.error
import urllib.request
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
BUILD_DIR = ROOT / "build"
VERSION = "5.4.9"
SHA256 = "2335b6c582a52654f94612bf10d2f4672805d05329aa6568b1d8cd9e5c6fb8e6"
PREFIX = BUILD_DIR / f"lua-{VERSION}"
BIN_DIR = PREFIX / "bin"
LUA = BIN_DIR / "lua"
LUAC = BIN_DIR / "luac"
ARCHIVE_URL = f"https://www.lua.org/ftp/lua-{VERSION}.tar.gz"


def _log(message: str) -> None:
    print(f"[lua-runtime] {message}", file=sys.stderr)


def _is_valid() -> bool:
    if not LUA.is_file() or not LUAC.is_file():
        return False
    for binary in (LUA, LUAC):
        try:
            result = subprocess.run([str(binary), "-v"], capture_output=True, text=True, check=False)
        except OSError:
            return False
        version_output = result.stdout + result.stderr
        if result.returncode != 0 or not version_output.startswith(f"Lua {VERSION}"):
            return False
    return True


def _download(destination: Path) -> None:
    _log(f"Downloading Lua {VERSION} from {ARCHIVE_URL}")
    request = urllib.request.Request(ARCHIVE_URL, headers={"User-Agent": "exasol-semantic-views"})
    for attempt in range(6):
        try:
            with urllib.request.urlopen(request, timeout=30) as response, destination.open("wb") as out:
                shutil.copyfileobj(response, out)
            break
        except (OSError, urllib.error.URLError) as exc:
            destination.unlink(missing_ok=True)
            if attempt == 5:
                raise RuntimeError(f"Could not download Lua {VERSION} from {ARCHIVE_URL}: {exc}") from exc
            _log(f"Download failed; retrying ({attempt + 1}/5): {exc}")
            time.sleep(min(attempt + 1, 5))
    _log("Verifying archive checksum")
    digest = hashlib.sha256(destination.read_bytes()).hexdigest()
    if digest != SHA256:
        raise RuntimeError(f"Lua {VERSION} archive SHA-256 mismatch: got {digest}")


def _unpack_archive(archive: Path, destination: Path) -> Path:
    _log(f"Unpacking Lua {VERSION} source archive")
    with tarfile.open(archive, "r:gz") as bundle:
        # The source archive is checksum-pinned; still reject unexpected paths.
        root = destination.resolve()
        for member in bundle.getmembers():
            if not (destination / member.name).resolve().is_relative_to(root):
                raise RuntimeError(f"Unsafe path in Lua archive: {member.name}")
        bundle.extractall(destination, filter="data")
    return destination / f"lua-{VERSION}"


def _build_lua(source: Path, make_target: str, temp: Path) -> None:
    _log(f"Building Lua {VERSION} for {make_target}")
    subprocess.run(["make", "-C", str(source), make_target], check=True)
    staged = temp / "install"
    staged_bin = staged / "bin"
    staged_bin.mkdir(parents=True)
    shutil.copy2(source / "src/lua", staged_bin / "lua")
    shutil.copy2(source / "src/luac", staged_bin / "luac")

    previous = temp / "previous"
    if PREFIX.exists():
        PREFIX.rename(previous)
    try:
        staged.rename(PREFIX)
    except OSError:
        if previous.exists():
            previous.rename(PREFIX)
        raise
    shutil.rmtree(previous, ignore_errors=True)
    _log(f"Installed Lua {VERSION} at {PREFIX}")


def ensure_lua() -> tuple[Path, Path]:
    """Return the pinned interpreter and compiler, building them on first use."""
    if _is_valid():
        _log(f"Lua {VERSION} is already installed at {PREFIX}")
        return LUA, LUAC

    system = platform.system()
    make_target = {"Linux": "linux", "Darwin": "macosx"}.get(system)
    if make_target is None:
        raise RuntimeError(f"Automatic Lua setup is supported on Linux and macOS, not {system}")

    BUILD_DIR.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="lua-build-", dir=BUILD_DIR) as temp_name:
        temp = Path(temp_name)
        archive = temp / f"lua-{VERSION}.tar.gz"
        _download(archive)
        source = _unpack_archive(archive, temp)
        _build_lua(source, make_target, temp)

    if not _is_valid():
        raise RuntimeError(f"Built Lua binaries did not report Lua {VERSION}")
    _log(f"Lua {VERSION} is ready at {PREFIX}")
    return LUA, LUAC


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--lua", action="store_true", help="print the Lua interpreter path")
    parser.add_argument("--luac", action="store_true", help="print the Lua compiler path")
    parser.add_argument("--bin-dir", action="store_true", help="print the directory containing both binaries")
    args = parser.parse_args()
    lua, luac = ensure_lua()
    if args.lua:
        print(lua)
    elif args.luac:
        print(luac)
    elif args.bin_dir:
        print(lua.parent)
    else:
        print(f"Lua {VERSION} ready at {lua.parent}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
