# Splitup Web

Splitup's marketing landing page **and** the Universal Link / App Link host
for `splitup.tappstudio.in`. Pure HTML/CSS, no build step.

## What's here

```
/index.html                                  landing page
/style.css                                   shared styles (brand tokens pulled from the Splitup Flutter app)
/join/index.html                             store-redirect fallback for the join deep link
/.well-known/apple-app-site-association       iOS Universal Links verification
/.well-known/assetlinks.json                  Android App Links verification
/CNAME                                        GitHub Pages custom domain
```

## Deploy

Deployed via **GitHub Pages from the `release` branch, root (`/`)**. `main`
is reserved for source/dev if a build step is ever introduced later —
there is none today, so `release` can be edited directly, or changes can be
merged/cherry-picked over from `main`.

```bash
git checkout release
# edit files
git commit -m "..."
git push origin release
```

GitHub Pages settings: Settings → Pages → Source: "Deploy from a branch",
Branch: `release` / `root (/)`, Custom domain: `splitup.tappstudio.in`,
Enforce HTTPS enabled once the cert provisions.

## ⚠️ Load-bearing files

`/join/index.html` and everything under `/.well-known/` are load-bearing for
the Splitup app's "join a group via link" deep linking
(`https://splitup.tappstudio.in/join?code=ABC123`). Before merging any
change to those files, re-validate:

- AASA: [Apple's AASA validator](https://search.developer.apple.com/appsearch-validation-tool/)
  — expects `appID: 686K8WJMYW.in.tappstudio.splitup`, `paths: ["/join*"]`.
- assetlinks.json: Google's
  [Statement List Generator](https://developers.google.com/digital-asset-links/tools/generator)
  — expects `package_name: in.tappstudio.splitup` with both the Play App
  Signing and local upload-keystore SHA-256 fingerprints listed.

See `deeplink.md` in the Splitup Flutter repo for the full deep-link brief.
