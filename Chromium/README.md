# Chromium engine integration

Orbit embeds Chromium built directly from source -- no third-party prebuilt.
The pinned version lives in `chromium-version.json`.

Orbit's own embedder -- the GN target that produces "Orbit Framework.framework"
plus its three helper `.app` bundles, and the `ContentMainDelegate` /
`ContentBrowserClient` C++ that back them -- lives at `Chromium/Embedder/` in
this repository, tracked normally in git like any other source. See "Orbit's
embedder" below for how that reaches into the (gitignored, resynced) Chromium
checkout, and `Chromium/Embedder/BUILD.gn` for the GN target definitions
themselves. The browser-side Swift bridge that loads and drives this framework
from Orbit.app lives at `Orbit/Engine/Chromium/` and is separate, ongoing work;
this document describes the engine itself and how it is built.

## Two ways to get a build

| source | command | time | who uses it |
| --- | --- | --- | --- |
| Orbit's own published build | `Scripts/chromium fetch` | minutes | default; ordinary clones and CI, once the publish pipeline has run |
| build from source | `Scripts/chromium build --from-source` | hours, tens of GB | the machine that produces the published build |

There is no fallback source: upstream Chromium does not publish
ready-to-embed binaries, so until `build-and-publish` has produced and
uploaded one, `fetch` has nothing to install. `pin` still always resolves
against a real, existing Chromium git tag (verified with `git ls-remote`), so
what gets pinned is always buildable even when it is not yet fetchable.

`fetch` verifies the download by SHA-256 before extracting anything, and fails
closed (deletes the download, does not install) on a mismatch.

`build --from-source` drives `ThirdParty/depot_tools` (a git submodule)
through `gclient sync`, `gn gen` and `autoninja` directly against a plain
Chromium checkout -- no third-party build driver. It checks out
Chromium at `ThirdParty/chromium/src` with `--no-history`, builds the GN
target named by `build_target` in the manifest, and never writes outside
`ThirdParty/` -- every cache `gclient`/`gn`/`cipd`/`vpython` would otherwise
put under `$HOME` is redirected to `ThirdParty/.gclient-home` (see
`build_env()` in `chromium_manager.py`). `Scripts/chromium package` packages
the built artifact into the tarball `build-and-publish` uploads, and
`Scripts/chromium record-prebuilt` records its checksum in the manifest. A
normal contributor never runs the source build.

Two build targets are known to `BUILD_TARGET_ARTIFACTS`/`BUILD_DIR_FOR_TARGET`
in `chromium_manager.py`, in different output directories with different GN
configurations, on purpose:

| `build_target` | output dir (`shipping` / `dcheck`) | `is_component_build` | what it is |
| --- | --- | --- | --- |
| `content_shell` | `out/Release` / `out/ReleaseDCheck` | `true` (fast, the standard local-build args from Chromium's own docs) | Chromium's own reference embedder. Proved the toolchain end to end; not something Orbit ships. Kept as a cheap way to sanity-check a toolchain/checkout change without touching the much larger `orbit` build. |
| `orbit` | `out/OrbitShipping` / `out/Orbit` | `false` | Orbit's own embedder (`//orbit`, see below). The one that ships. |

## Two engine configurations

Every `build_target` is built twice, in configurations that differ in one GN
argument:

| `--config` | `dcheck_always_on` | who gets it |
| --- | --- | --- |
| `shipping` | `false` | users. The Release Xcode configuration, `Scripts/release`, the DMG. What Chrome stable ships. |
| `dcheck` | `true` | the Debug Xcode configuration and `Scripts/live-engine-tests`. An invariant violation aborts the process by name instead of misbehaving quietly. |

`dcheck_always_on` defaults to `(build_with_chromium && !is_official_build)`
in `build/config/dcheck_always_on.gni`, and Orbit sets neither, so *not*
writing it down is how a shipping browser ends up compiling in every
development assertion in Blink, net and content and treating each one as
fatal. Both configurations therefore state it explicitly, and three separate
things refuse to let the shipping one drift:

* `Scripts/security-guards dcheck` reads the args `chromium_manager.py` would
  write, the `args.gn` of any out directory present, and the marker in any
  installed engine. It needs no engine and no host and runs on Linux.
* `//orbit`'s `OrbitEngineBuildMarker()` (in
  `Chromium/Embedder/bridge/orbit_bridge_api.cc`) compiles the string
  `orbit-engine-build: dcheck=1` or `=0` from `DCHECK_IS_ON()` into the
  framework binary itself, so what a build *is* can be read rather than
  inferred from what it was asked to be.
* `Scripts/chromium verify-engine --config <name> [--bundle Orbit.app]` reads
  that marker. `fetch`, `build`, `package`, `ensure` and `doctor` all call it;
  ci.yml and release.yml run it against the archived `Orbit.app` before
  anything is signed.

