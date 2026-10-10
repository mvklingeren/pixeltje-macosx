from __future__ import annotations

import hashlib
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from pixaimodel import ContractError, audit_references, audit_source  # noqa: E402


class CleanCheckoutAuditTests(unittest.TestCase):
    def git(self, root: Path, *arguments: str) -> str:
        result = subprocess.run(
            ["git", "-C", str(root), *arguments],
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        return result.stdout.strip()

    def initialize_repository(self, root: Path, files: dict[str, bytes]) -> str:
        root.mkdir()
        self.git(root, "init", "-q")
        for relative, contents in files.items():
            path = root / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(contents)
        self.git(root, "add", "--all")
        self.git(
            root,
            "-c",
            "user.name=Pixeltje Tests",
            "-c",
            "user.email=pixeltje-tests@example.invalid",
            "commit",
            "-q",
            "-m",
            "fixture",
        )
        return self.git(root, "rev-parse", "HEAD")

    def write_lock(self, path: Path, value: dict[str, object]) -> None:
        path.write_text(json.dumps(value), encoding="utf-8")

    def source_lock(self, revision: str, locked_bytes: bytes) -> dict[str, object]:
        return {
            "schemaVersion": "1.0.0",
            "publisherModel": {
                "revision": revision,
                "files": [
                    {
                        "path": "locked.bin",
                        "size": len(locked_bytes),
                        "sha256": hashlib.sha256(locked_bytes).hexdigest(),
                    }
                ],
            },
        }

    def test_source_audit_rejects_tracked_change_outside_locked_inventory(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "source"
            locked_bytes = b"locked publisher bytes"
            revision = self.initialize_repository(
                source,
                {"locked.bin": locked_bytes, "implementation.py": b"original\n"},
            )
            lock = root / "source-lock.json"
            self.write_lock(lock, self.source_lock(revision, locked_bytes))

            audit_source(source, lock, allow_lfs_pointers=False)
            (source / "implementation.py").write_bytes(b"modified\n")

            with self.assertRaisesRegex(
                ContractError, "publisher source checkout is not clean"
            ):
                audit_source(source, lock, allow_lfs_pointers=False)

    def test_source_audit_rejects_untracked_file(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "source"
            locked_bytes = b"locked publisher bytes"
            revision = self.initialize_repository(source, {"locked.bin": locked_bytes})
            lock = root / "source-lock.json"
            self.write_lock(lock, self.source_lock(revision, locked_bytes))
            (source / "injected.py").write_bytes(b"untrusted\n")

            with self.assertRaisesRegex(ContractError, r"\?\? injected\.py"):
                audit_source(source, lock, allow_lfs_pointers=False)

    def test_reference_audit_rejects_dirty_checkout_before_hash_trust(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            publisher = root / "publisher"
            apple = root / "apple"
            publisher_license = b"publisher license\n"
            apple_license = b"apple license\n"
            uv_lock = b"pinned environment\n"
            publisher_revision = self.initialize_repository(
                publisher,
                {"LICENSE": publisher_license, "implementation.py": b"original\n"},
            )
            apple_revision = self.initialize_repository(
                apple, {"LICENSE": apple_license, "uv.lock": uv_lock}
            )
            lock = root / "source-lock.json"
            self.write_lock(
                lock,
                {
                    "publisherReference": {
                        "revision": publisher_revision,
                        "licenseSHA256": hashlib.sha256(publisher_license).hexdigest(),
                    },
                    "coreAITooling": {
                        "revision": apple_revision,
                        "licenseSHA256": hashlib.sha256(apple_license).hexdigest(),
                        "uvLockSHA256": hashlib.sha256(uv_lock).hexdigest(),
                    },
                },
            )

            audit_references(publisher, apple, lock)
            (publisher / "implementation.py").write_bytes(b"modified\n")
            self.git(publisher, "add", "implementation.py")

            with self.assertRaisesRegex(
                ContractError, "publisher reference checkout is not clean"
            ):
                audit_references(publisher, apple, lock)

    def test_reference_audit_rejects_untracked_apple_tooling_file(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            publisher = root / "publisher"
            apple = root / "apple"
            publisher_license = b"publisher license\n"
            apple_license = b"apple license\n"
            uv_lock = b"pinned environment\n"
            publisher_revision = self.initialize_repository(
                publisher, {"LICENSE": publisher_license}
            )
            apple_revision = self.initialize_repository(
                apple, {"LICENSE": apple_license, "uv.lock": uv_lock}
            )
            lock = root / "source-lock.json"
            self.write_lock(
                lock,
                {
                    "publisherReference": {
                        "revision": publisher_revision,
                        "licenseSHA256": hashlib.sha256(publisher_license).hexdigest(),
                    },
                    "coreAITooling": {
                        "revision": apple_revision,
                        "licenseSHA256": hashlib.sha256(apple_license).hexdigest(),
                        "uvLockSHA256": hashlib.sha256(uv_lock).hexdigest(),
                    },
                },
            )
            (apple / "injected.py").write_bytes(b"untrusted\n")

            with self.assertRaisesRegex(
                ContractError, "Apple Core AI tooling checkout is not clean"
            ):
                audit_references(publisher, apple, lock)


if __name__ == "__main__":
    unittest.main()
