#!/usr/bin/env bash

set -Eeuo pipefail

usage() {
  cat <<'EOF'
Build Smokeview and create a self-extracting Linux installer.

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
  upstream_version="$(sed -nE 's/.*project\(smv .*VERSION ([0-9]+\.[0-9]+\.[0-9]+).*/\1/p' "$repo_root/CMakeLists.txt" | head -n 1)"
  ashton_release="$(sed -nE 's/.*set\(ASHTON_RELEASE "([^"]+)"\).*/\1/p' "$repo_root/CMakeLists.txt" | head -n 1)"
  [[ -n "$upstream_version" ]] || fail "could not determine the upstream Smokeview version from CMakeLists.txt"
  [[ -n "$ashton_release" ]] || fail "could not determine the Ashton release from CMakeLists.txt"
  version="${upstream_version}-${ashton_release}"
fi
version="${version#v}"
[[ "$version" =~ ^[0-9A-Za-z][0-9A-Za-z._-]*$ ]] || fail "invalid version: $version"

[[ -f "$config_file" ]] || fail "configuration file not found: $config_file"
[[ -f "$repo_root/Build/for_bundle/.smokeview_bin" ]] || fail ".smokeview_bin is missing"
[[ -f "$repo_root/Build/for_bundle/objects.svo" ]] || fail "objects.svo is missing"
[[ -f "$repo_root/Utilities/Scripts/capture_result_slices.py" ]] || fail "capture_result_slices.py is missing"
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

binary_version="$("$binary" -version 2>&1 | sed -nE 's/^Revision[[:space:]]*:[[:space:]]*//p' | head -n 1)"
[[ -n "$binary_version" ]] || fail "could not read the revision from the release executable"
if [[ "$binary_version" != "$version" ]]; then
  fail "package version $version does not match executable revision $binary_version; rebuild after updating ASHTON_RELEASE in CMakeLists.txt"
fi

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
install -m 0755 "$repo_root/Utilities/Scripts/capture_result_slices.py" "$package_dir/capture_result_slices.py"
install -m 0644 "$config_file" "$package_dir/smokeview.ini"
install -m 0644 "$repo_root/Build/for_bundle/.smokeview_bin" "$package_dir/.smokeview_bin"
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

Capture every configured result-review slice with:

  ./capture_result_slices.py /absolute/path/to/case.smv --overwrite

The packaged smokeview.ini and objects.svo files are loaded from this directory.
The capture utility requires Python 3.10 or newer and, unless --no-crop is used,
ImageMagick. It launches a separate automated Smokeview process, so an
interactive Smokeview window may remain open while capture runs.
Contact the Ashton Digital internal support channel for help with this build.
EOF

payload_path="$stage_root/$package_name.tar.gz"
installer_path="$output_dir/$package_name.sh"
checksum_path="$installer_path.sha256"
tar -C "$stage_root" -czf "$payload_path" "$package_name"

cat > "$installer_path" <<EOF
#!/usr/bin/env bash

set -Eeuo pipefail

package_name='$package_name'
version='$version'
EOF

cat >> "$installer_path" <<'EOF'

usage() {
  cat <<USAGE
Install Ashton Smokeview ${version} for Linux.

Usage:
  ./$(basename "$0") [options]

Options:
  --target DIR       Installation directory
                     (default: $HOME/.local/opt/$package_name)
  --extract FILE     Extract the embedded tar.gz without installing
  --yes              Accept the default installation directory
  -h, --help         Show this help
USAGE
}

fail() {
  echo "error: $*" >&2
  exit 1
}

target=""
extract_file=""
accept_default=0

while (($# > 0)); do
  case "$1" in
    --target)
      (($# >= 2)) || fail "--target requires a directory"
      target="$2"
      shift 2
      ;;
    --extract)
      (($# >= 2)) || fail "--extract requires a filename"
      extract_file="$2"
      shift 2
      ;;
    --yes)
      accept_default=1
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

payload_line="$(awk '/^__SMV_PAYLOAD_FOLLOWS__$/ { print NR + 1; exit }' "$0")"
[[ -n "$payload_line" ]] || fail "embedded archive marker not found"

if [[ -n "$extract_file" ]]; then
  if [[ -e "$extract_file" ]]; then
    fail "refusing to overwrite existing file: $extract_file"
  fi
  tail -n +"$payload_line" "$0" > "$extract_file"
  echo "Extracted $extract_file"
  exit 0
fi

default_target="$HOME/.local/opt/$package_name"
if [[ -z "$target" ]]; then
  target="$default_target"
  if ((accept_default == 0)); then
    echo "Ashton Smokeview v${version}"
    echo
    read -r -p "Installation directory [$default_target]: " answer
    target="${answer:-$default_target}"
  fi
fi

if [[ -e "$target" && ! -d "$target" ]]; then
  fail "installation target exists and is not a directory: $target"
fi

mkdir -p "$target"
temporary_dir="$(mktemp -d "${TMPDIR:-/tmp}/ashton-smokeview-install.XXXXXX")"
trap 'rm -rf -- "$temporary_dir"' EXIT
tail -n +"$payload_line" "$0" | tar -xz -C "$temporary_dir"
cp -R "$temporary_dir/$package_name/." "$target/"
chmod 0755 "$target/smokeview"

link_dir="${XDG_BIN_HOME:-$HOME/.local/bin}"
mkdir -p "$link_dir"
ln -sfn "$target/smokeview" "$link_dir/ashton-smokeview"
ln -sfn "$target/capture_result_slices.py" "$link_dir/ashton-capture-slices"

generic_launcher="$link_dir/smokeview"
if [[ ! -e "$generic_launcher" && ! -L "$generic_launcher" ]]; then
  ln -s "$target/smokeview" "$generic_launcher"
elif [[ -L "$generic_launcher" && "$(readlink "$generic_launcher")" == *"/ashton-smokeview-v"* ]]; then
  ln -sfn "$target/smokeview" "$generic_launcher"
else
  echo "Existing launcher was not replaced: $generic_launcher"
fi

data_home="${XDG_DATA_HOME:-$HOME/.local/share}"
config_home="${XDG_CONFIG_HOME:-$HOME/.config}"
applications_dir="$data_home/applications"
mime_dir="$data_home/mime"
mkdir -p "$applications_dir" "$mime_dir/packages" "$config_home"

cat > "$mime_dir/packages/ashton-smokeview.xml" <<'MIME_EOF'
<?xml version="1.0" encoding="UTF-8"?>
<mime-info xmlns="http://www.freedesktop.org/standards/shared-mime-info">
  <mime-type type="application/x-ashton-smokeview">
    <comment>Smokeview case</comment>
    <glob pattern="*.smv"/>
  </mime-type>
</mime-info>
MIME_EOF

cat > "$applications_dir/ashton-smokeview.desktop" <<DESKTOP_EOF
[Desktop Entry]
Type=Application
Name=Ashton Smokeview
Comment=Open a Smokeview case
Exec="$link_dir/ashton-smokeview" %f
Icon=applications-graphics
Terminal=false
MimeType=application/x-ashton-smokeview;
DESKTOP_EOF

cat > "$applications_dir/ashton-capture-slices.desktop" <<DESKTOP_EOF
[Desktop Entry]
Type=Application
Name=Capture result slices
Comment=Capture configured result-review slices with Ashton Smokeview
Exec="$link_dir/ashton-capture-slices" %f --overwrite
Icon=camera-photo
Terminal=true
NoDisplay=true
MimeType=application/x-ashton-smokeview;
DESKTOP_EOF

if command -v update-mime-database >/dev/null 2>&1; then
  update-mime-database "$mime_dir" >/dev/null 2>&1 || echo "Warning: could not update the MIME database."
fi
if command -v update-desktop-database >/dev/null 2>&1; then
  update-desktop-database "$applications_dir" >/dev/null 2>&1 || echo "Warning: could not update the desktop application database."
fi
if command -v xdg-mime >/dev/null 2>&1; then
  xdg-mime default ashton-smokeview.desktop application/x-ashton-smokeview >/dev/null 2>&1 || \
    echo "Warning: could not set Ashton Smokeview as the default .smv application."
fi

echo
echo "Installed Ashton Smokeview in $target"
echo "Smokeview launcher: $link_dir/ashton-smokeview"
echo "Capture launcher: $link_dir/ashton-capture-slices"
echo "Run now: $link_dir/ashton-smokeview"
echo "To capture: $link_dir/ashton-capture-slices /path/to/case.smv"
echo "Desktop integration: right-click an .smv file and choose Open With -> Capture result slices."
echo "If 'smokeview' still runs an older copy, run 'type -a smokeview'."
echo "Remove any old alias, or run 'hash -r' if the old path was cached."
if [[ ":$PATH:" != *":$link_dir:"* ]]; then
  echo "Add $link_dir to PATH, or run $target/smokeview directly."
fi
exit 0

__SMV_PAYLOAD_FOLLOWS__
EOF

cat "$payload_path" >> "$installer_path"
chmod 0755 "$installer_path"
(
  cd "$output_dir"
  sha256sum "$(basename "$installer_path")" > "$(basename "$checksum_path")"
)

echo "Created $installer_path"
echo "Created $checksum_path"
