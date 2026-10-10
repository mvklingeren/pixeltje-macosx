import Foundation

/// Python sources for the classification task. Dataset bytes are fetched only
/// when the exported project is run, into the user's data directory.
enum ModelPythonClassification {
  static let trainingSource = #"""
  """Train an image classifier and measure accuracy on held-out examples."""
  import argparse
  import hashlib
  import json
  import os
  import urllib.request
  import uuid
  from pathlib import Path

  import numpy as np
  import torch
  from torch.utils.data import DataLoader, TensorDataset, random_split

  from model import GRAPH_SHA256, IMAGE_SHAPE, OUTPUT_SHAPE, build_model

  DATASET_PRESET = "DEFAULT_DATASET_PRESET"
  MNIST_URL = "https://storage.googleapis.com/tensorflow/tf-keras-datasets/mnist.npz"
  MNIST_SHA256 = "731c5ac602752760c8e48fbffcf8c3b850d9dc2a2aedcf2cc48468fc17b673d1"
  DEFAULT_CACHE = Path.home() / "Library/Application Support/Pixeltje/Datasets/MNIST/mnist.npz"


  def sha256(path: Path):
      digest = hashlib.sha256()
      with path.open("rb") as source:
          for chunk in iter(lambda: source.read(1024 * 1024), b""):
              digest.update(chunk)
      return digest.hexdigest()


  def ensure_mnist(path: Path):
      if path.exists():
          if sha256(path) != MNIST_SHA256:
              raise ValueError(f"MNIST cache hash mismatch at {path}; move the file and retry")
          return path
      path.parent.mkdir(parents=True, exist_ok=True)
      temporary = path.with_name(f".{path.name}.{uuid.uuid4().hex}.download")
      print(f"Downloading MNIST to {path}", flush=True)
      try:
          with urllib.request.urlopen(MNIST_URL, timeout=60) as response, temporary.open("wb") as output:
              count = 0
              while chunk := response.read(1024 * 1024):
                  count += len(chunk)
                  if count > 25 * 1024 * 1024:
                      raise ValueError("MNIST download exceeds the expected size")
                  output.write(chunk)
          if sha256(temporary) != MNIST_SHA256:
              raise ValueError("MNIST download hash did not match the published Keras source")
          os.replace(temporary, path)
      finally:
          temporary.unlink(missing_ok=True)
      return path


  def normalized_images(values, name: str, from_mnist: bool):
      values = np.asarray(values)
      if from_mnist:
          if values.ndim != 3 or values.shape[1:] != (28, 28) or values.dtype != np.uint8:
              raise ValueError(f"{name} must contain 28x28 uint8 MNIST images")
          values = values[:, None, :, :].astype(np.float32) / 255.0
      elif values.dtype != np.float32:
          raise ValueError(f"{name} must contain float32 images")
      if values.ndim != len(IMAGE_SHAPE) + 1 or tuple(values.shape[1:]) != IMAGE_SHAPE:
          raise ValueError(f"{name} must have trailing shape {IMAGE_SHAPE}")
      if len(values) == 0 or not np.isfinite(values).all() or values.min() < 0 or values.max() > 1:
          raise ValueError(f"{name} needs finite image values in [0, 1]")
      return torch.from_numpy(np.ascontiguousarray(values))


  def labels(values, count: int, name: str):
      values = np.asarray(values)
      if values.ndim != 1 or len(values) != count or not np.issubdtype(values.dtype, np.integer):
          raise ValueError(f"{name} must contain one integer label per image")
      if values.min() < 0 or values.max() >= OUTPUT_SHAPE[0]:
          raise ValueError(f"{name} labels must be in [0, {OUTPUT_SHAPE[0] - 1}]")
      return torch.from_numpy(np.ascontiguousarray(values.astype(np.int64)))


  def load_data(path: Path, from_mnist: bool):
      with np.load(path, allow_pickle=False) as arrays:
          if from_mnist:
              keys = ("x_train", "y_train", "x_test", "y_test")
          else:
              keys = ("inputs", "labels", "test_inputs", "test_labels")
          if any(key not in arrays for key in keys):
              raise ValueError(f"Classification NPZ needs {', '.join(keys)}")
          train_x = normalized_images(arrays[keys[0]], keys[0], from_mnist)
          train_y = labels(arrays[keys[1]], len(train_x), keys[1])
          test_x = normalized_images(arrays[keys[2]], keys[2], from_mnist)
          test_y = labels(arrays[keys[3]], len(test_x), keys[3])
      if len(train_x) < 5:
          raise ValueError("Classification needs at least five training examples")
      return TensorDataset(train_x, train_y), TensorDataset(test_x, test_y)


  def evaluate(model, loader, device):
      total_loss = 0.0
      correct = 0
      count = 0
      model.eval()
      with torch.no_grad():
          for images, expected in loader:
              images, expected = images.to(device), expected.to(device)
              logits = model(images)
              total_loss += float(torch.nn.functional.cross_entropy(logits, expected).cpu()) * len(images)
              correct += int((logits.argmax(dim=1) == expected).sum().cpu())
              count += len(images)
      return total_loss / count, correct / count


