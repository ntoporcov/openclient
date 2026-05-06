---
name: install-iphone
description: Build, install, and launch the OpenClient iOS app on a physical iPhone. Use when testing on-device, diagnosing iPhone install/launch failures, or refreshing the on-device debug build.
---

# OpenClient iPhone Install

Use this skill to build the app for a physical iOS device, install it on the configured iPhone, and launch it.

## Target iPhone

- Device name: `Nic iPhone`
- Device UDID source: `OPENCLIENT_IPHONE_UDID`
- App bundle ID: `com.ntoporcov.openclient`
- Fresh app path: `.derived-data-device/Build/Products/Debug-iphoneos/OpenClient.app`

Do not hardcode the UDID in commands or logs. Read it from the environment. If `OPENCLIENT_IPHONE_UDID` is missing, source `.opencode/.env` if it exists, then stop and ask the user to set it locally before installing if it is still missing.

Skip device discovery unless build, install, or launch fails.

Use this shell guard before install/launch commands:

```bash
[ -f .opencode/.env ] && set -a && . .opencode/.env && set +a
: "${OPENCLIENT_IPHONE_UDID:?Set OPENCLIENT_IPHONE_UDID to the target iPhone UDID}"
```

## Build

Build for iPhone using repo-local derived data so the install path is fresh and deterministic:

```bash
xcodebuild -quiet -project OpenCodeIOSClient.xcodeproj -scheme OpenCodeIOSClient -sdk iphoneos -derivedDataPath .derived-data-device build
```

Do not install from stale global DerivedData or old repo-local paths. The expected fresh install artifact is:

```bash
.derived-data-device/Build/Products/Debug-iphoneos/OpenClient.app
```

Important stale-path warning:

- Do not install from `DerivedData/Build/Products/...` unless that exact folder was the explicit `-derivedDataPath` for the build you just ran.
- A stale `OpenCodeIOSClient.app` may have the wrong bundle identifier after the app rename.
- Prefer `.derived-data-device/Build/Products/Debug-iphoneos/OpenClient.app` after the command above.

## Install On iPhone

Install the freshly built app:

```bash
[ -f .opencode/.env ] && set -a && . .opencode/.env && set +a; : "${OPENCLIENT_IPHONE_UDID:?Set OPENCLIENT_IPHONE_UDID to the target iPhone UDID}" && xcrun devicectl device install app --device "$OPENCLIENT_IPHONE_UDID" ".derived-data-device/Build/Products/Debug-iphoneos/OpenClient.app"
```

## Launch On iPhone

Launch the installed app:

```bash
[ -f .opencode/.env ] && set -a && . .opencode/.env && set +a; : "${OPENCLIENT_IPHONE_UDID:?Set OPENCLIENT_IPHONE_UDID to the target iPhone UDID}" && xcrun devicectl device process launch --device "$OPENCLIENT_IPHONE_UDID" com.ntoporcov.openclient
```

## Failure Handling

If install or launch fails because the iPhone is locked, unavailable, disconnected, or not paired, then verify device availability:

```bash
xcrun xcdevice list
```

Common fixes:

- Unlock Nic iPhone.
- Reconnect USB once.
- Ensure Developer Mode is enabled on the iPhone.
- If using wireless debugging, ensure the Mac and iPhone are on the same LAN.
- Verify `Connect via network` in Xcode Devices and Simulators.

If install succeeds but launch fails because the iPhone is locked or unavailable, say that the install may have succeeded and the app can be opened manually after unlocking.

## When Xcode Project Generation Is Needed

If build fails with bundle identifier validation errors, regenerate the project from `project.yml` using the local signing override, then rebuild:

```bash
INCLUDE_PROJECT_LOCAL_YAML=1 /Users/mininic/.local/bin/xcodegen generate
```

Known validation error strings include:

- `error: Unexpected app bundle identifier '$PRODUCT_BUNDLE_IDENTIFIER'. Regenerate the project from project.yml before building.`
- `error: Unexpected extension bundle identifier '$PRODUCT_BUNDLE_IDENTIFIER'. Regenerate the project from project.yml before building.`

## Final Report

Report:

- Whether the iPhone device build succeeded.
- Whether install on the configured iPhone succeeded.
- Whether launch on the configured iPhone succeeded.
- Any exact blocker if build/install/launch failed.
