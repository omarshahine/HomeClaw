#!/usr/bin/env python3
"""Rebuild the pinned npm archive with two verified, compatible bundle patches.

Manual developer command only. No install lifecycle hook or npm config changes.
Downloads remain integrity-pinned; temporary sources are retained for inspection.
"""
import argparse
import base64
import gzip
import hashlib
import json
import os
from pathlib import Path
import posixpath
import shutil
import tarfile
import tempfile
import urllib.request

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--check", action="store_true", help="Verify the committed archive against pinned source contents without rewriting it")
CHECK = parser.parse_args().check

ROOT = Path(__file__).resolve().parent.parent
VENDOR = ROOT / "vendor"
VERSION = "12.2.1+security.20261024"
ARCHIVE = "npm-12.2.1-security.20261024.tgz"
SOURCES = json.loads((VENDOR / "npm-security-sources.json").read_text())
EXPECTED = {"npm": "12.2.1", "ip-address": "10.7.4", "undici": "6.29.1"}
if len(SOURCES) != len(EXPECTED) or {s["name"]: s["version"] for s in SOURCES} != EXPECTED:
    raise ValueError("Unexpected source package set")
WORK = Path(tempfile.mkdtemp(prefix="npm-security-bundle-"))


def unpack(archive, destination):
    destination.mkdir()
    with tarfile.open(archive, "r:gz") as stream:
        for member in stream.getmembers():
            name = posixpath.normpath(member.name)
            if name != "package" and not name.startswith("package/"):
                raise ValueError("Unexpected archive path: " + member.name)
            if member.isdev() or member.isfifo():
                raise ValueError("Unsupported archive entry")
            if member.issym() or member.islnk():
                parent = posixpath.dirname(name) if member.issym() else ""
                target = posixpath.normpath(posixpath.join(parent, member.linkname))
                if not target.startswith("package/"):
                    raise ValueError("Unsafe archive link: " + member.name)
        stream.extractall(destination)
    return destination / "package"


def snapshot(directory):
    result = {}
    for parent, dirs, files in os.walk(directory, followlinks=False):
        for name in sorted(dirs + files):
            path = Path(parent) / name
            relative = path.relative_to(directory).as_posix()
            if path.is_symlink():
                result[relative] = ["link", os.readlink(path)]
            elif path.is_file():
                result[relative] = ["file", hashlib.sha256(path.read_bytes()).hexdigest(), path.stat().st_mode & 0o777]
    return result


packages = {}
for source in SOURCES:
    url = source["tarball"]
    expected_url = "https://registry.npmjs.org/{0}/-/{0}-{1}.tgz".format(source["name"], source["version"])
    if url != expected_url:
        raise ValueError("Only pinned public npm registry URLs are supported")
    archive = WORK / (source["name"] + ".tgz")
    with urllib.request.urlopen(url, timeout=90) as response:
        data = response.read()
    integrity = "sha512-" + base64.b64encode(hashlib.sha512(data).digest()).decode()
    if integrity != source["integrity"]:
        raise ValueError("Source integrity mismatch: " + source["name"])
    archive.write_bytes(data)
    packages[source["name"]] = unpack(archive, WORK / source["name"])
    manifest = json.loads((packages[source["name"]] / "package.json").read_text())
    if manifest["name"] != source["name"] or manifest["version"] != source["version"]:
        raise ValueError("Source manifest mismatch")

package = packages["npm"]
before = snapshot(package)
original_manifest = json.loads((package / "package.json").read_text())
for name in ["ip-address", "undici"]:
    target = package / "node_modules" / name
    target.rename(WORK / ("original-" + name))
    shutil.copytree(packages[name], target, symlinks=True)
manifest = dict(original_manifest)
manifest["version"] = VERSION
(package / "package.json").write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + "\n")
after = snapshot(package)
changed = sorted(k for k in before.keys() | after.keys() if before.get(k) != after.get(k))
if any(k != "package.json" and not k.startswith(("node_modules/ip-address/", "node_modules/undici/")) for k in changed):
    raise ValueError("Unexpected file changes outside the two patched bundles")

if CHECK:
    archive = VENDOR / ARCHIVE
    verified = unpack(archive, WORK / "verification")
    if snapshot(verified) != after:
        raise ValueError("Committed archive differs from the pinned patched source tree")
    data = archive.read_bytes()
    provenance = json.loads((VENDOR / "npm-security-provenance.json").read_text())
    expected = {"archive": ARCHIVE, "packageVersion": VERSION, "sha256": hashlib.sha256(data).hexdigest(), "integrity": "sha512-" + base64.b64encode(hashlib.sha512(data).digest()).decode(), "sources": SOURCES, "changedFiles": changed, "unchangedOutsidePatchedBundlesAndVersion": True}
    if provenance != expected:
        raise ValueError("Committed archive provenance mismatch")
    print(json.dumps({"verified": True, "archive": str(archive), "sha256": expected["sha256"], "changedFiles": len(changed)}, indent=2))
    raise SystemExit(0)

# Sorted members, fixed ownership/timestamps and no gzip filename make the
# archive reproducible without packing scripts or a platform-specific tar CLI.
output = VENDOR / ARCHIVE
with output.open("wb") as handle:
    with gzip.GzipFile(filename="", mode="wb", fileobj=handle, mtime=0, compresslevel=9) as compressed:
        with tarfile.open(fileobj=compressed, mode="w", format=tarfile.PAX_FORMAT) as stream:
            paths = [package]
            for parent, dirs, files in os.walk(package, followlinks=False):
                paths.extend(Path(parent) / name for name in dirs + files)
            for path in sorted(paths, key=lambda item: item.relative_to(package.parent).as_posix()):
                info = stream.gettarinfo(str(path), arcname=path.relative_to(package.parent).as_posix())
                info.uid = info.gid = 0
                info.uname = info.gname = ""
                info.mtime = 315532800
                info.pax_headers = {}
                if info.isfile():
                    with path.open("rb") as source:
                        stream.addfile(info, source)
                else:
                    stream.addfile(info)
verified = unpack(output, WORK / "verification")
if snapshot(verified) != after:
    raise ValueError("Generated archive does not match the verified patched tree")
data = output.read_bytes()
provenance = {"archive": ARCHIVE, "packageVersion": VERSION, "sha256": hashlib.sha256(data).hexdigest(), "integrity": "sha512-" + base64.b64encode(hashlib.sha512(data).digest()).decode(), "sources": SOURCES, "changedFiles": changed, "unchangedOutsidePatchedBundlesAndVersion": True}
(VENDOR / "npm-security-provenance.json").write_text(json.dumps(provenance, indent=2) + "\n")
print(json.dumps({"archive": str(output), "sha256": provenance["sha256"], "integrity": provenance["integrity"], "changedFiles": len(changed), "temporarySources": str(WORK)}, indent=2))
