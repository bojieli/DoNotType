#!/bin/sh
set -eu
cd "$(dirname "$0")"
xcrun clang -fobjc-arc -fmodules -O2 -mmacosx-version-min=12.0 "$@" \
    -framework Foundation -framework AVFoundation \
    -Wl,-sectcreate,__TEXT,__info_plist,Info.plist record.m -o record
