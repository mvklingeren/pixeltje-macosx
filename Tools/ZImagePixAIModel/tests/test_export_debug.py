from __future__ import annotations

import contextlib
import io
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import export_components  # noqa: E402
from pixaimodel import ContractError  # noqa: E402


class DebugExportTests(unittest.TestCase):
    def arguments(self, component: str = "denoiser") -> list[str]:
        return [
            component,
            "--source",
            "/tmp/publisher",
            "--output",
            "/tmp/probe.aimodel",
        ]

    def test_release_remains_default(self) -> None:
        with mock.patch.object(export_components, "export_component") as export:
            status = export_components.main(self.arguments())

        self.assertEqual(status, 0)
        export.assert_called_once()
        self.assertFalse(export.call_args.args[0].debug_export)

    def test_converter_mode_selects_release_or_debug_exactly(self) -> None:
        fake_coreai_torch = mock.Mock()
        fake_coreai_torch.TorchConverter.Mode.RELEASE = object()
        fake_coreai_torch.TorchConverter.Mode.DEBUG = object()

        self.assertIs(
            export_components._converter_mode(fake_coreai_torch, False),
            fake_coreai_torch.TorchConverter.Mode.RELEASE,
        )
        self.assertIs(
            export_components._converter_mode(fake_coreai_torch, True),
            fake_coreai_torch.TorchConverter.Mode.DEBUG,
        )

    def test_profiler_metadata_is_unambiguously_tiny_and_debug(self) -> None:
        metadata = export_components.profiler_probe_metadata("bfloat16")

        self.assertEqual(metadata["component"], "denoiser")
        self.assertEqual(metadata["variant"], "tiny-probe")
        self.assertTrue(metadata["probe"])
        self.assertEqual(metadata["converterMode"], "debug")
        self.assertEqual(metadata["precision"], "bfloat16")
        self.assertEqual(metadata["promptWidth"], 64)
        self.assertEqual(metadata["promptBucket"], 64)

    def test_debug_export_is_accepted_for_denoiser_probe(self) -> None:
        arguments = self.arguments() + ["--probe", "--debug-export"]
        with mock.patch.object(export_components, "export_component") as export:
            status = export_components.main(arguments)

        self.assertEqual(status, 0)
        export.assert_called_once()
        options = export.call_args.args[0]
        self.assertTrue(options.probe)
        self.assertTrue(options.debug_export)

    def test_debug_export_is_rejected_without_probe(self) -> None:
        standard_error = io.StringIO()
        with (
            mock.patch.object(export_components, "export_component") as export,
            contextlib.redirect_stderr(standard_error),
        ):
            status = export_components.main(self.arguments() + ["--debug-export"])

        self.assertEqual(status, 2)
        export.assert_not_called()
        self.assertIn("requires denoiser --probe", standard_error.getvalue())

    def test_debug_export_is_rejected_for_other_components(self) -> None:
        standard_error = io.StringIO()
        with (
            mock.patch.object(export_components, "export_component") as export,
            contextlib.redirect_stderr(standard_error),
        ):
            status = export_components.main(
                self.arguments("vae-decoder") + ["--debug-export"]
            )

        self.assertEqual(status, 2)
        export.assert_not_called()

    def test_direct_debug_full_denoiser_export_is_rejected_before_import(self) -> None:
        with self.assertRaisesRegex(ContractError, "restricted to the tiny"):
            export_components.export_denoiser(
                mock.Mock(), "bfloat16", probe=False, debug_export=True
            )

    def test_existing_export_report_is_never_replaced(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            report = root / "preserved.json"
            report.write_text("preserved", encoding="utf-8")
            options = mock.Mock(
                source=str(root / "publisher"),
                output=str(root / "new.aimodel"),
                report=str(report),
                debug_export=False,
                component="denoiser",
                probe=True,
            )

            with self.assertRaisesRegex(ContractError, "existing report"):
                export_components.export_component(options)
            self.assertEqual(report.read_text(encoding="utf-8"), "preserved")

    def test_export_report_cannot_be_written_inside_asset(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            output = root / "new.aimodel"
            options = mock.Mock(
                source=str(root / "publisher"),
                output=str(output),
                report=str(output / "metadata.json"),
                debug_export=False,
                component="denoiser",
                probe=True,
            )

            with self.assertRaisesRegex(ContractError, "outside the model artifact"):
                export_components.export_component(options)
            self.assertFalse(output.exists())

    def test_debug_asset_cannot_be_written_inside_git(self) -> None:
        output = Path(export_components.HERE).parent.parent / "never.aimodel"
        options = mock.Mock(
            source="/tmp/publisher",
            output=str(output),
            report=None,
            debug_export=True,
            component="denoiser",
            probe=True,
        )

        with self.assertRaisesRegex(ContractError, "outside Git"):
            export_components.export_component(options)
        self.assertFalse(output.exists())


if __name__ == "__main__":
    unittest.main()
