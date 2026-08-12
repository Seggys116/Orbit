# OrbitTests

Orbit's test targets. Read this before adding a test, and before trusting a
green checkmark. There are **two** targets, split by whether a test needs a
real `Orbit.app` process to resolve `@testable import Orbit` against:

- **`OrbitTests`** (this folder) — host-less. No `TEST_HOST`. Real
  production code reaches it two ways: files with a small, shallow
  dependency graph are **symlinked** in (see "Symlinked reused sources"
  below); anything needing the real `AppEnvironment` singleton (too wide a
  dependency graph to symlink — the engine, `HistoryStore`, `DownloadStore`,
  `BoostStore`, `NoteStore`, `EaselStore`, `UIExtensionPoints`) instead
  belongs in `OrbitAppTests`.
- **`OrbitAppTests`** (`../OrbitAppTests/`) — hosted. `TEST_HOST` = built
  `Orbit.app`, `BUNDLE_LOADER` = the same, so `@testable import Orbit`
  resolves against the app's own compiled symbols directly — no file
  duplication needed for anything reached this way. There's no separate
  `OrbitAppTests/README.md`; this file documents both targets. See
  "OrbitAppTests: the hosted target" below.

## Running the tests

```
xcodebuild -project Orbit.xcodeproj -scheme Orbit -configuration Debug \
  -destination 'platform=macOS,arch=arm64' test
```

Or, from Xcode: select the **Orbit** scheme, `Cmd+U`. This runs both
`OrbitTests` and `OrbitAppTests`.

This never launches `Orbit.app` as a real, visible application — see
"OrbitAppTests: the hosted target" below for exactly how a *hosted* test
target avoids that, and "Why `OrbitTests` itself has no TEST_HOST" for why
most of this suite avoids the question entirely. `Scripts/app-launch-smoke`
is the one thing here that does launch it, and only it can catch a defect on
the real launch path.

### The live-engine suites are not in that run

`OrbitAppTests/Chromium*LiveTests.swift` start a real Chromium — a real browser
process, its helper processes, a window on screen — and skip themselves in the
command above. They have their own:

```
Scripts/live-engine-tests
Scripts/live-engine-tests --suite ChromiumMediaLiveTests
```

They are the only tests here that can observe real page behaviour, so a green
run of everything else is not evidence about the browser. Do not try to enable
them with `ORBIT_LIVE_ENGINE=1 xcodebuild test`: `xcodebuild` does not pass its
environment to a hosted test host, so that command skips them and still reports
success. The script writes the variable into the `.xctestrun` and then checks
that the expected number of tests actually executed;
`.github/workflows/live-engine.yml` runs it nightly, on demand, and on any pull
request labelled `live-engine`. `Scripts/live-engine-tests`' header has the
whole account.

### Nothing above launches the app a user launches

Every suite here, live ones included, runs inside an XCTest host: a different
principal class, a different `applicationDidFinishLaunching` order, and no
window-server session of its own. A crash on the AppKit window-creation path is
invisible to all of them, which is how
`[FATAL:allocator_shim_apple.cc(61)] Check failed: false. Oops! No zone found`
reached a user while 1722 unit tests and 155 live tests were green.

```
Scripts/app-launch-smoke                      both schemes, 5 launches each
Scripts/app-launch-smoke --attempts 10        for an intermittent crash
Scripts/app-launch-smoke --scheme Demo --skip-build
```

It launches `Orbit.app` and `OrbitDemo.app` through LaunchServices, repeatedly,
and fails unless every launch reached a painted page, wrote nothing to
`~/Library/Application Support/Orbit`, and quit cleanly. The app's half is
`Orbit/Core/AppSmokeProbe.swift`, inert without `ORBIT_SMOKE_PROBE=1`; the
stages and checks it declares are read back out of that source, so a run that
does less than the app claims to do cannot report success.
`.github/workflows/build-test.yml` runs it on every pull request.

