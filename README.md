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

Tomcat 9 is deliberate: the validator WAR is built against `javax.servlet`, so
Tomcat 10+ (which moved to `jakarta.servlet`) will not run it.

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

Upstream states it does not support any JDK above 8. This image runs Java 17
anyway, so re-run a real validation after every bump rather than trusting a
successful startup.

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

Expect enhanced scanning to report findings against the JARs inside the WAR
(Spring 4.3.30, Hibernate 5.0.7, log4j 1.2.17, jackson-databind 2.9.x, and so
on). Those are fixed by the upstream validator release, not by this repo, and
they do not move until `VALIDATOR_VERSION` does.