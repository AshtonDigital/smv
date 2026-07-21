#!/usr/bin/env bash

set -Eeuo pipefail

usage() {
  cat <<'EOF'
Build and package Smokeview for Linux.

Usage:
  scripts/package_release_linux.sh [options]

Options:
  --version VERSION     Package version (default: version from CMakeLists.txt)
  --config FILE         Release smokeview.ini (default: Build/for_bundle/smokeview.ini)
  --build-dir DIR       CMake build directory (default: cbuild/release-linux)
  --output-dir DIR      Package output directory (default: dist)
  --skip-build          Package an existing release build
  -h, --help            Show this help

Relative paths are resolved from the repository root.
EOF
}

fail() {
  echo "error: $*" >&2
  exit 1
}

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"

version=""
config_file="Build/for_bundle/smokeview.ini"
build_dir="cbuild/release-linux"
output_dir="dist"
skip_build=0

while (($# > 0)); do
  case "$1" in
    --version)
      (($# >= 2)) || fail "--version requires a value"
      version="$2"
      shift 2
      ;;
    --config)
      (($# >= 2)) || fail "--config requires a value"
      config_file="$2"
      shift 2
      ;;
    --build-dir)
      (($# >= 2)) || fail "--build-dir requires a value"
      build_dir="$2"
      shift 2
      ;;
    --output-dir)
      (($# >= 2)) || fail "--output-dir requires a value"
      output_dir="$2"
      shift 2
      ;;
    --skip-build)
      skip_build=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "unknown option: $1"
      ;;
  esac
done

[[ "$(uname -s)" == "Linux" ]] || fail "this script must be run on Linux"

absolute_from_root() {
  local path="$1"
  if [[ "$path" == /* ]]; then
    printf '%s\n' "$path"
  else
    printf '%s/%s\n' "$repo_root" "$path"
  fi
}

config_file="$(absolute_from_root "$config_file")"
build_dir="$(absolute_from_root "$build_dir")"
output_dir="$(absolute_from_root "$output_dir")"

if [[ -z "$version" ]]; then
  version="$(sed -nE 's/.*project\(smv .*VERSION ([0-9]+\.[0-9]+\.[0-9]+).*/\1/p' "$repo_root/CMakeLists.txt" | head -n 1)"
fi
version="${version#v}"
[[ "$version" =~ ^[0-9A-Za-z][0-9A-Za-z._-]*$ ]] || fail "invalid version: $version"

[[ -f "$config_file" ]] || fail "configuration file not found: $config_file"
[[ -f "$repo_root/Build/for_bundle/objects.svo" ]] || fail "objects.svo is missing"
[[ -d "$repo_root/Build/for_bundle/colorbars" ]] || fail "colorbars directory is missing"
[[ -d "$repo_root/Build/for_bundle/textures" ]] || fail "textures directory is missing"

if ((skip_build == 0)); then
  cmake -S "$repo_root" -B "$build_dir" \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED_LIBS=OFF \
    -DVENDORED_UI_LIBS=ON \
    -DVENDORED_LIBS=OFF
  cmake --build "$build_dir" --target smokeview --parallel
fi

binary="$build_dir/smokeview"
[[ -x "$binary" ]] || fail "release executable not found: $binary"

if ldd "$binary" | grep -q 'not found'; then
  ldd "$binary" >&2
  fail "the release executable has unresolved shared-library dependencies"
fi

if command -v readelf >/dev/null 2>&1; then
  runtime_paths="$(readelf -d "$binary" 2>/dev/null | grep -E 'RPATH|RUNPATH' || true)"
  if [[ "$runtime_paths" == *"$repo_root"* ]]; then
    echo "$runtime_paths" >&2
    fail "the release executable contains a runtime path into the source checkout"
  fi
fi

case "$(uname -m)" in
  x86_64) architecture="x64" ;;
  aarch64|arm64) architecture="arm64" ;;
  *) architecture="$(uname -m)" ;;
esac

package_name="ashton-smokeview-v${version}-linux-${architecture}"
mkdir -p "$output_dir"
stage_root="$(mktemp -d "${TMPDIR:-/tmp}/smv-package.XXXXXX")"
trap 'rm -rf -- "$stage_root"' EXIT
package_dir="$stage_root/$package_name"
mkdir -p "$package_dir"

install -m 0755 "$binary" "$package_dir/smokeview"
install -m 0644 "$config_file" "$package_dir/smokeview.ini"
install -m 0644 "$repo_root/Build/for_bundle/objects.svo" "$package_dir/objects.svo"
cp -R "$repo_root/Build/for_bundle/colorbars" "$package_dir/colorbars"
cp -R "$repo_root/Build/for_bundle/textures" "$package_dir/textures"

commit="$(git -C "$repo_root" rev-parse --short=12 HEAD 2>/dev/null || echo unknown)"
dirty="no"
if [[ -n "$(git -C "$repo_root" status --porcelain --untracked-files=no 2>/dev/null)" ]]; then
  dirty="yes"
fi
compiler="$(sed -nE 's/^CMAKE_C_COMPILER(:FILEPATH|:STRING)?=//p' "$build_dir/CMakeCache.txt" | head -n 1)"
compiler="${compiler:-unknown}"

cat > "$package_dir/VERSION" <<EOF
Version: v${version}
Git commit: ${commit}
Git working tree dirty: ${dirty}
Build date: $(date -u +'%Y-%m-%dT%H:%M:%SZ')
Platform: Linux ${architecture}
Compiler: ${compiler}
EOF

cat > "$package_dir/README.txt" <<'EOF'
Ashton Smokeview
================

Keep this directory together. Run Smokeview with an absolute path to a case:

  ./smokeview /absolute/path/to/case.smv

The packaged smokeview.ini and objects.svo files are loaded from this directory.
Contact the Ashton Digital internal support channel for help with this build.
EOF

archive_path="$output_dir/$package_name.tar.gz"
checksum_path="$archive_path.sha256"
tar -C "$stage_root" -czf "$archive_path" "$package_name"
(
  cd "$output_dir"
  sha256sum "$(basename "$archive_path")" > "$(basename "$checksum_path")"
)

echo "Created $archive_path"
echo "Created $checksum_path"
