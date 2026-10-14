# KVM Dashboard: Rebuild Prompt

Paste everything below the line into a new Claude Code session, started in an empty folder (for example `~/Documents/GitHub/KVM`). It contains all the requirements, the design decisions, and the problems already solved, so the app can be rebuilt in one pass.

---

Build me a native macOS app called **KVM Dashboard** that shows several GL.iNet Comet KVM (GLKVM) web consoles in one window. It's for my home lab, where each ESX host has its own KVM. Build it, install it to /Applications, and leave it ready to use.

## My environment

- macOS 27 on Apple silicon. **Only the Xcode Command Line Tools are installed, not Xcode.** Rust is not installed.
- Four GL.iNet Comet KVMs (RM1 and RM1V2, firmware V1.10.1). Their web consoles are:
  - ESX-01 → `https://192.168.100.141/#/`
  - ESX-02 → `https://192.168.100.142/#/`
  - ESX-03 → `https://192.168.100.143/#/`
  - ESX-04 → `https://192.168.100.144/#/`
- Each KVM uses a **self-signed HTTPS certificate** and **requires a login**. I will log in to each pane myself. Never ask for the password, and never store credentials in code, config, or docs.
- Your sandboxed shell may not reach the 192.168.100.x LAN. If you need to test a KVM, run `curl` in my Terminal panel instead.

## Decisions already made (don't re-try these)

1. **Not a static web page with iframes.** I tried this. The panes stay blank. The KVMs send no X-Frame-Options or CSP headers. The real cause is the login: inside an iframe on another origin, the GLKVM session cookies and storage are third-party and get blocked, so the app never renders.
2. **Not Tauri.** Rust isn't installed, and Tauri makes it hard to accept self-signed certificates.
3. **Native SwiftUI + WKWebView**, built with `swiftc` from the Command Line Tools. No Xcode project.
4. **Don't use `@State` or any other SwiftUI macro.** The Command Line Tools don't ship the `SwiftUIMacros` plugin, so `@State` fails to compile ("external macro implementation type 'SwiftUIMacros.StateMacro' could not be found"). Use a tiny generic `final class Box<Value>: ObservableObject { @Published var value: Value }` held with `@StateObject`. `@StateObject`, `@ObservedObject`, `@EnvironmentObject`, `@FocusState`, and `@Binding` all work.
5. **Compile in Swift 5 language mode** (`-swift-version 5`), with zero warnings.

## Project layout

```
KVM/
├── README.md
├── .gitignore                 # mac/build/ and .DS_Store
├── docs/images/kvm-dashboard-icon.png
└── mac/
    ├── build.sh
    ├── Info.plist
    ├── AppIcon.icns
    ├── Sources/KVMDashboard.swift   # whole app, one file
    └── tools/
        ├── make-icon.swift
        └── make-icon.sh
```

## Build script (`mac/build.sh`, zsh, `set -euo pipefail`)

- Create `mac/build/KVM Dashboard.app/Contents/{MacOS,Resources}`.
- Compile with `swiftc -O -swift-version 5 -parse-as-library -target "$(uname -m)-apple-macos14.0" Sources/*.swift -o ".../MacOS/KVMDashboard"`.
- Copy `Info.plist` and `AppIcon.icns` into the bundle.
- Ad-hoc sign with `codesign --force --sign -`.

## Info.plist

- Name and display name: `KVM Dashboard`. Executable: `KVMDashboard`.
- **Bundle ID `com.vcrocs.kvmwall`.** Keep this exact ID. The existing install's settings and logins are stored under it.
- `CFBundleIconFile` = `AppIcon`. `LSMinimumSystemVersion` 14.0. `NSHighResolutionCapable`.
- `NSLocalNetworkUsageDescription`: without it, macOS blocks connections to the LAN KVMs.
- `NSMicrophoneUsageDescription` and `NSCameraUsageDescription`, because the KVM console can use the microphone.
- `NSAppTransportSecurity` → `NSAllowsArbitraryLoadsInWebContent` = true.

## App behaviour

### Model and persistence

