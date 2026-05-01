---
description: Build, install, and launch the app on a connected iPhone
---

Build the app for a physical iOS device, install it on Nic iPhone, and launch it.

Use the device install workflow from `AGENTS.md`:

- Target device: Nic iPhone (`00008150-001A43A80207801C`).
- Skip device discovery unless install or launch fails.
- Build using repo-local derived data so the install path is fresh:
- Build using repo-local derived data so the install path is fresh:

```bash
xcodebuild -quiet -project OpenCodeIOSClient.xcodeproj -scheme OpenCodeIOSClient -sdk iphoneos -derivedDataPath .derived-data-device build
```

- Install the freshly built app from:

```bash
.derived-data-device/Build/Products/Debug-iphoneos/OpenClient.app
```

- Use this install command:

```bash
xcrun devicectl device install app --device "00008150-001A43A80207801C" ".derived-data-device/Build/Products/Debug-iphoneos/OpenClient.app"
```

- Launch the installed app with:

```bash
xcrun devicectl device process launch --device "00008150-001A43A80207801C" com.ntoporcov.openclient
```

If install or launch fails because the device is locked or unavailable, then run `xcrun xcdevice list` to verify availability. Say that the install may have succeeded if only launch failed, and that the app can be opened manually after unlocking.
