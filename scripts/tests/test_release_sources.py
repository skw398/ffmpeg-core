"""Source-package collection and preparation use data fixtures, never builds."""

import contextlib
import hashlib
import io
import json
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from build_data import Pin
import release_sources as sources


def archive_bytes(files):
    data = io.BytesIO()
    with tarfile.open(fileobj=data, mode="w") as archive:
        for name, content in files.items():
            member = tarfile.TarInfo(name)
            member.size = len(content)
            archive.addfile(member, io.BytesIO(content))
    return data.getvalue()


class ReleaseSourcesTest(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.package = self.root / "package"
        self.package.mkdir()
        self.pin = Pin("fixture", "tag", "https://example.invalid/fixture", "COMMIT=" + "b" * 40, "MIT")
        self.archive = archive_bytes({"fixture/LICENSE": b"fixture license", "fixture/source.c": b"source"})
        (self.package / "upstream").mkdir()
        (self.package / "upstream/fixture.tar").write_bytes(self.archive)
        self.manifest = {"format": 1, "projectCommit": "a" * 40,
                         "packages": {"fixture": {"version": self.pin.version, "url": self.pin.url,
                                                   "sourcePin": self.pin.checksum, "path": "upstream/fixture.tar"}},
                         "files": {"upstream/fixture.tar": hashlib.sha256(self.archive).hexdigest()}}
        self.destination = self.root / "build/src/fixture"
        self.save_manifest()

    def save_manifest(self):
        (self.package / "manifest.json").write_text(json.dumps(self.manifest))

    def test_extract_fixed_git_and_tar_sources_without_fetching(self):
        with contextlib.redirect_stdout(io.StringIO()):
            sources.extract(self.package, self.pin, self.destination)
            self.assertEqual((self.destination / "source.c").read_bytes(), b"source")
            self.pin = Pin("fixture", "tag", self.pin.url, hashlib.sha256(self.archive).hexdigest(), "MIT")
            self.manifest["packages"]["fixture"]["sourcePin"] = self.pin.checksum
            self.save_manifest()
            sources.extract(self.package, self.pin, self.destination)
            self.assertEqual((self.destination / "LICENSE").read_bytes(), b"fixture license")

    def test_bad_pin_or_archive_preserves_existing_destination(self):
        self.destination.mkdir(parents=True)
        (self.destination / "keep").write_text("existing")
        self.manifest["packages"]["fixture"]["sourcePin"] = "COMMIT=" + "c" * 40
        self.save_manifest()
        with self.assertRaisesRegex(ValueError, "pin mismatch"):
            sources.extract(self.package, self.pin, self.destination)
        self.manifest["packages"]["fixture"]["sourcePin"] = self.pin.checksum
        self.save_manifest()
        (self.package / "upstream/fixture.tar").write_text("corrupt")
        with self.assertRaisesRegex(ValueError, "checksum mismatch"):
            sources.extract(self.package, self.pin, self.destination)
        self.assertEqual((self.destination / "keep").read_text(), "existing")

    def test_archive_traversal_and_multiple_roots_are_rejected(self):
        for files in ({"fixture/../../escape": b"bad"}, {"one/file": b"one", "two/file": b"two"}):
            with self.subTest(files=files):
                data = archive_bytes(files)
                (self.package / "upstream/fixture.tar").write_bytes(data)
                self.manifest["files"]["upstream/fixture.tar"] = hashlib.sha256(data).hexdigest()
                self.save_manifest()
                with self.assertRaises((ValueError, tarfile.TarError)):
                    sources.extract(self.package, self.pin, self.destination)
        self.assertFalse((self.root / "escape").exists())

    def test_collect_uses_commit_snapshot_and_excludes_cache_files(self):
        project = self.root / "project"
        for name in sources.ROOT_FILES:
            file = project / name
            file.parent.mkdir(parents=True, exist_ok=True)
            file.write_text("project fixture\n")
        (project / "scripts/__pycache__").mkdir()
        (project / "scripts/__pycache__/cache.cpython-314.pyc").write_text("excluded")
        output = self.root / "sources.tar.xz"
        info = self.root / "toolchain-versions.txt"
        info.write_text("toolchain")

        def git(command, **kwargs):
            if "ls-files" in command:
                return subprocess.CompletedProcess(command, 0, stdout=b"scripts/__pycache__/cache.cpython-314.pyc\0")
            if "archive" in command:
                self.assertEqual(command[-1], self.pin.commit)
                kwargs["stdout"].write(self.archive)
                return subprocess.CompletedProcess(command, 0)
            return subprocess.CompletedProcess(command, 0, stdout=("a" * 40 if command[2] == str(project) else "b" * 40) + "\n")

        with patch.object(sources.subprocess, "run", side_effect=git), contextlib.redirect_stdout(io.StringIO()):
            sources.collect(project, {"fixture": self.pin}, self.root / "src", self.root, output, [info])
        with tarfile.open(output) as archive:
            names = archive.getnames()
            self.assertFalse(any("__pycache__" in name for name in names))
            manifest = json.load(archive.extractfile(sources.BUNDLE_NAME + "/manifest.json"))
            self.assertEqual(manifest["packages"]["fixture"]["sourcePin"], self.pin.checksum)
            self.assertEqual(archive.extractfile(sources.BUNDLE_NAME + "/upstream/fixture.tar").read(), self.archive)
            self.assertEqual(archive.extractfile(sources.BUNDLE_NAME + "/project/SOURCE-CHANGES.md").read(),
                             (project / "SOURCE-CHANGES.md").read_bytes())
        with patch.object(sources.subprocess, "run", side_effect=git), self.assertRaisesRegex(ValueError, "source commit mismatch"):
            bad = Pin(self.pin.name, self.pin.version, self.pin.url, "COMMIT=" + "c" * 40, "MIT")
            sources.collect(project, {"fixture": bad}, self.root / "src", self.root, output, [info])

    def test_collect_rejects_corrupt_tarball(self):
        pin = Pin("fixture", "tag", self.pin.url, "c" * 64, "MIT")
        pin.archive(self.root).write_bytes(self.archive)
        with patch.object(sources, "project_files", return_value=[]), \
                patch.object(sources.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, stdout="a" * 40)), \
                self.assertRaisesRegex(ValueError, "source checksum mismatch"):
            sources.collect(self.root, {"fixture": pin}, self.root, self.root, self.root / "sources.tar.xz", [])


if __name__ == "__main__":
    unittest.main()