- `KVM { id: UUID, name, url, enabled }`.
- `Config { kvms, layout, theme, showURL }` with the four defaults above. Save it as JSON in UserDefaults under key `kvm-wall-config-v1`, and keep that key name.
- Layouts: `2 × 2` (default), `1 row`, `1 column`, `Auto` (1 → 1 column, ≤4 → 2, ≤9 → 3, else 4). Pad incomplete rows with empty cells so tiles stay equal width.
- Themes: `Dark` (default), `Light`, `System`. Apply the theme by setting `NSApp.appearance` (darkAqua, aqua, or nil) so the WebKit pages get the matching `prefers-color-scheme` too.

### Web views

- Subclass `WKWebView` as `KVMWebView`, which is also its own navigation and UI delegate and an `ObservableObject` with `@Published loaded` and `errorText`.
- Configuration:
  - `websiteDataStore = .default()`, so logins persist between launches.
  - `mediaTypesRequiringUserActionForPlayback = []`.
  - `isElementFullscreenEnabled = true`.
  - `applicationNameForUserAgent = "Version/18.0 Safari/605.1.15"`.
  - `isInspectable = true`.
  - Turn off background drawing.
- **Certificate trust:** in `didReceive challenge`, accept `NSURLAuthenticationMethodServerTrust` only when the challenge host equals that pane's configured host. Use default handling for everything else.
- Track load state from `didFinish`, `didFail`, and `didFailProvisionalNavigation`, ignoring `NSURLErrorCancelled`.
- Grant microphone and camera requests only from the configured host. Otherwise prompt.
- Open `target=_blank` links in the default browser.
- Show JavaScript `alert` and `confirm` as `NSAlert`, since the KVM uses confirm dialogs for actions like reboot.
- **Cache one web view per KVM id in the store**, and recreate it only if that KVM's URL changes. Host it with an `NSViewRepresentable` container that re-parents the cached web view. This way, re-ordering, changing layout, or maximizing never reloads a console or logs out of it. Remove web views for deleted or hidden KVMs.

### Main window

- A single `Window("KVM Dashboard", id: "dashboard")` scene with default size 1600×1000 and minimum 800×500. The app quits when its last window closes.
- Toolbar:
  - A segmented Theme picker.
  - A Reload All button.
  - `SettingsLink` (gear icon).
- Each pane has a 30 pt header and the console below it on a black background. The header holds:
  - A status dot: green when loaded, grey while loading, red on error.
  - The bold host name.
  - A **⌘N tile badge** (N = position among enabled KVMs, 1–9). Its tooltip explains ⌘N and ⌘0.
  - The URL in muted caption text, if enabled.
  - Four icon buttons: Reload (`arrow.clockwise`), Open in browser (`arrow.up.right.square`), Maximize / Back to grid (`square` / `rectangle.grid.2x2`), and Full screen (`arrow.up.left.and.arrow.down.right`).
- **Hover on the header icons:**
  - Highlight the icon in primary blue, with an 18% tinted rounded background and a 60% primary border.
  - Show the pointing-hand cursor.
  - Show the action name in primary-coloured caption text in the header, just left of the icons.
  - Keep the standard `.help` tooltip as well.
- An error overlay shows the message with a Retry button.
- **Maximize** shows only that pane in the window.
- **Full screen:** maximize the pane, then call `window.toggleFullScreen`.
  - Hide the pane header and padding while in full screen.
  - Show an "Exit Full Screen" button in the top-right of the pane on hover.
  - On `NSWindow.didExitFullScreenNotification`, clear the full-screen and maximized state.

### Keyboard shortcuts

- **⌘1–⌘9:** fill the window with tile N. Pressing the same key again returns to the grid. In full screen, the shortcut switches which console is shown and stays in full screen. Beep if no tile N exists.
- **⌘0:** return to the grid, exiting full screen if needed.
- **⇧⌘R:** Reload All. **⌘,** opens Settings.
- **Implement ⌘0–⌘9 with `NSEvent.addLocalMonitorForEvents(matching: .keyDown)`.** Check that the modifiers (device-independent) are exactly `.command`, then consume the event. This is required because a focused KVM console captures keystrokes and would swallow normal menu key equivalents.
  - To avoid the "NSEvent is not Sendable" warning, compute a Bool inside `MainActor.assumeIsolated` and return `nil` or the event outside it.
