#!/usr/bin/env python3
"""Download one pinned optional helper. Never starts it or reads credentials."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import tarfile
import tempfile
import urllib.request

VERSION = "8.0.17"
ARCHIVES = {
    "arm64": ("aarch64", "d4952068c413060e3a8c082cc616fee707c701a01bebec59c45903bce402be9d"),
    "x86_64": ("amd64", "540148a4f01ee297dcb5c6c99df8dc9be68c011ead4ff0751dc8c41b5485ad80"),
}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--directory", type=Path, default=Path(__file__).resolve().parent.parent / ".build/tools" / ("CLIProxyAPI-" + VERSION))
    args = parser.parse_args()
    if platform.system() != "Darwin" or platform.machine() not in ARCHIVES:
        parser.error("Only pinned macOS arm64/x86_64 helpers are supported.")
    arch, digest = ARCHIVES[platform.machine()]
    name = f"CLIProxyAPI_{VERSION}_darwin_{arch}.tar.gz"
    url = f"https://github.com/router-for-me/CLIProxyAPI/releases/download/v{VERSION}/{name}"
    directory = args.directory.resolve()
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    with tempfile.TemporaryDirectory(prefix=".download-", dir=directory) as temporary:
        archive = Path(temporary) / name
        request = urllib.request.Request(url, headers={"User-Agent": "AIHub-backend-installer/0.1"})
        with urllib.request.urlopen(request, timeout=30) as response, archive.open("wb") as target:
            if not response.geturl().startswith("https://"):
                raise RuntimeError("Refused an insecure download redirect.")
            total = 0
            while chunk := response.read(65536):
                total += len(chunk)
                if total > 80 * 1024 * 1024:
                    raise RuntimeError("Helper archive exceeds size limit.")
                target.write(chunk)
        actual = hashlib.sha256(archive.read_bytes()).hexdigest()
        if actual != digest:
            raise RuntimeError("Pinned archive SHA-256 mismatch; nothing installed.")
        with tarfile.open(archive) as tar:
            candidates = [m for m in tar.getmembers() if m.isfile() and Path(m.name).name in ("cli-proxy-api", "CLIProxyAPI", "cliproxyapi")]
            if len(candidates) != 1 or candidates[0].size > 160 * 1024 * 1024:
                raise RuntimeError("Unexpected helper archive contents.")
            member = tar.extractfile(candidates[0])
            if member is None:
                raise RuntimeError("Missing helper binary.")
            staged = Path(temporary) / "helper"
            staged.write_bytes(member.read())
        staged.chmod(0o755)
        os.replace(staged, directory / "cli-proxy-api")
        (directory / "installed.json").write_text(json.dumps({"version": VERSION, "source": url, "archiveSHA256": digest}, indent=2))
    print(directory / "cli-proxy-api")


if __name__ == "__main__":
    main()
