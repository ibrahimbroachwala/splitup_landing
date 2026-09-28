# Splitup Web

Marketing site for [Splitup](https://splitup.tappstudio.in) **and** the host for the
app's Universal Link / App Link verification files.

Pure HTML + CSS. **No build step, no dependencies, no `node_modules`.** Open
`index.html` in a browser, or serve the directory:

```sh
python3 -m http.server 8000
```

## Files

```
index.html            Single-page landing site
style.css             Every page's styles (tokens, primitives, sections, legal)
privacy/ terms/ support/   Legal + support pages
join/                 Deep-link redirect  ⚠️ load-bearing
.well-known/          AASA + assetlinks.json  ⚠️ load-bearing
assets/
  fonts/              Poppins 400-900 (latin + latin-ext), self-hosted
  shots/              Ten gallery screenshots (WebP, 660x1434)
  og-src/og.html      Source for the Open Graph card
  build-assets.sh     Regenerates shots/, fonts/, icons and og.png
robots.txt sitemap.xml CNAME .nojekyll
```

## Design system

The look is neo-brutalist: thick ink borders, **hard offset shadows** (never
blurred), tilted stickers, dot grids and Poppins 800 headlines.

Colours, radii and spacing in `style.css` are mirrored from the Flutter app via
`splitzy/store/screenshots_v2/src/tokens.css`, which in turn mirrors
`lib/styles/colors.dart`, `app_radii.dart` and `app_spacing.dart`. **Don't invent
new colours**, change them in the app first, then port them here, or the site,
the app and the store screenshots drift apart.

Key conventions:

- Everything is authored **mobile-first**; media queries only add complexity upward.
- `--w-border` (2 / 2.5px) and `--w-shadow` (3 / 4px) step up at 720px. Shadows are
  hard-edged but **translucent** (`--shadow-col`), which keeps the neo-brutalist
  look without the eye strain of solid black offsets.
- Borders use `--ink-soft`, not pure `--ink`; large fills use `--yellow-soft`.
- In dark mode hard shadows flip from ink to a translucent yellow.
- Per-theme values are **derived tokens** (`--mark-bg`, `--mark-fg`, `--dot-col`,
  `--doodle-col`) set once per theme. Components read them and never declare their
  own dark rule, otherwise each would need duplicating for the theme toggle.
- Coloured tiles (`.tile-yellow`, `.tile-ink`, `.plan-featured`) must pin `--fg`,
  not just `color`. `.chip` reads `--fg`, so a tile that sets only `color` leaves
  chips inheriting the page's text colour and they vanish in the opposite theme.
- The hero phone is a live HTML port of the app UI (`store/screenshots_v2/src/app-ui.css`),
  authored at true app scale (440pt) and transform-scaled via `--ps`. It carries its
  own `--a-*` theme vars so it renders the app's light theme on a light page and its
  dark theme on a dark one, independent of the page palette.

## Icons

All icons are inline SVG in a `<symbol>` sprite at the top of `<body>`. The
323 KB Material Symbols font is deliberately **not** shipped.

`#i-handshake` is the exception: it's the app's own settlement icon
(`Icons.handshake_outlined`), extracted as an exact path from the same
`material-symbols-outlined.woff2` the store screenshots use, so the web and the
app show the identical glyph. To re-extract after a font update:

```py
from fontTools.ttLib import TTFont
from fontTools.pens.svgPathPen import SVGPathPen
f = TTFont('../splitzy/store/screenshots_v2/src/fonts/material-symbols-outlined.woff2')
gs = f.getGlyphSet(); pen = SVGPathPen(gs); gs['handshake'].draw(pen)
print(pen.getCommands())
```

Material Symbols are 960 upem with the icon box spanning y -80 to 880, so the path
is wrapped in `transform="translate(0,880) scale(1,-1)"` inside a
`viewBox="0 0 960 960"` and filled with `currentColor` (no stroke).

## Theme toggle

The nav has a light/dark toggle. It sets `data-theme` on `<html>` and stores the
choice in `localStorage` under `splitup-theme`. With nothing stored the page follows
the OS via `prefers-color-scheme`.

Every dark rule is therefore declared **twice**: once under
`@media (prefers-color-scheme: dark) { :root:not([data-theme="light"]) ... }` and once
under `:root[data-theme="dark"]`. Keep both in sync, or prefer adding a derived token
to the two root blocks instead (see above).

A tiny inline script in each page's `<head>` applies the stored theme before first
paint, so a chosen theme never flashes the other one. It must stay in `<head>`,
before the stylesheet's first use.

## Copy style

**No em dashes or en dashes anywhere**, including the legal pages. Use a colon,
a comma, a semicolon, a full stop or parentheses instead. Middle dots (`·`) in
the footer and the sample expense row are fine.

Page titles use `Brand | Page` (e.g. `Privacy Policy | Splitup`).

## Pricing model

The site states: **create 1 group free, join unlimited groups free**, and buy more
groups you can create via **one-time** packs of **1 / 5 / unlimited**. Every feature
is unlocked in every group, free or paid. Packs only change how many groups you can
create.

> ⚠️ `/terms/` still describes Unlimited as a *"subscription package"* and applies a
> 30-active-group fair-use cap to it. That wording predates the one-time model and
> contradicts the landing page. It's legal copy, so it wasn't changed here. Get it
> reviewed and updated.

## Regenerating assets

```sh
sh assets/build-assets.sh
```

Pulls the ten store slides from `../splitzy/store/screenshots_v2/png/`, downscales
and converts them to WebP (2.7 MB → ~670 KB), re-vendors the Poppins woff2 files,
rebuilds the icon variants, and re-renders `assets/og.png` with headless Chrome.
Requires Chrome, `cwebp` (`brew install webp`) and macOS `sips`.

## Scrolling gotcha

`overflow: hidden` makes an element a **scroll container**. When an in-page
anchor sits inside one, the browser scrolls that box as well as the window,
shifting content that can never be scrolled back because there is no scrollbar.
This clipped the hero headline and pushed the phone behind the sticky nav.

Every clipping container here therefore declares `overflow: hidden` followed by
`overflow: clip`. `clip` clips identically but is not scrollable; the `hidden`
line stays as a fallback for Safari below 16, which ignores the `clip` line.
**Never use a bare `overflow: hidden` for clipping in this stylesheet.**

Anchor offset is `scroll-padding-top` on `html` only. Do not also add
`scroll-margin-top` to the targets, or the two offsets combine.

## Deploy

GitHub Pages, from a branch:

- Settings → Pages → Source: **Deploy from a branch**
- Branch: `release` / root (`/`)
- Custom domain: `splitup.tappstudio.in`, Enforce HTTPS

**Pushing to `release` publishes immediately**: there is no CI gate and no preview
environment. (`main` is stale and far behind; don't deploy from it.)

## ⚠️ Load-bearing files

`/join/index.html` and everything under `/.well-known/` make
`https://splitup.tappstudio.in/join?code=ABC123` open the installed app. If you
touch them, re-validate before merging:

- **Apple**: `.well-known/apple-app-site-association`, `appID`
  `686K8WJMYW.in.tappstudio.splitup`, `paths: ["/join*"]`. Must be served as JSON
  with no extension. Check with Apple's AASA validator.
- **Android**: `.well-known/assetlinks.json`, `package_name`
  `in.tappstudio.splitup`, with SHA-256 fingerprints for **both** Play App Signing
  and the local upload keystore. Check with Google's Statement List Generator.

`.nojekyll` must stay: GitHub Pages otherwise strips dot-directories and
`/.well-known/` 404s.

A broken AASA silently breaks group invites in the shipped app, so never change
these "just to tidy up".

See `deeplink.md` in the Splitup Flutter repo for the full brief.
