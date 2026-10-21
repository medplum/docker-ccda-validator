#!/usr/bin/env bash
# Build referenceccdaservice.war from the submodules and copy it to webapps/.
#
# Order matters: the WAR resolves contentvalidator-api and codevalidator-api
# from the local Maven repo and neither is published anywhere, so both forks
# have to be installed first. See "The WAR must be built first" in README.md.
#
#   scripts/build-war.sh                  # all three, tests skipped
#   scripts/build-war.sh --only-validator # just the WAR (forks already installed)
#   scripts/build-war.sh --with-tests     # run the validator's tests too
#
# Always `clean`: maven-war-plugin assembles the WAR from the exploded
# target/referenceccdaservice/ directory and never prunes it, so after a
# dependency bump the old jar stays in WEB-INF/lib beside the new one. The WAR
# then ships both (jackson-databind 2.22.1 *and* 2.22.3), the scanner still
# flags the old one, and which one loads is up to classpath order.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MVN=(mvn -B -ntp)
only_validator=false
validator_goal=(-DskipTests clean package)

for arg in "$@"; do
  case "$arg" in
    --only-validator) only_validator=true ;;
    --with-tests) validator_goal=(clean verify) ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

if [[ "$only_validator" == false ]]; then
  (cd "$ROOT/submodules/content-validator-api" && "${MVN[@]}" -DskipTests clean install)
  (cd "$ROOT/submodules/code-validator-api" && "${MVN[@]}" -DskipTests clean install)
fi
(cd "$ROOT/submodules/reference-ccda-validator" && "${MVN[@]}" "${validator_goal[@]}")

war="$ROOT/submodules/reference-ccda-validator/target/referenceccdaservice.war"
# Belt and braces for the `clean` above: two versions of one jar is never intended.
dupes="$(unzip -Z1 "$war" 'WEB-INF/lib/*.jar' | sed -E 's|.*/||; s/-[0-9][^-]*(-SNAPSHOT)?\.jar$//' | sort | uniq -d)"
if [[ -n "$dupes" ]]; then
  echo "WEB-INF/lib holds more than one version of: $dupes" >&2
  exit 1
fi

mkdir -p "$ROOT/webapps"
cp "$war" "$ROOT/webapps/"
echo "built $ROOT/webapps/referenceccdaservice.war"
