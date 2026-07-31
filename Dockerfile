# syntax=docker/dockerfile:1

# ---------------------------------------------------------------------------
# Base image: Amazon Linux 2023 + Amazon Corretto 17 (headless).
#
# Why this one:
#   * ECR can actually scan it. AL2023 is a supported OS for both ECR basic
#     scanning (Clair) and ECR enhanced scanning (Amazon Inspector). The old
#     fedora:21 base was on neither list, so ECR reported UNSUPPORTED_IMAGE:
#     zero findings, which is not the same thing as zero vulnerabilities.
#   * Small footprint: ~135 rpms, and no wget/tar/unzip/perl/git in the runtime
#     layer. Corretto 17 publishes no -jre, so -headless is the slim variant:
#     it drops the AWT/Swing native stack the server never loads.
#     AWS publishes ALAS security updates for AL2023 into 2028.
#   * Distroless / Chainguard / Wolfi bases would be leaner still, but ECR
#     cannot enumerate their packages, which fails the scannability goal.
# ---------------------------------------------------------------------------
# Java 17 and Tomcat 10.1 are now required, not optional. The WAR is built
# against jakarta.servlet 6.0 and Spring Framework 6.2, which need a Servlet 6.0
# container (Tomcat 10.1.x) and a Java 17 baseline. Tomcat 9 cannot load a
# jakarta.servlet webapp at all, and Spring 6 will not run on Java 8.
#
# This is what closes the Spring CVEs: 5.3.39 was the last public OSS 5.3.x
# release, so every remaining Spring fix lived in 6.x/7.x behind exactly this
# migration. See the vulnerability posture section of the README.
ARG BASE_IMAGE=amazoncorretto:17-al2023-headless
ARG TOMCAT_VERSION=10.1.57

# --- Apache Tomcat, used only as a file source ------------------------------
# $CATALINA_HOME is pure Java, so it copies cleanly onto any base or arch.
# This replaces Fedora's `yum install tomcat`, which pinned us to whatever
# Tomcat the distro happened to carry.
#
# The JDK in this tag is irrelevant: nothing from this stage ever runs, only
# $CATALINA_HOME is copied out of it. The official -corretto variants stop at
# Tomcat 9, so 10.1 uses the temurin build to keep an exact patch version pinned
# rather than floating on the 10.1 tag.
FROM tomcat:${TOMCAT_VERSION}-jdk17-temurin AS tomcat-dist

# --- Build stage ------------------------------------------------------------
# Everything needing the network or the git submodules happens here, and stays
# here. The runtime image receives only finished artifacts.
FROM ${BASE_IMAGE} AS build

# The WAR is now built from source rather than downloaded from a GitHub release,
# because the jakarta.servlet/Spring 6 migration is not upstream: no published
# onc-healthit release runs on Tomcat 10.1. So there is no release tag or
# sha256 to pin, and VALIDATOR_REPO/VALIDATOR_VERSION/VALIDATOR_WAR_SHA256 are
# gone with the download.
#
# webapps/ is gitignored, so the WAR is NOT in a fresh clone and must be built
# before `docker build`:
#
#   cd ../reference-ccda-validator \
#     && mvn -DskipTests package \
#     && cp target/referenceccdaservice.war ../docker-ccda-validator/webapps/
#
# That also means the build no longer verifies what it is installing. The
# provenance check moved from "sha256 of a published release" to "whatever you
# just compiled", which is stronger in one sense and weaker in another: nothing
# stops a stale WAR from being reused. Check the timestamp if a rebuild looks
# suspiciously unchanged.
WORKDIR /staging

COPY webapps/referenceccdaservice.war ./

# Explode the WAR here rather than letting Tomcat expand it on first boot, so
# webapps/ needs no write access at runtime.
#
# The patch-war-jars.sh step that used to run here is gone. Every jar it
# replaced is now fixed at source in the WAR, and the script is written to fail
# the build when a jar it expects is missing -- which is now all twelve of them.
# files/jar-patches/ and files/scripts/patch-war-jars.sh are dead code.
RUN dnf -y install unzip \
 && dnf clean all \
 && unzip -q referenceccdaservice.war -d webapp \
 && rm referenceccdaservice.war \
 && chmod -R a+rX webapp

