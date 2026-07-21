# Ashton Smokeview Internal Release Guide

This document defines how the Ashton custom Smokeview fork is built, tested,
versioned, packaged, and distributed internally.

The current implementation is a pre-v1 development build. Do not distribute it
as v1 until the release checklist in this document has been completed.

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

Use annotated tags for distributed versions:

```bash
git tag -a ashton-smv-v1.0.0 -m "Ashton Smokeview v1.0.0"
git push origin ashton-smv-v1.0.0
```

Only tag a commit after its release package has passed the acceptance tests.

## Configuration Files

Smokeview reads its global configuration from `smokeview.ini` in the detected
Smokeview root directory. For the portable internal package, the executable,
`smokeview.ini`, and `objects.svo` must be placed in the same top-level
directory.

The current development configuration was obtained from:

```text
/home/tomcox/SharedFolder/VMLinux/smokeview.ini
```

That file is a complete saved Smokeview configuration, not just a colourbar
definition file. Before v1, create and review a curated release INI containing:

- the standard Smokeview defaults required by the team;
- the four approved custom `GCOLORBAR` definitions;
- the approved `V2_SLICE` bounds;
- any required `RESULTWORKFLOW` overrides.

Avoid shipping case-specific camera, input-file, clipping, or display state as
global defaults unless the team has explicitly approved those settings.

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
root. Linux produces a standard portable `tar.gz` archive; Windows produces a
portable ZIP. A self-extracting Linux `.sh` is intentionally not used because it
would require recipients to execute the archive before inspecting its contents.

```bash
scripts/package_release_linux.sh \
  --version 1.0.0 \
  --config path/to/curated/smokeview.ini
```

From an x64 Visual Studio Developer PowerShell on Windows:

```powershell
scripts\package_release_windows.ps1 `
  -Version 1.0.0 `
  -ConfigFile path\to\curated\smokeview.ini
```

Both scripts put the archive and a SHA-256 checksum in `dist/`. They accept
`--help`/`Get-Help`-style parameter discovery and can package an existing build
with `--skip-build`/`-SkipBuild`. The Windows package uses the static MSVC
runtime so that installing the Visual C++ Redistributable is not a prerequisite.

The manual commands below document the underlying Linux process and remain
useful for troubleshooting.

```bash
rm -rf cbuild/release

cmake -S . -B cbuild/release \
  -DCMAKE_BUILD_TYPE=Release \
  -DBUILD_SHARED_LIBS=OFF \
  -DVENDORED_UI_LIBS=ON \
  -DVENDORED_LIBS=OFF

cmake --build cbuild/release --target smokeview -j4
```

Inspect the resulting binary before packaging:

```bash
ldd cbuild/release/smokeview
readelf -d cbuild/release/smokeview | grep -E 'RPATH|RUNPATH' || true
```

The output must not contain paths under a developer's home directory or source
checkout. The Linux build will still depend on common system OpenGL, X11, image,
and C/C++ runtime libraries. Build on the oldest supported internal Linux image
and test the package on every supported Linux image.

## Package Layout

The v1 Linux archive should use this layout:

```text
ashton-smokeview-v1.0.0-linux-x64/
|-- smokeview
|-- smokeview.ini
|-- objects.svo
|-- colorbars/
|-- textures/
|-- README.txt
`-- VERSION
```

`VERSION` should contain the release version, Git commit, build date, platform,
and compiler. `README.txt` should contain the launch command, supported platform,
shortcut summary, configuration location, and internal support contact.

Assemble the staging directory only after the curated release INI exists:

```bash
version=v1.0.0
package="dist/ashton-smokeview-${version}-linux-x64"

rm -rf "$package"
mkdir -p "$package"
install -m 0755 cbuild/release/smokeview "$package/smokeview"
install -m 0644 path/to/curated/smokeview.ini "$package/smokeview.ini"
install -m 0644 Build/for_bundle/objects.svo "$package/objects.svo"
cp -R Build/for_bundle/colorbars "$package/colorbars"
cp -R Build/for_bundle/textures "$package/textures"
```

Create the archive and checksum:

```bash
tar -C dist -czf "${package}.tar.gz" "$(basename "$package")"
sha256sum "${package}.tar.gz" > "${package}.tar.gz.sha256"
```

## Acceptance Testing

Use one representative case that contains all required scalar quantities and
X, Y, and Z slice planes. Record the case name and test result with the release.

Verify all of the following before v1:

- Smokeview starts from the extracted package without access to the source tree.
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
- The archive passes testing on a second machine that has no source checkout.
- `sha256sum -c` validates the published archive.

## Publishing Internally

Publish both the archive and its `.sha256` file using one controlled location:

- a release attached to the internal Ashton GitHub repository; or
- a versioned folder in the company SharedFolder; or
- the company's managed internal software repository.

Do not distribute an unversioned executable over an existing release. Keep old
archives available so a team can roll back to the preceding known-good version.

Recipients should extract the complete directory and run:

```bash
./smokeview /absolute/path/to/case.smv
```

The Linux archive cannot be used natively on Windows. A Windows release needs a
separate Windows build, package, and acceptance-test pass.

## Deferred Work Before v1

The following items remain open for the v1 release cycle:

- finish and approve any additional shortcut behaviour;
- obtain a permanent representative regression-test case;
- curate and commit or securely store the release `smokeview.ini`;
- decide the supported Linux distribution and minimum library versions;
- decide whether a separate velocity-vector workflow is required;
- add automated workflow scripting and batch screenshots if included in v1;
- write user-facing release notes and the package `README.txt`;
- perform clean-machine acceptance testing;
- select the final v1 commit, build it, test it, and then create the tag.

Update this document whenever the shortcut contract, configuration format,
supported platforms, packaging layout, or release process changes.
