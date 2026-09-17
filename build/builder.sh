#!/bin/bash
set -euo pipefail

LIBSCRAPLI_TAG="${TAG:-}"
LIBSCRAPLI_TARGET="${TARGET:-}"
OUT_NAME="${OUT_NAME:-}"

if [[ -z "$LIBSCRAPLI_TAG" ]]; then
    git clone --depth 1 https://github.com/kentik/libscrapli

elif [[ "$LIBSCRAPLI_TAG" =~ ^[0-9a-fA-F]{7,40}$ ]]; then
    git clone https://github.com/kentik/libscrapli
    git -C ./libscrapli/ checkout "$LIBSCRAPLI_TAG"

else
    git clone --branch "$LIBSCRAPLI_TAG" --depth 1 --single-branch https://github.com/kentik/libscrapli
fi

cd libscrapli

# hack to get openssl to not break on first build? i dunno... whatever
# NOTE(kentik): keep this step (with -Dtarget) even though upstream removed it --
# it fixes libscrapli's own docker build path so the statically linked openssl is
# built for the same target/CPU baseline as the rest of libscrapli, avoiding a
# CPU-feature mismatch. See docs/SIGILL-INVESTIGATION-REPORT.md section 0.6.
cd lib/openssl
zig build "-Dtarget=${LIBSCRAPLI_TARGET}"
cd ../..

zig build "-Dtarget=${LIBSCRAPLI_TARGET}" -freference-trace --summary all -- --release

cp zig-out/"${LIBSCRAPLI_TARGET}"/libscrapli.* /out/"${OUT_NAME}"
