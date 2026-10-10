#!/usr/bin/env python3
"""Run a Core AI validator while preserving crash/abort evidence as strict JSON."""

from __future__ import annotations

import argparse
import importlib.metadata
import json
import os
import platform
import resource
import signal
import subprocess
import sys
import tempfile
import time
from contextlib import ExitStack
from datetime import UTC, datetime
from pathlib import Path
from typing import Any, Callable, Sequence, TypeVar

from pixaimodel import (
    ContractError,
    HERE,
    canonical_json_bytes,
    guarded_resolve,
    outside_checkout,
    sha256_file,
    sha256_tree,
)


DEFAULT_TIMEOUT_SECONDS = 60 * 60
TERMINATION_GRACE_SECONDS = 10.0
_T = TypeVar("_T")


def _is_within(path: Path, root: Path) -> bool:
    return path == root or root in path.parents


def validate_evidence_paths(asset: Path, paths: dict[str, Path]) -> None:
    items = list(paths.items())
    for name, path in items:
        if _is_within(path, asset):
            raise ContractError(f"{name} must stay outside the Core AI asset: {path}")
    for index, (left_name, left) in enumerate(items):
        for right_name, right in items[index + 1 :]:
            if left == right or _is_within(left, right) or _is_within(right, left):
                raise ContractError(
                    "evidence paths must be distinct and non-nested: "
                    f"{left_name}={left}, {right_name}={right}"
                )


def positive_seconds(value: str) -> float:
    try:
        parsed = float(value)
    except ValueError as error:
        raise argparse.ArgumentTypeError("must be a number") from error
    if not 0.0 < parsed < float("inf"):
        raise argparse.ArgumentTypeError("must be finite and greater than zero")
    return parsed


def file_record(path: Path) -> dict[str, Any]:
    if path.is_symlink():
        raise ContractError(f"evidence file must not be a symlink: {path}")
    if not path.is_file():
        raise ContractError(f"evidence file is missing or not regular: {path}")
    return {
        "path": str(path),
        "size": path.stat().st_size,
        "sha256": sha256_file(path),
    }


def _fsync_directory(path: Path) -> None:
    flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0)
    descriptor = os.open(path, flags)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def prepare_atomic_new_json(path: Path, label: str = "report") -> Path:
    """Preflight a no-replace JSON destination before expensive work."""

    if path.is_symlink() or path.exists():
        raise ContractError(f"refusing to replace existing {label}: {path}")
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.parent.is_symlink() or not path.parent.is_dir():
        raise ContractError(f"{label} parent is not a real directory: {path.parent}")
    return path


def write_atomic_new_json(path: Path, value: Any) -> None:
    """Durably publish strict JSON without replacing existing evidence."""

    if path.is_symlink() or path.exists():
        raise ContractError(f"refusing to replace existing report: {path}")
    payload = canonical_json_bytes(value)
    descriptor, temporary_name = tempfile.mkstemp(
        dir=path.parent,
        prefix=f".{path.name}.",
        suffix=".tmp",
    )
    temporary = Path(temporary_name)
    descriptor_open = True
    try:
        with os.fdopen(descriptor, "wb") as handle:
            descriptor_open = False
            handle.write(payload)
            handle.flush()
            os.fsync(handle.fileno())
        # Linking a same-directory temporary file publishes it atomically and,
        # unlike os.replace(), cannot overwrite evidence created after preflight.
        try:
            os.link(temporary, path)
        except FileExistsError as error:
            raise ContractError(f"refusing to replace existing report: {path}") from error
        temporary.unlink()
        _fsync_directory(path.parent)
    finally:
        if descriptor_open:
            os.close(descriptor)
        try:
            temporary.unlink()
        except FileNotFoundError:
            pass


def _reject_json_constant(value: str) -> None:
    raise ContractError(f"non-finite JSON constant is forbidden: {value}")


