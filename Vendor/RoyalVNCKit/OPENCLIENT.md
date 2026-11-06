# OpenClient receive-only clipboard adapter

MIT-licensed source snapshot from https://github.com/royalapplications/royalvnc,
revision `090b96eddeee183e9fec293c5cd881d302a4349d`. The upstream package manifest,
license and Sources are preserved so builds do not mutate SwiftPM checkouts.

Local delta: `VNCConnection.serverClipboardTextHandler` receives ordinary RFB
ServerCutText messages independently of `isClipboardRedirectionEnabled`. It runs
on the receive task; consumers must hop to their own actor. It does not read or
write a system clipboard. OpenClient leaves automatic clipboard redirection off.
Apple servers additionally receive an automatic pasteboard subscription (client
message `0x15`). Apple pasteboard packets (`0x1f`) are decoded independently of
standard ServerCutText; promised contents are requested with `0x0b`. Only UTF-8
and big-endian UTF-16 plain-text flavors reach the callback. Expanded archives
are bounded to 4 MiB; larger archives are drained without expansion. This does
not enable client-to-server clipboard synchronization or alter RFB version
negotiation. Live macOS compatibility still needs verification.

Apple wire-format research: `internal/rfb/clipboard.go`, `messages.go`, and
`handshake.go` in https://github.com/nekohasekai/open-screen-sharing. That project's
GPL source was consulted for protocol facts; its implementation is not vendored.
The Swift receive-only parser is a local implementation. Standard RFB extended
clipboard negotiation remains unsupported by this upstream revision.

Replace the snapshot with an upstream dependency when a receive-only hook is
available. Retain the MIT license with any redistribution.
