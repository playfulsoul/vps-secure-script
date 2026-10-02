"""Pinned upstream artifact verification. Nothing is executed by this module."""
import hashlib
import os
from pathlib import Path, PurePosixPath
import stat
import zipfile

VERSION = "26.3.27"
ARCHIVE_URL = "https://github.com/XTLS/Xray-core/releases/download/v26.3.27/Xray-linux-64.zip"
ARCHIVE_SHA256 = "23cd9af937744d97776ee35ecad4972cf4b2109d1e0fe6be9930467608f7c8ae"
RELEASES = {
    VERSION: ARCHIVE_SHA256,
    "26.2.6": "29ce535b56e207a406ffa1c2d4842dcc410be003eff8ec508bb732abc9f8e385",
}
MAX_ARCHIVE = 128 * 1024 * 1024
MAX_BINARY = 128 * 1024 * 1024


class ArtifactError(Exception):
    """Redacted artifact rejection."""


def unpack_verified(archive, destination, version=None):
    """Create a new binary only after verifying the whole immutable archive."""
    destination = Path(destination)
    # Read once: never verify one path and then reopen potentially changed data.
    with open(archive, "rb") as stream:
        data = stream.read(MAX_ARCHIVE + 1)
    if len(data) > MAX_ARCHIVE:
        raise ArtifactError("archive_too_large")
    expected = ARCHIVE_SHA256 if version is None else RELEASES.get(version)
    if expected is None or hashlib.sha256(data).hexdigest() != expected:
        raise ArtifactError("archive_digest_mismatch")
    import io
    try:
        with zipfile.ZipFile(io.BytesIO(data)) as package:
            members = package.infolist()
            names = [item.filename for item in members]
            if len(set(names)) != len(names) or names.count("xray") != 1:
                raise ArtifactError("archive_members_invalid")
            for item in members:
                path = PurePosixPath(item.filename)
                mode = item.external_attr >> 16
                if path.is_absolute() or ".." in path.parts or "\\" in item.filename or stat.S_ISLNK(mode):
                    raise ArtifactError("archive_member_unsafe")
            entry = package.getinfo("xray")
            if entry.is_dir() or entry.file_size > MAX_BINARY:
                raise ArtifactError("binary_size_invalid")
            binary = package.read(entry)
    except (zipfile.BadZipFile, KeyError, RuntimeError):
        raise ArtifactError("archive_invalid") from None
    if not binary.startswith(b"\x7fELF"):
        raise ArtifactError("binary_format_invalid")
    # Do not overwrite a user's binary or follow a destination symlink.
    fd = os.open(destination, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o700)
    try:
        with os.fdopen(fd, "wb") as output:
            output.write(binary)
            output.flush()
            os.fsync(output.fileno())
    except BaseException:
        destination.unlink()
        raise
    return hashlib.sha256(binary).hexdigest()
