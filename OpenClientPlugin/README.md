# OpenClient Plugin

Connect OpenCode to the OpenClient iOS app for native tools, declarative
visuals, and in-app browser automation.

## Install

Bundled notifications are currently an unreleased development feature. The
published `0.2.0` package provides the native tools bridge but does not include
OC Notify. Build this repository's plugin and replace the existing plugin entry
with the absolute URL of its built entrypoint:

```json
{
  "$schema": "https://opencode.ai/config.json",
  "plugin": [
    ["file:///absolute/path/to/OpenClientPlugin/dist/index.js", {
      "notifications": {
        "enabled": true,
        "publicOrigin": "https://notify.example.com",
        "port": 4319,
        "dataDir": "/absolute/path/to/notification-state"
      }
    }]
  ]
}
```

Quit and restart OpenCode after changing plugin configuration. OpenCode loads
plugins at startup and does not hot-reload them.

OpenCode `1.18.5` or newer is required so the host invokes the plugin disposal
hook during shutdown and reload.

The OpenClient iOS app discovers the bridge on the connected OpenCode host and
advertises the native tools supported by that app build.

For repository development, run `npm run build` before loading `dist/index.js`.
Do not also load the old npm entry or the standalone notification adapter.
OpenCode must be restarted after changing plugin code or configuration.

The first feature is a dual-stack WebSocket bridge that binds the first
available port in `4070...4090` on all IPv4 and IPv6 interfaces. It exposes two
OpenCode tools:

- `openclient_get_tool_list`
- `openclient_execute_tool`

The bridge intentionally has no application-layer authentication or encryption.
Run it only on a host whose network access is already restricted by a Tailnet,
VPN, firewall, or equivalent trusted-network architecture. Do not expose ports
`4070...4090` directly to the public internet.

Endpoints:

- `GET /openclient/v1/health`
- `POST /openclient/v1/notifications/setup`
- `GET /openclient/v1/ws`
- `GET /openclient/v1/image/resources/:resourceID/content`
- `POST /openclient/v1/video/resources/:resourceID/stream`
- `DELETE /openclient/v1/video/resources/:resourceID/stream`
- `DELETE /openclient/v1/video/streams/:streamID`
- `GET /openclient/v1/video/streams/:streamID/playlist.m3u8`
- `GET /openclient/v1/video/streams/:streamID/{init.mp4,segment-NNNNNN.m4s}`

Notifications are disabled by default. When enabled, `publicOrigin` is required
and must be a path-free HTTPS origin. The PWA listens only on `127.0.0.1` at
`port` (default `4319`). `dataDir` defaults to
`$XDG_STATE_HOME/opencode/openclient/notifications` or
`~/.local/state/opencode/openclient/notifications`; configure an absolute path
when migrating existing OC Notify state.

For migration, stop the old standalone OC Notify process before starting the
plugin so it releases the PWA port and data directory. Use the exact same
absolute `dataDir` in the plugin options and every pairing command; do not rely
on `npm run pair` defaults for an existing prototype `.data` directory. Perform
the final controlled restart only when active OpenCode work can be interrupted.

The native setup endpoint creates a one-use, 10-minute connection-prefill code.
It does not pair a browser, authorize a device, save a destination, enable push,
or opt into activity notifications. A first-time Home Screen PWA must still be
paired using a separate code generated on the Mac:

```bash
openclient-notify pair --data-dir /absolute/path/to/notification-state
```

For the repository prototype state, the explicit command is:

```bash
openclient-notify pair --data-dir /absolute/path/to/NotificationPWA/.data
```

`openclient_visual_image` accepts an absolute path to a readable regular JPEG,
PNG, or WebP file up to 20 MiB. Tool execution canonicalizes and validates the
source, then creates an opaque image resource. The persisted visual payload
contains dimensions, bounded file metadata, an opaque content path, and a JPEG
preview no larger than 96 px on either side or 32 KiB decoded. It does not
contain the original image bytes or source path. A content `GET` revalidates the
source identity and returns the original bytes with the exact image content
type, `nosniff`, and private no-store caching.

`openclient_visual_video` accepts an absolute path to a readable regular MP4
file. Tool execution creates a dormant opaque resource and persists coded
`width`, `height`, clockwise `rotation` (degrees), `duration` (seconds), and a
bounded JPEG cover generated from the first frame. HLS preparation remains lazy
and begins only after a playback `POST`.

Image and video resources use rolling 30-day retention and survive plugin and
OpenCode restarts in private `0600` registries under
`~/.local/state/opencode/openclient/{image,video}-resources-<port>.json` (or the
equivalent `XDG_STATE_HOME` path). Registry and temporary-media directories are
forced to mode `0700`. Each service retains at most 128 least-recently-used
resources. Before content loading or playback, the plugin verifies that the
source is still the same regular file by checking its canonical path, device,
inode, size, and modification time.

The source path never appears in declarative result metadata or an HTTP route.
It is still an argument to `openclient_execute_tool`, so OpenCode persists the
original `filePath` with the tool invocation in session history and may expose
the canonical path in permission details. This capability does not make the
input path private from OpenCode itself.

Resource creation runs `ffprobe` and preview `ffmpeg` against an
identity-validated open file descriptor on supported platforms, never against
the user-provided path. Invalid or oversized previews reject resource creation.

Each playback `POST` starts an independent `ffmpeg` stream-copy fragmented MP4
HLS lease; dismissing that player deletes only its stream. Active streams and
generated HLS media remain in a private temporary directory and are removed at
shutdown. Media stays on the bridge HTTP port and is never sent through the
WebSocket protocol. Video sources are limited to 20 GiB and playback to three
concurrent streams. Image and video tools require `ffmpeg` and `ffprobe` in the
plugin process PATH.

## Development

```bash
npm install
npm run check
npm run build
```

Add hooks and tools to the object returned by `OpenClientPlugin` in
`src/index.ts`.

Validate the exact package contents without publishing:

```bash
npm run pack:check
```

Publishers can release the current package version with:

```bash
npm run distribute
```

On the OpenClient release Mac, this command reads the npm token from the
`openclient-npm-publish` service in macOS Keychain and provides it only to the
`npm publish` subprocess. Publishing requires an npm account with write access
to the `@openclient-ios` scope.

Plugin documentation: <https://opencode.ai/docs/plugins/>
