#!/usr/bin/env python3
"""Render every configured Smokeview result-review slice."""

from __future__ import annotations

import argparse
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile


def smokeview_file(value: str) -> Path:
    path = Path(value).expanduser()
    if path.suffix.lower() != ".smv":
        path = path.with_suffix(".smv")
    path = path.resolve()
    if not path.is_file():
        raise argparse.ArgumentTypeError(f"Smokeview file does not exist: {path}")
    return path


def executable_file(value: str) -> Path:
    path = Path(value).expanduser().resolve()
    if not path.is_file() or not os.access(path, os.X_OK):
        raise argparse.ArgumentTypeError(f"Smokeview executable is not executable: {path}")
    return path


def render_size(value: str) -> tuple[int, int]:
    match = re.fullmatch(r"(\d+)[xX](\d+)", value)
    if match is None or int(match.group(1)) <= 0 or int(match.group(2)) <= 0:
        raise argparse.ArgumentTypeError("render size must be WIDTHxHEIGHT")
    return int(match.group(1)), int(match.group(2))


def display_size() -> tuple[int, int] | None:
    commands = (
        (["xrandr", "--current"], r"current\s+(\d+)\s+x\s+(\d+)"),
        (["xdpyinfo"], r"dimensions:\s+(\d+)x(\d+)\s+pixels"),
    )
    for command, pattern in commands:
        try:
            result = subprocess.run(
                command, check=False, capture_output=True, text=True, timeout=5
            )
        except (FileNotFoundError, subprocess.TimeoutExpired):
            continue
        match = re.search(pattern, result.stdout)
        if match is not None:
            return int(match.group(1)), int(match.group(2))
    return None


def supports_result_capture(executable: Path) -> bool:
    keywords = (b"SMV_FEATURE_RENDERRESULTS_1", b"RENDERFULLSCREEN")
    overlap = b""
    with executable.open("rb") as stream:
        while chunk := stream.read(1024 * 1024):
            data = overlap + chunk
            keywords = tuple(keyword for keyword in keywords if keyword not in data)
            if not keywords:
                return True
            overlap = data[-64:]
    return not keywords


def find_smokeview(explicit: Path | None) -> Path:
    if explicit is not None:
        return explicit

    candidates: list[Path] = []
    repo_root = Path(__file__).resolve().parents[2]
    candidates.append(repo_root / "cbuild" / "review" / "smokeview")
    candidates.extend((repo_root / "Build" / "smokeview").glob("*/smokeview_*"))

    env_smv = os.environ.get("SMV")
    if env_smv:
        candidates.append(Path(env_smv).expanduser())
    for command in ("smokeview", "smokeview_linux"):
        found = shutil.which(command)
        if found:
            candidates.append(Path(found))

    for candidate in candidates:
        candidate = candidate.resolve()
        if candidate.is_file() and os.access(candidate, os.X_OK):
            return candidate
    raise RuntimeError(
        "Smokeview was not found. Pass --smokeview EXE, set SMV, or add smokeview to PATH."
    )


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Open a .smv case and save a PNG for every configured visibility, "
            "temperature, velocity and pressure review slice."
        )
    )
    parser.add_argument("case", type=smokeview_file, help="case .smv file (extension optional)")
    parser.add_argument(
        "-o", "--output", type=Path,
        help="output directory (default: CASE_slice_captures beside the .smv file)",
    )
    parser.add_argument(
        "-e", "--smokeview", type=executable_file,
        help="Smokeview executable (otherwise use this repository's build, SMV, or PATH)",
    )
    parser.add_argument("--prefix", help="output filename prefix (default: case name)")
    parser.add_argument(
        "--size", type=render_size, metavar="WIDTHxHEIGHT",
        help="capture dimensions (default: current display resolution)",
    )
    parser.add_argument(
        "--time", type=float, default=150.0,
        help="simulation time to capture (default: 150 s; nearest available frame is used)",
    )
    parser.add_argument(
        "--overwrite", action="store_true", help="replace captures that already exist"
    )
    parser.add_argument(
        "--keep-script", action="store_true", help="retain the generated .ssf file in the output directory"
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    case: Path = args.case
    output = (args.output or case.with_name(f"{case.stem}_slice_captures")).expanduser().resolve()
    prefix = args.prefix or case.stem
    fullscreen = args.size is None
    width, height = args.size or display_size() or (1920, 1080)
    if "\n" in prefix or "\r" in prefix:
        raise RuntimeError("The filename prefix must be one line")
    if "\n" in str(output) or "\r" in str(output) or "#" in str(output):
        raise RuntimeError("The output path cannot contain a newline or '#' character")

    smokeview = find_smokeview(args.smokeview)
    if not supports_result_capture(smokeview):
        raise RuntimeError(
            f"{smokeview} does not support the RENDERRESULTS command. "
            "Build Smokeview from this checkout or pass that executable with --smokeview."
        )
    output.mkdir(parents=True, exist_ok=True)
    if args.overwrite:
        capture_name = re.compile(
            rf"{re.escape(prefix)}_(visibility|temperature|velocity|pressure)_[xyz]_\d{{3}}_.+\.png"
        )
        for path in output.iterdir():
            if path.is_file() and capture_name.fullmatch(path.name) is not None:
                path.unlink()
    script_text = (
        ("RENDERFULLSCREEN\n" if fullscreen else "")
        + "RENDERSIZE\n"
        + (" 0 0\n" if fullscreen else f" {width} {height}\n")
        + "RENDERTYPE\n"
        " PNG\n"
        "RENDERDIR\n"
        f" {output}{os.sep}\n"
        "RENDERRESULTS\n"
        f" {prefix}\n"
        f" {args.time:.9g}\n"
    )

    script_path: Path
    remove_script = not args.keep_script
    if args.keep_script:
        script_path = output / f"{case.stem}_capture_results.ssf"
        script_path.write_text(script_text, encoding="utf-8")
    else:
        with tempfile.NamedTemporaryFile(
            mode="w", encoding="utf-8", suffix=".ssf", prefix="smv_capture_", delete=False
        ) as stream:
            stream.write(script_text)
            script_path = Path(stream.name)

    command = [str(smokeview)]
    if args.overwrite:
        command.append("-render_overwrite")
    command.extend(["-script", str(script_path), case.name])
    print(f"Capturing result slices from {case} at t={args.time:g} s")
    print(f"Writing PNG files to {output}")
    print(f"Capture size: {width}x{height}")
    print(f"Using Smokeview: {smokeview}")
    try:
        return subprocess.run(command, cwd=case.parent, check=False).returncode
    finally:
        if remove_script:
            script_path.unlink(missing_ok=True)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, RuntimeError) as error:
        print(f"capture_result_slices: {error}", file=sys.stderr)
        sys.exit(2)
