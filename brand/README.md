# Sky Lang brand assets

SVG-only brand kit. All assets are pure SVG with no external dependencies (system-ui font stack — browsers render natively).

## Files

| File | Use case | Size |
|---|---|---|
| `icon.svg` | Primary app icon — README headers, social preview, marketing pages, large display contexts | 256 × 256 viewBox (scales to any size) |
| `favicon.svg` | Browser favicon — solid fill (not gradient) so it stays crisp at 16 × 16 | 64 × 64 viewBox |
| `wordmark.svg` | Horizontal "SKY LANG" wordmark — emails, presentation slides, READMEs that want the full name | 520 × 144 viewBox |
| `icon-light.svg` | Inverted variant for dark backgrounds (dark-mode docs, dark slides) | 256 × 256 viewBox |
| `icon-mono.svg` | Single-color outline variant — uses `currentColor`, caller controls fill via CSS `color:` | 256 × 256 viewBox |

## Palette

| Token | Hex | Use |
|---|---|---|
| Dark navy | `#1a1a2e` | Logo background, primary on light surfaces |
| Indigo light | `#a5b4fc` | "SKY" wordmark text, icon gradient start, light-on-dark text |
| Indigo deep | `#4f46e5` | Icon gradient end, primary buttons, accents |
| Slate gray | `#64748b` | "LANG" wordmark text, body subtle text |
| Indigo-50 | `#eef2ff` | Background for `icon-light.svg`, very-subtle accent backgrounds |

## Usage examples

### HTML favicon link

```html
<link rel="icon" type="image/svg+xml" href="/brand/favicon.svg">
```

### README header

```markdown
<p align="center">
    <img src="https://sky-lang.org/brand/wordmark.svg" alt="Sky Lang" width="320">
</p>
```

### Social preview (OpenGraph)

```html
<meta property="og:image" content="https://sky-lang.org/brand/icon.svg">
<meta property="twitter:image" content="https://sky-lang.org/brand/icon.svg">
```

(Note: some social media platforms — Twitter / LinkedIn — prefer PNG for previews. Run `rsvg-convert -w 1200 -h 630 icon.svg > og-image.png` to generate a PNG variant if needed.)

### Inline SVG (best for mask-image / CSS recolour via `icon-mono.svg`)

```html
<span class="sky-icon" style="color: var(--brand)">
    <!-- inline the SVG file content here -->
</span>
```

## Don'ts

- Don't recolour the gradient stops without updating both endpoints
- Don't stretch the wordmark — adjust the SVG width attr proportionally
- Don't apply drop shadows or glows in CSS — the design is intentionally flat
- Don't use the icon at < 24 × 24 — use `favicon.svg` for tiny sizes (it has a higher contrast ratio)

## License

Same as the rest of `sky-lang.org` — Apache 2.0 for the brand assets, free to use in references to the language ("built in Sky Lang", "powered by Sky Lang"), modify for brand-consistent variants, etc. Don't use the marks to imply endorsement of unrelated projects.
