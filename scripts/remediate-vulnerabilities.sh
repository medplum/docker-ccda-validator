#!/usr/bin/env bash
# Rebuild the image with every available fix applied, and report what is left.
#
#   1. Build the WAR, scan its jars, and pin each vulnerable artifact to its
#      fixed version in submodules/reference-ccda-validator/pom.xml
#      (scripts/vulnfix.py pin-java). Repeat until a scan turns up nothing
#      new to pin, since a bump can pull in a different transitive version.
#   2. Run the validator's tests if the pom changed.
#   3. Build the image with --pull --no-cache, so the runtime stage's
#      `dnf upgrade` actually reruns and picks up every ALAS fix published so
#      far. With the layer cached the rebuild is a no-op; see "Rebuilding is
#      what clears OS findings" in README.md.
#   4. Scan the image; raise TOMCAT_VERSION if the Tomcat jars carry a fixed
#      finding, and rebuild once more if so.
#   5. Boot the container and validate a sample C-CDA through the API.
#   6. Write report.md and summary.json, comparing against the deployed image
#      when --baseline-image is given.
#
# Nothing is committed or pushed; scripts/open-remediation-prs.sh does that.
# Needs Docker, JDK 17 + Maven, python3, curl and jq. Trivy runs from a
# digest-pinned container, so it does not need installing.
#
# Options:
#   --out DIR                 output directory (default: ./remediation)
#   --severity LIST           severities to act on (default: HIGH,CRITICAL)
#   --baseline-image REF      deployed image to compare against (must be pullable)
#   --inspector-findings FILE `aws inspector2 list-findings` JSON for that image;
#                             its jar findings are pinned alongside Trivy's
#   --platform PLATFORM       image platform (default: linux/amd64)
#   --skip-image              Java dependencies only
#   --skip-tests              do not run the validator's tests after a pin
#   --max-rounds N            pin/rebuild rounds for the WAR (default: 3)
#
# Environment: FORCE_RELEASE=true marks the run as releasable even when only
# OS packages changed and there is no baseline to prove it.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/remediation"
SEVERITY="HIGH,CRITICAL"
BASELINE_IMAGE=""
INSPECTOR=""
PLATFORM="linux/amd64"
SKIP_IMAGE=false
SKIP_TESTS=false
MAX_ROUNDS=3
IMAGE="ccda-validator:remediation"
VALIDATOR="$ROOT/submodules/reference-ccda-validator"
# Pinned by digest. Trivy's own release channel was compromised in 2026, so a
# floating tag here would run whatever was pushed last with Docker socket-level
# access to the build. Bump deliberately, to a release at least two weeks old.
TRIVY_IMAGE="${TRIVY_IMAGE:-aquasec/trivy:0.75.0@sha256:af6acf9a6b85dfe389a1941505c0ce9efef52a4719635e1a962f022a3d855daa}"
TRIVY_CACHE="${TRIVY_CACHE:-$HOME/.cache/trivy}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --out) OUT="$2"; shift 2 ;;
    --severity) SEVERITY="$2"; shift 2 ;;
    --baseline-image) BASELINE_IMAGE="$2"; shift 2 ;;
    --inspector-findings) INSPECTOR="$2"; shift 2 ;;
    --platform) PLATFORM="$2"; shift 2 ;;
    --skip-image) SKIP_IMAGE=true; shift ;;
    --skip-tests) SKIP_TESTS=true; shift ;;
    --max-rounds) MAX_ROUNDS="$2"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

mkdir -p "$OUT" "$TRIVY_CACHE"
OUT="$(cd "$OUT" && pwd)"
inspector_copy=""
if [[ -n "$INSPECTOR" ]]; then
  inspector_copy="$(mktemp)"
  cp "$INSPECTOR" "$inspector_copy"