## Why `OrbitTests` itself has no TEST_HOST

The obvious way to give a test bundle access to an app's real types is
`TEST_HOST` + `BUNDLE_LOADER`: Xcode launches the app, injects the test
bundle into its process, and `@testable import Orbit` resolves against the
running app's own symbols. `OrbitAppTests` (below) does exactly this. This
target (`OrbitTests`) deliberately does not, so that the large majority of
Orbit's tests — everything that doesn't specifically need the real
`AppEnvironment` — never depend on `Orbit.app` building or launching
correctly at all: `OrbitTests` has no dependency on the `Orbit` target,
literally cannot open a window or start the engine, and stays fast and
resilient to unrelated breakage elsewhere in the app.

So `OrbitTests` is a **logic-test bundle with no host application at all**
(no `TEST_HOST`, no `BUNDLE_LOADER` in its target settings — see
`Orbit.xcodeproj/project.pbxproj`). It never touches the `Orbit` executable,
directly or indirectly.

**The trade-off:** a no-host bundle can't `@testable import Orbit` — an app
executable's symbols simply aren't loaded into the plain `xctest` process a
host-less bundle runs in. Real production code reaches this target one of
two ways instead:

1. **Symlinked reused sources** (preferred for anything with a shallow
   dependency graph — see the next section) — the literal real file, picked
   up automatically by this folder's `PBXFileSystemSynchronizedRootGroup`,
   zero `project.pbxproj` edits.
2. **`PBXBuildFile`/`PBXFileReference` "reused Orbit sources"** (the
   original mechanism, still used for `BrowserStore*.swift`,
   `ModelTypes.swift`, the reused Sidebar views, etc. — see the table
   below) — the same real file, compiled a second time as an explicit
   member of this target's `Sources` build phase in `project.pbxproj`.

Either way, because the `.swift` file itself is byte-for-byte what ships in
the app, a real regression in it still fails these tests — nothing here is
a hand-typed re-implementation.

## Symlinked reused sources

**These are symlinks, not copies — do not "tidy" them into copies.** A copy
silently reintroduces exactly the mirror-test problem this whole
target-restructuring round of work existed to fix: a copy drifts out of
sync with the real file the moment the real file changes, and a test
against a stale copy can never catch a real regression again. If a symlink
ever looks broken (red in Xcode, "no such file" from `swiftc`), fix the
symlink (`ln -sf`) — never replace it with a copy of the file's current
contents.

