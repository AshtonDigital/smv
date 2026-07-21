# Ashton Smokeview Internal Release Guide

This document defines how the Ashton custom Smokeview fork is built, tested,
versioned, packaged, and distributed internally. The current release line is
based on Smokeview 6.11.2 and uses an Ashton suffix such as `af1`, producing the
combined version `6.11.2-af1`.

## Current Customisation

The fork adds CFD result-review workflows intended to reduce repetitive setup.

| Shortcut | Action |
| --- | --- |
| `Ctrl+X` | Cycle X-minimum, X-maximum, and exterior views |
| `Ctrl+Y` | Cycle Y-minimum, Y-maximum, and exterior views |
| `Ctrl+Z` | Cycle Z-minimum, Z-maximum, and exterior views |
| `Ctrl+I` | Cycle scalar visibility slices |
| `Ctrl+T` | Cycle scalar temperature slices |
| `Ctrl+V` | Cycle scalar velocity-magnitude slices |
| `Ctrl+P` | Cycle scalar pressure slices |

Each result shortcut cycles matching planes in X, Y, then Z order. Selecting a
plane loads its slice files, selects the configured colourbar and bounds, clips
at the plane's actual coordinate, selects the matching axis view, and applies a
fitted zoom. The final step turns the workflow off and restores the camera and
clipping state that existed before the workflow started.

The default result mappings are:

| Workflow | Slice label | Colourbar |
| --- | --- | --- |
| Visibility | `VIS_C0.9H0.1` | `Visibility` |
| Temperature | `temp` | `Temperature` |
| Velocity | `vel` | `Velocity` |
| Pressure | `pres` | `Pressure` |

Mappings can be overridden with `RESULTWORKFLOW` records in the global or
case-specific INI. A case-specific record takes precedence.

## Repository Management

The internal repository is:

```text
git@github.com:AshtonDigital/smv.git
```

Changes may be committed directly to the internal release branch without a
pull request if that is the team's agreed process. Keep commits focused and do
not commit generated files from `cbuild/` or packaged release archives.

Before starting release work:

```bash
git status --short --branch
git pull --ff-only
```

Use annotated tags for distributed versions. The tag must match the version
reported by `smokeview -version` and printed in the installer filename:

```bash
git tag -a ashton-smv-v6.11.2-af1 -m "Ashton Smokeview 6.11.2-af1"
git push origin ashton-smv-v6.11.2-af1
```

Only tag a commit after its release package has passed the acceptance tests.

## Configuration Files

Smokeview reads its global configuration from `smokeview.ini` in the detected
Smokeview root directory. For the portable internal package, the executable,
`smokeview.ini`, and `objects.svo` must be placed in the same top-level
directory.

The approved company-default configuration is maintained at:

```text
/home/tomcox/SharedFolder/VMLinux/smokeview.ini
```

`Build/for_bundle/smokeview.ini` is the version-controlled release snapshot of
that file and is packaged on both platforms. The company default is a complete
saved Smokeview configuration, not just a colourbar definition file. Review
changes to it for:

- the standard Smokeview defaults required by the team;
- the five approved company `GCOLORBAR` definitions;
- the approved `V2_SLICE` bounds;
- any required `RESULTWORKFLOW` overrides.

Only ship case-specific camera, input-file, clipping, or display state when the
team has explicitly approved those settings as part of the company default.

## Development Build

Use the persistent ignored build directory for local testing:

```bash
cmake -S . -B cbuild/review \
  -DCMAKE_BUILD_TYPE=Release \
  -DVENDORED_UI_LIBS=ON \
  -DVENDORED_LIBS=OFF

cmake --build cbuild/review --target smokeview -j4
```

For current development testing, place the required resources beside the
executable:

```bash
cp /home/tomcox/SharedFolder/VMLinux/smokeview.ini cbuild/review/smokeview.ini
cp Build/for_bundle/objects.svo cbuild/review/objects.svo
```

