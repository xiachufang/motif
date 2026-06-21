# Releasing Motif

The version is decided in **one place** — `apps/flutter/pubspec.yaml`:

```yaml
version: 1.0.1+2
#        ^^^^^ ^
#        |     build number (+N)
#        semantic version (MAJOR.MINOR.PATCH)
```

The `Makefile` reads this and feeds it into every build (`--build-name` /
`--build-number`, artifact names, the manifest). iOS/macOS get the same version
through Xcode Cloud, which runs `flutter build --config-only` so the app's
`CFBundleShortVersionString` / `CFBundleVersion` also come from pubspec. The git
**tag** decides the GitHub Release / `.dmg` title. These must agree:
`release-tag` derives the tag from pubspec so they can't drift, and the tag is
re-asserted against pubspec on every tagged push — by `version-check` for the
GitHub Actions builds, and by the `ci_post_clone.sh` guard for the Xcode Cloud
iOS/macOS builds.

## Steps

1. **Bump the version.** Edit `apps/flutter/pubspec.yaml`:
   - Raise the semantic version (`1.0.0` → `1.0.1`) for a user-facing release.
   - **Always raise the build number** (`+1` → `+2`), even for a re-spin of the
     same semantic version — App Store / Play reject a non-increasing build
     number.

2. **Commit the bump.**

   ```sh
   git commit -am "Release 1.0.1"
   ```

3. **Tag and push.** `make release-tag` creates `v<semver>` from pubspec (it
   refuses a dirty tree or an existing tag), then push the tag to fire the CI:

   ```sh
   make release-tag
   git push origin main           # the bump commit
   git push origin v1.0.1         # the command release-tag printed
   ```

   Pushing the tag triggers:
   - `release-desktop` → Linux + Windows desktop apps
   - `release-motifd` → Linux + macOS `motifd` binaries
   - `review-image` / `motifd-image` / `rendezvous-image` → Docker images
   - **Xcode Cloud** (separate from GitHub Actions) → macOS `.dmg` + iOS

   All assets land on the **same** GitHub Release named after the tag; whichever
   job finishes first creates it, the rest append.

4. **Verify.** Watch the Actions tab go green, then check the `v1.0.1` Release
   has the desktop `.tar.gz`s, the `motifd` `.tar.gz`s, `MANIFEST.txt`, and the
   Xcode Cloud `.dmg`.

## Dry run before tagging

Every release workflow has `workflow_dispatch`, so you can run it manually from
the Actions tab to shake out build issues before committing to a tag
(`version-check` is skipped on manual runs). Locally you can also build a single
platform — same commands the CI runs, output in `dist/release/`:

```sh
make release-flutter-macos      # or release-flutter-linux / -windows
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
