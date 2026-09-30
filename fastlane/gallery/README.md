# App Store gallery — 1.0.23 draft

Ten headline/subheadline compositions for each device:

1. Projects and conversations
2. Queue and Steer
3. Side Question
4. Optional tool/reasoning/context grouping
5. Accent colors and bubble styles
6. Project conversations and pinned sessions
7. Project, model, agent, and reasoning selection
8. In-chat permission approvals
9. Assistant questions
10. Home Screen widgets

All ten slides use dedicated gallery captures. For an early draft when a dedicated
capture is missing, the renderer can explicitly reuse the screenshot library:

```sh
swift scripts/render-app-store-gallery.swift --existing-captures
```

The default command requires dedicated gallery captures for every slide. The
fallback flag never replaces a dedicated gallery capture when one exists.

Capture `GalleryScreenshotUITests/testCaptureGallerySources` on the current required
iPhone Pro Max and 13-inch iPad Pro simulators. Captures are deterministic, use sample
content, and write `gallery-*.png` into `fastlane/screenshots/en_US/`.

Then run from the repository root:

```sh
swift scripts/render-app-store-gallery.swift
```

The renderer writes full-resolution PNGs and overview contact sheets to `en-US/`:

- iPhone: 1320 × 2868
- iPad: 2064 × 2752

Edit headline/subheadline copy and palette in the renderer. These are English marketing
drafts, separate from the application's localized String Catalogs. The captured product
UI is not repainted. Screens are framed and scaled proportionally.

## App Store Connect management

`fastlane ios metadata` renders the gallery from dedicated captures, stages exactly
10 numbered slides per device under `build/app-store-gallery/en-US/`, and replaces
the App Store Connect screenshots through the API alongside metadata. Contact sheets
and raw simulator captures are excluded. Exported PNGs have no alpha channel.
The renderer uses an opaque RGBX Quartz canvas and validates decoded PNG pixels
for color variation and bright content before staging. Unsupported 24-bit AppKit
drawing contexts previously produced all-black files despite valid PNG headers.

Use `FASTLANE_SKIP_SCREENSHOTS=1 fastlane ios metadata` for a text-only update.
The standalone renderer does not upload anything.
