#!/usr/bin/env python3
"""Compare the reviewed 4B Distilled Pixel Pipeline graph with local ComfyUI."""

import argparse
import hashlib
import json
import platform
import statistics
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
PROMPT = (
    "A hedgehog wearing a tiny party hat surrounded by confetti, "
    "early digital camera style, slight noise, flash photography, "
    "candid moment, 2000s digicam aesthetic, festive birthday celebration atmosphere"
)


def request_json(url, payload=None):
    body = None if payload is None else json.dumps(payload).encode("utf-8")
    request = urllib.request.Request(
        url, data=body, headers={"Content-Type": "application/json"}
    )
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            return json.load(response)
    except urllib.error.HTTPError as error:
        raise RuntimeError(f"{url}: HTTP {error.code}: {error.read().decode()}") from error


def distilled_workflow(path, prompt):
    workflow = json.loads(path.read_text())
    expected = {
        "75:70": ("UNETLoader", "unet_name", "flux-2-klein-9b-fp8.safetensors"),
        "75:71": ("CLIPLoader", "clip_name", "qwen_3_8b_fp8mixed.safetensors"),
        "75:72": ("VAELoader", "vae_name", "flux2-vae.safetensors"),
        "75:76": ("ConditioningZeroOut", None, None),
        "75:62": ("Flux2Scheduler", "steps", 4),
        "75:63": ("CFGGuider", "cfg", 1),
    }
    for node_id, (node_type, field, value) in expected.items():
        node = workflow.get(node_id, {})
        if node.get("class_type") != node_type or (
            field is not None and node.get("inputs", {}).get(field) != value
        ):
            raise RuntimeError(f"Unexpected Distilled template at node {node_id}")
    if workflow["75:63"]["inputs"]["negative"] != ["75:76", 0]:
        raise RuntimeError("Distilled negative-conditioning branch changed")
    workflow["75:70"]["inputs"]["unet_name"] = "flux-2-klein-4b.safetensors"
    workflow["75:71"]["inputs"]["clip_name"] = "qwen_3_4b.safetensors"
    workflow["76"]["inputs"]["value"] = prompt
    workflow["9"]["inputs"]["filename_prefix"] = "pixeltje-klein-benchmark"
    return workflow


def run_pipeline(args, output_dir):
    command = [
        str(args.pipeline_executable),
        str(args.pipeline),
        str(args.package),
        args.prompt,
        str(args.seed),
        str(args.runs),
        str(output_dir),
    ]
    print("Running Pixel Pipeline…", flush=True)
    result = subprocess.run(command, text=True, capture_output=True)
    if result.returncode:
        raise RuntimeError(
            f"Pixel Pipeline exited {result.returncode}:\n{result.stdout}\n{result.stderr}"
        )
    records = []
    for line in result.stdout.splitlines():
        try:
            item = json.loads(line)
        except json.JSONDecodeError:
            print(line, flush=True)
            continue
        if item.get("runtime") == "pixel_pipeline":
            records.append(item)
            print(f"  run {item['run']}: {item['seconds']:.2f}s", flush=True)
    if len(records) != args.runs:
        raise RuntimeError(f"Expected {args.runs} Pixel Pipeline records, got {len(records)}")
    return records


