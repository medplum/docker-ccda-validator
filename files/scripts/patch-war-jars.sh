#!/bin/sh
#
# Replace known-vulnerable jars inside the vendor WAR with the lowest fixed
# versions that keep Java 8 bytecode compatibility. The table lives in
# files/jar-patches/replacements.tsv.
#
# Deliberately NOT patched here:
#
#   * spring-core / -web / -webmvc / -expression -- every remaining fix is in
#     Spring 6.x or 7.x, which require jakarta.servlet and Java 17. That means a
#     WAR recompiled by upstream plus Tomcat 10+, not a jar swap. One of them
#     (CVE-2026-41849, spring-expression) has no fixed release at all.
#   * xmlbeans, xlsx-streamer -- code-validator-api is precompiled against
#     xlsx-streamer 1.0.1, so a major bump risks NoSuchMethodError while parsing
#     the VSAC valueset spreadsheets, which is the vocabulary validation path.
#   * springfox-swagger-ui -- has to stay in step with springfox-swagger2 2.5.0.
#
# Usage: patch-war-jars.sh <exploded WEB-INF/lib> <jar-patches dir>
# Requires MAVEN_REPO in the environment.

set -eu

LIB="$1"
PATCHES="$(cd "$2" && pwd)"   # absolute: the verify step runs from a temp dir
: "${MAVEN_REPO:?MAVEN_REPO must be set}"

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

# Fetch every replacement first, then verify the whole set against the pinned
# checksums before touching the WAR.
count=0
while read -r old path; do
    case "$old" in ''|'#'*) continue ;; esac

    if [ ! -f "$LIB/$old" ]; then
        echo "ERROR: $old is not in the WAR." >&2
        echo "       The WAR's dependency versions changed. Re-scan the image and" >&2
        echo "       rebuild files/jar-patches/replacements.tsv before continuing --" >&2
        echo "       skipping it would silently ship the vulnerable jar." >&2
        exit 1
    fi

    curl -fsSL -o "$STAGE/$(basename "$path")" "$MAVEN_REPO/$path"
    count=$((count + 1))
done < "$PATCHES/replacements.tsv"

( cd "$STAGE" && sha256sum -c "$PATCHES/patches.sha256" )

# Swap them in only once everything above succeeded.
while read -r old path; do
    case "$old" in ''|'#'*) continue ;; esac
    rm -f "$LIB/$old"
    cp "$STAGE/$(basename "$path")" "$LIB/"
    echo "patched: $old -> $(basename "$path")"
done < "$PATCHES/replacements.tsv"

echo "patch-war-jars: replaced $count jar(s)"
