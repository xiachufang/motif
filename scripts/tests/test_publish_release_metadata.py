import hashlib
from pathlib import Path
import sys
import tempfile
import unittest


sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from publish_release_metadata import build_asset_entry, merge_manifest


class ReleaseMetadataTest(unittest.TestCase):
    def test_builds_immutable_asset_metadata(self):
        with tempfile.TemporaryDirectory() as directory:
            artifact = Path(directory) / "motifd-1.2.3-linux-x86_64.tar.gz"
            artifact.write_bytes(b"motifd archive")

            entry = build_asset_entry(
                artifact=artifact,
                repository="xiachufang/motif",
                tag="v1.2.3",
                published_at="2026-08-03T00:00:00Z",
            )

        self.assertEqual(entry["version"], "1.2.3")
        self.assertEqual(entry["tag"], "v1.2.3")
        self.assertEqual(entry["size"], len(b"motifd archive"))
        self.assertEqual(
            entry["sha256"], hashlib.sha256(b"motifd archive").hexdigest()
        )
        self.assertEqual(
            entry["url"],
            "https://github.com/xiachufang/motif/releases/download/"
            "v1.2.3/motifd-1.2.3-linux-x86_64.tar.gz",
        )

    def test_preserves_other_platforms_when_advancing_one(self):
        existing = {
            "schema": 1,
            "channel": "stable",
            "product": "app",
            "updatedAt": "2026-08-01T00:00:00Z",
            "assets": {
                "macos-arm64": {"version": "1.2.2", "url": "https://old"}
            },
        }
        linux = {"version": "1.2.3", "url": "https://new"}

        merged = merge_manifest(
            existing,
            product="app",
            platform="linux-x86_64",
            entry=linux,
            updated_at="2026-08-03T00:00:00Z",
        )

        self.assertEqual(merged["assets"]["macos-arm64"]["version"], "1.2.2")
        self.assertEqual(merged["assets"]["linux-x86_64"], linux)
        self.assertEqual(merged["updatedAt"], "2026-08-03T00:00:00Z")
        self.assertNotIn("linux-x86_64", existing["assets"])

    def test_rejects_cross_product_updates(self):
        with self.assertRaisesRegex(ValueError, "product does not match"):
            merge_manifest(
                {
                    "schema": 1,
                    "channel": "stable",
                    "product": "motifd",
                    "assets": {},
                },
                product="app",
                platform="linux-x86_64",
                entry={"version": "1.2.3"},
            )


if __name__ == "__main__":
    unittest.main()
