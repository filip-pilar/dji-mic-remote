#!/usr/bin/env python3
"""Validate the pinned manifest before copying an optional offline model into a build."""
import hashlib
import json
import pathlib
import shutil
import sys

source, destination = map(pathlib.Path, sys.argv[1:])
manifest = json.loads((pathlib.Path(__file__).resolve().parents[1] / 'Sources/DJIMicRemote/Resources/ModelManifest.json').read_text())
for entry in manifest['files']:
    path = source / entry['path']
    with path.open('rb') as stream:
        hasher = hashlib.sha256()
        for chunk in iter(lambda: stream.read(1048576), b''):
            hasher.update(chunk)
        digest = hasher.hexdigest()
    if path.stat().st_size != entry['bytes'] or digest != entry['sha256']:
        raise SystemExit(f"Model verification failed: {entry['path']}")
if destination.exists():
    shutil.rmtree(destination)
for entry in manifest['files']:
    target = destination / entry['path']
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source / entry['path'], target)
print(f"Bundled verified Parakeet revision {manifest['revision']}")
