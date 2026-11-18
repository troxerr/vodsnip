# Vodsnip

A native macOS app in SwiftUI. It runs on this Mac only, with a local
SwiftData database and no server.

## Layout

- `Sources/Vodsnip/` the app. `App.swift` has the window, menus, and the database location.
- `Sources/VodsnipKit/` rules and data logic with no SwiftUI. Tests in `Tests/VodsnipKitTests/`.
- `Package.swift` a Swift package. There is no Xcode project.
- `build.sh` builds, signs, and installs `~/Applications/Vodsnip.app`.
- `Icon/AppIcon.icon` the app icon, an Icon Composer file (JSON plus SVG layers). `build.sh` compiles it with `tools/make_icon.sh`; `tools/icon_review.sh` renders every look into one PNG.
- `docs/` the brief, the screen index, and the user stories, when they exist.

## Build and check

- Build and install: `./build.sh`. Add `--open` to restart the app with the new build. The build shows warnings; fix them.
- Unit tests: `swift test --scratch-path ~/Library/Developer/Vodsnip/test-build`.
- Self-test (the app's real functions on a /tmp store): `tools/selftest.sh`. Exit 0 when every check passes. Add a check for every story with logic in `SelfTest.swift`.
- After every UI change, take snapshots with sample data and look at them: `tools/snap.sh`.
  It writes `/tmp/Vodsnip-shots/<page>-light.png` and `-dark.png` for every sidebar page, and `settings-<tab>-light.png` and `-dark.png` for every Settings tab, then quits. `APP_SNAPSHOT_PAGES=all,settings tools/snap.sh` limits the pages.
  For a panel, sheet, or popover, add a capture to `Snapshot.swift` like the Settings loop.
- Snapshots, seed data, and the self-test refuse to run without `APP_STORE` in /tmp.
- Never test against the real database in `~/Library/Application Support/Vodsnip/`.
- Then check the grid: `tools/grid-lint.sh` and `swift tools/check-layout.swift /tmp/Vodsnip-shots/*-layout.json`. Both print PASS.
- A change is done when the build has no errors, the grid checks pass, and you looked at the light and dark snapshots.

## Design rules

- Use Apple's controls and system styles. Only the accent color is custom: `UI/Theme.swift` (`ThemeStore.defaultID`). People change it, and light or dark mode, in Settings > Appearance.
- Views use `.tint`, `Palette.accent`, `Palette.accentText` (accent-colored text), and `Palette.onAccent` (text on an accent fill). Never hard-code colors, radii, or durations in views.
- Compare accents: add `APP_ACCENT=<id>` to the snapshot command.
- Spacing comes from `Space` in `UI/Grid.swift`, on a 4 pt grid. Mark custom pages and cards with `.gridArea` and `.gridProbe`.
- Windows open calm: `.noInitialFocus()` on every window and sheet (no focus ring or selected text on open), `.fitsContent()` on sheets and Settings tabs (no scroll bar with nothing to scroll). System scroll bars. Both in `UI/WindowBehavior.swift`.
- Settings: one tab per topic in `SettingsView.swift`, one grouped Form per tab. Add a case to `SettingsTab` for a new tab.
- Window chrome (title bar, toolbar, sidebar, menus, sheets) stays system. Buttons use system styles, like `.borderedProminent`.
- Colors: `.primary`, `.secondary`, `.tint`, and system colors. Never fixed grays or white for text.
- Every action has a menu bar item and a keyboard shortcut.
- `Label` for icon and text pairs. SF Symbols for icons.
- `ContentUnavailableView` for empty states.
- Liquid Glass belongs to floating controls only, never to content.

## Skills

The bama plugin has a skill for each step: `mac-design` (design rules),
`design-system` (accent and tokens), `layout-grid`, `ux-design`,
`swift-swiftui`, `os-integrations`, `performance`, `build-and-verify`,
`test-mac-app`, `app-icon`, `user-stories`, and `improve-loop`. Use them.

## Git

- Commit after each working change, with a message that says what the user can now do.

## Releasing
- `tools/fetch_vendor.sh` puts the official yt-dlp in `vendor/bin` (git ignores it). Rerun it for every release: Twitch changes break old yt-dlp builds. ffmpeg and ffprobe come from `tools/build_ffmpeg.sh`, an LGPL-only build from the official source (ready-made static builds bundle GPL codecs). Mention FFmpeg and the LGPL in About or on the site.
- `tools/release.sh` builds `dist/Vodsnip-<version>.dmg`. With a Developer ID certificate and `NOTARY_PROFILE` it signs with the hardened runtime, notarizes and staples. Without them it builds an ad hoc DMG that runs on this Mac only.
- The app looks for its tools in `Contents/Resources/bin` first, then Homebrew and PATH.

## Windows app (`windows/`)
- Tauri 2: Rust backend in `windows/src-tauri/src` (the same download logic as `Sources/VodsnipKit`, ported, with tests: `cd windows/src-tauri && cargo test`), plain HTML/CSS/JS front end in `windows/src`.
- Run it on a Mac for UI and download checks: `cd windows && npx tauri dev`. Test hooks: `VODSNIP_URL=<link> VODSNIP_MODE=range VODSNIP_AUTO=download,cancel:20`.
- The Windows installer is built by `.github/workflows/windows.yml` on a Windows runner (tests, tool download with checksums, installer, silent-install check, installer as a download). The runner fetches `yt-dlp.exe` and an LGPL `ffmpeg.exe` itself. Not yet run.

## Mac release in CI (`.github/workflows/mac-release.yml`)
Runs `tools/release.sh` on a macOS 26 runner (manual, or on a `v*` tag). Needs secrets `MACOS_CERT_P12` (base64), `MACOS_CERT_PASSWORD`, `APPLE_ID`, `APPLE_APP_PASSWORD`, `APPLE_TEAM_ID` to sign and notarize; without them it builds an ad hoc DMG and attaches no release. macOS runner minutes cost 10x on private repos.
