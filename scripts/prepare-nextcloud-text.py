#!/usr/bin/env python3
"""Extract the reviewed signed Text compatibility app, without changing services."""
import argparse
import gzip
import hashlib
import json
from pathlib import Path, PurePosixPath
import tarfile
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
ARTIFACT = json.loads((ROOT / 'application-artifacts.json').read_text())['text_compatibility']


def prepare(source, destination):
    with source.open('rb') as stream:
        if hashlib.file_digest(stream, 'sha256').hexdigest() != ARTIFACT['sha256']:
            raise ValueError('Official Nextcloud archive checksum mismatch')
    if destination.exists():
        raise FileExistsError('Refusing to overwrite an existing app archive')
    prefix = 'nextcloud/apps/text'
    info = signature = None
    total = 0
    output = destination.open('xb')
    try:
        # Streaming avoids repeated decompression of the full server archive.
        with output, gzip.GzipFile(fileobj=output, mode='wb', mtime=0) as compressed:
            with tarfile.open(fileobj=compressed, mode='w|') as target, tarfile.open(source, 'r|bz2') as archive:
                for member in archive:
                    if member.name != prefix and not member.name.startswith(prefix + '/'):
                        continue
                    path = PurePosixPath(member.name)
                    if path.is_absolute() or '..' in path.parts or not (member.isfile() or member.isdir()):
                        raise ValueError('Unsafe Text archive entry')
                    total += member.size
                    if total > 256 * 1024**2:
                        raise ValueError('Text app exceeds the reviewed size limit')
                    data = archive.extractfile(member) if member.isfile() else None
                    member.name = member.name.removeprefix('nextcloud/apps/')
                    if member.name in ('text/appinfo/info.xml', 'text/appinfo/signature.json'):
                        import io
                        content = data.read()
                        if member.name.endswith('info.xml'):
                            info = ET.fromstring(content)
                        else:
                            signature = json.loads(content)
                        data = io.BytesIO(content)
                    target.addfile(member, data)
        requirement = info.find('dependencies/nextcloud') if info is not None else None
        if info is None or info.findtext('version') != ARTIFACT['version'] or requirement is None:
            raise ValueError('Text app metadata differs from the reviewed version')
        if requirement.attrib != {'min-version': '35', 'max-version': '35'} or not signature:
            raise ValueError('Text compatibility range or signature is missing')
    except BaseException:
        destination.unlink(missing_ok=True)
        raise
    with destination.open('rb') as stream:
        checksum = hashlib.file_digest(stream, 'sha256').hexdigest()
    return {'app': 'text', 'version': ARTIFACT['version'], 'sha256': checksum,
            'source_sha256': ARTIFACT['sha256'], 'source_url': ARTIFACT['url'],
            'services_changed': False, 'official_runtime_integrity_check_required': True}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--server-archive', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    print(json.dumps(prepare(args.server_archive, args.output), indent=2))


if __name__ == '__main__':
    main()
