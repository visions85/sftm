#!/bin/sh
# Fetch the MAME driver source files the SFTM port is written against.
# See cores/sftm/doc/PORTING.md. Files land in doc/mame-src/ (gitignored).
set -e
cd "$(dirname "$0")"
mkdir -p mame-src
for f in src/mame/itech/itech32.cpp src/mame/itech/itech32.h \
         src/mame/itech/itech32_v.cpp \
         src/devices/sound/es5506.cpp src/devices/sound/es5506.h; do
    echo "fetching $f"
    curl -sL "https://raw.githubusercontent.com/mamedev/mame/master/$f" \
         -o "mame-src/$(basename "$f")"
done