def run_comfy(args, workflow, output_dir):
    base = args.comfy_url.rstrip("/")
    queue = request_json(base + "/queue")
    if queue.get("queue_running") or queue.get("queue_pending"):
        raise RuntimeError("ComfyUI has other queued/running jobs; benchmark would be confounded")
    records = []
    for index in range(args.runs):
        print(f"Running ComfyUI {index + 1}/{args.runs}…", flush=True)
        run_seed = args.seed + index
        workflow["75:73"]["inputs"]["noise_seed"] = run_seed
        start = time.perf_counter()
        response = request_json(base + "/prompt", {
            "prompt": workflow,
            "client_id": "pixeltje-klein-benchmark",
        })
        prompt_id = response.get("prompt_id")
        if not prompt_id:
            raise RuntimeError(f"ComfyUI rejected the workflow: {response}")
        deadline = time.monotonic() + args.timeout
        while True:
            history = request_json(base + "/history/" + urllib.parse.quote(prompt_id))
            item = history.get(prompt_id)
            if item:
                status = item.get("status", {})
                if status.get("status_str") != "success" or not status.get("completed"):
                    raise RuntimeError(f"ComfyUI job {prompt_id} failed: {status}")
                break
            if time.monotonic() >= deadline:
                raise TimeoutError(f"ComfyUI job {prompt_id} exceeded {args.timeout}s")
            time.sleep(0.25)
        seconds = time.perf_counter() - start
        images = item.get("outputs", {}).get("9", {}).get("images", [])
        if len(images) != 1:
            raise RuntimeError(f"ComfyUI job {prompt_id} returned {len(images)} images")
        image = images[0]
        query = urllib.parse.urlencode({
            "filename": image["filename"],
            "subfolder": image.get("subfolder", ""),
            "type": image.get("type", "output"),
        })
        with urllib.request.urlopen(base + "/view?" + query, timeout=60) as response:
            pixels = response.read()
        file = output_dir / f"comfy-{index + 1}.png"
        file.write_bytes(pixels)
        record = {
            "runtime": "comfyui",
            "run": index + 1,
            "seed": run_seed,
            "seconds": seconds,
            "promptID": prompt_id,
            "output": str(file),
            "pngSHA256": hashlib.sha256(pixels).hexdigest(),
        }
        records.append(record)
        print(f"  run {index + 1}: {seconds:.2f}s", flush=True)
    return records


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--runs", type=int, default=3)
    parser.add_argument("--seed", type=int, default=42)
    parser.add_argument("--prompt", default=PROMPT)
    parser.add_argument("--timeout", type=int, default=1800)
    parser.add_argument("--comfy-url", default="http://127.0.0.1:8188")
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument(
        "--pipeline-executable", type=Path,
        default=ROOT / ".build/debug/pixeltje-pipeline-benchmark")
    parser.add_argument(
        "--pipeline", type=Path,
        default=ROOT / "Examples/image_flux2_klein_text_to_image_4b_distilled-coreai.pixpipeline.json")
    parser.add_argument(
        "--package", type=Path,
        default=Path.home() / "coreai-models/exports/FLUX.2-klein-4B")
    parser.add_argument(
        "--comfy-template", type=Path,
        default=ROOT / "Sources/PixeltjeMacKit/Resources/ComfyUI/image_flux2_klein_text_to_image_9b_distilled_api.json")
    args = parser.parse_args()
    if args.runs < 2 or not (0 <= args.seed <= 0xFFFFFFFF - args.runs + 1):
        parser.error("--runs must be at least 2 and all seeds must fit in UInt32")
    args.output_dir.mkdir(parents=True, exist_ok=True)
    workflow = distilled_workflow(args.comfy_template, args.prompt)
    workflow["75:73"]["inputs"]["noise_seed"] = args.seed
    workflow_bytes = json.dumps(workflow, sort_keys=True).encode("utf-8")
    (args.output_dir / "comfy-workflow.json").write_bytes(workflow_bytes)
    stats = request_json(args.comfy_url.rstrip("/") + "/system_stats")
    pipeline = run_pipeline(args, args.output_dir)
    comfy = run_comfy(args, workflow, args.output_dir)
    report = {
        "method": "same FLUX.2 Klein 4B Distilled family, 1024x1024, 4 steps, guidance 1, Euler; matched seeds increment each run to defeat ComfyUI output caching; first run is the initial invocation in a fresh benchmark process/server, later runs are repeats; wall time excludes client-side output PNG writing/retrieval",
        "prompt": args.prompt,
        "seed": args.seed,
        "host": platform.platform(),
        "comfySystem": stats.get("system"),
        "comfyDevices": stats.get("devices"),
        "comfyWorkflowSHA256": hashlib.sha256(workflow_bytes).hexdigest(),
        "pipeline": pipeline,
        "comfyui": comfy,
        "warmMedianSeconds": {
            "pixel_pipeline": statistics.median(x["seconds"] for x in pipeline[1:]),
            "comfyui": statistics.median(x["seconds"] for x in comfy[1:]),
        },
    }
    report_path = args.output_dir / "report.json"
    report_path.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    print(f"Report: {report_path}")
    print(
        "Warm median Pixel Pipeline / ComfyUI: "
        f"{report['warmMedianSeconds']['pixel_pipeline']:.2f}s / "
        f"{report['warmMedianSeconds']['comfyui']:.2f}s"
    )


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print(f"Benchmark failed: {error}", file=sys.stderr)
        sys.exit(1)
