#!/bin/sh
# Makes small Matroska/WebM files with ffmpeg, remuxes them with the app's code
# and decodes every frame of every track through AVFoundation.
# ffmpeg is only needed to create the fixtures.
set -e
cd "$(dirname "$0")/.."
OUT=build/fixtures
mkdir -p "$OUT"

gen() {
    name=$1; shift
    [ -f "$OUT/$name" ] && return
    ffmpeg -v error -y -f lavfi -i testsrc2=size=640x360:rate=24000/1001 \
        -f lavfi -i sine=frequency=440:sample_rate=48000 -t 4 "$@" "$OUT/$name" 2> "$OUT/ffmpeg.log" \
        || { cat "$OUT/ffmpeg.log"; exit 1; }
}

gen h264_bframes_aac.mkv -c:v libx264 -bf 3 -c:a aac
gen hevc10_ac3.mkv -c:v libx265 -pix_fmt yuv420p10le -c:a ac3 -ac 6 -x265-params log-level=error
gen h264_eac3.mkv -c:v libx264 -c:a eac3
gen h264_mp3.mkv -c:v libx264 -c:a libmp3lame
gen vp9.webm -c:v libvpx-vp9 -b:v 500k -an
gen av1.mkv -c:v libsvtav1 -an

if [ ! -f "$OUT/subtitles.mkv" ]; then
    printf '1\n00:00:00,500 --> 00:00:02,000\n<i>Hello</i> there\n\n2\n00:00:01,500 --> 00:00:03,000\nOverlapping line\n' > "$OUT/s.srt"
    ffmpeg -v error -y -i "$OUT/h264_bframes_aac.mkv" -i "$OUT/s.srt" -map 0 -map 1 -c copy "$OUT/subtitles.mkv"
fi

SOURCES="Sources/EBML.swift Sources/Matroska.swift Sources/MovieWriter.swift Sources/SampleEntries.swift Sources/Remuxer.swift Sources/Subtitles.swift"
xcrun swiftc -O -swift-version 5 $SOURCES Tests/main.swift -o build/check
build/check "$OUT"/*.mkv "$OUT"/*.webm "$@"
