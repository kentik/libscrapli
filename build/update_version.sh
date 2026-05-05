#!/bin/bash
set -euo pipefail

LIBSCRAPLI_TAG="${1:-}"
VERSION="${LIBSCRAPLI_TAG#v}"

IFS='-' read -r BASE PRE <<<"$VERSION"
IFS='.' read -r MAJOR MINOR PATCH <<<"$BASE"

if [[ -z "$PRE" ]]; then
    PRE="null"
else
    PRE="\"$PRE\""
fi

sed -i.bak -E "s|^([[:space:]]+\.major =)(.*)|\1 ${MAJOR},|" build.zig
sed -i.bak -E "s|^([[:space:]]+\.minor =)(.*)|\1 ${MINOR},|" build.zig
sed -i.bak -E "s|^([[:space:]]+\.patch =)(.*)|\1 ${PATCH},|" build.zig
sed -i.bak -E "s|^([[:space:]]+\.pre =)(.*)|\1 ${PRE},|" build.zig
rm build.zig.bak

sed -i.bak -E "s|(\.version = )(.*)|\1\"${VERSION}\",|g" build.zig.zon
rm build.zig.zon.bak
