# Cellblock Repo

Tweaks made for Cellblock OS (roothide, iphoneos-arm64e).

Add this source in Sileo or Zebra:

```
https://misalovesjapuszko.github.io/cellblock-repo/
```

To publish a package, put its `.deb` in `debs/` and push. A GitHub Action rebuilds
`Packages` and `Release`.