  def main():
      parser = argparse.ArgumentParser(description=__doc__)
      parser.add_argument("--data", type=Path, help="NPZ with inputs/labels and test_inputs/test_labels")
      parser.add_argument("--dataset-cache", type=Path, default=DEFAULT_CACHE)
      parser.add_argument("--output-dir", type=Path, required=True)
      parser.add_argument("--epochs", type=int, default=DEFAULT_EPOCHS)
      parser.add_argument("--batch-size", type=int, default=DEFAULT_BATCH_SIZE)
      parser.add_argument("--learning-rate", type=float, default=DEFAULT_LEARNING_RATE)
      parser.add_argument("--seed", type=int, default=DEFAULT_SEED)
      parser.add_argument("--resume", type=Path)
      args = parser.parse_args()
      if args.epochs < 1 or args.batch_size < 1 or args.learning_rate <= 0:
          parser.error("epochs, batch size, and learning rate must be positive")
      if len(OUTPUT_SHAPE) != 1 or OUTPUT_SHAPE[0] < 2:
          parser.error("The model output must be a vector of class scores")
      if args.data is None and DATASET_PRESET != "mnist":
          parser.error("Connect a classification dataset or select the MNIST preset")
      torch.manual_seed(args.seed)
      dataset = args.data if args.data is not None else ensure_mnist(args.dataset_cache)
      train_set, test_set = load_data(dataset, from_mnist=args.data is None)
      print(f"Using dataset at {dataset}", flush=True)
      validation_count = max(1, len(train_set) // 5)
      training_count = len(train_set) - validation_count
      train_set, validation_set = random_split(
          train_set, [training_count, validation_count],
          generator=torch.Generator().manual_seed(args.seed))
      loader = DataLoader(train_set, batch_size=args.batch_size, shuffle=True)
      validation_loader = DataLoader(validation_set, batch_size=args.batch_size)
      test_loader = DataLoader(test_set, batch_size=args.batch_size)
      device = torch.device("mps" if torch.backends.mps.is_available() else "cpu")
      model = build_model().to(device)
      optimizer = torch.optim.Adam(model.parameters(), lr=args.learning_rate)
      start_epoch = 0
      if args.resume:
          checkpoint = torch.load(args.resume, map_location="cpu", weights_only=True)
          if checkpoint["graph_sha256"] != GRAPH_SHA256 or checkpoint.get("task") != "classification":
              raise ValueError("Checkpoint belongs to another classifier")
          model.load_state_dict(checkpoint["model_state_dict"], strict=True)
          optimizer.load_state_dict(checkpoint["optimizer_state_dict"])
          start_epoch = int(checkpoint["epoch"])
      args.output_dir.mkdir(parents=True, exist_ok=True)
      for epoch in range(start_epoch, args.epochs):
          model.train()
          total_loss = 0.0
          for images, expected in loader:
              images, expected = images.to(device), expected.to(device)
              optimizer.zero_grad(set_to_none=True)
              loss = torch.nn.functional.cross_entropy(model(images), expected)
              loss.backward()
              optimizer.step()
              total_loss += float(loss.detach().cpu()) * len(images)
          validation_loss, validation_accuracy = evaluate(model, validation_loader, device)
          checkpoint = {"epoch": epoch + 1, "graph_sha256": GRAPH_SHA256,
                        "task": "classification", "model_state_dict": model.state_dict(),
                        "optimizer_state_dict": optimizer.state_dict(),
                        "validation_loss": validation_loss,
                        "validation_accuracy": validation_accuracy}
          temporary = args.output_dir / "checkpoint.tmp"
          torch.save(checkpoint, temporary)
          os.replace(temporary, args.output_dir / "checkpoint.pt")
          print(json.dumps({"kind": "epoch", "epoch": epoch + 1, "epochs": args.epochs,
                            "loss": total_loss / training_count,
                            "validation_loss": validation_loss,
                            "validation_accuracy": validation_accuracy,
                            "device": str(device)}), flush=True)
      test_loss, test_accuracy = evaluate(model, test_loader, device)
      metrics = {"task": "classification", "graph_sha256": GRAPH_SHA256,
                 "test_loss": test_loss, "test_accuracy": test_accuracy,
                 "test_examples": len(test_set)}
      temporary = args.output_dir / "metrics.tmp"
      temporary.write_text(json.dumps(metrics, indent=2) + "\n", encoding="utf-8")
      os.replace(temporary, args.output_dir / "metrics.json")
      print(json.dumps({"kind": "test", **metrics}), flush=True)


  if __name__ == "__main__":
      main()
  """#

  static let readmeSource = #"""
  # Pixeltje Pipeline image classification

  This is a standalone Python training project exported from
  `workflow.pixpipeline.json`. The model predicts class scores. Training uses
  cross-entropy, reports validation accuracy each epoch, and evaluates the
  untouched test set at the end.

  The MNIST preset downloads the official Keras `mnist.npz` to
  `~/Library/Application Support/Pixeltje/Datasets/MNIST/mnist.npz` on first
  use. It verifies the published SHA-256 before using the data. The dataset is
  never written into this project or the Pixeltje source repository. MNIST is
  provided under CC BY-SA 3.0 by Yann LeCun and Corinna Cortes:
  https://keras.io/api/datasets/mnist/

  Alternatively, pass `--data /path/to/classification.npz` containing float32 NCHW
  `inputs` and `test_inputs` arrays in `[0, 1]`, plus integer `labels` and
  `test_labels` vectors. The output width determines the number of classes.

  ```sh
  python model.py
  python train.py --output-dir ./run
  python export_coreai.py --checkpoint ./run/checkpoint.pt --output ./trained.aimodel
  ```

  The run directory contains `checkpoint.pt` and `metrics.json`. Core AI
  export verifies the converted model against PyTorch on a fixed input.
  """#
}
