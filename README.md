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
new colours** — change them in the app first, then port them here, or the site,
the app and the store screenshots drift apart.

Key conventions:

- Everything is authored **mobile-first**; media queries only add complexity upward.
- `--w-border` / `--w-shadow` step up at 720px so cards don't look clumsy on phones.
- In dark mode every hard shadow flips from ink to yellow.
- The hero phone is a live HTML port of the app UI (`store/screenshots_v2/src/app-ui.css`),
  authored at true app scale (440pt) and transform-scaled via `--ps`. It carries its
  own `--a-*` theme vars so it renders the app's light theme on a light page and its
  dark theme on a dark one, independent of the page palette.

## Regenerating assets

```sh
sh assets/build-assets.sh
```

Pulls the ten store slides from `../splitzy/store/screenshots_v2/png/`, downscales
and converts them to WebP (2.7 MB → ~670 KB), re-vendors the Poppins woff2 files,
rebuilds the icon variants, and re-renders `assets/og.png` with headless Chrome.
Requires Chrome, `cwebp` (`brew install webp`) and macOS `sips`.

## Deploy

GitHub Pages, from a branch:

- Settings → Pages → Source: **Deploy from a branch**
- Branch: `release` / root (`/`)
- Custom domain: `splitup.tappstudio.in`, Enforce HTTPS

**Pushing to `release` publishes immediately** — there is no CI gate and no preview
environment. (`main` is stale and far behind; don't deploy from it.)

## ⚠️ Load-bearing files

`/join/index.html` and everything under `/.well-known/` make
`https://splitup.tappstudio.in/join?code=ABC123` open the installed app. If you
touch them, re-validate before merging:

- **Apple** — `.well-known/apple-app-site-association`, `appID`
  `686K8WJMYW.in.tappstudio.splitup`, `paths: ["/join*"]`. Must be served as JSON
  with no extension. Check with Apple's AASA validator.
- **Android** — `.well-known/assetlinks.json`, `package_name`
  `in.tappstudio.splitup`, with SHA-256 fingerprints for **both** Play App Signing
  and the local upload keystore. Check with Google's Statement List Generator.

`.nojekyll` must stay: GitHub Pages otherwise strips dot-directories and
`/.well-known/` 404s.

A broken AASA silently breaks group invites in the shipped app, so never change
these "just to tidy up".

See `deeplink.md` in the Splitup Flutter repo for the full brief.
