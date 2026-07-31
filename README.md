# docker-ccda-validator

CCDA Validator in a docker container

## What You'll need

1. Docker

## Development Usage

git clone this repo (and submodules! VERY important!)
```
git clone --recurse-submodules https://github.com/mieweb/docker-ccda-validator.git
```

Build the docker
```
cd docker-ccda-validator
docker build -t docker-ccda-validator .
```

Run the docker
```
docker run -dp 8080:8080 docker-ccda-validator
```

Wait...
Try opening up any of the following URLS:

http://SERVER_IP:8080/referenceccdaservice/static/validationui.html
![validationui](https://i.imgur.com/DM3E6ny.png)

http://SERVER_IP:8080/referenceccdaservice/swagger-ui.html#/reference-ccda-validation-controller
![swagger-ui](https://i.imgur.com/1OdtDyg.png)

**Breaking API change in v1.1.4:** the `POST /referenceccdaservice/` form
parameter `curesUpdate` (boolean) is gone, replaced by an optional `ccdaType`
string. Callers still sending `curesUpdate` will not error — the parameter is
simply ignored, so requests silently lose that behavior.

## The image

| | |
|---|---|
| Base | `amazoncorretto:17-al2023-headless` (Amazon Linux 2023 + Corretto 17) |
| Servlet container | Apache Tomcat 10.1.57, copied from the official `tomcat` image |
| Runs as | uid/gid `10001`, non-root |
| Validator | `referenceccdaservice.war`, built from source and copied from `webapps/` |

`TOMCAT_VERSION` and `BASE_IMAGE` are build args, so they can be overridden
without editing the Dockerfile:

```
docker build --build-arg TOMCAT_VERSION=10.1.57 -t docker-ccda-validator .
```

**The WAR must be built first.** `webapps/` is gitignored, so it is empty in a
fresh clone and the build will fail on the `COPY` until it is populated. Build it
from the submodules, which track the `medplum/` forks and are pinned to the exact
source the image ships. `code-validator-api` has to be installed first — the
validator resolves it from the local Maven repo as
`org.sitenv.vocabulary:codevalidator-api:latestVersion`, and it is not published
anywhere:

```
cd submodules/code-validator-api
mvn -DskipTests install
cd ../reference-ccda-validator
mvn -DskipTests package
cp target/referenceccdaservice.war ../../webapps/
```

Both builds need Java 17; each submodule carries a `.java-version` pinning it.

Two version choices are deliberate, and both are now requirements rather than
preferences:

- **Tomcat 10.1** — the WAR is built against `jakarta.servlet` 6.0, so it needs a
  Servlet 6.0 container. Tomcat 9 cannot load it at all.
- **Java 17** — Spring Framework 6.2's baseline. This is what closes the Spring
  CVEs: 5.3.39 was the last public OSS 5.3.x release, so every remaining Spring
  fix lived in 6.x/7.x behind the `jakarta.servlet` migration. `javax.xml.bind`
  and `javax.annotation`, which the JDK dropped after 8, are now declared
  explicitly by the WAR as their Jakarta equivalents.

### CORS is now set explicitly

`cors.allowed.origins` is pinned to `*` in
`files/config_extra/cors-filter.xml` rather than left to the default, because the
default is not stable across Tomcat versions — Tomcat 9 defaulted to `*`, and
Tomcat 10.1 defaults to the empty string and rejects non-allowed origins with
**403**. Pinning it keeps this image's long-standing behaviour instead of letting
a container upgrade silently change who can call the service.

`*` means any website can POST a C-CDA here and read the result back. That is
tolerable only because the service is unauthenticated and stateless — callers
supply their own documents. Narrow it to an origin list if the validator becomes
reachable from outside a trusted network or gains any authenticated endpoint.

### Upgrading the validator

The WAR is no longer a published release download. The `jakarta.servlet`/Spring 6
migration is not upstream, so it is built from the
[medplum/reference-ccda-validator](https://github.com/medplum/reference-ccda-validator)
fork, which also needs its two API dependencies built and installed first
(`content-validator-api`, then `code-validator-api`, then the validator itself —
each with `mvn -DskipTests install`).

Three things move together when merging new upstream work into that fork:

1. Rebuild the WAR and re-copy it into `webapps/`.
2. `files/configs_folder/ccdaReferenceValidatorConfig.xml` — this ships
   *separately* from the WAR and is versioned with it, so a stale copy silently
   validates against the wrong expressions. Refresh it from
   `configuration/ccdaReferenceValidatorConfig.xml` at the matching tag.
3. `files/config_extra/referenceccdaservice.xml` — compare against
   `configuration/referenceccdaservice.xml` at the matching tag for new
   parameters.

Re-run a real validation after every bump rather than trusting a successful
startup — the app deploys and serves its UI fine in states where the validators
themselves are misconfigured.

## Pushing to ECR

### The image version lives in `VERSION`

`VERSION` at the repo root is the image version, and the only place it is
written down. Tags are `v<VERSION>-<short-sha>`:

```
docker build --platform linux/amd64 --provenance=false \
  -t 647991932601.dkr.ecr.us-east-1.amazonaws.com/medplum/ccda-validator:v$(cat VERSION)-$(git rev-parse --short HEAD) .
```

Bump `VERSION` in the same commit as the change it ships, so the tag is
derivable from the tree rather than remembered. Before this file existed the
version lived only as an ECR tag, which made `aws ecr describe-images` the sole
record of what had shipped.

Two things this does *not* live in, deliberately:

- **The submodule forks.** The image version is a property of what this repo
  builds, not of its inputs. Bumping `TOMCAT_VERSION` or `BASE_IMAGE` ships a new
  image version with byte-identical submodule commits, so a copy in the forks
  would be stale by construction — and `pom.xml` is an upstream-tracked file, so
  a Medplum-only version there conflicts on every merge from onc-healthit.
- **A git tag.** This repo has none. `VERSION` plus the commit sha in the image
  tag covers it; add tags later if you want, but keep `VERSION` authoritative.

Note the forks' own poms still carry upstream's version strings (`1.1.5`,
`latestVersion`) while shipping materially different code, so a deployed WAR
reports a version that points at source which cannot build it. Fixing that means
a `-medplum.N` qualifier on the forks, tracked separately from this file.

Amazon Linux 2023 is a supported OS for both ECR basic scanning and ECR
enhanced scanning (Amazon Inspector), so findings actually show up. The
previous `fedora:21` base was supported by neither, which meant ECR reported
the image as unscannable rather than clean.

`--platform` above is not optional either: the Dockerfile is arch-agnostic, but a
local build only produces your host's architecture, so an Apple Silicon machine
ships arm64 to an amd64 deployment without complaining.

Rebuilding is what clears OS findings: the runtime stage runs
`dnf upgrade` so each build picks up the latest ALAS advisories.

### `--provenance=false` is required, not cosmetic

Without it, buildx attaches a provenance attestation, which turns the push into
an OCI **image index** holding two manifests: the real one, plus an attestation
manifest whose platform is `unknown/unknown`. Amazon Inspector cannot read that
shape and reports the image as **`UNSUPPORTED_IMAGE`** — the same zero-findings
non-answer the `fedora:21` base used to produce, for an entirely unrelated
reason. Picking a scannable base image gets you nothing if the manifest wrapping
it is unscannable.

Confirm the manifest is a plain single manifest after pushing, because a
successful push tells you nothing about this:

```
aws ecr describe-images --repository-name medplum/ccda-validator \
  --image-ids imageTag=<tag> --query 'imageDetails[0].imageManifestMediaType'
```

Want `application/vnd.docker.distribution.manifest.v2+json`. If it says
`application/vnd.oci.image.index.v1+json`, the attestation is there and the
image will not be scanned. `docker build` and `docker buildx build --push` both
need the flag; `--sbom=false` belongs with it if SBOM generation is ever turned
on. Then check that scanning actually ran:

```
aws ecr describe-image-scan-findings --repository-name medplum/ccda-validator \
  --image-id imageTag=<tag> --query 'imageScanStatus.status'
```

`ACTIVE` means scanned. A `ScanNotFoundException` right after a push usually
just means Inspector has not caught up yet — retry for a few minutes before
concluding anything.

### Vulnerability posture

The OS layer scans clean, and the WAR's jars are now fixed at source rather than
patched after the fact.

**The build-time jar patching is gone.** `files/jar-patches/` and
`files/scripts/patch-war-jars.sh` are dead code — every jar they replaced is now
at a fixed version in the WAR itself, so the script would fail the build looking
for filenames that no longer exist. They are kept only for the reasoning
recorded in their comments and can be deleted.

The **111 runtime artifacts** in the WAR have no known advisories. What the
migration cleared that a jar swap could not:

- **All Spring findings** (15 on `spring-webmvc` alone, plus `spring-core`,
  `spring-web`, `spring-expression`, `spring-context`) — fixed by Spring 6.2.19.
  This was the whole reason for the Java 17/Tomcat 10.1 move. Note CVE-2026-41849
  has no fixed release on any branch but does not affect 6.2.19.
- **CVE-2022-23640 in `xlsx-streamer`** — previously unfixable because 2.2.0
  needs POI 4.1.2 against a shipped POI 3.17. Resolved by moving to the
  maintained fork `com.github.pjfanning:excel-streaming-reader` 5.2.0, which
  targets POI 5.5.1 exactly, alongside POI 3.17 → 5.5.1 and xmlbeans 2.6 → 5.3.0.
- **Two HIGHs in `commons-fileupload`** — the dependency is gone entirely, since
  Spring 6 removed `CommonsMultipartResolver` in favour of the container's own
  multipart parsing.
- **CRITICAL CVE-2019-17495** (Swagger UI XSS) — springfox 2.5.0 replaced with
  springdoc-openapi 2.8.17. The UI moved to `/swagger-ui/index.html`
  (`/swagger-ui.html` still redirects) and the spec to `/v3/api-docs`.

- **CVE-2025-48924 in `commons-lang` 2.6** (medium) — the jar is gone. There is
  no fix in the 2.x line; the advisory's remedy is `commons-lang3` 3.18+, a
  different artifact in a different package, so this was not a version bump. The
  only consumer of the 2.x package was the prebuilt
  `org.hl7.security.ds4p.contentprofile` jar, whose
  `SecurityXSIProvider$TemplateComparator` calls `StringUtils.isEmpty(String)`.
  That code *is* reachable — `ReferenceCCDAValidator.validateAsDS4P` →
  `DS4PUtil.validateAsDS4P` registers `SecurityXSIProvider` in MDHT's
  `XSITypeProviderRegistry` — so the dependency could not simply be dropped, and
  renaming the package inside the prebuilt jar would not work either because
  lang3's signature is `isEmpty(CharSequence)`. Instead the validator supplies
  that one method itself from `src/main/java/org/apache/commons/lang/`,
  delegating to `commons-lang3` 3.20.0; `WEB-INF/classes` precedes
  `WEB-INF/lib` on the webapp classpath. Add methods to that shim only if a new
  2.x reference appears — scan the built WAR's jars for the
  `org/apache/commons/lang/` package (excluding `lang3`) to check.

The remaining findings, and why they stay:

- **CVE-2026-66299 in Tomcat 10.1.57** — **not applicable to this image**, but it
  will show up in ECR as a HIGH (7.5) against `lib/catalina.jar`. It is an
  unbounded-buffer DoS in the **WebSocket chat example**, and Apache's own
  advisory rates it **Low** and states that users who removed the examples web
  application are not affected. The runtime stage deletes `webapps.dist`, so
  `examples` is not in the image at all — `webapps/` holds only
  `referenceccdaservice`. Inspector is version-matching `catalina.jar` and does
  not model reachability, hence the severity gap.

  Do not chase this one with a version bump. The fix is 10.1.58, which Apache
  lists as *not yet released*; Inspector's "fixed in 11.0.25" is just the
  parallel fix on the 11.x branch and is **not** a reason to migrate to Tomcat
  11. Bump `TOMCAT_VERSION` to 10.1.58 when it ships, to clear the report rather
  than the risk.

Before acting on any Tomcat finding here, read the Apache advisory
(<https://tomcat.apache.org/security-10.html>) rather than Inspector's severity
and `fixedInVersion`. Check the "Affects" range and any mitigation note — several
Tomcat CVEs only reach the examples, manager, or host-manager apps, none of which
this image ships.

Rebuilding is still what clears OS findings. Re-scan the WAR's jars whenever the
fork merges new upstream work.