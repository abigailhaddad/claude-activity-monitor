#!/usr/bin/env bash
# install.sh's "audio off" rewrite must actually blank the audio keys.
# The sed line is pulled out of install.sh and run on a copy of config.yaml.

set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
source "$DIR/helpers.sh"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
CONFIG="$TMP/config.yaml"
cp "$DIR/../config.yaml" "$CONFIG"
tmp="$TMP/out.yaml"

echo "== install.sh audio off =="

cmd=$(grep -A1 "release_audio_file):" "$DIR/../install.sh")
# the extracted line already ends with `> "$tmp" && mv "$tmp" "$CONFIG"`
eval "$cmd" 2>/dev/null

assert_eq "$(grep '^block_audio_file:' "$CONFIG")" 'block_audio_file: ""' "block_audio_file blanked"
assert_eq "$(grep '^release_audio_file:' "$CONFIG")" 'release_audio_file: ""' "release_audio_file blanked"
assert_eq "$(grep '^nudge_audio_file:' "$CONFIG")" 'nudge_audio_file: ""' "nudge_audio_file blank"

report
