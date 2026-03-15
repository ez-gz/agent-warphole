# WarpholPhone — iOS app

SwiftUI app that connects to the warphole phone server and lets you read
the conversation + send messages (with live dictation) from your phone.

## Setup (2 minutes)

1. Open Xcode → **File > New > Project** → **iOS > App**
2. Product name: `WarpholPhone`, Interface: SwiftUI, Language: Swift
3. Delete the generated `ContentView.swift` (or replace it)
4. Drag all `.swift` files from `ios/WarpholPhone/` into the project
5. In project settings → **Info** tab, merge the keys from `Info.plist`
   (mic + speech recognition usage descriptions)
6. In project settings → **Signing & Capabilities**, add:
   - **Speech Recognition** entitlement (if not auto-added)
7. Build & run on device (simulator works too, but no mic)

## Hardcoded server

Default server URL: `https://ztester123.fly.dev`

Change it at runtime in the **Settings** sheet (gear icon, top-right),
or update the default in `PhoneClient.swift`:

```swift
UserDefaults.standard.string(forKey: "phoneServerURL") ?? "https://yourapp.fly.dev"
```

## Features

- **Live conversation** — polls `/api/conversation` every 2.2s, auto-scrolls
- **Dictation** — tap mic, speak, words appear live in the input field as you talk
- **Send** — tap the blue arrow (or finish dictating and tap send)
- **Quick keys** — `esc`, `ctrl+c`, `↑`, `↓` chips above the input bar for
  interrupting Claude or navigating history
- **Status indicator** — green = live session, orange = waiting, red = offline
- **Settings** — change server URL without rebuilding

## Architecture

```
PhoneClient      — polls /api/info + /api/conversation, sends to /api/input
DictationEngine  — SFSpeechAudioBufferRecognitionRequest (live streaming)
ContentView      — main chat + input bar, wires client ↔ dictation
MessageBubble    — user (blue right) / assistant (gray left) / tool chips
SettingsView     — URL config + connection status
```