The engines are separate downloads and separate release assets
(`orbit-chromium-<version>-<platform>-<config>.tar.xz`), recorded separately
under `prebuilt.configs` in `chromium-version.json`.

`orbit` must be a non-component (static) build, and this is a correctness
requirement, not a preference: content's macOS sandbox model requires a
sandboxed child to `dlopen()` its own framework strictly *after* applying the
Seatbelt profile (see the process-and-sandbox design note), and the profile
only grants filesystem access under the framework's own bundle path. In a
component build, most of Chromium's code lives in loose `.dylib`s dropped
directly in `root_out_dir` -- outside the bundle, and not staged into it by
anything -- so a sandboxed child cannot load them at all, and the framework
cannot be relocated into a shipped `.app` in the first place (verified by
copying a component-build "Orbit Framework.framework" out of the build tree
and watching `dyld` fail to find `libsandbox_mac_seatbelt.dylib`, which never
left `out/Release`). A static build links everything Orbit needs directly
into the one framework binary, matching how Chrome itself ships.

## Orbit's embedder

`Chromium/Embedder/` is Orbit's own GN target: a `mac_framework_bundle`
producing `Orbit Framework.framework` (Orbit's `ContentMainDelegate` and
`ContentBrowserClient`, plus everything under `//content/public/app`), three
nested helper `.app` bundles (plain, Renderer, GPU -- see
`//content/public/app/mac_helpers.gni`'s `content_mac_helpers`, which this
reuses directly so the role names always match what
`Scripts/release_manager.py` expects), and `orbit_selftest`, a standalone
build-validation tool (never shipped) that `dlopen()`s the built framework and
calls `OrbitMain` the same way the real stubs do.

It lives in this repository, not inside `ThirdParty/chromium/`, because the
checkout is gitignored and gets torn down and resynced (a version bump, a
fresh clone): anything written only into the checkout does not survive that.
Reaching it from inside the checkout, so GN can build it, takes two pieces of
generated state, both regenerated by `chromium_manager.py` every time it
touches the checkout (`link_embedder_source()` / `patch_root_build_gn()`,
called from `checkout_chromium()`):

1. A symlink, `ThirdParty/chromium/src/orbit -> Chromium/Embedder`. Not a copy
   and not a DEPS entry: depot_tools' own
   `gclient sync --reset --delete_unversioned_trees` (which `build --from-source`
   runs on every version bump) deletes untracked directories under `src/`, but
   its own code explicitly skips symlinks --
   `gclient_scm.py`: `if not os.path.islink(full_path): ... rmtree(full_path)`,
   verified by reading it, not assumed. That is the one thing that survives
   both a resync and a fresh clone without ever writing into the checkout.
2. One small, clearly-marked `group("orbit_embedder")` appended to the
   checkout's own root `BUILD.gn`. GN only defines targets reachable, through
   `deps`, from that file (its own top comment says so); a symlinked directory
   nothing depends on is simply never parsed, `--root-pattern`/`root_patterns`
   included -- verified empirically, not from the (contradicted-by-behaviour)
   help text. The root `BUILD.gn` *is* reset to upstream on every version
   bump, unlike the symlink, so this one is reapplied idempotently every time
   rather than surviving on its own; `ORBIT_ROOT_BUILD_GN_MARKER` is what
   makes reapplication a no-op when it is already there.

Both are pure regenerated build inputs, exactly like
`Chromium/Generated/Chromium.xcconfig` and `ThirdParty/prebuilt/<config>`
already are -- nothing here is a hand-maintained patch someone has to
remember to redo.

The result of a build (`Scripts/chromium build --from-source`, target
`orbit`) is:

```
Orbit Framework.framework/
  Orbit Framework -> Versions/Current/Orbit Framework
  Helpers -> Versions/Current/Helpers
  Resources -> Versions/Current/Resources
  Versions/
    A/
      Orbit Framework                          the Mach-O; exports OrbitMain
      Resources/Info.plist
      Helpers/
        Orbit Helper.app                       every --type=utility service
        Orbit Helper (Renderer).app
        Orbit Helper (GPU).app
    Current -> A
```

`Scripts/embed-chromium-framework.sh`, run as a build phase on both the Orbit
and OrbitDemo Xcode targets, copies this into each app's own
`Contents/Frameworks/` and ad-hoc/dev re-signs the framework and each helper
with its role's entitlements from `Orbit/Resources/OrbitHelper*.entitlements`
-- the same files `Scripts/release_manager.py` already owns, not a second
copy of that table. It is a no-op, not a failure, until `orbit` has actually
been built (see `Chromium.xcconfig`'s `FRAMEWORK_SEARCH_PATHS`/
`HEADER_SEARCH_PATHS`, wired the same way): every other Xcode build in this
repository has to keep working while that bakes.

