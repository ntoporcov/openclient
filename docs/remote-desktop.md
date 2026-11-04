# Remote desktop and human handoff

## Product contract

Two entry points share one host-scoped desktop viewer:

- A plugin tool requests human help, presenting a transcript card with the reason and an Open Remote Desktop action. Its execution remains pending until the user explicitly chooses Done or Cancel. Closing the viewer does not complete the tool.
- Projects exposes Remote Desktop when the connected plugin supports a usable viewer session. Manual access is independent of chat execution.

The desktop must be the same interactive desktop used by the agent. A separate virtual login session does not satisfy a login handoff.

## Implemented: detection boundary

Set `OPENCLIENT_VNC_URL=vnc://127.0.0.1:5900` in the plugin host environment and restart OpenCode. This is explicit host configuration, not a tool-supplied network target. URLs cannot contain credentials.

The bridge health response includes an additive `remoteDesktop` field:

```json
{
  "version": 1,
  "transport": "rfb",
  "state": "detected",
  "protocolVersion": "003.008"
}
```

States are `unconfigured`, `unavailable`, and `detected`. Detection reads the 12-byte RFB server greeting with a one-second deadline. It does not authenticate or send input. Results are cached for five seconds and concurrent probes coalesce. Target addresses and credentials are not advertised.

iOS preserves this advertisement on its discovered bridge endpoint. Older plugins and malformed optional advertisements remain compatible. `detected` deliberately does not enable an Open button: it is not proof that authentication, shared-desktop access, or screen transport works.

## Next implementation gates

1. Test a noVNC viewer against macOS Screen Sharing on the actual agent desktop, including authentication and shared-session behavior. Record supported authentication types; an RFB greeting alone cannot prove compatibility.
2. Implement the separate binary WebSocket-to-RFB transport. Reuse authenticated host connectivity where available; the current bridge's health/device registration endpoint alone is not desktop authorization. Use short-lived viewer credentials and explicit origin validation. Do not proxy arbitrary client-supplied destinations.
3. Bundle the viewer for iOS, then add its dedicated store/coordinator, reconnect, keyboard modifiers, pointer gestures and lifecycle cleanup. Avoid routing frames through chat SSE.
4. Add the Projects entry point using live viewer capability, not merely plugin presence.
5. Add the pending handoff tool for both supported plugin APIs and its native transcript presentation. Bind completion to the originating tool/session. Done resumes the agent; cancellation and abort resolve cleanly; viewer dismissal leaves the request pending. Support reopening after disconnect.

## Verification

Initial host probe on November 3, 2026 found `RFB 003.889` at `127.0.0.1:5900`. Authentication and shared-desktop behavior have not yet been verified.

- Plugin tests use real loopback TCP servers for fragmented RFB greetings, non-VNC services, silent/partial peers, probe coalescing and credential-free configuration.
- The final feature requires physical iPhone testing against the actual desktop: login handoff, manual access, reconnect, cancel, tool abort and same-host/multiple-project behavior.