fi
rm -f "$OUT"/*.json "$OUT"/*.tar "$OUT"/*.log "$OUT"/report.md
if [[ -n "$inspector_copy" ]]; then
  INSPECTOR="$OUT/inspector-baseline.json"
  mv "$inspector_copy" "$INSPECTOR"
fi

vulnfix() { python3 -I "$ROOT/scripts/vulnfix.py" "$@"; }
log() { printf '\n==> %s\n' "$*"; }
sha() { shasum -a 256 "$1" | cut -d' ' -f1; }

trivy() {
  docker run --rm \
    -v "$TRIVY_CACHE:/root/.cache/trivy" \
    -v "$OUT:/out" \
    -v "$ROOT/webapps:/webapps:ro" \
    "$TRIVY_IMAGE" "$@"
}

scan_war() {
  trivy rootfs --quiet --scanners vuln --pkg-types library --format json \
    --output "/out/$1" /webapps/referenceccdaservice.war
}

scan_image() {  # scan_image IMAGE_REF OUTPUT_NAME
  docker save -o "$OUT/image.tar" "$1"
  trivy image --quiet --scanners vuln --format json --output "/out/$2" --input /out/image.tar
  rm -f "$OUT/image.tar"
}

build_image() {
  docker buildx build --pull --no-cache --platform "$PLATFORM" \
    --provenance=false --sbom=false --load -t "$IMAGE" "$ROOT"
}

smoke_test() {
  local cid port sample ok=false
  cid="$(docker run -d --platform "$PLATFORM" -p 127.0.0.1::8080 "$IMAGE")"
  port="$(docker port "$cid" 8080/tcp | head -1 | sed 's/.*://')"
  for _ in $(seq 1 90); do
    if curl -fsS "http://127.0.0.1:$port/referenceccdaservice/static/validationui.html" -o /dev/null 2>/dev/null; then
      ok=true
      break
    fi
    sleep 5
  done
  # Loading the UI only proves Tomcat deployed the WAR. A validation request
  # goes through MDHT, the code validator and Jackson serialization, which is
  # where a dependency bump would actually break.
  if [[ "$ok" == true ]]; then
    sample="$VALIDATOR/src/test/resources/C-CDA_R2-1_CCD_EF.xml"
    if ! curl -fsS --max-time 300 "http://127.0.0.1:$port/referenceccdaservice/" \
        -F validationObjective=C-CDA_IG_Plus_Vocab -F referenceFileName= \
        -F "ccdaFile=@$sample;type=text/xml" -o "$OUT/smoke-response.json" \
      || ! jq -e '.resultsMetaData.resultMetaData | length > 0' "$OUT/smoke-response.json" >/dev/null; then
      ok=false
    fi
  fi
  [[ "$ok" == true ]] || docker logs "$cid" > "$OUT/smoke-container.log" 2>&1 || true
  docker rm -f "$cid" >/dev/null
  [[ "$ok" == true ]]
}

build_ok=false
tests_ok=skipped
image_ok=skipped
smoke_ok=skipped
notes=()
pom_before="$(sha "$VALIDATOR/pom.xml")"
dockerfile_before="$(sha "$ROOT/Dockerfile")"

# --- 1. Java dependencies -----------------------------------------------------
log "Building the WAR"
if "$ROOT/scripts/build-war.sh"; then
  build_ok=true
  round=1
  while (( round <= MAX_ROUNDS )); do
    log "Scanning WAR jars (round $round)"
    scan_war "war-round-$round.json"
    pin_args=(pin-java --pom "$VALIDATOR/pom.xml" --severity "$SEVERITY"
              --trivy "$OUT/war-round-$round.json" --output "$OUT/pins.json")
    # Inspector describes the deployed WAR, so it only applies before the first rebuild.
    if (( round == 1 )) && [[ -n "$INSPECTOR" ]]; then
      pin_args+=(--inspector "$INSPECTOR" --path-prefix WEB-INF/lib)
    fi
    before="$(sha "$VALIDATOR/pom.xml")"
    vulnfix "${pin_args[@]}"
    [[ "$(sha "$VALIDATOR/pom.xml")" == "$before" ]] && break
    log "Rebuilding the WAR with the new pins"
    if ! "$ROOT/scripts/build-war.sh" --only-validator; then
      build_ok=false
      notes+=("The WAR no longer compiles after the dependency bump; see the job log.")
      break
    fi
    round=$((round + 1))
  done
fi
[[ -f "$OUT/pins.json" ]] || echo '{"changes": [], "skipped": []}' > "$OUT/pins.json"
pom_changed=false
[[ "$(sha "$VALIDATOR/pom.xml")" != "$pom_before" ]] && pom_changed=true

# --- 2. Tests -----------------------------------------------------------------
if [[ "$build_ok" == true && "$pom_changed" == true && "$SKIP_TESTS" == false ]]; then
  log "Running the validator's tests against the new pins"
  if "$ROOT/scripts/build-war.sh" --only-validator --with-tests; then
    tests_ok=true
  else
    tests_ok=false
    notes+=("The validator's tests fail with the new pins. The PR is opened as a draft for a human to take over.")
  fi
fi

# --- 3-5. Image ---------------------------------------------------------------
if [[ "$build_ok" == true && "$SKIP_IMAGE" == false ]]; then
  log "Building the image (--pull --no-cache, so dnf upgrade reruns)"
  if build_image; then
    image_ok=true
    log "Scanning the image"
    scan_image "$IMAGE" image.json
    vulnfix pin-tomcat --dockerfile "$ROOT/Dockerfile" --severity "$SEVERITY" \
      --trivy "$OUT/image.json" --output "$OUT/tomcat.json"
    if [[ "$(sha "$ROOT/Dockerfile")" != "$dockerfile_before" ]]; then
      log "Rebuilding with the new TOMCAT_VERSION"
      if build_image; then
        scan_image "$IMAGE" image.json
      else
        image_ok=false
      fi
    fi
  else
    image_ok=false
  fi
  if [[ "$image_ok" == true ]]; then
    log "Smoke-testing the container"
    if smoke_test; then smoke_ok=true; else smoke_ok=false; fi
  fi
fi

# --- 6. Baseline and report ---------------------------------------------------
report_args=(report --severity "$SEVERITY" --pins "$OUT/pins.json" --tomcat "$OUT/tomcat.json"
             --build-ok "$build_ok" --tests-ok "$tests_ok" --image-ok "$image_ok" --smoke-ok "$smoke_ok"
             --output "$OUT/report.md" --summary "$OUT/summary.json")
if [[ -n "$BASELINE_IMAGE" ]]; then
  log "Scanning the baseline image $BASELINE_IMAGE"
  if docker pull --platform "$PLATFORM" "$BASELINE_IMAGE" >/dev/null && scan_image "$BASELINE_IMAGE" baseline.json; then
    report_args+=(--baseline-scan "$OUT/baseline.json" --baseline-label "$BASELINE_IMAGE")
  else
    notes+=("Could not pull or scan the baseline image \`$BASELINE_IMAGE\`.")
  fi
elif [[ -n "$INSPECTOR" ]]; then
  report_args+=(--baseline-inspector "$INSPECTOR" --baseline-label "Amazon Inspector")
fi
if [[ -f "$OUT/image.json" ]]; then
  report_args+=(--image-scan "$OUT/image.json")
else
  report_args+=(--image-scan "$OUT/war-round-1.json")
  notes+=("No image was built, so the remaining findings below cover the WAR's jars only.")
fi
if (( ${#notes[@]} )); then
  report_args+=(--notes "$(printf '> **Note:** %s\n>\n' "${notes[@]}")")
fi
vulnfix "${report_args[@]}"

# --- Is there anything to ship? ----------------------------------------------
release=false
reasons=()
[[ "$pom_changed" == true ]] && reasons+=("Java dependency pins")
[[ "$(sha "$ROOT/Dockerfile")" != "$dockerfile_before" ]] && reasons+=("TOMCAT_VERSION bump")
if git -C "$ROOT" submodule status | grep -q '^+'; then reasons+=("submodule commits not yet in the image"); fi
resolved="$(jq -r '.resolved_vs_baseline // 0' "$OUT/summary.json")"
(( resolved > 0 )) && reasons+=("$resolved finding(s) cleared relative to the deployed image")
[[ "${FORCE_RELEASE:-false}" == true ]] && reasons+=("forced")
(( ${#reasons[@]} )) && release=true
verified=true
for s in "$build_ok" "$tests_ok" "$image_ok" "$smoke_ok"; do
  [[ "$s" == false ]] && verified=false
done

jq --argjson release "$release" --argjson verified "$verified" \
   --arg reasons "$(IFS=';'; echo "${reasons[*]:-}")" \
   '. + {release: $release, verified: $verified, release_reasons: ($reasons | split(";") | map(select(. != "")))}' \
   "$OUT/summary.json" > "$OUT/summary.json.tmp" && mv "$OUT/summary.json.tmp" "$OUT/summary.json"

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  { echo "release=$release"; echo "verified=$verified"; } >> "$GITHUB_OUTPUT"
fi

log "Done: release=$release verified=$verified${reasons:+ (${reasons[*]})}"
echo "Report: $OUT/report.md"
