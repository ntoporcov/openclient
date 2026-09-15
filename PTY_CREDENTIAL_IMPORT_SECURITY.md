# PTY Credential Import Security Boundary

This foundation uses a dedicated legacy OpenCode PTY as a bounded transport for a
selected provider credential. Production composition creates the transport and importer
only after explicit read approval and current-context revalidation. Tests use synthetic
source data only.

Upstream OpenCode's PTY create contract accepts `env`, while PTY `Info`, inventory,
and lifecycle events expose `command`, `args`, `cwd`, and other process metadata but
not `env`. PTY output is broadcast to subscribers and retained in a replay buffer;
other authorized subscribers can also inject input. The operation PSK is therefore
placed only in the PTY environment. Credential values are never placed in the PTY
title, command, arguments, environment, URL, query, logs, or temporary files.

Each operation uses an ephemeral iPhone and helper X25519 key pair plus a random PSK.
READY is authenticated with HMAC-SHA256 and binds the client key, helper key, version,
operation, provider, and source. Directional ChaCha20-Poly1305 keys are derived with
HKDF-SHA256 over the X25519 shared secret, using the PSK as salt and the transcript as
context. START and RESULT bind direction, message type, sequence, and nonce as AEAD
associated data. The helper does not read the source before authenticating START.

This application-layer encryption prevents passive network observers and PTY
subscribers that know only public PTY metadata from reading the RESULT or forging
READY, START, or RESULT. It does not make plain HTTP or WS safe. An active MITM on
HTTP can observe or alter PTY creation, including its environment, and can expose or
compromise the existing OpenCode control-plane Basic authentication. HTTP/WS is
rejected by default and requires an explicit insecure-transport opt-in. HTTPS/WSS
uses normal platform trust and is accepted by default.

Only the verified legacy PTY/auth-file contract is eligible. The current local v2 PTY
contract has not been verified for credential import and fails closed. A retry is a
new explicit operation: there is no reconnect, re-execution, fallback path, crawl, or
automatic reread. Cleanup targets exactly the operation's captured PTY through the
captured transport and scope; existing PTYs are not inventoried or changed. Cleanup is
best-effort and bounded so a nonresponsive server cannot indefinitely delay the primary
result. A cleanup timeout does not claim that the remote PTY was deleted; the helper's
own deadline still limits credential-read lifetime.

Importer PTYs use a reserved title plus exact helper argument signature and are filtered
from OpenClient's normal terminal lifecycle and inventory projection. This is UI
containment, not a security boundary against other OpenCode clients. The helper also
fails closed when `OPENCODE_AUTH_CONTENT` is present rather than treating a potentially
stale file as the active OpenCode credential source.