# Validator config tree, laid out where config_extra/referenceccdaservice.xml
# points. code_repository and scenarios_directory are read at startup, so they
# have to exist even while empty.
#
# configs_folder/ccdaReferenceValidatorConfig.xml is versioned with the WAR and
# ships separately from it, so it has to be refreshed from
# configuration/ccdaReferenceValidatorConfig.xml whenever the WAR is rebuilt
# from a new upstream merge.
COPY files/configs_folder/ ccda/files/configs_folder/
COPY submodules/code-validator-api/codevalidator-api/docs/ValueSetsHandCreatedbySITE/ \
     ccda/files/validator_configuration/vocabulary/valueset_repository/VSAC/
RUN mkdir -p ccda/files/validator_configuration/vocabulary/code_repository \
             ccda/files/validator_configuration/scenarios_directory

# The JDK dropped javax.xml.bind and javax.annotation after Java 8 (JEP 320),
# which is what made raising the JDK risky before. That is now handled at the
# source rather than by luck: the WAR declares the Jakarta replacements
# explicitly -- jakarta.xml.bind-api + jaxb-runtime (JAXB, used by
# code-validator-api's Jaxb2Marshaller) and jakarta.annotation-api (@Resource)
# are all in WEB-INF/lib by declaration, not as an incidental transitive.

# Add the CorsFilter to Tomcat's own conf/web.xml rather than replacing the
# whole file — see files/config_extra/cors-filter.xml for why.
COPY --from=tomcat-dist /usr/local/tomcat/conf/web.xml stock-web.xml
COPY files/config_extra/cors-filter.xml cors-filter.xml
RUN sed '/<\/web-app>/d' stock-web.xml > web.xml \
 && cat cors-filter.xml >> web.xml \
 && printf '</web-app>\n' >> web.xml

# --- Runtime ----------------------------------------------------------------
FROM ${BASE_IMAGE}

# Pick up ALAS advisories published since the base image was cut, so a rebuild
# is enough to clear OS findings in ECR.
RUN dnf -y --releasever=latest upgrade \
 && dnf clean all \
 && rm -rf /var/cache/dnf /var/cache/libdnf5

ENV CATALINA_HOME=/usr/local/tomcat
ENV PATH="${CATALINA_HOME}/bin:${PATH}" \
    JAVA_OPTS="-Djava.awt.headless=true -XX:MaxRAMPercentage=75.0"

COPY --from=tomcat-dist /usr/local/tomcat ${CATALINA_HOME}
COPY --from=build /staging/web.xml ${CATALINA_HOME}/conf/web.xml
COPY --from=build /staging/ccda /etc/ccda
COPY files/config_extra/referenceccdaservice.xml \
     ${CATALINA_HOME}/conf/Catalina/localhost/referenceccdaservice.xml
COPY --from=build /staging/webapp \
     ${CATALINA_HOME}/webapps/referenceccdaservice

# The stock ROOT/docs/examples/manager/host-manager apps ship unpacked in
# webapps.dist. None are served here, and manager/host-manager are the usual
# Tomcat CVE magnets, so drop them rather than leave them one mv away.
RUN rm -rf ${CATALINA_HOME}/webapps.dist

# Run unprivileged. shadow-utils is not in the base image and is not worth
# installing for one account, so the entries go in directly. Only the
# directories Tomcat writes to are handed over; conf and /etc/ccda stay
# root-owned and read-only to the runtime user.
ARG UID=10001
RUN printf 'tomcat:x:%s:%s::%s:/sbin/nologin\n' "${UID}" "${UID}" "${CATALINA_HOME}" >> /etc/passwd \
 && printf 'tomcat:x:%s:\n' "${UID}" >> /etc/group \
 && chown -R "${UID}:${UID}" \
      ${CATALINA_HOME}/logs \
      ${CATALINA_HOME}/temp \
      ${CATALINA_HOME}/webapps \
      ${CATALINA_HOME}/work
USER ${UID}:${UID}

EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=5s --start-period=180s --retries=5 \
  CMD curl -fsS http://localhost:8080/referenceccdaservice/static/validationui.html \
      -o /dev/null || exit 1

# Foreground, so Tomcat is PID 1 and receives Docker's stop signal directly.
CMD ["catalina.sh", "run"]