| Folder | Symlinks into | Used by |
|---|---|---|
| `ReusedCommandBarSources/` | `Orbit/UI/CommandBar/*.swift` (`FuzzyMatcher`, `CommandBarModel`, `CommandResultRowView`, `RelativeTimeFormatter`, `SearchSuggestionsClient`) | `CommandBarRankingTests.swift`, `CommandBarRenderTests.swift`, `SearchSuggestionsClientTests.swift` |
| `ReusedControlsSources/` | `Orbit/UI/Controls/OrbitControlMetrics.swift`, `OrbitToggle.swift`, `OrbitButton.swift`, `OrbitScroller.swift` | `ControlsAndSettingsTests.swift`'s `ControlRenderTests`, `OrbitScrollerTests.swift` |
| `ReusedLibrarySources/` | `Orbit/UI/Library/LibraryComponents.swift`, `LibraryPalette.swift`, `DownloadThumbnail.swift` | `LibraryTests.swift`, `DownloadsFlyoutTests.swift` |
| `ReusedSpacesSources/` | `Orbit/UI/Spaces/SpaceSwipeGestureCatcher.swift` | `SpaceSwipeGestureCatcherTests.swift` |
| `ReusedSidebarSources/` | `Orbit/UI/Sidebar/SidebarResizeHandle.swift` | `SidebarResizeHandleTests.swift` |
| `ReusedAssistSources/` | `Orbit/Features/Assist/AskOnPageController.swift`, `AssistPrivacyDisclosure.swift`, `AssistProvider.swift`, `AssistRuntime.swift`, `AssistSettings.swift`, `ChatGPTCommandBar.swift`, `InstantLinkResolver.swift`, `LinkPreviewController.swift`, `LinkPreviewFetcher.swift`, `PageTextExtractor.swift` (all ten, verified against `ls -la OrbitTests/ReusedAssistSources/`) | `AssistProviderTests.swift`, `AssistRuntimeTests.swift`, `AssistPageTextAndSettingsTests.swift`, `AssistPrivacyDisclosureTests.swift`, `AskOnPageQuoteTests.swift`, `ChatGPTCommandBarTests.swift`, `InstantLinkResolverTests.swift`, `LinkPreviewControllerTests.swift`, `LinkPreviewFetcherTests.swift`, `LinkPreviewRuntimeTests.swift` |
| `ReusedCalendarSources/` | `Orbit/Features/LiveCalendars/LiveCalendarModels.swift`, `LiveCalendarStore.swift`, `LiveCalendarCountdownPill.swift` | `LiveCalendarTests.swift` |
| `ReusedGitHubLiveFolderSources/` | `Orbit/Features/GitHubLiveFolders/GitHubLiveFolderModels.swift`, `GitHubLiveFolderSource.swift`, `GitHubLiveFolderStore.swift` | `GitHubLiveFolderStoreTests.swift`, `GitHubLiveFolderSourceTests.swift`, `GitHubLiveFolderBackCompatDecodingTests.swift` |
| `ReusedUpdaterSources/` | `Orbit/Core/UpdaterPreferences.swift`, `UpdaterStatus.swift` (Sparkle-free halves of the in-app updater — `UpdaterController.swift` itself is `#if canImport(Sparkle)` and cannot be reached from any test target; see `UpdaterPreferencesTests.swift`'s header) | `UpdaterPreferencesTests.swift`, `UpdaterStatusTests.swift` |

Two notes on the Assist and Live Calendars sets, because both are the kind of
thing the next person will otherwise rediscover the hard way:

- `TidyTabTitlesCoordinator.swift`, `TidyDownloadsCoordinator.swift` and
  `LiveCalendarRowView.swift` are **deliberately not** symlinked — each reaches
  `AppEnvironment`, so per the rule above they belong in `OrbitAppTests`, and
  that is where `AssistCoordinatorTests.swift` and
  `TidyDownloadsCoordinatorTests.swift` live.
- `LiveCalendarCountdownPill` is in a file of its own purely so it *can* be
  symlinked. `FavoritesGridView.swift` draws it and is itself compiled into
  this target, so the pill has to be reachable here; keeping it beside
  `LiveCalendarJoinRow` (which reaches `AppEnvironment`) would have broken this
  target's build. Likewise `EventEmoji` sits in `LiveCalendarModels.swift`
  rather than next to the view that uses it.

Verified (not just assumed) to actually compile the real file: introducing a
deliberate syntax error into `Orbit/UI/CommandBar/FuzzyMatcher.swift` made
`OrbitTests` fail to build at the path
`OrbitTests/ReusedCommandBarSources/FuzzyMatcher.swift`, and reverting it
restored a clean build — confirming the compiler resolves the symlink to the
real file's current contents, not a stale snapshot. Re-run that check
yourself (temporarily, and revert immediately) if you're ever unsure a
symlink is doing what it looks like it's doing.

**Adding a new one:** if the file you need has a small, self-contained
dependency graph (a handful of `Orbit/**` files, no `AppEnvironment`, no
engine), symlink it in — `ln -s ../../Orbit/<path>/<File>.swift
OrbitTests/Reused<Something>Sources/<File>.swift` — rather than adding
`PBXFileReference`/`PBXBuildFile` entries to `project.pbxproj`, and rather
than hand-typing a mirror. If the file's dependency graph is wide (it pulls
in `AppEnvironment`, the engine, or another store), it belongs in
`OrbitAppTests` instead (below), not symlinked here.

