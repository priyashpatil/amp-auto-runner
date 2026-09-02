#!/bin/bash

set -euo pipefail

source_icon="$1"
output_icon="$2"
iconset="$(dirname "${SCRIPT_OUTPUT_FILE_1}")"
mkdir -p "$iconset" "$(dirname "$output_icon")"
rm -f "$iconset"/*.png "$output_icon"

for size in 16 32 128 256 512; do
    sips -s format png -z "$size" "$size" "$source_icon" \
        --out "$iconset/icon_${size}x${size}.png" >/dev/null
    double_size=$((size * 2))
    sips -s format png -z "$double_size" "$double_size" "$source_icon" \
        --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done

iconutil -c icns "$iconset" -o "$output_icon"
