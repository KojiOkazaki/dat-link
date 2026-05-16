---
name: meta-rayban-display
description: Use when building or extending an iOS app for Meta Ray-Ban Display glasses via the Meta Wearables Device Access Toolkit (DAT) v0.7+. Covers MWDATDisplay setup, FlexBox composition, DeviceSession lifecycle, Info.plist requirements (DAMEnabled, MWDAT block), universal links, AASA hosting, MockDeviceKit testing, and known firmware/SDK gotchas. TRIGGER when the user mentions Meta Ray-Ban Display, MWDATDisplay, Wearables.shared, addDisplay, display.send, FlexBox glasses HUD, scene-description-to-glasses, or wants to extend an iOS app to render onto smart glasses.
---

# Meta Ray-Ban Display iOS Development

This skill covers everything needed to build an iOS app that renders content onto the Meta Ray-Ban Display via the Wearables Device Access Toolkit (DAT) v0.7+.

## When to use

- Adding glasses-HUD output to an existing iOS/SwiftUI app
- Starting a new Display-only or Display+Camera app
- Migrating an app from DAT 0.4 (StreamSession) to 0.7 (DeviceSession + Stream)
- Debugging session, registration, or rendering failures
- Composing FlexBox / Text / Icon / Button layouts for the glasses display

## Quick orientation (read first)

DAT 0.7 splits into modules:

| Module | Purpose |
|---|---|
| `MWDATCore` | Registration, `Wearables.shared`, `DeviceSession`, errors |
| `MWDATCamera` | `Stream` capability — video frames, photo capture |
| `MWDATDisplay` | `Display` capability — `FlexBox` UI tree, `VideoPlayer` |
| `MWDATMockDevice` | `#if DEBUG` mock pairing without hardware |

The runtime shape is:

```
Wearables.shared
  → AutoDeviceSelector(wearables:filter:)
    → wearables.createSession(deviceSelector:) → DeviceSession
      → session.start()
      → session.addStream(config:) → Stream      (camera path)
      → session.addDisplay()       → Display     (HUD path)
        → display.start()
        → try await display.send(FlexBox { ... })
```

You can attach **both** `Stream` and `Display` capabilities to one `DeviceSession` to do "camera in → analysis → HUD out" in a single session.

## Project setup checklist

### 1. SPM dependency

In Xcode → File → Add Package Dependencies → `https://github.com/facebook/meta-wearables-dat-ios` → pin to **0.7.0+**.

Link these products to the app target:
- `MWDATCore` (always)
- `MWDATDisplay` (for HUD output)
- `MWDATCamera` (for camera streaming)
- `MWDATMockDevice` (DEBUG only)

### 2. Info.plist

Add the `MWDAT` block. **`DAMEnabled` is mandatory for Display.**

See `templates/Info.plist.fragment.xml`.

```xml
<key>MWDAT</key>
<dict>
    <key>AppLinkURLScheme</key>
    <string>yourapp://</string>
    <key>ClientToken</key>
    <string>AR|YOUR_APP_ID|YOUR_TOKEN</string>
    <key>DAMEnabled</key>
    <true/>
    <key>MetaAppID</key>
    <string>YOUR_APP_ID</string>
    <key>TeamID</key>
    <string>YOUR_TEAM_ID</string>
</dict>
```

Plus these standard keys:
- `NSBluetoothAlwaysUsageDescription`
- `UIBackgroundModes` (bluetooth-central, bluetooth-peripheral, external-accessory, audio)
- `UISupportedExternalAccessoryProtocols` → `com.meta.ar.wearable`
- `CFBundleURLTypes` with your custom URL scheme

### 3. Entitlements

`com.apple.developer.associated-domains` → `applinks:yourdomain.example`

### 4. Universal Link / AASA

Meta AI redirects back to the app via the universal link after registration.

