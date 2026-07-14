# Releasing Motif

The version is decided in **one place** — `apps/flutter/pubspec.yaml`:

```yaml
version: 1.0.1+2
#        ^^^^^ ^
#        |     build number (+N)
#        semantic version (MAJOR.MINOR.PATCH)
```

The `Makefile` reads this and feeds it into every build (`--build-name` /
`--build-number`, artifact names, the manifest). The iOS Xcode Cloud build runs
`flutter build --config-only`, so its `CFBundleShortVersionString` /
`CFBundleVersion` also come from pubspec. The git **tag** decides the GitHub
Release / `.dmg` title. These must agree: `release-tag` derives the tag from
pubspec so they can't drift, and the tag is re-asserted against pubspec on every
tagged push — by `version-check` for the GitHub Actions builds, and by the
`ci_post_clone.sh` guard for the Xcode Cloud iOS build.

## Steps

From a clean working tree, one command does everything — bump, commit, tag, push:

```sh
make release-tag                 # BUMP=patch (default): 1.0.0 -> 1.0.1
make release-tag BUMP=minor      # 1.0.3 -> 1.1.0
make release-tag BUMP=major      # 1.3.2 -> 2.0.0
```

`release-tag` will:

1. Refuse to run if the working tree is dirty (so the only change is the bump).
2. Compute the new version from `BUMP` and **always increment the build number**
   (`+N` → `+N+1`) — App Store / Play reject a non-increasing build number.
3. Rewrite `version:` in `apps/flutter/pubspec.yaml`, commit it as
   `Release <semver>`, create the annotated tag `v<semver>` (refusing if it
   already exists), then push the current branch **and** the tag.

   Pushing the tag triggers:
   - `release-desktop` → Linux + Windows desktop apps
   - `release-macos-signed` → signed + notarized macOS `.dmg`
   - `release-motifd` → Linux + macOS `motifd` binaries
   - `review-image` / `motifd-image` / `rendezvous-image` / `push-relay-image` → Docker images
   - **Xcode Cloud** (separate from GitHub Actions) → iOS

   All assets land on the **same** GitHub Release named after the tag; whichever
   job finishes first creates it, the rest append.

**After pushing**, verify: watch the Actions tab go green, then check the new
Release has the desktop `.tar.gz`s, the `motifd` `.tar.gz`s, `MANIFEST.txt`, and
the signed and notarized macOS `.dmg`. Verify the iOS build separately in Xcode
Cloud / App Store Connect.

## Dry run before tagging

Every release workflow has `workflow_dispatch`, so you can run it manually from
the Actions tab to shake out build issues before committing to a tag
(`version-check` is skipped on manual runs). Locally you can also build a single
platform — same commands the CI runs, output in `dist/release/`:

```sh
make release-flutter-macos      # signed + notarized; local Keychain or five CI credential env vars
make release-flutter-linux      # or release-flutter-windows
make release-motifd-macos       # or release-motifd-linux
make release-manifest
```

## Rolling back a bad tag

```sh
git push origin :refs/tags/v1.0.1   # delete remote tag
git tag -d v1.0.1                   # delete local tag
```

Then delete the GitHub Release from the Releases page, and handle any build
already uploaded to App Store Connect / TestFlight there.

## Notes

- The Rust workspace version (`Cargo.toml`, `0.1.0`) is independent and not part
  of consumer releases — don't touch it for a normal release.
- `version-check` only compares `MAJOR.MINOR.PATCH`. Pre-release / CI suffixes
  pass: `v1.0.1-rc1` and `v1.0.1-ci.20260618.1` both match pubspec `1.0.1`.
- The build number (`+N`) is never in the tag and is not CI-checked — it's on
  you to bump it.
