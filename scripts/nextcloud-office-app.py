#!/usr/bin/env python3
"""Install the reviewed Office app; never resolve an unpinned app-store version."""
import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import subprocess
import tarfile
import tempfile
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
ARTIFACT = json.loads((ROOT / 'application-artifacts.json').read_text())['richdocuments_existing_compatibility']


def validate_archive(path, expected=ARTIFACT):
    with path.open('rb') as stream:
        if hashlib.file_digest(stream, 'sha256').hexdigest() != expected['sha256']:
            raise ValueError('Office artifact checksum mismatch')
    with tarfile.open(path) as archive:
        members = archive.getmembers()
        total = 0
        for member in members:
            name = PurePosixPath(member.name)
            if name.is_absolute() or '..' in name.parts or not name.parts or name.parts[0] != 'richdocuments':
                raise ValueError('Office archive contains an invalid path')
            if not (member.isfile() or member.isdir()):
                raise ValueError('Office archive links/devices are not allowed')
            total += member.size
        if total > 512 * 1024**2:
            raise ValueError('Office archive exceeds the reviewed size limit')
        info = ET.fromstring(archive.extractfile('richdocuments/appinfo/info.xml').read())
        requirement = info.find('dependencies/nextcloud')
        major = expected['nextcloud_major']
        if info.findtext('version') != expected['version'] or requirement is None:
            raise ValueError('Office app version mismatch')
        if not int(requirement.get('min-version')) <= major <= int(requirement.get('max-version')):
            raise ValueError('Office app is not compatible with the pinned Nextcloud major')


def main():
    os.umask(0o077)
    parser = argparse.ArgumentParser()
    parser.add_argument('--archive', type=Path)
    parser.add_argument('--container', default='nextcloud-app')
    args = parser.parse_args()
    archive = args.archive
    if archive is None:
        archive = Path.home() / '.cache/woow-release' / ARTIFACT['url'].rsplit('/', 1)[1]
        archive.parent.mkdir(parents=True, exist_ok=True)
        if not archive.exists():
            partial = archive.with_suffix('.download')
            subprocess.run(['curl', '-fsSL', '--retry', '3', ARTIFACT['url'], '-o', partial], check=True)
            validate_archive(partial)
            partial.replace(archive)
    validate_archive(archive)
    container = args.container
    occ = ['podman', 'exec', '--user', 'www-data', container, 'php', 'occ']
    status = json.loads(subprocess.check_output([*occ, 'status', '--output=json'], text=True))
    if int(status['version'].split('.')[0]) != ARTIFACT['nextcloud_major']:
        raise SystemExit('Nextcloud major differs; existing apps were not changed')
    current = subprocess.run([*occ, 'config:app:get', 'richdocuments', 'installed_version'], capture_output=True, text=True)
    if current.stdout.strip() and current.stdout.strip() != ARTIFACT['version']:
        raise SystemExit('Existing Office app version differs; a separate upgrade plan is required')
    destination = '/var/www/html/custom_apps/richdocuments'
    present = subprocess.run(['podman', 'exec', container, 'test', '-e', destination]).returncode == 0
    if present:
        info = subprocess.check_output(['podman', 'exec', container, 'cat', destination + '/appinfo/info.xml'])
        if ET.fromstring(info).findtext('version') != ARTIFACT['version']:
            raise SystemExit('Existing Office files differ; refusing to overwrite them')
    else:
        with tempfile.TemporaryDirectory(prefix='woow-office-app-') as temp:
            with tarfile.open(archive) as bundle:
                bundle.extractall(temp, filter='data')
            subprocess.run(['podman', 'cp', str(Path(temp) / 'richdocuments'), container + ':/var/www/html/custom_apps/'], check=True)
        subprocess.run(['podman', 'exec', '--user', '0', container, 'chown', '-R', '33:33', destination], check=True)
    subprocess.run([*occ, 'integrity:check-app', 'richdocuments'], check=True)
    subprocess.run([*occ, 'app:enable', 'richdocuments'], check=True)
    installed = subprocess.check_output([*occ, 'config:app:get', 'richdocuments', 'installed_version'], text=True).strip()
    if installed != ARTIFACT['version']:
        raise SystemExit('Office app activation returned an unexpected version')
    print(json.dumps({'app': 'richdocuments', 'version': installed, 'archive_sha256': ARTIFACT['sha256'], 'integrity_check_passed': True}))


if __name__ == '__main__':
    main()
