#!/usr/bin/env python3
"""Batch audio transcription using OpenVINO GenAI on an Intel GPU."""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import time
from pathlib import Path
from typing import Any

import numpy as np
import openvino as ov
import openvino_genai as ov_genai


ROOT = Path(__file__).resolve().parent
MODEL_ALIASES = {
    "tiny": "openai/whisper-tiny",
    "base": "openai/whisper-base",
    "small": "openai/whisper-small",
    "medium": "openai/whisper-medium",
    "large": "openai/whisper-large-v3",
    "large-v3": "openai/whisper-large-v3",
}
AUDIO_SUFFIXES = {".wav", ".mp3", ".m4a", ".flac", ".ogg", ".opus", ".aac"}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input", nargs="?", default=".", type=Path, help="audio directory")
    parser.add_argument("model", nargs="?", default="medium", help="Whisper size, HF model ID, or converted model directory")
    parser.add_argument("output", nargs="?", default=Path("transcripts-openvino"), type=Path)
    parser.add_argument("--language", default="ru", help="Whisper language code, or 'auto'")
    parser.add_argument("--device", default="GPU", choices=("GPU", "AUTO", "CPU"))
    parser.add_argument("--model-dir", type=Path, default=ROOT / ".openvino_models")
    parser.add_argument("--offline", action="store_true", help="never download/convert a missing model")
    parser.add_argument("--check", action="store_true", help="show OpenVINO devices and exit")
    return parser.parse_args()


def available_devices() -> list[str]:
    return ov.Core().available_devices


def require_device(device: str) -> None:
    devices = available_devices()
    print(f"OpenVINO devices: {', '.join(devices) or 'none'}")
    if device == "GPU" and not any(item == "GPU" or item.startswith("GPU.") for item in devices):
        raise RuntimeError("Intel GPU is not available to OpenVINO. Run ./whisper_openvino_setup.sh first.")


def model_location(model: str, model_root: Path) -> Path:
    supplied = Path(model).expanduser()
    if supplied.is_dir():
        return supplied.resolve()
    model_id = MODEL_ALIASES.get(model, model)
    return model_root / model_id.replace("/", "--")


def ensure_model(model: str, model_root: Path, offline: bool) -> Path:
    destination = model_location(model, model_root)
    if destination.is_dir() and any(destination.glob("*.xml")):
        return destination
    if Path(model).expanduser().exists():
        raise RuntimeError(f"Converted OpenVINO model is incomplete: {destination}")
    if offline:
        raise RuntimeError(f"Model is not cached: {destination}")

    model_id = MODEL_ALIASES.get(model, model)
    destination.parent.mkdir(parents=True, exist_ok=True)
    cache = ROOT / ".cache" / "huggingface"
    cache.mkdir(parents=True, exist_ok=True)
    env = os.environ.copy()
    env.update({"HF_HOME": str(cache), "HUGGINGFACE_HUB_CACHE": str(cache / "hub")})
    print(f"Downloading and converting {model_id} to {destination} (first run only)...")
    optimum_cli = Path(sys.executable).with_name("optimum-cli")
    subprocess.run(
        [str(optimum_cli), "export", "openvino",
         "--model", model_id, "--task", "automatic-speech-recognition-with-past", str(destination)],
        check=True,
        env=env,
    )
    return destination


def audio_files(directory: Path) -> list[Path]:
    if not directory.is_dir():
        raise RuntimeError(f"Input directory does not exist: {directory}")
    return sorted(path for path in directory.iterdir() if path.is_file() and path.suffix.lower() in AUDIO_SUFFIXES)


def decode_audio(path: Path) -> np.ndarray:
    """Decode with ffmpeg to the 16 kHz mono float waveform Whisper expects."""
    try:
        process = subprocess.run(
            ["ffmpeg", "-v", "error", "-i", str(path), "-f", "f32le", "-acodec", "pcm_f32le", "-ac", "1", "-ar", "16000", "-"],
            check=True,
            stdout=subprocess.PIPE,
        )
    except FileNotFoundError as exc:
        raise RuntimeError("ffmpeg is not installed. Run ./whisper_openvino_setup.sh.") from exc
    except subprocess.CalledProcessError as exc:
        raise RuntimeError(f"ffmpeg could not decode {path}") from exc
    return np.frombuffer(process.stdout, dtype=np.float32).copy()


def result_text(result: Any) -> str:
    texts = getattr(result, "texts", None)
    return str(texts[0] if texts else result).strip()


def result_segments(result: Any) -> list[dict[str, Any]]:
    groups = getattr(result, "chunks", None)
    if not groups:
        return []
    chunks = groups[0] if isinstance(groups[0], (list, tuple)) else groups
    return [{"start": float(c.start_ts), "end": float(c.end_ts), "text": c.text.strip()} for c in chunks]


def timestamp(seconds: float) -> str:
    milliseconds = round(seconds * 1000)
    hours, milliseconds = divmod(milliseconds, 3_600_000)
    minutes, milliseconds = divmod(milliseconds, 60_000)
    secs, milliseconds = divmod(milliseconds, 1000)
    return f"{hours:02d}:{minutes:02d}:{secs:02d},{milliseconds:03d}"


def save_result(result: dict[str, Any], output: Path) -> None:
    output.mkdir(parents=True, exist_ok=True)
    stem = Path(result["file"]).stem
    (output / f"{stem}.txt").write_text(result["text"], encoding="utf-8")
    with (output / f"{stem}.srt").open("w", encoding="utf-8") as stream:
        for index, segment in enumerate(result["segments"], 1):
            stream.write(f'{index}\n{timestamp(segment["start"])} --> {timestamp(segment["end"])}\n{segment["text"]}\n\n')
    with (output / "all_transcripts.txt").open("a", encoding="utf-8") as stream:
        stream.write(f'=== {Path(result["file"]).name} ===\n{result["text"]}\n\n')


def main() -> int:
    args = parse_args()
    require_device(args.device)
    if args.check:
        return 0

    files = audio_files(args.input)
    if not files:
        raise RuntimeError(f"No supported audio files found in {args.input}")
    model_path = ensure_model(args.model, args.model_dir, args.offline)
    pipeline_class = getattr(ov_genai, "ASRPipeline", None) or getattr(ov_genai, "WhisperPipeline")
    print(f"Loading {model_path} on {args.device}...")
    pipeline = pipeline_class(str(model_path), args.device)

    args.output.mkdir(parents=True, exist_ok=True)
    (args.output / "all_transcripts.txt").write_text("", encoding="utf-8")
    results: list[dict[str, Any]] = []
    generation = {"return_timestamps": True, "task": "transcribe"}
    if args.language.lower() != "auto":
        generation["language"] = f"<|{args.language.strip('<|>')}|>"

    for index, path in enumerate(files, 1):
        print(f"[{index}/{len(files)}] Transcribing {path.name}...")
        started = time.perf_counter()
        generated = pipeline.generate(decode_audio(path).tolist(), **generation)
        item = {"file": str(path), "text": result_text(generated), "segments": result_segments(generated),
                "language": args.language, "device": args.device, "processing_time": time.perf_counter() - started}
        results.append(item)
        save_result(item, args.output)
        print(f'Completed in {item["processing_time"]:.1f}s')

    (args.output / "transcripts_detailed.json").write_text(json.dumps(results, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"Done: {len(results)} file(s), results in {args.output}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (RuntimeError, subprocess.CalledProcessError) as error:
        print(f"Error: {error}", file=sys.stderr)
        raise SystemExit(1)
