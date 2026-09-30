# Changelog

## 0.4.1

- Keep OpenClient tool execution outside V2 Code Mode so native visual renderer
  metadata is preserved in the transcript. Nested Code Mode calls only retain
  input/status, causing successfully prepared images and other visuals to disappear.

## 0.4.0

- Add OpenCode V2 native tool registration, cancellation, session location handling,
  and notification event normalization, alongside OpenCode V1 1.18.29+ support.
- Keep the same package entry point for both host versions.
- Support explicit `serverURL` configuration for managed V2 services.
- Rename the internal bridge server module so V2 local-directory discovery loads
  the plugin entry point instead of mistaking the bridge helper for a plugin.

## 0.3.0

- Bundle optional OC Notify notifications and the `openclient-notify` pairing CLI.