- Also list the shortcuts in the View menu (`CommandGroup(after: .toolbar)`): "Reload All KVMs", "Show All Tiles" (⌘0), and "Fill Window with <name>" (⌘1…⌘9).

### Settings scene (⌘,)

- A `List` of KVM rows. Each row has:
  - A drag handle (`.onMove` to reorder).
  - Name field.
  - URL field, which commits on Return or when focus is lost, so typing doesn't reload the console on every keystroke.
  - A Show toggle.
  - ▲▼ buttons.
  - A trash button.
- An **Add KVM** button.
- Segmented Layout picker, segmented Theme picker, and a "Show URL in pane header" toggle.
- Export… and Import… the config as JSON, via `NSSavePanel` / `NSOpenPanel`, pretty-printed with sorted keys, default filename `kvm-dashboard-config.json`.
- **Reset to Defaults.**

### Theme colours (VMware Clarity / Aria Operations)

Build dynamic colours with `NSColor(name:dynamicProvider:)` using `bestMatch(from: [.darkAqua, .aqua])`.

| Token | Light | Dark |
| --- | --- | --- |
| bg | `#fafafa` | `#1b2a32` |
| surface | `#ffffff` | `#21333b` |
| border | `#cccccc` | `#485764` |
| text | `#313131` | `#e9ecef` |
| muted | `#666666` | `#adbbc4` |
| primary | `#0072a3` | `#49afd9` |
| success | `#3c8500` | `#60b515` |
| danger | `#c21d00` | `#f54f47` |

Panes have a 4 pt corner radius, a 1 pt border, and a 6 pt gap between them.

## App icon (keyboard and mouse)

`mac/tools/make-icon.swift` draws a 1024×1024 PNG with AppKit:

- A macOS icon tile: 824 pt rounded rect inset 100 pt, radius 185.
- A drop shadow, and a vertical gradient from `#2a4250` to `#0f171c`.
- A 6 pt border in `#49afd9` at 35% opacity, plus a soft radial `#49afd9` glow.
- The SF Symbol `keyboard` in `#49afd9`, 520 wide at (153, 420).
- `computermouse` in `#e9ecef`, 175 wide, 22 pt to the right of the keyboard and sitting on its baseline.
- A heavy 132 pt "KVM" wordmark in `#e9ecef`, centred at y = 235.

`mac/tools/make-icon.sh` compiles that script, renders the PNG, builds an iconset (16–512 at @1x and @2x) with `sips`, runs `iconutil -c icns` to make `mac/AppIcon.icns`, and copies the PNG to `docs/images/kvm-dashboard-icon.png`. **Show me the rendered PNG** and check that the content is vertically balanced on the tile.

## Docs

Write `README.md` with these sections:

- Centred icon and title.
- "Why this exists", linking my hardware post: https://www.vcrocs.info/home-lab-glinet-comet-kvm.html
- Features.
- A requirements table.
- Build and install, cloning from `https://github.com/dalehassinger/KVM.git`.
- First run: allow Local Network, log in to each pane, set the URLs in Settings.
- Using the dashboard: a pane-icon table, a shortcuts table including ⌘0–⌘9, Settings, and an example export JSON.
- Home lab tips: DHCP reservations, naming panes after hosts, powering each KVM from a neighbouring host's USB port, remote access over Twingate/VPN, and setting EDID.
- "Why a native app and not a web page?"
- Troubleshooting:
  - Local Network permission.
  - `curl -kI`.
  - `killall Dock` for a stale icon.
  - `defaults delete com.vcrocs.kvmwall` to reset.
  - Inspect Element.
- Project layout.
- A note that the build uses `Box` instead of `@State`.
- Credits.

## Finish

1. Run `mac/tools/make-icon.sh`, then `mac/build.sh`. The build must have zero warnings.
2. Quit any running copy, then install with `rm -rf "/Applications/KVM Dashboard.app" && cp -R "mac/build/KVM Dashboard.app" /Applications/`, and launch it.
3. Tell me to click **Allow** on the Local Network prompt and log in to each pane. Then ask me to test ⌘1–⌘4 and ⌘0 with the focus inside a console.
4. Don't commit or push until I ask. When I do, push to `main` on `https://github.com/dalehassinger/KVM`.
