# OpenClient receive-only clipboard adapter

MIT-licensed source snapshot from https://github.com/royalapplications/royalvnc,
revision `090b96eddeee183e9fec293c5cd881d302a4349d`. The upstream package manifest,
license and Sources are preserved so builds do not mutate SwiftPM checkouts.

Local delta: `VNCConnection.serverClipboardTextHandler` receives ordinary RFB
ServerCutText messages independently of `isClipboardRedirectionEnabled`. It runs
on the receive task; consumers must hop to their own actor. It does not read or
write a system clipboard. OpenClient leaves automatic clipboard redirection off.
Extended clipboard negotiation is still unsupported by this upstream revision.

Replace the snapshot with an upstream dependency when a receive-only hook is
available. Retain the MIT license with any redistribution.