`chromium-version.json`'s `build_target` stays `content_shell` until a build
for `orbit` is actually installed at `ThirdParty/prebuilt/shipping` --
switching it before that makes `Scripts/chromium ensure` (which every Orbit/
OrbitDemo build runs first) fail outright, since there is no published `orbit`
build yet either. Flip it, and re-run `Scripts/chromium sync`, once
`build --from-source` (or `fetch`, once a build is published) has produced one.

## Build wiring

`Scripts/chromium` is the only thing that reads or writes
`chromium-version.json`, and the only thing that turns it into build inputs.

| command | what it does |
| --- | --- |
| `ensure` | make the pinned build present, fetching it if needed (this is what the Xcode build runs) |
| `status` | what is pinned, what is installed, what is published, what is newer upstream |
| `pin <version>` | move the pin (`latest`, `latest-beta`, a full Chromium version), verified against a real Chromium git tag |
| `fetch` | download and verify Orbit's own published build (default) |
| `build --from-source` | check out and build Chromium locally (opt-in) |
| `package` | turn a local source build into a publishable tarball |
| `record-prebuilt` | record a published tarball's checksum/size in the manifest |
| `verify-engine` | prove an engine binary was compiled with the DCHECK setting its configuration declares |
| `bootstrap` | initialise the depot_tools submodule, check upstream reachability |
| `sync` | regenerate build inputs from the manifest |
| `doctor` | check the local toolchain and build state |
| `clean` | remove the installed build, or the whole source checkout |

Everything except `pin`, `sync` and `bootstrap` takes `--config
shipping|dcheck`, defaulting to `shipping`.

Both sources finish at the same place per configuration:
`ThirdParty/prebuilt/<version>-<config>/` for a download and
`out/<dir>` for a source build, symlinked from
`ThirdParty/prebuilt/<config>`. `sync` writes
`Chromium/Generated/Chromium.xcconfig` (gitignored, never hand-edit) and
`Orbit/Generated/ChromiumVersion.swift` from the manifest, and never inspects
what is on disk.

There is no bootstrap step for an ordinary clone. The `ChromiumEngine`
aggregate target runs `Scripts/ensure-chromium-engine.sh` before anything else
is compiled and always uses `fetch` -- an ordinary Xcode build never triggers
a multi-hour source build. Today that phase fails until a build has actually
been published, which is expected: there is nothing for it to link against
yet either.

`Chromium/Chromium.xcconfig` exposes `ORBIT_ENGINE_CONFIG` (`shipping`, and
`dcheck` for `[config=Debug]`), `ORBIT_CHROMIUM_ROOT`
(`$(SRCROOT)/ThirdParty/prebuilt/$(ORBIT_ENGINE_CONFIG)`), the version values,
and `FRAMEWORK_SEARCH_PATHS`/`HEADER_SEARCH_PATHS` pointed at the installed
`Orbit Framework.framework`. It still wires no `OTHER_LDFLAGS`/link-time
dependency on the framework: every process, including the browser-side Swift
app, loads it at runtime rather than linking it (see the process-and-sandbox
design note, section 1.4, on why even the never-sandboxed browser process
should stay a `dlopen()` shape), so there is nothing to link against yet, only
something to embed and later load. `ChromiumTests.xcconfig` is an include of
it: a test bundle inherits `ORBIT_ENGINE_CONFIG` from the configuration it is
built in, which is the same one its host app embedded.

---

## Engine bridge

`Chromium/Embedder/` (above) is the *engine side*: the framework and the helper
bundles Orbit.app loads. The *browser side* -- the Swift code in Orbit.app that
loads "Orbit Framework.framework", drives `OrbitMain`/`ContentMain`, and turns
`WebContents` into what a `BrowserEngine` conformance needs -- lives at
`Orbit/Engine/Chromium/` and is ongoing work: process/sandbox model,
entitlements per process, and how tabs render are all still open. One piece
should be treated as a draft to revise, not settled fact:

- `Scripts/release_manager.py`'s five-role signing table (browser, utility,
  renderer, GPU, alerts) and matching `Orbit/Resources/*.entitlements` files --
  the role *names* already match what `Chromium/Embedder/BUILD.gn`'s helper
  bundles produce (see above), but the table's `options`/signing-order
  rewrite in the process-and-sandbox design note, section 3.3, has not
  landed, and `Scripts/assemble-engine-bundle.sh` (design note section 4.5) is
  separate, larger follow-on work than `Scripts/embed-chromium-framework.sh`'s
  local-dev embed step above.
