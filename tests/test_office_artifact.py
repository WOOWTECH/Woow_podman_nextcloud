import hashlib
import importlib.util
import io
from pathlib import Path
import tarfile
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('office_app', Path(__file__).resolve().parents[1] / 'scripts/nextcloud-office-app.py')
office = importlib.util.module_from_spec(spec)
spec.loader.exec_module(office)


class OfficeArchiveTests(unittest.TestCase):
    def make(self, root, extra=None, version=office.ARTIFACT['version'], major='35'):
        archive = root / 'app.tar.gz'
        with tarfile.open(archive, 'w:gz') as bundle:
            body = f'<info><version>{version}</version><dependencies><nextcloud min-version="{major}" max-version="{major}" /></dependencies></info>'.encode()
            item = tarfile.TarInfo('richdocuments/appinfo/info.xml')
            item.size = len(body)
            bundle.addfile(item, io.BytesIO(body))
            if extra is not None:
                bundle.addfile(extra)
        expected = dict(office.ARTIFACT, sha256=hashlib.sha256(archive.read_bytes()).hexdigest())
        return archive, expected

    def test_compatible_archive(self):
        with tempfile.TemporaryDirectory() as temp:
            office.validate_archive(*self.make(Path(temp)))

    def test_path_link_version_and_core_mismatch(self):
        traversal = tarfile.TarInfo('richdocuments/../../config.php')
        link = tarfile.TarInfo('richdocuments/escape')
        link.type = tarfile.SYMTYPE
        link.linkname = '/etc'
        for options in ({'extra': traversal}, {'extra': link}, {'version': '13.0.0'}, {'major': '34'}):
            with self.subTest(options=options), tempfile.TemporaryDirectory() as temp:
                with self.assertRaises(ValueError):
                    office.validate_archive(*self.make(Path(temp), **options))

    def test_checksum_mismatch(self):
        with tempfile.TemporaryDirectory() as temp:
            archive, expected = self.make(Path(temp))
            expected['sha256'] = '0' * 64
            with self.assertRaises(ValueError):
                office.validate_archive(archive, expected)
