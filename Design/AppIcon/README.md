# Mimo app icon

Two rounded arches make an “m”: a frosted mark over a graphite-blue tile. All artwork is original, editable vector geometry.

- `mimo-icon.svg`: composed preview/master artwork, 1024 × 1024.
- `mimo-icon.png`: 1024px PNG with transparent outer padding.
- `mimo-icon.icns`: static macOS export with 16, 32, 128, 256, and 512-point representations at 1× and 2×.
- `mimo-symbol.svg`: simplified monochrome menu-bar artwork.
- `layers/background.svg` and `layers/glyph.svg`: separate unmasked full-square layers for the native Icon Composer handoff. These are source inputs, not a compiled `.icon` document.

The web preview uses these assets. No installed application bundle or existing dynamic country/status Dock behavior has changed.

The raster exports are generated from the master SVG with the `sharp` development tool; macOS `iconutil` packages the iconset. No rasterizer or dependency is needed by the webpage at runtime.
