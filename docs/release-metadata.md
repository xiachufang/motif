# Stable release metadata

Motif does not treat GitHub's `/releases/latest` response as proof that a
specific product or platform built successfully. Tagged App and motifd builds
publish per-platform stable pointers instead:

```text
https://xiachufang.github.io/motif/meta/v1/app/stable.json
https://xiachufang.github.io/motif/meta/v1/motifd/stable.json
```

Each manifest uses schema version 1 and records immutable GitHub Release URLs,
file sizes, and SHA-256 checksums:

```json
{
  "schema": 1,
  "channel": "stable",
  "product": "motifd",
  "updatedAt": "2026-08-03T10:00:00Z",
  "assets": {
    "linux-x86_64": {
      "version": "1.0.53",
      "tag": "v1.0.53",
      "file": "motifd-1.0.53-36-linux-x86_64.tar.gz",
      "url": "https://github.com/xiachufang/motif/releases/download/v1.0.53/motifd-1.0.53-36-linux-x86_64.tar.gz",
      "releasePage": "https://github.com/xiachufang/motif/releases/tag/v1.0.53",
      "sha256": "...",
      "size": 12345678,
      "publishedAt": "2026-08-03T10:00:00Z"
    }
  }
}
```

## Publishing

`scripts/publish_release_metadata.py` runs only after a release asset has been
built, verified, and uploaded. It updates `meta/v1/<product>/stable.json` on the
`release-metadata` branch through the GitHub Contents API. Updates use the
existing file SHA and retry conflicts, allowing independent platform jobs to
preserve one another's stable entries.

The branch is created from the default branch on the first successful tagged
release. Failed builds never invoke the publisher, so their platform pointer
continues to reference the previous known-good artifact.

After a release workflow completes, `pages.yml` checks out both `main` and
`release-metadata`, copies the latter's `meta/` directory into the site artifact,
and deploys the combined snapshot. This also publishes successful platform jobs
when another matrix entry failed; failed jobs never changed their pointer. A
Pages deployment is atomic and never replaces the existing website with a
metadata-only artifact.

## Consumers

- The desktop update checker reads the current platform's entry from
  `app/stable.json`. It still opens the GitHub Release page for manual install.
- SSH auto-initialize reads `motifd/stable.json`, selects the remote platform,
  and verifies the archive checksum. If the server cannot download or verify
  it, the App downloads and verifies the archive locally before uploading it
  over SFTP.

To roll back a platform, republish an older immutable asset with the script or
revert the corresponding metadata commit on `release-metadata`; no Release
asset needs to be overwritten.
