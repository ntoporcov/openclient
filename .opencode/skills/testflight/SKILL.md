---
name: testflight
description: Build and upload the OpenClient iOS app to TestFlight. Use when sending a new TestFlight build, bumping the build number for upload, diagnosing Fastlane upload/signing issues, or running the repository beta lane.
---

# OpenClient TestFlight Upload

Use this skill only for building and uploading OpenClient TestFlight builds from the local Mac build environment.

Git staging, committing, and pushing are intentionally out of scope for this skill. Use repository git workflow instructions or command-specific instructions for those steps.

## Critical Rule

Always run Fastlane with an explicit UTF-8 locale:

```bash
LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 fastlane ios beta
```

Plain `fastlane ios beta` has failed locally with Ruby/Fastlane encoding errors such as `invalid byte sequence in US-ASCII`. The UTF-8 locale is part of the required command, not an optional cleanup.

## Build Number Bump

App Store Connect requires each TestFlight upload to use a new build number.

Do not blindly increment the stale local value. The local project must follow App Store Connect/TestFlight:

1. Determine the latest TestFlight build number for the current app version.
2. Set local `CURRENT_PROJECT_VERSION` to latest TestFlight build + 1.
3. If the user provides the latest TestFlight build number, trust that number and use the next integer.

Example: if TestFlight latest build is `47`, set local `CURRENT_PROJECT_VERSION` to `48` before uploading.

The source of truth is `project.yml`:

```yaml
CURRENT_PROJECT_VERSION: <number>
```

Increment `CURRENT_PROJECT_VERSION`, then regenerate the Xcode project with the local signing override:

```bash
INCLUDE_PROJECT_LOCAL_YAML=1 /Users/mininic/.local/bin/xcodegen generate
```

This updates the generated project version in:

- `project.yml`
- `OpenCodeIOSClient.xcodeproj/project.pbxproj`

Do not modify local-only signing config or secret files while bumping the build number.

## Upload To TestFlight

Run:

```bash
LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 fastlane ios beta
```

The lane does the following:

- Loads App Store Connect API key credentials from ignored local environment/config.
- Runs `INCLUDE_PROJECT_LOCAL_YAML=1 /Users/mininic/.local/bin/xcodegen generate`.
- Archives the `OpenCodeIOSClient` scheme in Release configuration.
- Uses automatic signing with `-allowProvisioningUpdates`.
- Exports `build/fastlane/OpenClient.ipa`.
- Uploads to TestFlight with `skip_waiting_for_build_processing: true`.

## Known Valid IDs

- Main app bundle ID: `com.ntoporcov.openclient`
- Live Activity extension bundle ID: `com.ntoporcov.openclient.liveactivity`
- Installed app name: `OpenClient`

## Expected Local Credentials

Do not print or inspect secret values. The local environment may provide:

- `APP_STORE_CONNECT_API_KEY_ID`
- `APP_STORE_CONNECT_ISSUER_ID`
- `APP_STORE_CONNECT_API_KEY_CONTENT`
- `APP_STORE_CONNECT_API_KEY_PATH`

If both content and path are set, the Fastlane lane prefers `APP_STORE_CONNECT_API_KEY_CONTENT`.

## Stop Conditions

If Fastlane fails because App Store Connect credentials or signing are missing, report the exact blocker and stop. Do not guess, do not modify signing config blindly, and do not inspect or print secret values.

Common blockers to report exactly:

- Missing `APP_STORE_CONNECT_API_KEY_ID`, `APP_STORE_CONNECT_ISSUER_ID`, or both key content/path values.
- Apple signing/provisioning errors from archive/export.
- Bundle identifier validation errors. These usually mean the Xcode project needs to be regenerated from `project.yml` with `INCLUDE_PROJECT_LOCAL_YAML=1`.

## Final Report

Report:

- Build number uploaded.
- Whether `fastlane ios beta` succeeded.
- Any exact blocker if the build, archive, export, or upload failed.
