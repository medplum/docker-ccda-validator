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
fresh clone and the build will fail on the `COPY` until it is populated:

```
cd ../reference-ccda-validator
mvn -DskipTests package
cp target/referenceccdaservice.war ../docker-ccda-validator/webapps/
```

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

Amazon Linux 2023 is a supported OS for both ECR basic scanning and ECR
enhanced scanning (Amazon Inspector), so findings actually show up. The
previous `fedora:21` base was supported by neither, which meant ECR reported
the image as unscannable rather than clean.

Build for the architecture you deploy on — the Dockerfile is arch-agnostic,
but a local build only produces your host's architecture:

```
docker build --platform linux/amd64 -t docker-ccda-validator .
```

Rebuilding is what clears OS findings: the runtime stage runs
`dnf upgrade` so each build picks up the latest ALAS advisories.

### Vulnerability posture

The OS layer scans clean, and the WAR's jars are now fixed at source rather than
patched after the fact.

**The build-time jar patching is gone.** `files/jar-patches/` and
`files/scripts/patch-war-jars.sh` are dead code — every jar they replaced is now
at a fixed version in the WAR itself, so the script would fail the build looking
for filenames that no longer exist. They are kept only for the reasoning
recorded in their comments and can be deleted.

Of the **112 runtime artifacts** in the WAR, 111 have no known advisories. What
the migration cleared that a jar swap could not:

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

The one remaining finding, and why it stays:

- **CVE-2025-48924 in `commons-lang` 2.6** (medium). There is no fix in the 2.x
  line — the advisory's remedy is `commons-lang3` 3.18+, a different artifact.
  `org.hl7.security.ds4p.contentprofile` requires 2.6 at runtime, referencing
  `org.apache.commons.lang.StringUtils`. The vulnerable method is
  `ClassUtils.getShortClassName`, and across all 112 jars the only thing
  referencing `ClassUtils` is `commons-lang-2.6.jar` itself, so the vulnerable
  path is not reachable from application code.

Rebuilding is still what clears OS findings. Re-scan the WAR's jars whenever the
fork merges new upstream work.