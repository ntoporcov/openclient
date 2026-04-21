# OpenCode iOS Client Starter

This folder is a starter for a native SwiftUI iOS client that connects to an OpenCode server.

## Intended user flow

1. Enter a server URL such as `http://192.168.1.50:4096` or `https://opencode.example.com`.
2. Enter the OpenCode server username and password.
3. Connect and verify the server is healthy.
4. List or create sessions.
5. Open a session and chat with OpenCode.

## OpenCode server assumptions

The current starter targets the documented endpoints:

- `GET /global/health`
- `GET /session`
- `POST /session`
- `GET /session/:id/message`
- `POST /session/:id/message`

Authentication is HTTP Basic Auth using `OPENCODE_SERVER_PASSWORD` on the host machine and optional `OPENCODE_SERVER_USERNAME`.

## Folder layout

- `OpenCodeIOSClient/OpenCodeIOSClientApp.swift`: app entry point
- `OpenCodeIOSClient/API`: small API client for the OpenCode server
- `OpenCodeIOSClient/Models`: DTOs and connection config
- `OpenCodeIOSClient/ViewModels`: app state and screen orchestration
- `OpenCodeIOSClient/Views`: SwiftUI screens

## Current status

This starter now includes a generated Xcode project:

- `OpenCodeIOSClient.xcodeproj`
- `project.yml` for regenerating the project with XcodeGen

## Local tooling

`xcodegen` was installed locally at:

`/Users/mininic/.local/bin/xcodegen`

## Useful commands

Regenerate the Xcode project:

```bash
/Users/mininic/.local/bin/xcodegen generate
```

Build for Simulator:

```bash
xcodebuild -quiet -project OpenCodeIOSClient.xcodeproj -scheme OpenCodeIOSClient -destination 'platform=iOS Simulator,name=iPhone 17' build
```

Open in Xcode:

```bash
open OpenCodeIOSClient.xcodeproj
```

## Recommended next steps

1. Add Keychain-backed credential storage.
2. Add SSE support for `/event` so responses can update in real time.
3. Add request/response logging and better transport errors.
4. Add support for permission prompts and tool activity rendering.
5. Add TLS guidance or a reverse proxy for secure remote access.
