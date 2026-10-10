from __future__ import annotations

import json
import os
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from contextlib import redirect_stdout
from io import StringIO
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from pixaimodel import (  # noqa: E402
    ContractError,
    HERE,
    canonical_json_bytes,
    sha256_file,
    sha256_tree,
)
import run_validation_subprocess as supervisor  # noqa: E402


SCRIPT = Path(supervisor.__file__).resolve()


def strict_load(path: Path) -> dict[str, object]:
    def reject_constant(value: str) -> None:
        raise ValueError(f"non-finite constant: {value}")

    value = json.loads(path.read_text(encoding="utf-8"), parse_constant=reject_constant)
    if not isinstance(value, dict):
        raise AssertionError("expected a JSON object")
    return value


class ValidationSubprocessTests(unittest.TestCase):
    def layout(self, root: Path) -> tuple[Path, dict[str, Path]]:
        asset = root / "fixture.aimodel"
        asset.mkdir()
        (asset / "weights.bin").write_bytes(b"stable fixture")
        evidence = root / "evidence"
        return asset, {
            "report": evidence / "supervisor.json",
            "child-report": evidence / "child.json",
            "stdout-log": evidence / "stdout.log",
            "stderr-log": evidence / "stderr.log",
        }

    def child_report(self, asset: Path, *, digest: str | None = None) -> dict[str, object]:
        return {
            "schemaVersion": "1.0.0",
            "component": "denoiser",
            "asset": asset.name,
            "assetDigestAlgorithm": "sha256-tree-v1",
            "assetDigest": digest or sha256_tree(asset),
            "computePolicy": "cpu-only",
            "sourceLockSHA256": sha256_file(HERE / "source-lock.json"),
            "results": [{"status": "passed"}],
            "status": "passed",
        }

    def writer_command(
        self,
        child_report: Path,
        payload: str,
        *,
        tail: str = "",
    ) -> list[str]:
        program = (
            "from pathlib import Path\n"
            "import sys\n"
            "Path(sys.argv[1]).write_text(sys.argv[2], encoding='utf-8')\n"
            "print('child stdout', flush=True)\n"
            "print('child stderr', file=sys.stderr, flush=True)\n"
            f"{tail}\n"
        )
        return [sys.executable, "-c", program, str(child_report), payload]

    def wrapper_arguments(
        self,
        asset: Path,
        paths: dict[str, Path],
        command: list[str],
        *,
        timeout_seconds: float = 3.0,
    ) -> list[str]:
        return [
            "--asset",
            str(asset),
            "--child-report",
            str(paths["child-report"]),
            "--stdout-log",
            str(paths["stdout-log"]),
            "--stderr-log",
            str(paths["stderr-log"]),
            "--report",
            str(paths["report"]),
            "--timeout-seconds",
            str(timeout_seconds),
            "--",
            *command,
        ]

    def invoke(
        self,
        asset: Path,
        paths: dict[str, Path],
        command: list[str],
        *,
        timeout_seconds: float = 3.0,
        outer_timeout: float = 10.0,
    ) -> subprocess.CompletedProcess[str]:
        environment = os.environ.copy()
        environment["PIXELTJE_COREAI_COMPUTE"] = "cpu-only"
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        return subprocess.run(
            [
                sys.executable,
                str(SCRIPT),
                *self.wrapper_arguments(
                    asset, paths, command, timeout_seconds=timeout_seconds
                ),
            ],
            check=False,
            capture_output=True,
            text=True,
            env=environment,
            timeout=outer_timeout,
        )

    def test_paths_must_be_distinct_non_nested_and_outside_asset(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            asset, paths = self.layout(Path(temporary))
            resolved = {
                name: supervisor.outside_checkout(path)
                for name, path in paths.items()
            }
            duplicate = dict(resolved)
            duplicate["stderr-log"] = duplicate["stdout-log"]
            with self.assertRaisesRegex(Exception, "distinct"):
                supervisor.validate_evidence_paths(asset.resolve(), duplicate)

            nested = dict(resolved)
            nested["stderr-log"] = nested["stdout-log"] / "nested.log"
            with self.assertRaisesRegex(Exception, "non-nested"):
                supervisor.validate_evidence_paths(asset.resolve(), nested)

            inside = dict(resolved)
            inside["report"] = asset.resolve() / "report.json"
            with self.assertRaisesRegex(Exception, "outside the Core AI asset"):
                supervisor.validate_evidence_paths(asset.resolve(), inside)

            with self.assertRaisesRegex(Exception, "outside Git"):
                supervisor.outside_checkout(HERE / "forbidden-report.json")
            with self.assertRaisesRegex(Exception, "forbidden external source"):
                supervisor.guarded_resolve(
                    Path.home() / "source" / "pixeltje" / "do-not-inspect.json"
                )

    def test_passing_child_is_bound_to_unchanged_asset(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            asset, paths = self.layout(Path(temporary))
            payload = json.dumps(self.child_report(asset), allow_nan=False)
            completed = self.invoke(
                asset,
                paths,
                self.writer_command(paths["child-report"], payload),
            )

            self.assertEqual(completed.returncode, 0, completed.stderr)
            report = strict_load(paths["report"])
            self.assertEqual(report["status"], "passed")
            self.assertTrue(report["childReportValid"])
            self.assertTrue(report["assetUnchanged"])
            self.assertEqual(report["assetDigestBefore"], report["assetDigestAfter"])
            self.assertEqual(
                paths["report"].read_bytes(), canonical_json_bytes(report)
            )
            self.assertEqual(
                list(paths["report"].parent.glob(".supervisor.json.*.tmp")), []
            )

    def test_malformed_child_reports_still_produce_strict_failure_evidence(self) -> None:
        cases = (
            "{",
            '{"x":NaN}',
            '{"status":"passed","status":"failed"}',
            "[]",
        )
        for payload in cases:
            with self.subTest(payload=payload), tempfile.TemporaryDirectory() as temporary:
                asset, paths = self.layout(Path(temporary))
                completed = self.invoke(
                    asset,
                    paths,
                    self.writer_command(paths["child-report"], payload),
                )

                self.assertEqual(completed.returncode, 1, completed.stderr)
                report = strict_load(paths["report"])
                self.assertEqual(report["status"], "failed")
                self.assertGreater(report["childReport"]["size"], 0)
                self.assertEqual(
                    report["childReport"]["sha256"],
                    sha256_file(paths["child-report"]),
                )
                self.assertIn(
                    "child-report-parse",
                    {item["stage"] for item in report["errors"]},
                )

    def test_wrong_asset_digest_cannot_be_blessed(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            asset, paths = self.layout(Path(temporary))
            payload = json.dumps(
                self.child_report(asset, digest="0" * 64), allow_nan=False
            )
            completed = self.invoke(
                asset,
                paths,
                self.writer_command(paths["child-report"], payload),
            )

            self.assertEqual(completed.returncode, 1, completed.stderr)
            report = strict_load(paths["report"])
            self.assertFalse(report["childReportValid"])
            self.assertIn(
                "child-report-validation",
                {item["stage"] for item in report["errors"]},
            )

    def test_launch_failure_still_produces_report_and_logs(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            asset, paths = self.layout(Path(temporary))
            completed = self.invoke(
                asset,
                paths,
                [str(Path(temporary) / "does-not-exist")],
            )

            self.assertEqual(completed.returncode, 1, completed.stderr)
            report = strict_load(paths["report"])
            self.assertEqual(report["status"], "failed")
            self.assertIsNone(report["returnCode"])
            self.assertIn(
                "child-launch", {item["stage"] for item in report["errors"]}
            )
            self.assertEqual(report["stdout"]["size"], 0)
            self.assertEqual(report["stderr"]["size"], 0)

    @unittest.skipUnless(os.name == "posix", "POSIX signal semantics required")
    def test_direct_child_abort_is_recorded_even_with_passing_child_report(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            asset, paths = self.layout(Path(temporary))
            payload = json.dumps(self.child_report(asset), allow_nan=False)
            tail = (
                "import os, resource, signal\n"
                "resource.setrlimit(resource.RLIMIT_CORE, (0, 0))\n"
                "os.kill(os.getpid(), signal.SIGABRT)"
            )
            completed = self.invoke(
                asset,
                paths,
                self.writer_command(paths["child-report"], payload, tail=tail),
            )

            self.assertEqual(completed.returncode, 1, completed.stderr)
            report = strict_load(paths["report"])
            self.assertEqual(report["returnCode"], -signal.SIGABRT)
            self.assertEqual(report["terminatingSignal"], "SIGABRT")
            self.assertTrue(report["childReportValid"])
            self.assertEqual(report["status"], "failed")
            self.assertIn(b"child stderr", paths["stderr-log"].read_bytes())

    @unittest.skipUnless(os.name == "posix", "POSIX signal semantics required")
    def test_timeout_terminates_child_and_preserves_logs(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            asset, paths = self.layout(Path(temporary))
            command = [
                sys.executable,
                "-c",
                "import time; print('before sleep', flush=True); time.sleep(60)",
            ]
            started = time.monotonic()
            completed = self.invoke(
                asset,
                paths,
                command,
                timeout_seconds=0.1,
                outer_timeout=5.0,
            )

            self.assertLess(time.monotonic() - started, 5.0)
            self.assertEqual(completed.returncode, 1, completed.stderr)
            report = strict_load(paths["report"])
            self.assertTrue(report["timedOut"])
            self.assertEqual(report["terminatingSignal"], "SIGTERM")
            self.assertEqual(report["timeoutTermination"], "SIGTERM")
            self.assertIn(b"before sleep", paths["stdout-log"].read_bytes())

    def test_asset_mutation_is_detected_after_a_zero_exit(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            asset, paths = self.layout(Path(temporary))
            payload = json.dumps(self.child_report(asset), allow_nan=False)
            tail = "Path(sys.argv[3]).write_bytes(b'mutated')"
            command = self.writer_command(
                paths["child-report"], payload, tail=tail
            ) + [str(asset / "weights.bin")]
            completed = self.invoke(asset, paths, command)

            self.assertEqual(completed.returncode, 1, completed.stderr)
            report = strict_load(paths["report"])
            self.assertFalse(report["assetUnchanged"])
            self.assertNotEqual(report["assetDigestBefore"], report["assetDigestAfter"])
            self.assertIn(
                "asset-mutated", {item["stage"] for item in report["errors"]}
            )

    def test_enrichment_failure_is_serialized_instead_of_raised(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            asset, paths = self.layout(Path(temporary))
            payload = json.dumps(self.child_report(asset), allow_nan=False)
            command = self.writer_command(paths["child-report"], payload)
            arguments = self.wrapper_arguments(asset, paths, command)
            with (
                mock.patch.dict(
                    os.environ, {"PIXELTJE_COREAI_COMPUTE": "cpu-only"}
                ),
                mock.patch.object(
                    supervisor,
                    "system_record",
                    side_effect=RuntimeError("version probe failed"),
                ),
                redirect_stdout(StringIO()),
            ):
                result = supervisor.main(arguments)

            self.assertEqual(result, 1)
            report = strict_load(paths["report"])
            self.assertIsNone(report["system"])
            self.assertIn(
                "system-record", {item["stage"] for item in report["errors"]}
            )

    def test_atomic_writer_never_replaces_or_leaves_partial_json(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            existing = root / "existing.json"
            existing.write_bytes(b"sentinel")
            with self.assertRaises(ContractError):
                supervisor.write_atomic_new_json(existing, {"status": "failed"})
            self.assertEqual(existing.read_bytes(), b"sentinel")

            invalid = root / "invalid.json"
            with self.assertRaises(ValueError):
                supervisor.write_atomic_new_json(invalid, {"value": float("nan")})
            self.assertFalse(invalid.exists())
            self.assertEqual(list(root.glob(".*.tmp")), [])


if __name__ == "__main__":
    unittest.main()
