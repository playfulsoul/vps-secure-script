import hashlib
import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import zipfile

MODULE = Path(__file__).resolve().parents[2] / 'modules/builtin/applications-reality-node/artifacts.py'
spec = importlib.util.spec_from_file_location('artifacts', MODULE)
artifacts = importlib.util.module_from_spec(spec)
spec.loader.exec_module(artifacts)


class ArtifactTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.archive = self.root / 'fixture.zip'
        self.binary = self.root / 'xray'

    def fixture(self, extra=None):
        with zipfile.ZipFile(self.archive, 'w') as package:
            package.writestr('xray', b'\x7fELFsynthetic-not-executable')
            if extra:
                package.writestr(extra, b'not-used')
        return hashlib.sha256(self.archive.read_bytes()).hexdigest()

    def test_bad_digest_does_not_write(self):
        self.fixture()
        with self.assertRaisesRegex(artifacts.ArtifactError, 'digest_mismatch'):
            artifacts.unpack_verified(self.archive, self.binary)
        self.assertFalse(self.binary.exists())

    def test_verified_binary_and_exclusive_destination(self):
        with patch.object(artifacts, 'ARCHIVE_SHA256', self.fixture()):
            artifacts.unpack_verified(self.archive, self.binary)
            self.assertEqual(self.binary.stat().st_mode & 0o777, 0o700)
            with self.assertRaises(FileExistsError):
                artifacts.unpack_verified(self.archive, self.binary)

    def test_traversal_and_symlink_rejected(self):
        for name in ('../escape', '/escape', 'a\\escape'):
            with patch.object(artifacts, 'ARCHIVE_SHA256', self.fixture(name)):
                with self.assertRaisesRegex(artifacts.ArtifactError, 'unsafe'):
                    artifacts.unpack_verified(self.archive, self.binary)
        info = zipfile.ZipInfo('link')
        info.external_attr = 0o120777 << 16
        with zipfile.ZipFile(self.archive, 'w') as package:
            package.writestr('xray', b'\x7fELFsynthetic')
            package.writestr(info, b'xray')
        with patch.object(artifacts, 'ARCHIVE_SHA256', hashlib.sha256(self.archive.read_bytes()).hexdigest()):
            with self.assertRaisesRegex(artifacts.ArtifactError, 'unsafe'):
                artifacts.unpack_verified(self.archive, self.binary)

    def test_destination_symlink_preserved(self):
        self.binary.symlink_to(self.root / 'elsewhere')
        with patch.object(artifacts, 'ARCHIVE_SHA256', self.fixture()):
            with self.assertRaises(FileExistsError):
                artifacts.unpack_verified(self.archive, self.binary)
        self.assertFalse((self.root / 'elsewhere').exists())

    def test_archive_size_bound(self):
        self.fixture()
        with patch.object(artifacts, 'MAX_ARCHIVE', 1):
            with self.assertRaisesRegex(artifacts.ArtifactError, 'too_large'):
                artifacts.unpack_verified(self.archive, self.binary)
