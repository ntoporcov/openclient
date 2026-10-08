# App Store creative assets

Dedicated artwork for the **Header** and **Search Results** placements in App Store Connect.

- `en-US/header-3840x1646.png`: product page header.
- `en-US/search-results-3840x2560.png`: search results.
- `pt-BR/` and `it/`: localized search-results copy; captured app content remains English. The header has centered phone artwork without promotional text and is identical across locales.

All exports are opaque sRGB PNGs. These are separate from the ten-image screenshot gallery.

Regenerate from the repository root:

```sh
swift scripts/render-app-store-creatives.swift
```

The artwork uses existing real iPhone captures of grouped tool activity and project sessions. Upload each file to its corresponding placement, then use ASC Preview to check the final presentation before submitting.

Specifications: https://developer.apple.com/help/app-store-connect/reference/app-information/creative-assets-specifications