def _reject_duplicate_keys(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise ContractError(f"duplicate JSON key: {key!r}")
        result[key] = value
    return result


def load_strict_child_report(path: Path) -> dict[str, Any]:
    if path.is_symlink():
        raise ContractError(f"child report must not be a symlink: {path}")
    try:
        text = path.read_text(encoding="utf-8")
        value = json.loads(
            text,
            object_pairs_hook=_reject_duplicate_keys,
            parse_constant=_reject_json_constant,
        )
    except ContractError:
        raise
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise ContractError(f"cannot read strict child JSON {path}: {error}") from error
    if not isinstance(value, dict):
        raise ContractError("child report must be a JSON object")
    return value


def validate_child_report(
    report: dict[str, Any],
    *,
    asset: Path,
    asset_digest: str,
    source_lock_digest: str,
    expected_component: str,
    expected_compute_policy: str,
) -> None:
    expected = {
        "schemaVersion": "1.0.0",
        "component": expected_component,
        "assetDigestAlgorithm": "sha256-tree-v1",
        "assetDigest": asset_digest,
        "computePolicy": expected_compute_policy,
        "sourceLockSHA256": source_lock_digest,
    }
    for key, expected_value in expected.items():
        if report.get(key) != expected_value:
            raise ContractError(
                f"child report {key} mismatch: expected {expected_value!r}, "
                f"found {report.get(key)!r}"
            )
    if report.get("asset") not in {asset.name, str(asset)}:
        raise ContractError(
            f"child report asset mismatch: expected {asset.name!r} or {str(asset)!r}, "
            f"found {report.get('asset')!r}"
        )
    status = report.get("status")
    if status not in {"passed", "failed"}:
        raise ContractError(f"invalid child report status: {status!r}")
    results = report.get("results")
    if not isinstance(results, list) or not results:
        raise ContractError("child report must contain at least one result")
    result_statuses = [
        item.get("status") if isinstance(item, dict) else None for item in results
    ]
    if any(item not in {"passed", "failed"} for item in result_statuses):
        raise ContractError("every child result must have passed or failed status")
    if status == "passed" and any(item != "passed" for item in result_statuses):
        raise ContractError("a passed child report contains a failed result")


def system_record() -> dict[str, Any]:
    """Collect versions without importing Torch or the Core AI conversion stack."""

    try:
        macos = subprocess.run(
            ["sw_vers", "-productVersion"],
            check=True,
            capture_output=True,
            text=True,
            timeout=10,
        ).stdout.strip()
        build = subprocess.run(
            ["sw_vers", "-buildVersion"],
            check=True,
            capture_output=True,
            text=True,
            timeout=10,
        ).stdout.strip()
    except (OSError, subprocess.CalledProcessError, subprocess.TimeoutExpired):
        macos, build = platform.mac_ver()[0] or "unknown", "unknown"
    packages: dict[str, str | None] = {}
    for name in (
        "coreai-core",
        "coreai-torch",
        "diffusers",
        "numpy",
        "safetensors",
        "torch",
        "torchao",
        "transformers",
    ):
        try:
            packages[name] = importlib.metadata.version(name)
        except importlib.metadata.PackageNotFoundError:
            packages[name] = None
    return {
        "macOS": macos,
        "build": build,
        "machine": platform.machine(),
        "python": platform.python_version(),
        "packages": packages,
    }


def _error_record(stage: str, error: BaseException) -> dict[str, str]:
    return {
        "stage": stage,
        "type": type(error).__name__,
        "message": str(error),
    }


def _record_error(report: dict[str, Any], stage: str, error: BaseException) -> None:
    report["errors"].append(_error_record(stage, error))


def _capture(
    report: dict[str, Any],
    key: str,
    stage: str,
    operation: Callable[[], _T],
) -> _T | None:
    try:
        value = operation()
    except Exception as error:  # The failure belongs in the durable envelope.
        _record_error(report, stage, error)
        report[key] = None
        return None
    report[key] = value
    return value


def _peak_child_resident_bytes() -> int:
    value = int(resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss)
    # Darwin reports bytes; Linux reports KiB. Keep the serialized ABI honest
    # when the offline tests happen to run on a non-Darwin host.
    return value * 1024 if sys.platform.startswith("linux") else value


def _signal_name(return_code: int | None) -> str | None:
    if return_code is None or return_code >= 0:
        return None
    try:
        return signal.Signals(-return_code).name
    except ValueError:
        return f"UNKNOWN_{-return_code}"


def _signal_process_group(process: subprocess.Popen[bytes], signal_number: int) -> None:
    if os.name == "posix":
        try:
            os.killpg(process.pid, signal_number)
        except ProcessLookupError:
            pass
    elif signal_number == signal.SIGTERM:
        process.terminate()
    else:
        process.kill()


def _wait_bounded(
    process: subprocess.Popen[bytes],
    *,
    timeout_seconds: float,
    report: dict[str, Any],
) -> int:
    try:
        return process.wait(timeout=timeout_seconds)
    except subprocess.TimeoutExpired as error:
        report["timedOut"] = True
        _record_error(report, "child-timeout", error)
        _signal_process_group(process, signal.SIGTERM)
        report["timeoutTermination"] = "SIGTERM"
        try:
            return process.wait(timeout=TERMINATION_GRACE_SECONDS)
        except subprocess.TimeoutExpired:
            _signal_process_group(process, signal.SIGKILL)
            report["timeoutTermination"] = "SIGKILL"
            return process.wait()


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--asset", required=True)
    parser.add_argument("--child-report", required=True)
    parser.add_argument("--stdout-log", required=True)
    parser.add_argument("--stderr-log", required=True)
    parser.add_argument("--report", required=True)
    parser.add_argument(
        "--timeout-seconds",
        type=positive_seconds,
        default=float(DEFAULT_TIMEOUT_SECONDS),
    )
    parser.add_argument("--expected-component", default="denoiser")
    parser.add_argument("command", nargs=argparse.REMAINDER)
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    command = list(args.command)
    if command[:1] == ["--"]:
        command = command[1:]
    if not command:
        raise SystemExit("error: missing child command after --")

    try:
        asset = guarded_resolve(Path(args.asset))
        if not asset.is_dir() or asset.suffix != ".aimodel":
            raise ContractError(f"invalid Core AI asset: {asset}")
        evidence_paths = {
            "report": outside_checkout(Path(args.report)),
            "child-report": outside_checkout(Path(args.child_report)),
            "stdout-log": outside_checkout(Path(args.stdout_log)),
            "stderr-log": outside_checkout(Path(args.stderr_log)),
        }
        validate_evidence_paths(asset, evidence_paths)
        for name, path in evidence_paths.items():
            if path.exists():
                raise ContractError(f"refusing to replace existing {name}: {path}")
        for parent in {path.parent for path in evidence_paths.values()}:
            parent.mkdir(parents=True, exist_ok=True)
    except (ContractError, OSError) as error:
        raise SystemExit(f"error: {error}") from error

    report_path = evidence_paths["report"]
    child_report_path = evidence_paths["child-report"]
    stdout_path = evidence_paths["stdout-log"]
    stderr_path = evidence_paths["stderr-log"]
    started_utc = datetime.now(UTC).isoformat()
    started = time.perf_counter()
    expected_compute_policy = os.environ.get(
        "PIXELTJE_COREAI_COMPUTE", "gpu-preferred"
    )
    report: dict[str, Any] = {
        "schemaVersion": "1.0.0",
        "diagnostic": "core-ai-validation-subprocess",
        "status": "failed",
        "command": command,
        "environment": {
            name: os.environ.get(name)
            for name in (
                "PIXELTJE_COREAI_COMPUTE",
                "PYTHONPATH",
                "PYTHONPYCACHEPREFIX",
            )
        },
        "effectiveCoreAIComputePolicy": expected_compute_policy,
        "expectedComponent": args.expected_component,
        "timeoutSeconds": args.timeout_seconds,
        "timeoutTermination": None,
        "timedOut": False,
        "returnCode": None,
        "terminatingSignal": None,
        "startedUTC": started_utc,
        "finishedUTC": None,
        "elapsedSeconds": None,
        "childElapsedSeconds": None,
        "peakChildResidentBytes": None,
        "peakChildResidentScope": (
            "waited subprocess tree; excludes external Core AI and ANE services"
        ),
        "asset": str(asset),
        "assetDigestAlgorithm": "sha256-tree-v1",
        "assetDigest": None,
        "assetDigestBefore": None,
        "assetDigestAfter": None,
        "assetUnchanged": None,
        "childReport": None,
        "childReportValid": False,
        "childStatus": None,
        "stdout": {"path": str(stdout_path)},
        "stderr": {"path": str(stderr_path)},
        "system": None,
        "sourceLockSHA256": None,
        "toolSHA256": None,
        "errors": [],
    }

    source_lock_digest = _capture(
        report,
        "sourceLockSHA256",
        "source-lock-hash",
        lambda: sha256_file(HERE / "source-lock.json"),
    )
    digest_started = time.perf_counter()
    asset_digest_before = _capture(
        report,
        "assetDigestBefore",
        "asset-digest-before",
        lambda: sha256_tree(asset),
    )
    report["assetDigestBeforeSeconds"] = time.perf_counter() - digest_started
    report["assetDigest"] = asset_digest_before

    launched = False
    if source_lock_digest is not None and asset_digest_before is not None:
        try:
            with ExitStack() as stack:
                stdout = stack.enter_context(stdout_path.open("xb"))
                stderr = stack.enter_context(stderr_path.open("xb"))
                child_started = time.perf_counter()
                try:
                    process = subprocess.Popen(
                        command,
                        stdin=subprocess.DEVNULL,
                        stdout=stdout,
                        stderr=stderr,
                        env=os.environ.copy(),
                        start_new_session=os.name == "posix",
                    )
                except OSError as error:
                    _record_error(report, "child-launch", error)
                else:
                    launched = True
                    try:
                        report["returnCode"] = _wait_bounded(
                            process,
                            timeout_seconds=args.timeout_seconds,
                            report=report,
                        )
                    except OSError as error:
                        _record_error(report, "child-wait", error)
                        _signal_process_group(process, signal.SIGKILL)
                        report["returnCode"] = process.wait()
                    report["childElapsedSeconds"] = time.perf_counter() - child_started
        except OSError as error:
            _record_error(report, "evidence-log-open", error)

    report["terminatingSignal"] = _signal_name(report["returnCode"])
    if report["returnCode"] not in {None, 0}:
        _record_error(
            report,
            "child-exit",
            ContractError(f"child exited with status {report['returnCode']}"),
        )

    # Capture child usage before system_record() starts its own version probes.
    _capture(
        report,
        "peakChildResidentBytes",
        "child-resource-usage",
        _peak_child_resident_bytes,
    )

    if child_report_path.exists():
        child_record = _capture(
            report,
            "childReport",
            "child-report-record",
            lambda: file_record(child_report_path),
        )
        child_report: dict[str, Any] | None = None
        if child_record is not None:
            child_report = _capture(
                report,
                "_childReportValue",
                "child-report-parse",
                lambda: load_strict_child_report(child_report_path),
            )
        if child_report is not None:
            report.pop("_childReportValue", None)
            report["childStatus"] = child_report.get("status")
            try:
                assert asset_digest_before is not None
                assert source_lock_digest is not None
                validate_child_report(
                    child_report,
                    asset=asset,
                    asset_digest=asset_digest_before,
                    source_lock_digest=source_lock_digest,
                    expected_component=args.expected_component,
                    expected_compute_policy=expected_compute_policy,
                )
            except (AssertionError, ContractError) as error:
                _record_error(report, "child-report-validation", error)
            else:
                report["childReportValid"] = True
    elif launched:
        _record_error(
            report,
            "child-report-missing",
            ContractError(f"child did not create its report: {child_report_path}"),
        )

    digest_started = time.perf_counter()
    asset_digest_after = _capture(
        report,
        "assetDigestAfter",
        "asset-digest-after",
        lambda: sha256_tree(asset),
    )
    report["assetDigestAfterSeconds"] = time.perf_counter() - digest_started
    if asset_digest_before is not None and asset_digest_after is not None:
        report["assetUnchanged"] = asset_digest_before == asset_digest_after
        if not report["assetUnchanged"]:
            _record_error(
                report,
                "asset-mutated",
                ContractError("Core AI asset digest changed during validation"),
            )

    for key, path in (("stdout", stdout_path), ("stderr", stderr_path)):
        if path.exists():
            _capture(report, key, f"{key}-record", lambda path=path: file_record(path))

    _capture(report, "system", "system-record", system_record)
    _capture(
        report,
        "toolSHA256",
        "tool-hash",
        lambda: sha256_file(Path(__file__).resolve()),
    )

    child_passed = (
        report["returnCode"] == 0
        and not report["timedOut"]
        and report["childReportValid"]
        and report["childStatus"] == "passed"
        and report["assetUnchanged"] is True
        and not report["errors"]
    )
    report["status"] = "passed" if child_passed else "failed"
    report["finishedUTC"] = datetime.now(UTC).isoformat()
    report["elapsedSeconds"] = time.perf_counter() - started
    write_atomic_new_json(report_path, report)
    print(json.dumps(report, allow_nan=False, indent=2, sort_keys=True))
    return 0 if child_passed else 1


if __name__ == "__main__":
    raise SystemExit(main())
