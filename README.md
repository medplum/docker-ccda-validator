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
| Base | `amazoncorretto:8-al2023-jre` (Amazon Linux 2023 + Corretto 8) |
| Servlet container | Apache Tomcat 9.0.120, copied from the official `tomcat` image |
| Runs as | uid/gid `10001`, non-root |
| Validator | `referenceccdaservice.war` v1.1.4, downloaded and sha256-verified at build time |

Versions are build args, so they can be overridden without editing the
Dockerfile:

```
docker build --build-arg VALIDATOR_VERSION=v1.1.4 \
             --build-arg VALIDATOR_WAR_SHA256=<sha256 of that war> \
             --build-arg TOMCAT_VERSION=9.0.120 \
             -t docker-ccda-validator .
```

Two version choices are deliberate:

- **Tomcat 9** — the WAR is built against `javax.servlet`, so Tomcat 10+ (which
  moved to `jakarta.servlet`) will not run it.
- **Java 8** — the only JDK upstream supports for this validator. It is not a
  dead end: AWS lists Corretto 8's last planned update as October 2030, later
  than Corretto 11. Newer JDKs do run (Corretto 17 was tested and produced an
  identical finding set), but they are unsupported by upstream, and Java 11+
  removes `javax.xml.bind`, which this app needs.

### Upgrading the validator

Upstream moved to
[onc-healthit/reference-ccda-validator](https://github.com/onc-healthit/reference-ccda-validator)
and its tags now carry a `v` prefix. Three things move together on a version
bump:

1. `VALIDATOR_VERSION` and `VALIDATOR_WAR_SHA256` in the Dockerfile.
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

The OS layer scans clean. Everything that remains is in the vendor WAR's
bundled jars.

Eleven of those jars are replaced at build time with the lowest fixed versions
that keep Java 8 bytecode compatibility — see
`files/jar-patches/replacements.tsv` for the table and
`files/scripts/patch-war-jars.sh` for what is deliberately left alone. That
clears 16 CVEs:

| | critical | high | medium | low |
|---|---|---|---|---|
| Vendor WAR as shipped | 5 | 18 | 26 | 10 |
| After jar patches | 2 | 7 | 25 | 10 |

**0 critical / 0 high is not reachable from this repo.** What is left:

- **7 Spring findings** (`spring-webmvc`, `spring-expression`, `spring-core`,
  `spring-web`) are fixed only in Spring 6.x/7.x, which require
  `jakarta.servlet` and Java 17 — a WAR recompiled by upstream plus Tomcat 10+.
  5.3.39 is the last public OSS 5.3.x release, so there is no patch-level escape.
  One of them, CVE-2026-41849, has no fixed release at all. The critical among
  them, CVE-2016-1000027, needs Spring's `HttpInvokerServiceExporter`; this app
  does not use HTTP invoker remoting, so it is not reachable here.
- **CVE-2022-23640 in `xlsx-streamer` 1.0.1.** The fix (2.2.0) is built against
  POI 4.1.2 while the WAR ships POI 3.17, so it fails at startup — this was
  tried and reverted, see the note in `patch-war-jars.sh`. Clearing it means
  bumping POI too, which cascades into `poi-ooxml-schemas`, `commons-compress`
  and `curvesapi` beneath a precompiled `code-validator-api`.

So a green Inspector dashboard means these plus documented suppression rules,
not zero findings. Re-run `files/scripts/patch-war-jars.sh`'s table against a
fresh scan whenever `VALIDATOR_VERSION` moves — the build fails loudly if a
listed jar is no longer in the WAR rather than silently shipping it unpatched.