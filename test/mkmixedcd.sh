#!/bin/bash
# Build a mixed mode CD image (track 1 data, further tracks audio) as
# BIN/CUE, like the CDs of DOS games with CD audio music.
#
#   test/mkmixedcd.sh <outdir> <audio file>...
#
# Each audio file (anything ffmpeg reads, e.g. FLAC) becomes one audio track,
# cut to TRACK_SECONDS seconds (default 30).  Output: <outdir>/mixed.cue
set -euo pipefail

OUT=$1; shift
TRACK_SECONDS=${TRACK_SECONDS:-30}
mkdir -p "$OUT/data"
printf 'Mixed mode test CD: data track\r\n' > "$OUT/data/README.TXT"
xorriso -as mkisofs -quiet -V MIXEDCD -o "$OUT/track01.iso" "$OUT/data" 2>/dev/null

{
    echo 'FILE "track01.iso" BINARY'
    echo '  TRACK 01 MODE1/2048'
    echo '    INDEX 01 00:00:00'
} > "$OUT/mixed.cue"

n=2
for f in "$@"; do
    bin=$(printf 'track%02d.bin' $n)
    # CD audio: 44.1 kHz, 16 bit little endian, stereo, whole 2352 byte sectors
    ffmpeg -v error -y -t "$TRACK_SECONDS" -i "$f" -f s16le -acodec pcm_s16le -ar 44100 -ac 2 "$OUT/$bin"
    size=$(stat -c %s "$OUT/$bin")
    truncate -s $(( (size + 2351) / 2352 * 2352 )) "$OUT/$bin"
    {
        echo "FILE \"$bin\" BINARY"
        printf '  TRACK %02d AUDIO\n' $n
        echo '    PREGAP 00:02:00'
        echo '    INDEX 01 00:00:00'
    } >> "$OUT/mixed.cue"
    n=$((n + 1))
done
echo "$OUT/mixed.cue"