- The Dev Center "Universal Link" field needs the host (no path).
- The AASA must be served at **`https://<host>/.well-known/apple-app-site-association`** (the **root** of the domain — GitHub project pages won't work, you need a user page like `username.github.io`).
- Content:

```json
{
  "applinks": {
    "apps": [],
    "details": [{
      "appID": "TEAM_ID.com.your.bundle",
      "paths": ["*"]
    }]
  }
}
```

**Fallback:** if you can't host AASA at the domain root, set `AppLinkURLScheme` to a regular URL scheme like `yourapp://` and skip the universal-link path. Registration still works because Meta AI calls back via the scheme.

### 5. Wearables Developer Center

1. https://wearables.developer.meta.com/ → create project
2. Configure **Team ID**, **Bundle ID**, **Universal Link**
3. **Permissions** → add `Camera access` (and Display when listed) + write rationale → **SAVE**
4. **Distribute → Release Channel** → create "Internal", add your Meta account email as Test User
5. Accept the invite from `https://wearables.meta.com/invites` on the phone
6. Copy the generated `MetaAppID` + `ClientToken` into Info.plist

### 6. On the phone (one-time)

1. Install latest Meta AI iOS app
2. Pair Ray-Ban Display in Meta AI
3. Meta AI → Settings → App info → **Developer Mode ON**
   - The "noDeviceConfig / Waiting for the app to restart" toggle bug is harmless — ignore it (see Issue #151)

### 7. iOS version notes

iOS 26.0–26.5 + Developer Mode is currently fragile (Issue #176). If `devicesStream()` returns nothing despite registration succeeding, try iOS 25.x or wait for an SDK fix.

## App-level wiring

```swift
import MWDATCore
import MWDATDisplay
import SwiftUI

@main
struct MyApp: App {
  @StateObject private var wearablesVM: WearablesViewModel

  init() {
    do { try Wearables.configure() } catch { NSLog("DAT configure failed: \(error)") }
    let wearables = Wearables.shared
    _wearablesVM = StateObject(wrappedValue: WearablesViewModel(wearables: wearables))
  }

  var body: some Scene {
    WindowGroup {
      RootView(viewModel: wearablesVM)
        .onOpenURL { url in
          Task { @MainActor in
            try? await Wearables.shared.handleUrl(url)
          }
        }
    }
  }
}
```

## Core architecture: abstract the glasses output

Hide the SDK behind a protocol so the rest of the app stays SDK-agnostic and Mock-testable. Concrete templates in `templates/`.

```swift
public protocol GlassesDisplayClient: Sendable {
  func show(payload: DisplayPayload) async throws
  func clear() async throws
}
```

Three implementations:
- `DATGlassesDisplayClient` — real, wraps `MWDATDisplay.Display`
- `MockGlassesDisplayClient` — `#if DEBUG`, prints + publishes for SwiftUI preview
- `NoopGlassesDisplayClient` (optional) — for tests

Inject via `@StateObject` / `@EnvironmentObject` in the app entry point. Select Mock vs DAT with `#if targetEnvironment(simulator)`.

## Real Display client (the key 30 lines)

```swift
import MWDATCore
import MWDATDisplay

@MainActor
final class DATGlassesDisplayClient: GlassesDisplayClient {
  private let wearables: any WearablesInterface
  private let selector: AutoDeviceSelector
  private var session: DeviceSession?
  private var display: Display?

  init(wearables: any WearablesInterface) {
    self.wearables = wearables
    self.selector = AutoDeviceSelector(
      wearables: wearables,
      filter: { $0.supportsDisplay() }   // ← important, see "Gotchas"
    )
  }

  func show(payload: DisplayPayload) async throws {
    try await ensureReady()
    guard let display else { throw DisplayError.connectionNotAvailable }
    try await display.send(makeView(for: payload))
  }

  func clear() async throws {
    try? await display?.send(FlexBox(direction: .column) { })
  }

  private func ensureReady() async throws {
    if display != nil { return }
    let session = try wearables.createSession(deviceSelector: selector)
    try session.start()
    let display = try session.addDisplay()
    await display.start()
    self.session = session
    self.display = display
  }

  private func makeView(for payload: DisplayPayload) -> FlexBox {
    FlexBox(direction: .column, spacing: 6, padding: EdgeInsets(all: 12)) {
      Text(payload.title, style: .heading)
      Text(payload.body,  style: .body)
      if !payload.chips.isEmpty {
        FlexBox(direction: .row, spacing: 6) {
          for chip in payload.chips.prefix(3) {
            Text(chip, style: .meta, color: .secondary)
          }
        }
      }
    }
    .background(.card)
  }
}
```

## Display API building blocks

All Display UI is built from these `Sendable` value types from `MWDATDisplay`:

| Component | Purpose | Init signature highlights |
|---|---|---|
| `FlexBox` | Container (row/column, padding, background) | `init(direction:.column, spacing:0, alignment:.start, padding:nil, @ComponentBuilder content:)` |
| `Text` | Styled text | `init(_ content: String, style:.body, color:.primary)` |
| `Button` | Tappable | `init(label:, style:.primary, iconName:nil, onClick:nil)` |
| `Icon` | 100+ glyph catalog | `init(name: IconName, style:.filled)` |
| `Image` | URL-loaded | `init(uri:, sizePreset:.icon, cornerRadius:.none)` |
| `VideoPlayer` | MP4 full-screen | `init(provider:.uri(url), codec:.mp4, onError:nil)` |

Enums:
- `TextStyle`: `.heading`, `.body`, `.meta`
- `TextColor`: `.primary`, `.secondary`
- `ButtonStyle`: `.primary`, `.secondary`, `.outline`
- `Background`: `.none`, `.card`
- `Direction`: `.column`, `.row`, `.columnReverse`, `.rowReverse`
- `Alignment`: `.start`, `.center`, `.end`, `.stretch`
- `CornerRadius`: `.none`, `.small`, `.medium`
- `ImageSize`: `.icon`, `.fill`
- `IconName`: large enum, 100+ values (`.checkmark`, `.eye`, `.gear`, `.metaAi`, ...)

Modifiers chainable on FlexBox: `.padding(_:)`, `.background(_:)`, `.onTap(_:)`, `.flexGrow(_:)`, `.flexShrink(_:)`, `.alignSelf(_:)`.

Each `display.send(_:)` **replaces** the entire display content. There are no incremental updates.

Display rendering constraints:
- Native resolution **600 × 600** — don't ship oversized images
- Dims after 20s of inactivity, sleeps at 25s (session stays alive)
- Back gesture (two-finger tap on temple) ends the display session
- Video: MP4 only, max 400 px per side, ≤ 70 000 total pixels, HTTPS only

## DisplayPayload + DisplayFormatter pattern

For text-first UX (e.g. AI describes a scene → glasses shows summary), use this pattern:

```swift
public struct DisplayPayload {
  public var title: String      // <= 12 chars recommended
  public var body: String       // <= 40 chars
  public var chips: [String]    // <= 3
  public var durationSeconds: Int
  public var priority: DisplayPriority
}

public enum DisplayPriority: String { case low, normal, high }
```

The formatter:
- Truncates title to 12 chars (`s.prefix(11) + "…"`)
- Truncates body to 40 chars
- Clips chips to 3
- If `confidence < 0.5`, replaces body with "はっきり分かりません" / "Not sure"
- If safety keywords (`医療`/`法律`/`危険`/`投資`/`毒` etc.) appear, replaces body with "確認してください" / "Please verify" and sets `.high` priority
- Returns a separate `errorPayload(message:)` for analyzer failures

Full template in `templates/DisplayFormatter.swift`.

## Session lifecycle: gotchas

### `addStream` may return nil

`session.addStream(config:)` returns `Stream?`. nil means the device doesn't currently report streaming capability. Don't crash on it:

```swift
guard let stream = try session.addStream(config: streamConfig) else {
  showError("Stream capability is not available on this device.")
  return
}
```

### `sessionAlreadyExists`

`createSession` throws `DeviceSessionError.sessionAlreadyExists` if a previous `DeviceSession` from the same `Wearables.shared` hasn't been released. Always tear down before retry:

```swift
await teardownExistingSession()  // stop stream, set self.session = nil, sleep 200ms
let session = try wearables.createSession(deviceSelector: selector)
```

### Reentry guard

If the UI button can be tapped repeatedly, guard with a `Bool` flag:

```swift
if startSessionInProgress { return }
if session != nil { return }  // already running
startSessionInProgress = true
defer { startSessionInProgress = false }
```

### Auto-teardown on error

When `stream.errorPublisher` or `stream.statePublisher` fires `.stopped`, clear the Swift references so the next tap can retry:

```swift
errorListenerToken = stream.errorPublisher.listen { [weak self] error in
  Task { @MainActor in
    self?.showError(formatStreamingError(error))
    await self?.teardownExistingSession()
  }
}
```

### `StreamError` is non-frozen

Always include `@unknown default`. Confirmed cases in 0.7:
`.timeout`, `.permissionDenied`, `.hingesClosed`, `.thermalCritical`, `.thermalEmergency`, `.peakPowerShutdown`, `.batteryCritical`, `.videoStreamingError`, `.deviceNotFound`, `.deviceNotConnected`.

### MockDeviceKit needs enable() + don()

In 0.6+, `MockDeviceKit.shared.pairRaybanMeta()` crashes (`EXC_BREAKPOINT`) unless `enable()` was called first. And after pairing, the mock device is **not active** until `.don()` is invoked on it (Issue #171). Always gate `enable()` on `!isEnabled`:

```swift
if !MockDeviceKit.shared.isEnabled {
  MockDeviceKit.shared.enable()
}
let mock = MockDeviceKit.shared.pairRaybanMeta()
mock.powerOn()
mock.don()  // ← active device only after this
```

### `MockDisplaylessGlasses.getCameraKit()` removed

0.4 → 0.7 rename:

```swift
// 0.4
let cameraKit = (device as? MockDisplaylessGlasses)?.getCameraKit()
await cameraKit.setCameraFeed(fileURL: url)   // async

// 0.7
let camera = (device as? MockDisplaylessGlasses)?.services.camera
camera?.setCameraFeed(fileURL: url)            // sync
```

`setCameraFeed(cameraFacing:)` (front/back) is still async.

### `AutoDeviceSelector` filter

Pass `filter: { $0.supportsDisplay() }` if you call `addDisplay()`. Without the filter, the selector may pick a paired device that doesn't advertise Display capability and you get `DeviceSessionError.noEligibleDevice`.

```swift
AutoDeviceSelector(wearables: wearables, filter: { $0.supportsDisplay() })
```

Likewise filter on a Stream-only path if you only need camera.

## Known firmware-side blockers (May 2026)

Track these GitHub issues — they affect external developers regardless of how clean your code is:

| Issue | Symptom | Status |
|---|---|---|
| `facebook/meta-wearables-dat-ios#180` | `DeviceSessionError.datAppOnTheGlassesUpdateRequired` after a clean dev-center project + re-pair on Ray-Ban Display. `openDATGlassesAppUpdate()` opens Meta AI but doesn't surface an actionable update. Same symptom on Android. | Open, awaiting Meta-side firmware/Meta-AI sync |
| `facebook/meta-wearables-dat-ios#176` | iOS 26.x + Developer Mode → `devicesStream()` never returns devices, `startRegistration()` crashes EXC_BAD_ACCESS | Open |
| `facebook/meta-wearables-dat-ios#171` | Mock device never goes active in sample code | Workaround: `mock.don()` (Issue comment from alexsinkmeta) |
| `facebook/meta-wearables-dat-ios#151` | "noDeviceConfig" / "Waiting for the app to restart" UI loop in Meta AI when enabling Dev Mode | Cosmetic bug — Dev Mode IS being enabled, ignore the dialog (sourabh-nanoti) |

**Diagnostic fingerprint** for Issue #180: the iOS console will show
```
MediaStreamSession::_handleStartErrorCode - error: 2, category: ProtoSerializerError
```
followed by `WARPStreamClientService::stop` within ~100ms of starting the stream. `device.compatibility()` reports `.compatible` but the connection still ProtoSerializer-fails.

## Fallback: bypass DAT entirely

While the firmware-side block (#180) is in effect, you can still demonstrate the full app pipeline end-to-end on the iPhone by feeding images directly into your analyzer:

```swift
import PhotosUI

@State private var pickedItem: PhotosPickerItem?

PhotosPicker(selection: $pickedItem, matching: .images) {
  Label("Photo → Glasses", systemImage: "photo")
}
.onChange(of: pickedItem) { _, newItem in
  Task {
    guard let data = try? await newItem?.loadTransferable(type: Data.self),
          let image = UIImage(data: data) else { return }
    await glassesEnv.describeAndShow(image: image)
  }
}
```

Couple this with a `GlassesPreviewView` that renders `MockGlassesDisplayClient.currentPayload` so users see a simulated HUD on the iPhone screen. When firmware is fixed, the same `describeAndShow` will reach the real display with zero code change.

## Diagnostic logging template

Drop this into your session-management code while debugging:

```swift
NSLog("[GlassesDisplay] createSession ok, state=\(session.state)")
try session.start()
NSLog("[GlassesDisplay] session.start() returned, state=\(session.state)")
// optional settle wait
for _ in 0..<10 {
  let s = "\(session.state)"
  if !s.contains("starting") && !s.contains("stopping") { break }
  try? await Task.sleep(nanoseconds: 100_000_000)
}
NSLog("[GlassesDisplay] after settle, state=\(session.state)")
```

`MediaStreamSession::_handleStartErrorCode - error: <N>, category: <X>` in the C++ logs tells you which side rejected:
- `ProtoSerializerError` → firmware/SDK version mismatch on glasses (Issue #180)
- `permissionDenied` → user didn't grant camera in Meta AI flow
- `hingesClosed` → glasses are folded

## Templates included with this skill

In `.claude/skills/meta-rayban-display/templates/`:

- `Info.plist.fragment.xml` — drop-in MWDAT + Bluetooth keys
- `apple-app-site-association.json` — AASA file content
- `DisplayPayload.swift` + `DisplayPriority`
- `GlassesDisplayClient.swift` (protocol)
- `MockGlassesDisplayClient.swift` (DEBUG)
- `DATGlassesDisplayClient.swift` (real)
- `DisplayFormatter.swift` (length / safety / confidence rules)
- `GlassesPreviewView.swift` (iPhone-side simulated HUD)
- `AppWiring.swift` (example `@main` integration)

Copy what you need; the templates are self-contained and protocol-based so they can replace each other.

## Official sources to bookmark

- DAT iOS repo: `https://github.com/facebook/meta-wearables-dat-ios`
- CHANGELOG: same repo, `CHANGELOG.md`
- API reference: `https://wearables.developer.meta.com/docs/reference/ios_swift/dat/0.7`
- LLM-friendly docs endpoint: `https://wearables.developer.meta.com/llms.txt?full=true`
- Display integration guide: `https://wearables.developer.meta.com/docs/develop/dat/display/`
- DAT Claude Code plugin: `claude plugin marketplace add facebook/meta-wearables-dat-ios; claude plugin install mwdat-ios@mwdat-ios-marketplace`

## Migration cheatsheet: DAT 0.4 → 0.7

| 0.4 | 0.7 |
|---|---|
| `StreamSession(streamSessionConfig:, deviceSelector:)` | `let session = try wearables.createSession(deviceSelector:); let stream = try session.addStream(config:)` |
| `StreamSessionConfig` | `StreamConfiguration` |
| `StreamSessionState` | `StreamState` |
| `StreamSessionError` | `StreamError` (+ thermal/battery cases) |
| `streamSession.start()` (async) | `try session.start()` (sync) + `await stream?.start()` |
| Nothing | `session.addDisplay()` → `Display` (new capability) |
| `MockDisplaylessGlasses.getCameraKit()` | `MockDisplaylessGlasses.services.camera` (sync setters now) |
| Nothing | `MWDAT.DAMEnabled = true` in Info.plist (required for Display) |
| `WearablesInterface.addDeviceSessionStateListener(...)` | `session.stateStream()` |
| `DeviceStateSession` | `Wearables.deviceStateStream(for:)` |

## End-to-end MVP recipe (10 minutes)

When the user says "build a Display app that does X":

1. New SwiftUI App project, iOS 17+
2. Add SPM dependency `meta-wearables-dat-ios` @ 0.7.0+
3. Copy `templates/Info.plist.fragment.xml` into Info.plist, fill in MetaAppID/ClientToken/TeamID
4. Add `applinks:` entitlement
5. Copy `DisplayPayload.swift`, `GlassesDisplayClient.swift`, `MockGlassesDisplayClient.swift`, `DATGlassesDisplayClient.swift`, `DisplayFormatter.swift`, `GlassesPreviewView.swift` into the project
6. In `@main`:
   ```swift
   try? Wearables.configure()
   #if targetEnvironment(simulator)
   let client: any GlassesDisplayClient = MockGlassesDisplayClient()
   #else
   let client: any GlassesDisplayClient = DATGlassesDisplayClient(wearables: Wearables.shared)
   #endif
   ```
7. Wire `.environmentObject` + `.onOpenURL { Wearables.shared.handleUrl(...) }`
8. App-specific logic produces `DisplayPayload`s and calls `client.show(payload:)`
9. While firmware fix is pending: add a PhotosPicker that feeds straight into the pipeline so the demo works without glasses

After that the app is structured so swapping in any payload source (camera VLM, calendar event, location card, fitness counter, transit timer, ...) is a one-file change.