Run a representative case with:

```bash
./cbuild/review/smokeview /absolute/path/to/case.smv
```

Do not test by running Smokeview without a case file.

## Release Build

Create a clean release build with the vendored GLUT library linked statically.
This prevents the package from referring to a library inside the developer's
checkout.

For normal releases, use the platform packaging scripts from the repository
root. To match the official Smokeview distribution format, Linux produces a
self-extracting `.sh` installer and Windows produces an NSIS `.exe` installer.

```bash
./scripts/package_release_linux.sh
```

From an x64 Visual Studio Developer PowerShell on Windows:

```powershell
.\scripts\package_release_windows.ps1
```

Both scripts use `Build/for_bundle/smokeview.ini`, the committed snapshot of
the company default. Use `--config` or `-ConfigFile` only to test an explicitly
selected alternative configuration.

Both scripts put the installer and a SHA-256 checksum in `dist/`. They accept
`--help`/`Get-Help`-style parameter discovery and can package an existing build
with `--skip-build`/`-SkipBuild`. The Windows package uses the static MSVC
runtime so that installing the Visual C++ Redistributable is not a prerequisite.
Creating the Windows installer also requires NSIS 3 and its `makensis.exe`
compiler.

The release version combines the upstream Smokeview version with the Ashton
fork release, for example `6.11.2-af1`. Increment `ASHTON_RELEASE` in the root
`CMakeLists.txt` (`af2`, `af3`, and so on) before creating the next release.
The packaging scripts derive the version automatically and reject an installer
whose package version does not match the revision embedded in its executable.

Both installers include `capture_result_slices.py` beside the Smokeview
executable. This keeps the capture utility matched to the custom build and lets
it discover the installed executable without a `--smokeview` argument. End
users still need Python 3.10 or newer and, unless they use `--no-crop`,
ImageMagick.

On Windows, the installer adds **Capture result slices** to the `.smv` file
context menu. On Linux, it installs the `ashton-smokeview` and
`ashton-capture-slices` commands and registers **Capture result slices** as an
`.smv` application under **Open With**. These actions start a separate automated
Smokeview process; an existing interactive window can remain open.

The manual commands below document the underlying Linux process and remain
useful for troubleshooting.

```bash
rm -rf cbuild/release-linux

cmake -S . -B cbuild/release-linux \
  -DCMAKE_BUILD_TYPE=Release \
  -DBUILD_SHARED_LIBS=OFF \
  -DVENDORED_UI_LIBS=ON \
  -DVENDORED_LIBS=OFF

cmake --build cbuild/release-linux --target smokeview -j4
```

Inspect the resulting binary before packaging:

```bash
ldd cbuild/release-linux/smokeview
readelf -d cbuild/release-linux/smokeview | grep -E 'RPATH|RUNPATH' || true
```

The output must not contain paths under a developer's home directory or source
checkout. The Linux build will still depend on common system OpenGL, X11, image,
and C/C++ runtime libraries. Build on the oldest supported internal Linux image
and test the package on every supported Linux image.

## Package Layout

The Linux and Windows installers contain equivalent application resources.
The Linux payload has this layout:

```text
ashton-smokeview-v6.11.2-af1-linux-x64/
|-- smokeview
|-- capture_result_slices.py
|-- smokeview.ini
|-- objects.svo
|-- colorbars/
|-- textures/
|-- README.txt
`-- VERSION
```

The Windows payload uses `smokeview.exe` and also includes
`capture_result_slices.cmd`, which provides dependency checking and invokes the
Python capture utility. `VERSION` contains the release version, Git commit,
build date, platform and compiler. `README.txt` contains the launch and capture
commands, dependency notes, configuration location and support information.

The packaging scripts assemble these payloads automatically. The equivalent
manual Linux staging commands are useful only for troubleshooting:

```bash
version=6.11.2-af1
package="dist/ashton-smokeview-v${version}-linux-x64"

