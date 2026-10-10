from __future__ import annotations

import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import diagnose_denoiser  # noqa: E402
import make_validation_record  # noqa: E402
import validate_components  # noqa: E402
import validate_pipeline  # noqa: E402
import validate_vae_tiling  # noqa: E402
from pixaimodel import ContractError, guarded_resolve, outside_checkout  # noqa: E402
from run_validation_subprocess import prepare_atomic_new_json  # noqa: E402


class ReportNoReplaceTests(unittest.TestCase):
    def _sentinel(self, temporary: Path) -> Path:
        path = temporary / "report.json"
        path.write_bytes(b"preserve this evidence\n")
        return path

    def test_component_validator_preserves_existing_report_before_work(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            report = self._sentinel(Path(directory))
            arguments = [
                "validate_components.py",
                "prompt-encoder",
                "--asset",
                "unused.aimodel",
                "--source",
                "unused-source",
                "--report",
                str(report),
            ]
            with mock.patch.object(sys, "argv", arguments), mock.patch.object(
                validate_components.asyncio, "run"
            ) as run:
                self.assertNotEqual(validate_components.main(), 0)
                run.assert_not_called()
            self.assertEqual(report.read_bytes(), b"preserve this evidence\n")

    def test_vae_tiling_validator_preserves_existing_report_before_work(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            report = self._sentinel(Path(directory))
            arguments = [
                "validate_vae_tiling.py",
                "vae-decoder",
                "--asset",
                "unused.aimodel",
                "--source",
                "unused-source",
                "--report",
                str(report),
            ]
            with mock.patch.object(sys, "argv", arguments), mock.patch.object(
                validate_vae_tiling.asyncio, "run"
            ) as run:
                self.assertNotEqual(validate_vae_tiling.main(), 0)
                run.assert_not_called()
            self.assertEqual(report.read_bytes(), b"preserve this evidence\n")

    def test_pipeline_validator_preserves_existing_report_before_hashing(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            report = self._sentinel(Path(directory))
            arguments = [
                "validate_pipeline.py",
                "--source",
                "unused-source",
                "--publisher-reference",
                "unused-publisher",
                "--prompt-encoder",
                "unused-prompt.aimodel",
                "--denoiser",
                "unused-denoiser.aimodel",
                "--vae-decoder",
                "unused-decoder.aimodel",
                "--glue-test-log",
                "unused",
                "--report",
                str(report),
            ]
            with mock.patch.object(sys, "argv", arguments), mock.patch.object(
                validate_pipeline, "component_asset_bindings"
            ) as bindings:
                self.assertNotEqual(validate_pipeline.main(), 0)
                bindings.assert_not_called()
            self.assertEqual(report.read_bytes(), b"preserve this evidence\n")

    def test_denoiser_diagnostic_preserves_existing_report_before_work(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            report = self._sentinel(Path(directory))
            arguments = [
                "diagnose_denoiser.py",
                "--source",
                "unused-source",
                "--publisher-reference",
                "unused-publisher",
                "--output",
                str(Path(directory) / "probe.aimodel"),
                "--report",
                str(report),
            ]
            with mock.patch.object(sys, "argv", arguments), mock.patch.object(
                diagnose_denoiser.asyncio, "run"
            ) as run:
                self.assertNotEqual(diagnose_denoiser.main(), 0)
                run.assert_not_called()
            self.assertEqual(report.read_bytes(), b"preserve this evidence\n")

    def test_validation_aggregator_preserves_existing_output_before_work(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            report = self._sentinel(Path(directory))
            arguments = [
                "make_validation_record.py",
                "--source",
                "unused-source",
                "--publisher-reference",
                "unused-publisher",
                "--apple-reference",
                "unused-apple",
                "--lock",
                "unused-lock.json",
                "--prompt-report",
                "unused-prompt.json",
                "--denoiser-report",
                "unused-denoiser.json",
                "--vae-encoder-report",
                "unused-encoder.json",
                "--vae-decoder-report",
                "unused-decoder.json",
                "--vae-encoder-tiling-report",
                "unused-encoder-tiling.json",
                "--vae-decoder-tiling-report",
                "unused-decoder-tiling.json",
                "--pipeline-report",
                "unused-pipeline.json",
                "--glue-test-log",
                "unused-glue-tests.log",
                "--prompt-export-report",
                "unused-prompt-export.json",
                "--denoiser-export-report",
                "unused-denoiser-export.json",
                "--vae-encoder-export-report",
                "unused-encoder-export.json",
                "--vae-decoder-export-report",
                "unused-decoder-export.json",
                "--output",
                str(report),
            ]
            with mock.patch.object(sys, "argv", arguments), mock.patch.object(
                make_validation_record, "make_record"
            ) as make_record:
                self.assertNotEqual(make_validation_record.main(), 0)
                make_record.assert_not_called()
            self.assertEqual(report.read_bytes(), b"preserve this evidence\n")

    def test_report_preflight_rejects_broken_symlink(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            temporary = Path(directory)
            path = temporary / "report.json"
            path.symlink_to(temporary / "missing-target")
            with self.assertRaisesRegex(ContractError, "refusing to replace"):
                prepare_atomic_new_json(path)
            self.assertTrue(path.is_symlink())

    def test_durable_paths_reject_checkout_lexically_and_after_resolution(self) -> None:
        checkout = Path(__file__).resolve().parents[3]
        with self.assertRaisesRegex(ContractError, "outside Git"):
            outside_checkout(checkout / "never-write.json")

        with tempfile.TemporaryDirectory() as directory:
            alias = Path(directory) / "checkout-alias"
            alias.symlink_to(checkout, target_is_directory=True)
            with self.assertRaisesRegex(ContractError, "outside Git"):
                outside_checkout(alias / "never-write.json")

    def test_forbidden_sibling_is_rejected_before_traversal(self) -> None:
        forbidden = Path.home() / "source" / "pixeltje" / "never-inspect"
        with self.assertRaisesRegex(ContractError, "forbidden external source"):
            guarded_resolve(forbidden)

    def test_pipeline_path_guard_never_writes_forbidden_report(self) -> None:
        forbidden = Path.home() / "source" / "pixeltje" / "never-write.json"
        arguments = [
            "validate_pipeline.py",
            "--source",
            "/tmp/unused-source",
            "--publisher-reference",
            "/tmp/unused-publisher",
            "--prompt-encoder",
            "/tmp/unused-prompt.aimodel",
            "--denoiser",
            "/tmp/unused-denoiser.aimodel",
            "--vae-decoder",
            "/tmp/unused-decoder.aimodel",
            "--glue-test-log",
            "unused",
            "--report",
            str(forbidden),
        ]
        with mock.patch.object(sys, "argv", arguments), mock.patch.object(
            validate_pipeline, "write_atomic_new_json"
        ) as writer:
            self.assertNotEqual(validate_pipeline.main(), 0)
            writer.assert_not_called()

    def test_vae_path_guard_never_writes_forbidden_report(self) -> None:
        forbidden = Path.home() / "source" / "pixeltje" / "never-write.json"
        arguments = [
            "validate_vae_tiling.py",
            "vae-decoder",
            "--asset",
            "/tmp/unused.aimodel",
            "--source",
            "/tmp/unused-source",
            "--report",
            str(forbidden),
        ]
        with mock.patch.object(sys, "argv", arguments), mock.patch.object(
            validate_vae_tiling, "write_atomic_new_json"
        ) as writer:
            self.assertNotEqual(validate_vae_tiling.main(), 0)
            writer.assert_not_called()


if __name__ == "__main__":
    unittest.main()