## OrbitAppTests: the hosted target

`../OrbitAppTests/` is a **second** test target, `TEST_HOST` = the built
`Orbit.app`, `BUNDLE_LOADER` = the same — the standard Xcode mechanism for
giving a test bundle `@testable import Orbit` access to an app's real
compiled symbols. This exists specifically for tests that need the real
`AppEnvironment` singleton (`Orbit/Core/AppEnvironment.swift`) or a real
production view that reads `@Environment(AppEnvironment.self)` — its own
dependency graph (the engine, `HistoryStore`, `DownloadStore`, `BoostStore`,
`NoteStore`, `EaselStore`, `UIExtensionPoints`) is far too wide to compile a
second time into a host-less bundle the way `ReusedControlsSources/` etc.
do, so a hosted target is the only way to reach it with zero duplication.

**Why this doesn't launch the app.** A `TEST_HOST`-based test run genuinely
starts the `Orbit.app` process (visible briefly in `ps aux` as
`.../Orbit.app/Contents/MacOS/Orbit` while `xcodebuild test` runs — that's
inherent to how `TEST_HOST` works, not a bug) and runs its real
`NSApplicationDelegate.applicationDidFinishLaunching`. `OrbitAppDelegate`
(`Orbit/OrbitApp.swift`) guards the very first line of that method:

```swift
guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
```

`XCTestConfigurationFilePath` is set in the process environment by
Xcode/`xctest` exactly when — and only when — that process is hosting a test
bundle, so this guard is true precisely for a real, interactive launch and
false for every `TEST_HOST` run. With it in place, a hosted test run never
opens a window, never installs the menu bar, and never calls
`AppEnvironment.shared.startEngineIfNeeded()` — confirmed via `ps aux`
before/after a full `xcodebuild test` run showing no lingering `Orbit`/
`OrbitDemo` process or window. **Never remove or weaken this guard**; it is
the entire reason `OrbitAppTests` is safe to run in this project.

**What lives there:**

| File | Why it needs the hosted target |
|---|---|
| `AppEnvironmentSidebarTests.swift` | Drives `AppEnvironment.demo.perform(.toggleSidebar)` (D2) — needs the real `AppEnvironment`. |
| `AppEnvironmentSpacesTests.swift` | Drives `AppEnvironment.demo.perform(.nextSpace/.previousSpace)` (D3) and a scratch-rooted real `BrowserStore` for Space creation/deletion/reordering. |
| `AppEnvironmentWebContentsDelegateTests.swift` | Exercises `AppEnvironment`'s `WebContentsDelegate` callbacks (D4/D5) via the `#if DEBUG`-only `_test_attachWebContents` seam. |
| `SidebarRenderTests.swift` | Renders the real `SidebarBottomBar`/`TabRowView`/`SidebarTopRow`/`FavoritesGridView` (already compiled into `Orbit.app`, no reuse needed) against real `AppEnvironment.demo` (D5/D6/D8/D9). |
| `Support/MockWebContents.swift` | A `WebContents`/`EngineSession` test double (never a real engine backend) used by `AppEnvironmentWebContentsDelegateTests.swift`. |
| `ChromiumEngineTests.swift` | Tests the real `ChromiumEngine` — see "The Chromium backend in tests" below. |
| `RenderHarness.swift` | Symlink to `../OrbitTests/RenderHarness.swift` — one canonical copy, used by both targets. |

`AppEnvironment.demo` is a **factory**: every access builds a fresh instance
rooted at its own scratch directory under `NSTemporaryDirectory()`. It used
to be a process-wide `static let` shared across every `OrbitAppTests` file,
which made results order-dependent — each suite hand-restored whatever it
remembered touching, and anything it forgot leaked into whichever test ran
next. Tests now bind one per test method:

```swift
private lazy var env: AppEnvironment = AppEnvironment.demo
```

