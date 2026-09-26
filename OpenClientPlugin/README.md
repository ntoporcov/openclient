# OpenClient Plugin

Connect OpenCode to the OpenClient iOS app for native tools, declarative
visuals, in-app browser automation, and optional OC Notify notifications.

## Install

Add the plugin to your OpenCode configuration:

```json
{
  "$schema": "https://opencode.ai/config.json",
  "plugin": ["@openclient-ios/opencode-plugin@0.3.0"]
}
```

Version `0.3.0` includes OC Notify. To enable notifications, replace the plugin
entry with the options form:

```json
{
  "$schema": "https://opencode.ai/config.json",
  "plugin": [
    ["@openclient-ios/opencode-plugin@0.3.0", {
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

The current source build supports OpenCode **v1 1.18.29+** and **v2**, including
preview `0.0.0-next-17155`. Dual-version support is not yet published in `0.3.0`.
Both hosts load the same package and choose its native entry point automatically:
v1 calls `server()`, while v2 calls `setup()`. No version-mode option is needed.

The OpenClient iOS app discovers the bridge on the connected OpenCode host and
advertises the native tools supported by that app build.

For repository development, run `npm run build` and replace the npm entry with
`file:///absolute/path/to/OpenClientPlugin/dist/index.js`.
Do not also load the old npm entry or the standalone notification adapter.
OpenCode must be restarted after changing plugin code or configuration.

### V2 source configuration

V2 uses `plugins` and an object for package options (rather than v1's `plugin`
and tuple). Build the source and configure:

```json
{
  "$schema": "https://opencode.ai/config.json",
  "plugins": [{
    "package": "file:///absolute/path/to/OpenClientPlugin/dist/index.js",
    "options": {
      "notifications": {
        "enabled": true,
        "publicOrigin": "https://notify-v2.example.com",
        "port": 4321,
        "dataDir": "/absolute/path/to/v2-notification-state"
      }
    }
  }]
}
```

When running multiple servers on one machine, use distinct notification ports,
HTTPS origins, and data directories. Bridge ports are selected automatically.
V2 does not expose its listening URL to plugins, so the bridge uses the host's
`serve --port` / `--port=` argument, or `OPENCODE_SERVER_PORT`. Embedded hosts
without these can set the optional `serverURL` origin in plugin options.

V2 tools use native tool-registration permissions, JSON Schema, structured
output, and the session's canonical location. Current v2 passes cancellation
signals for tool execution; older previews without those signals can only
cancel outstanding device requests when the plugin unloads. Notifications
normalize v2 forms and events into the shared notification lifecycle.

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
It does not itself pair a browser or opt into activity notifications. Current
OpenClient builds launch the bundled pairing CLI through an OpenCode PTY and
copy one short-lived setup payload. The browser shows installation instructions;
the Home Screen PWA's **Paste Setup from OpenClient** pairs and saves the
connection. Notification permission and activity opt-in remain explicit.

For manual diagnostics, generate a pairing code with:

```bash
npm exec --package=@openclient-ios/opencode-plugin@0.3.0 -- openclient-notify pair --data-dir /absolute/path/to/notification-state
```

For the repository prototype state, the explicit command is:

```bash
npm exec --package=@openclient-ios/opencode-plugin@0.3.0 -- openclient-notify pair --data-dir /absolute/path/to/NotificationPWA/.data
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

The default export in `src/index.ts` contains both host entry points. V1 returns
its tools/hooks from `server`; `src/v2.ts` registers the shared tools and event
adapter through the v2 context. Keep host-specific translation at this boundary.

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
