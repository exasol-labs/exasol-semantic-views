"""Install and locate the repository-pinned Lua runtimes."""

from __future__ import annotations

import argparse
import hashlib
import os
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
DEFAULT_VERSION = "5.4.9"
ARCHIVE_SHA256 = {
    "5.4.9": "2335b6c582a52654f94612bf10d2f4672805d05329aa6568b1d8cd9e5c6fb8e6",
    "5.5.1": "1c4b4068d67061f2a2231ad2b5422e77acea1487ea9890f6320af614f4373dce",
}


def _paths(version: str) -> tuple[Path, Path, Path]:
    prefix = BUILD_DIR / f"lua-{version}"
    return prefix, prefix / "bin/lua", prefix / "bin/luac"


def _log(message: str) -> None:
    print(f"[lua-runtime] {message}", file=sys.stderr)


def _is_valid(version: str, lua: Path, luac: Path) -> bool:
    if not lua.is_file() or not luac.is_file():
        return False
    for binary in (lua, luac):
        try:
            result = subprocess.run([str(binary), "-v"], capture_output=True, text=True, check=False)
        except OSError:
            return False
        version_output = result.stdout + result.stderr
        if result.returncode != 0 or not version_output.startswith(f"Lua {version}"):
            return False
    return True


def _download(version: str, destination: Path) -> None:
    archive_url = f"https://www.lua.org/ftp/lua-{version}.tar.gz"
    _log(f"Downloading Lua {version} from {archive_url}")
    request = urllib.request.Request(archive_url, headers={"User-Agent": "exasol-semantic-views"})
    for attempt in range(6):
        try:
            with urllib.request.urlopen(request, timeout=30) as response, destination.open("wb") as out:
                shutil.copyfileobj(response, out)
            break
        except (OSError, urllib.error.URLError) as exc:
            destination.unlink(missing_ok=True)
            if attempt == 5:
                raise RuntimeError(f"Could not download Lua {version} from {archive_url}: {exc}") from exc
            _log(f"Download failed; retrying ({attempt + 1}/5): {exc}")
            time.sleep(min(attempt + 1, 5))
    _log("Verifying archive checksum")
    digest = hashlib.sha256(destination.read_bytes()).hexdigest()
    if digest != ARCHIVE_SHA256[version]:
        raise RuntimeError(f"Lua {version} archive SHA-256 mismatch: got {digest}")


def _unpack_archive(version: str, archive: Path, destination: Path) -> Path:
    _log(f"Unpacking Lua {version} source archive")
    with tarfile.open(archive, "r:gz") as bundle:
        # The source archive is checksum-pinned; still reject unexpected paths.
        root = destination.resolve()
        for member in bundle.getmembers():
            if not (destination / member.name).resolve().is_relative_to(root):
                raise RuntimeError(f"Unsafe path in Lua archive: {member.name}")
        bundle.extractall(destination, filter="data")
    return destination / f"lua-{version}"


def _build_lua(version: str, prefix: Path, source: Path, make_target: str, temp: Path) -> None:
    _log(f"Building Lua {version} for {make_target}")
    subprocess.run(["make", "-C", str(source), make_target], check=True)
    staged = temp / "install"
    staged_bin = staged / "bin"
    staged_bin.mkdir(parents=True)
    shutil.copy2(source / "src/lua", staged_bin / "lua")
    shutil.copy2(source / "src/luac", staged_bin / "luac")

    previous = temp / "previous"
    if prefix.exists():
        prefix.rename(previous)
    try:
        staged.rename(prefix)
    except OSError:
        if previous.exists():
            previous.rename(prefix)
        raise
    shutil.rmtree(previous, ignore_errors=True)
    _log(f"Installed Lua {version} at {prefix}")


def ensure_lua(version: str = DEFAULT_VERSION) -> tuple[Path, Path]:
    """Return a pinned interpreter and compiler, building them on first use."""
    if version not in ARCHIVE_SHA256:
        raise ValueError(f"Unsupported Lua version {version}; choose one of {', '.join(ARCHIVE_SHA256)}")
    prefix, lua, luac = _paths(version)
    if _is_valid(version, lua, luac):
        _log(f"Lua {version} is already installed at {prefix}")
        return lua, luac

    system = platform.system()
    make_target = {"Linux": "linux", "Darwin": "macosx"}.get(system)
    if make_target is None:
        raise RuntimeError(f"Automatic Lua setup is supported on Linux and macOS, not {system}")

    BUILD_DIR.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="lua-build-", dir=BUILD_DIR) as temp_name:
        temp = Path(temp_name)
        archive = temp / f"lua-{version}.tar.gz"
        _download(version, archive)
        source = _unpack_archive(version, archive, temp)
        _build_lua(version, prefix, source, make_target, temp)

    if not _is_valid(version, lua, luac):
        raise RuntimeError(f"Built Lua binaries did not report Lua {version}")
    _log(f"Lua {version} is ready at {prefix}")
    return lua, luac


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--version", choices=ARCHIVE_SHA256,
                        default=os.environ.get("LUA_VERSION", DEFAULT_VERSION),
                        help="Lua release to provision (default: %(default)s)")
    parser.add_argument("--lua", action="store_true", help="print the Lua interpreter path")
    parser.add_argument("--luac", action="store_true", help="print the Lua compiler path")
    parser.add_argument("--bin-dir", action="store_true", help="print the directory containing both binaries")
    args = parser.parse_args()
    lua, luac = ensure_lua(args.version)
    if args.lua:
        print(lua)
    elif args.luac:
        print(luac)
    elif args.bin_dir:
        print(lua.parent)
    else:
        print(f"Lua {args.version} ready at {lua.parent}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