A stored `lazy var`, not a computed property: a computed one would hand out a
*different* environment on every `env.` access within a single test, so
nothing written through it could be read back. The Orbit Demo *app*, which
genuinely needs one stable environment for its whole launch, uses the
separate `AppEnvironment.demoApp` singleton instead.

The `OrbitAppTests` `TestableReference` in the `Orbit` scheme is
`parallelizable = "NO"`, so its tests run serially in one process. That
matters for the `#if DEBUG` `AppEnvironment.defaults` / `ShortcutRegistry
.defaults` seams: a test can point one at its own `UserDefaults(suiteName:)`
in `setUp()` and restore `.standard` in `tearDown()` without racing a sibling.
`OrbitTests` is `parallelizable = "YES"` — its classes run in **separate
`xctest` processes that share `UserDefaults.standard`** — which is why every
suite there that persists anything (`ShortcutRegistryTests`,
`ShortcutIdentityAndNamingTests`, `SettingsBindingRoundTripTests`) runs
against its own scratch suite rather than `.standard`. An assertion on a
`.standard` key in this project passes alone and fails in a full run.

**`OrbitTests/TestDoubles.swift`'s `AppEnvironment` double still exists** —
it's still used by `PinnedFolderRowRenderTests.swift`,
`R3SpacesAndSplitViewStoreTests.swift` and `CommandBarRankingTests.swift`,
none of which were rewritten in this round (see
`TestFileCoverageGuardTests.swift`'s documented exception for exactly why).
Converting those three to the real `AppEnvironment.demo` via `OrbitAppTests`
the same way `SidebarRenderTests.swift` was is the natural next step, but
belongs to whichever agent owns each of those files' areas.

## Two process-wide hazards every render/window test must respect

`OrbitAppTests` is `parallelizable = "NO"`: **every class in it runs serially
in one process**. Two things therefore leak across suite boundaries unless
they are handled deliberately.

### 1. A window left behind kills the whole run, and blames the wrong test

`OrbitAppTests/WindowControllerResizeRegressionTests.swift` builds a real
`OrbitBorderlessWindow` through the production path. It used to call only
`window.close()`, which does **not** dismantle a window — the real
`NSHostingView` stays installed as its `contentView`. Every later SwiftUI
render anywhere in the process then drove another
`NSHostingView.setNeedsUpdate()` -> `-[NSView setNeedsUpdateConstraints:]` ->
`-[NSWindow _postWindowNeedsUpdateConstraints]` into that abandoned window
until AppKit exceeded its per-window pass limit and threw an **uncaught**
`NSGenericException`. An uncaught exception terminates the `xctest` process,
and XCTest attributes the termination to whichever test was executing at that
instant — so the reported failure named a different, innocent test every run
(`ScreenshotGenerationTests`, `SidebarMiniPlayerTests`, `ChromiumEngineTests`,
`PaneHeaderColorResolverTests` and `BrowserImportCoordinatorTests` were each
blamed at least once). It read as flakiness; it was one leaked object.

**If a test builds a real `NSWindow`, dismantle it in `tearDown`:** order it
out, drop the delegate, **clear `contentView`** (this is the step that makes
the hosting view unreachable, and the one `close()` never did), unhook it from
its controller, close it, release the references. See that file's
`tearDownWindow()`.
`WindowControllerResizeRegressionTests.test_noAbandonedHostingViewIsLeftInAnyWindow`
asserts this **across every window in the process**, so a reintroduction
anywhere fails under a name that says what is wrong.

### 2. `ImageRenderer` caches bitmaps by view type and size

`ImageRenderer` serves a cached bitmap keyed by (at least) the rendered view's
type and the proposed size, from a process-wide cache that outlives the
`ImageRenderer` instance. A second `render(SomeView(...), size: s)` later in
the same process could be handed the *first* call's image — including one
produced by a different test method in a different suite. It was measured, not
theorised: a test rendering an empty view reproducibly got back the previous
test method's bitmap, confirmed by dumping the image. `.id(UUID())`, rendering
twice, and `renderForScreenshot`'s settle passes all failed to defeat it.

A render test served a stale bitmap does not error — it quietly asserts on a
different view's pixels and **passes**. Across `OrbitAppTests` that exposed 30
render call sites in 13 files, spanning 92 test methods, all in one process.

`RenderHarness.swift` now handles this centrally, so no individual test has to:
every `render(_:size:)` and `renderForScreenshot(_:size:)` lays the view out at
exactly the requested `size` but places it top-leading inside a slightly
larger, **per-call-unique** frame, then crops the padding back off before the
bitmap reaches `RenderedImage`. No two renders in a process share a cache key,
and callers see no difference — the returned bitmap is exactly
`size * scale` pixels, with the view's origin still at (0, 0).
`OrbitAppTests/RenderHarnessCacheTests.swift` is the regression test: it
renders one view *type* at one size twice with different content and asserts
the second render is its own, plus asserts the crop is exact across several
consecutive (differently padded) renders.

**Do not work around this in an individual test** by inventing a unique size —
that shifts every point-space assertion in the test. It is already handled.

## The Chromium backend in tests

Nothing links the engine at compile time. `OrbitChromiumBridge` `dlopen`s
"Orbit Framework.framework" out of the host app bundle at runtime, so a test
target needs no engine build settings of its own — `Chromium/ChromiumTests.xcconfig`
is just an include of `Chromium/Chromium.xcconfig`.

**`OrbitAppTests` is where Chromium coverage belongs.** It is hosted by the
real `Orbit.app`, which carries the framework and its helper apps in its own
bundle, and it reaches every engine type through `@testable import Orbit`.

**`OrbitTests` must stay host-less.** It compiles a *curated* set of real
sources (see the two tables above); `Orbit/Engine/Chromium/` is not in it and
should not be added. A host-less `xctest` process has no app-bundle layout
with the helper apps beside it to `dlopen` against, so making it work would
mean rebuilding an app inside a logic-test bundle. This target has already
produced a `SIGSEGV` when given real windows — see
`../OrbitAppTests/WindowControllerResizeRegressionTests.swift`'s header.

**No test in the ordinary run starts a browser.** `OrbitAppDelegate` bails out
under `XCTestConfigurationFilePath` precisely so no engine is brought up during
`xcodebuild test`. Navigation, rendering, cookies, caches and
`ChromiumWebContents` are covered only by the live-engine suites above.

## Reused Orbit sources (PBXFileReference mechanism)

The files reused this way, and why each one is safe to compile standalone
(no engine, no window, no network unless explicitly noted):

| File | Why it's included |
|---|---|
| `Orbit/Models/ModelTypes.swift` | The whole document model (`Tab`, `Space`, `Profile`, …). Pure value types. |
| `Orbit/Models/PinnedNodeTree.swift` | Pinned-folder-tree algorithms `BrowserStore+Folders.swift` uses. |
| `Orbit/Models/BrowserStore*.swift` (all 6) | The real store under test in `StoreTests.swift`. |
| `Orbit/Persistence/StateStore.swift`, `SchemaMigration.swift` | `BrowserStore`'s persistence, pointed at a scratch temp directory per test — never the real `~/Library/Application Support/Orbit/State/`. |
| `Orbit/Core/DesignTokens.swift` | `OrbitMetrics`/`OrbitFont`/`OrbitMotion` — what `LayoutMetricsTests.swift` checks. |
| `Orbit/Engine/BrowserEngine.swift`, `EngineTypes.swift` | The `WebContents` protocol and its value types (`NavigationState`, `MediaState`, …) `TabRowView` and `ModelTypes.swift` (`DownloadItem`) need. Protocol declarations only — no engine conformance is compiled in. |
| `Orbit/UI/Theme/ThemeBackgroundView.swift`, `GrainTexture.swift`, `ThemeSelfCheck.swift` | `SpaceTheme.readableForeground`/`readableSecondaryForeground`, which every sidebar row reads. `GrainTexture`/`ThemeSelfCheck` are pulled in only because they live in files these extensions sit next to; neither is exercised by anything in this target. |
| `Orbit/Persistence/FaviconCache.swift`, `Orbit/UI/Sidebar/FaviconView.swift` | `TabRowView`'s favicon. Falls back to a generated tile with no favicon URL — the synthetic tabs in these tests never trigger a real network fetch. |
| `Orbit/UI/Sidebar/SidebarDragDrop.swift` | `SidebarDragPayload`, used by `FavoritesGridView`'s drag/drop. |
| `Orbit/UI/Sidebar/TabHoverPreviewView.swift`, `Orbit/UI/Spaces/MoveTabToSpaceMenu.swift` | Small real views `TabRowView`'s popover/context menu reference. |
| `Orbit/Core/ShortcutRegistry.swift` | `ShortcutCommandID`, the enum `AppEnvironment.perform(_:)` takes. |
| `Orbit/UI/Sidebar/SidebarBottomBar.swift`, `TabRowView.swift`, `SidebarTopRow.swift`, `FavoritesGridView.swift` | **The actual views under test** for D5/D6/D8/D9 — compiled exactly as they ship. |

**Not reused, faked instead** (`TestDoubles.swift`) — each is a small,
clearly-documented double, not a re-implementation of logic under test:

- **`AppEnvironment`** — the real one (`Orbit/Core/AppEnvironment.swift`) is
  a hard `@MainActor` singleton (`static let shared`, `private init()`) that
  owns the live engine/history/download stores. `TestDoubles.swift` declares
  its own class with the *same name*, marked `@Observable`, implementing only
  the members the five reused view files above actually call. If a future
  edit to one of those files calls an `env.` member this double doesn't have,
  the **build fails** with a normal "has no member" error — that's the
  signal to add the matching member here.
- **`SpaceSwitcherPagerView`** — the real one pulls in `SpaceEditPopover`
  (icon chooser, theme editor) and a custom environment key, none of which
  D5/D6/D8/D9 need; D7 (the switcher's own look) is explicitly out of this
  target's required scope. The double draws one dot per Space from the same
  `env.spaces`/`env.activeSpace` `AppEnvironment`'s double already has.
- **`LibraryWindowController`** — the real one opens an `NSWindow`. Only
  ever referenced from a button/menu *action* in the reused views, never
  during `body` evaluation, so a no-op is exactly correct here.
- **`SplitEdge`** — a 4-case enum mirrored from `Orbit/Core/AppEnvironment+SplitView.swift`,
  needed only so `TabRowView`'s `TabContextMenu` menu-action closures
  type-check.

If this trade-off ever needs revisiting (e.g. once the app gains a
`XCTestConfigurationFilePath`-style launch guard, making a real `TEST_HOST`
setup safe), the fix is entirely inside `OrbitTests/**` and
`project.pbxproj` — nothing under `Orbit/**` needs to change to switch back.

## What `RenderHarness.swift` can assert

`render(_:size:appearance:scale:)` rasterises any SwiftUI view off-screen via
`ImageRenderer` — no `NSWindow`, no launch. It returns a `RenderedImage`:

- `color(atX:y:) -> RGBA` — one pixel, by **point** coordinate (origin
  top-left, same space as the `size:` you rendered at).
- `averageColor(in: CGRect) -> RGBA` — mean colour over a point-space
  rectangle.
- `containsNonBackgroundPixels(in:background:tolerance:) -> Bool` — "is
  anything drawn here that isn't just the background" — the building block
  for "does this control exist" (D6, D9).
- `boundingBoxOfContent(tolerance:) -> CGRect?` — tightest rect enclosing
  every non-background pixel; `nil` if nothing was drawn.
- `writeDiagnosticPNG(named:) -> URL?` — dumps the image to
  `NSTemporaryDirectory()/OrbitTests-Diagnostics/<name>.png` **and prints
  that resolved path to the console** (`NSTemporaryDirectory()` is a
  per-user, per-machine path under `/var/folders/...` — not literally
  `/tmp` — so the printed line is the only reliable way to find the file).
  Every render test in `SidebarRenderTests.swift` calls this right before a
  failing assertion, so a red test always leaves a PNG behind and logs where.

**Coordinate mapping:** every method above takes points, not pixels.
Internally the backing `NSBitmapImageRep` is `size * scale` pixels (`scale`
defaults to 2.0, i.e. a standard Retina backing); each method multiplies
your point coordinate by `scale` before sampling. Reason in the same units
`OrbitMetrics` does and you'll never need to think about the backing scale
factor directly.

`RGBA` is `(r, g, b, a)` in `0...1`, with `isApproximately(_:tolerance:)` for
fuzzy comparison (bitmap round-trips introduce ~1-unit rounding noise).

## Reading a failing render test / diagnostic PNG

1. Look for a `RenderHarness: wrote diagnostic PNG to <path>` line in the
   test's console output (Xcode's Report Navigator, or `xcodebuild test`'s
   stdout) — that's the real, resolved path under `NSTemporaryDirectory()`.
2. Open it (`open <path>`). It's exactly the pixels the assertion inspected,
   at the exact size the test rendered at — no window chrome, no extra
   padding.
3. Cross-reference the region the test named (most assertion messages spell
   out the `CGRect` or colour in point space) against what you see.
4. If the view's layout genuinely changed on purpose, update the test's
   expected geometry *and* update `docs/ARC_VISUAL_REFERENCE.md`/
   `docs/DEFECTS.md` if the change contradicts a documented measurement —
   don't just loosen the tolerance until it's green.

## Adding a new render test

1. If the view you want to test is already compiled into this target (see
   the table above), just `render(YourView(...).environment(AppEnvironment()), size: ...)`.
2. If it isn't yet, add it as an extra `Compile Sources` member of the
   `OrbitTests` target in Xcode (Target Membership checkbox in the File
   Inspector — do **not** touch its membership in the `Orbit` target) or by
   hand in `project.pbxproj`, following the existing `PBXFileReference`/
   `PBXBuildFile` pairs under the `OrbitTests: reused Orbit sources` comment.
   Run `plutil -lint Orbit.xcodeproj/project.pbxproj` after any manual edit.
3. Fix whatever compile errors that surfaces — almost always a missing
   `AppEnvironment` member (add it to `TestDoubles.swift`, matching the
   *shape* of the real one) or a further real dependency worth reusing too.
4. Write the assertion against `RenderedImage`, citing the exact
   `docs/DEFECTS.md` item and/or `docs/ARC_VISUAL_REFERENCE.md` measurement
   it encodes, the way every existing test here does.
5. Confirm it fails against the broken behaviour (temporarily revert the
   relevant `Orbit/**` fix locally, or check out the pre-fix commit, run the
   test, confirm red) before trusting it as a regression guard, then restore
   the fix.

## `StoreTests.swift`: what it does and doesn't cover

Every `StoreTests` case builds its own `BrowserStore` against a fresh
`StateStore(rootDirectory:)` under a per-test scratch directory in
`FileManager.default.temporaryDirectory`, cleaned up in `tearDown()`. **No
test in this file can read or write the real user's
`~/Library/Application Support/Orbit/State/state.json`.**

`BrowserStore.init` runs `bootstrapIfNeeded()`, which seeds one Profile and
one Space when the document is empty — every test starts from
`store.activeSpace!` rather than an empty document, matching first-run
behaviour.

## Known-passing / known-failing right now

See the top-level report for the current pass/fail table — it will drift as
other agents land fixes concurrently in `Orbit/**`; re-run the suite rather
than trusting a stale table.
