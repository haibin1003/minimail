# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

MiniMail is a cross-platform web-wrapper app that embeds a webpage inside a native desktop shell. It wraps China Mobile Mail (mail.chinamobile.com) but the URL can be changed via shared config.

The project supports two platforms:
- macOS: Native Swift + WKWebView + AppKit (platforms/macos/)
- Windows: Electron + Chromium (platforms/windows/)

Shared configuration lives in shared/config.json and is consumed by both platforms.

## Directory Structure

```
├── shared/
│   └── config.json              # Cross-platform config (URL, window size, etc.)
├── platforms/
│   ├── macos/                   # macOS native version
│   │   ├── MiniMail.swift       # Single-file Swift app (~1100 lines)
│   │   ├── Makefile             # swiftc build
│   │   ├── Info.plist
│   │   ├── gen_icon.swift       # Icon generation script
│   │   └── AppIcon.icns
│   └── windows/                 # Windows Electron version
│       ├── src/main/
│       │   ├── index.js         # Main process (window, lifecycle)
│       │   ├── tray.js          # System tray controller
│       │   └── cookies.js       # Cookie persistence (JSON file)
│       ├── src/preload/
│       │   └── index.js         # Preload script (IPC bridge, keyboard shortcuts)
│       ├── package.json         # Build config + electron-builder
│       └── dist/                # Build output (generated)
└── README.md
```

## Build Commands

### macOS

Run from platforms/macos/:

| Command | Purpose |
|---------|---------|
| make | Compile to MiniMail.app bundle |
| make run | Compile and open the app |
| make clean | Remove build artifacts |
| make dmg | Build .app and package into DMG |

Uses swiftc with -framework Cocoa -framework WebKit -framework SwiftUI. No Xcode project required.

### Windows

Run from platforms/windows/:

| Command | Purpose |
|---------|---------|
| npm install | Install dependencies |
| npm run start | Run in development mode |
| npm run build | Build NSIS installer + portable EXE |
| npm run build:dir | Build unpacked directory only |

Build outputs in platforms/windows/dist/:
- NSIS installer (exe)
- Portable executable (exe)
- win-unpacked/ directory

Note: Set ELECTRON_MIRROR environment variable to a China mirror if downloads timeout.

## Configuration

Edit shared/config.json to change behavior on both platforms:

```json
{
  "targetURL": "https://example.com",
  "windowTitle": "My App",
  "windowWidth": 1200,
  "windowHeight": 800,
  "showNavigationBar": false,
  "customUserAgent": null
}
```

### macOS-only config

The macOS version also reads AppConfig enum at the top of MiniMail.swift. This overrides shared/config.json for backward compatibility. Prefer editing shared/config.json for cross-platform changes.

## Architecture

### macOS

Single-file Swift architecture. Key types in MiniMail.swift:

1. AppConfig (enum, line ~24) — URL, title, dimensions.
2. WebView (NSViewRepresentable, line ~266) — WKWebView wrapper. Restores cookies before loading (300ms delay for network process sync).
3. ContentView (SwiftUI View, line ~453) — Hosts WebView + optional NavigationBar. Launch URL prefers CookieManager.loadLastURL() over AppConfig.targetURL.
4. AppDelegate (NSApplicationDelegate, line ~971) — .accessory activation policy (no Dock), PID file lock, keyboard shortcuts, StatusBarController.
5. StatusBarController (line ~517) — Menu-bar icon. Injects JS to poll unread count every 30s (queries [data-unread] DOM attribute).

Critical design patterns:
- Global webView bridge: globalWebView (line ~21) bridges SwiftUI init timing gap for StatusBarController/KeyboardShortcutManager access.
- Cookie persistence: JSON serialization to ~/Library/Application Support/MiniMail/cookies.json. Session cookies get 30-day synthetic expiry.
- Single-instance: PID file lock at /tmp/MiniMail.lock.
- Menu-bar-only: LSUIElement in Info.plist + NSApp.setActivationPolicy(.accessory).
- WKProcessPool sharing: Module-level sharedProcessPool for cookie persistence across WKWebView recreations.

### Windows

Electron multi-file architecture:

1. src/main/index.js — Main process entry. Creates BrowserWindow, loads config, restores cookies, sets up navigation handlers, IPC for shortcuts.
2. src/main/tray.js — System tray controller with context menu. Menu items: toggle window, unread count, inbox, sent, refresh, shortcuts, quit.
3. src/main/cookies.js — Cookie persistence layer. Reads/writes JSON to userData directory. Same 30-day synthetic expiry logic as macOS.
4. src/preload/index.js — Preload script exposing safe IPC bridge. Intercepts window.alert with custom DOM overlay. Handles Alt+Left/Right for back/forward.

Key design patterns:
- requestSingleInstanceLock for single-instance protection.
- Context isolation + preload script for secure renderer/main communication.
- Tray icon with dynamic menu rebuild based on window visibility state.
- Cookie save on did-finish-load and before-quit.

## Feature Parity

| Feature | macOS | Windows |
|---------|-------|---------|
| Web rendering | WKWebView | Chromium (Electron) |
| System tray | NSStatusItem | Tray API |
| Single instance | PID file lock | requestSingleInstanceLock |
| Cookie persistence | JSON + WKHTTPCookieStore | JSON + session.cookies |
| Back/Forward | Cmd+[ / Cmd+] | Alt+Left / Alt+Right |
| Unread polling | executeJavaScript | executeJavaScript |
| New window intercept | setWindowOpenHandler | setWindowOpenHandler |
| JS Alert | NSAlert | Custom DOM overlay |
| Package format | .app / .dmg | .exe (NSIS) / portable |

## JavaScript Injection Points (both platforms)

queryUnreadCount() — Reads document.querySelector('[data-unread]') to get unread mail count. Runs on a 30-second timer after page load.

clickFolder(id:name:) — Simulates clicks on mail folder DOM elements by id (span_1, span_3, span_0 for Inbox, Sent, Unread). Used by tray/menu bar actions.

## Important Files

| File | Purpose |
|------|---------|
| shared/config.json | Cross-platform configuration |
| platforms/macos/MiniMail.swift | macOS app source |
| platforms/macos/Makefile | macOS build scripts |
| platforms/windows/src/main/index.js | Windows main process |
| platforms/windows/src/main/tray.js | Windows tray controller |
| platforms/windows/src/main/cookies.js | Windows cookie persistence |
| platforms/windows/package.json | Windows build config |
