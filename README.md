# Cellblock Repo

Tweaks made for Cellblock OS (roothide, iphoneos-arm64e).

Add this source in Sileo or Zebra:

```
https://raw.githubusercontent.com/misalovesjapuszko/cellblock-repo/main/
```

To publish a package, put its `.deb` in `debs/` and push. A GitHub Action rebuilds
`Packages` and `Release`.

## Tweaks

| Tweak | What it does |
|---|---|
| **Tidy** | Hides icon labels, page dots and the dock background (each switchable in TweakSettings) |
| **Tumble** | Home screen icons with gravity: tilt your phone and they fall, bounce and spin |

Sources are in `tweaks/<name>/`; `tweaks/tweaks.txt` lists them. Pushing a change builds the
`.deb`s on GitHub's macOS runner and updates the index.
