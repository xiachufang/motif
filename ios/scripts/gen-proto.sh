#!/usr/bin/env bash
# Regenerate Asr.pb.swift from Asr.proto using protoc + protoc-gen-swift.
# Run after editing the .proto file.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
IOS_DIR="$(cd -- "$SCRIPT_DIR/.." &> /dev/null && pwd)"
ASR_DIR="$IOS_DIR/Motif/ASR"
OUT_DIR="$ASR_DIR/Proto"

if ! command -v protoc &> /dev/null; then
    echo "error: protoc not found. brew install protobuf" >&2; exit 1
fi
if ! command -v protoc-gen-swift &> /dev/null; then
    echo "error: protoc-gen-swift not found. brew install swift-protobuf" >&2; exit 1
fi

mkdir -p "$OUT_DIR"
protoc --proto_path="$ASR_DIR" --swift_out="$OUT_DIR" "$ASR_DIR/Asr.proto"
echo ">>> generated $OUT_DIR/Asr.pb.swift"