rm -rf "$package"
mkdir -p "$package"
install -m 0755 cbuild/release-linux/smokeview "$package/smokeview"
install -m 0755 Utilities/Scripts/capture_result_slices.py \
  "$package/capture_result_slices.py"
install -m 0644 Build/for_bundle/smokeview.ini "$package/smokeview.ini"
install -m 0644 Build/for_bundle/objects.svo "$package/objects.svo"
cp -R Build/for_bundle/colorbars "$package/colorbars"
cp -R Build/for_bundle/textures "$package/textures"
```

For troubleshooting, create the payload archive directly with:

```bash
tar -C dist -czf "${package}.tar.gz" "$(basename "$package")"
```

The release script performs this staging automatically, embeds the compressed
payload after its installer shell code, and checksums the resulting `.sh` file.

## Acceptance Testing

Use one representative case that contains all required scalar quantities and
X, Y, and Z slice planes. Record the case name and test result with the release.

Verify all of the following before distributing a release:

- Smokeview starts from the installed package without access to the source tree.
- Startup output reports the package directory as `Root directory`.
- Startup output reports the packaged `smokeview.ini` and `objects.svo`.
- Existing important shortcuts still work: `O`, `Alt+V`, `Alt+B`, `Alt+C`,
  `Space`, `1` through `9`, and existing mouse modifiers.
- `Ctrl+X`, `Ctrl+Y`, and `Ctrl+Z` cycle the expected standard views.
- `Ctrl+I`, `Ctrl+T`, `Ctrl+V`, and `Ctrl+P` select the correct scalar quantity.
- Each result workflow cycles every expected X, Y, and Z plane in order.
- Each selected slice receives the correct colourbar and numeric bounds.
- Clipping uses the selected slice's actual coordinate.
- X and Y slices use the expected side view; Z slices use the top-down view.
- The fitted zoom shows the complete domain and normal zoom controls remain usable.
- Advancing to `off` restores the previous camera and clipping state.
- The installer passes testing on a second machine that has no source checkout.
- The published `.sha256` file validates the installer.
- The installed capture utility reports Python, Smokeview and ImageMagick
  dependencies clearly before rendering.
- The capture utility renders, crops and renames all configured result slices.
- Capture can run in a separate automated process while an interactive
  Smokeview window remains open.
- On Windows, double-clicking an `.smv` file opens Ashton Smokeview and the
  **Capture result slices** File Explorer context action works.
- On Linux, `ashton-smokeview` and `ashton-capture-slices` are available, an
  `.smv` file opens in Ashton Smokeview by default, and **Open With > Capture
  result slices** works in the desktop file manager.

## Publishing Internally

Publish both the installer and its `.sha256` file using one controlled location:

- a release attached to the internal Ashton GitHub repository; or
- a versioned folder in the company SharedFolder; or
- the company's managed internal software repository.

Do not distribute an unversioned installer over an existing release. Keep old
installers available so a team can roll back to the preceding known-good version.

Linux recipients should make the downloaded installer executable and run it:

```bash
chmod +x ashton-smokeview-v6.11.2-af1-linux-x64.sh
./ashton-smokeview-v6.11.2-af1-linux-x64.sh
```

Windows recipients run the `.exe` installer normally. The Linux installer cannot
be used natively on Windows; each platform needs its own build and acceptance-test
pass.

## Remaining Release Work

The following items still require a team decision or release-specific action:

- approve any additional shortcut behaviour;
- select and retain a representative regression-test case;
- decide the supported Linux distributions and minimum library versions;
- decide whether a separate velocity-vector workflow is required;
- write release notes for each distributed Ashton version;
- perform clean-machine acceptance testing on both platforms;
- select the final commit, build both installers, test them, then create the
  matching annotated tag.

Update this document whenever the shortcut contract, configuration format,
supported platforms, packaging layout, or release process changes.
