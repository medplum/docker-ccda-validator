# syntax=docker/dockerfile:1

# ---------------------------------------------------------------------------
# Base image: Amazon Linux 2023 + Amazon Corretto 8 (JRE).
#
# Why this one:
#   * ECR can actually scan it. AL2023 is a supported OS for both ECR basic
#     scanning (Clair) and ECR enhanced scanning (Amazon Inspector). The old
#     fedora:21 base was on neither list, so ECR reported UNSUPPORTED_IMAGE:
#     zero findings, which is not the same thing as zero vulnerabilities.
#   * Small footprint: ~135 rpms, and no wget/tar/unzip/perl/git in the runtime
#     layer. The -jre variant saves 60MB over the JDK and Tomcat only needs a
#     JRE (Jasper compiles JSPs with the ecj bundled in $CATALINA_HOME/lib).
#     AWS publishes ALAS security updates for AL2023 into 2028.
#   * Distroless / Chainguard / Wolfi bases would be leaner still, but ECR
#     cannot enumerate their packages, which fails the scannability goal.
# ---------------------------------------------------------------------------
# Java 8 because that is the only JDK upstream supports for this validator, and
# a certification-adjacent tool is the wrong place to run unsupported. It costs
# nothing in maintenance runway: AWS lists Corretto 8's last planned update as
# October 2030 (EOL December 2030), later than Corretto 11.
#
# JAVA_VERSION and BASE_IMAGE move together -- the Corretto tag suffix differs
# per line (8 publishes -jre, 11/17/21 publish -headless).
ARG JAVA_VERSION=8
ARG BASE_IMAGE=amazoncorretto:8-al2023-jre
ARG TOMCAT_VERSION=9.0.120

# --- Apache Tomcat, used only as a file source ------------------------------
# $CATALINA_HOME is pure Java, so it copies cleanly onto any base or arch.
# This replaces Fedora's `yum install tomcat`, which pinned us to whatever
# Tomcat the distro happened to carry.
FROM tomcat:${TOMCAT_VERSION}-jdk${JAVA_VERSION}-corretto AS tomcat-dist

# --- Build stage ------------------------------------------------------------
# Everything needing the network or the git submodules happens here, and stays
# here. The runtime image receives only finished artifacts.
FROM ${BASE_IMAGE} AS build

# The upstream project moved from siteadmin/ to onc-healthit/ and its release
# tags picked up a "v" prefix along the way.
ARG VALIDATOR_REPO=onc-healthit/reference-ccda-validator
ARG VALIDATOR_VERSION=v1.1.4
ARG VALIDATOR_WAR_SHA256=c790ebd283181a9e9fa9e67d345690792fb16fa2f55a0efffaf6a4cd371be858

WORKDIR /staging

RUN curl -fsSL -o referenceccdaservice.war \
      "https://github.com/${VALIDATOR_REPO}/releases/download/${VALIDATOR_VERSION}/referenceccdaservice.war" \
 && printf '%s  referenceccdaservice.war\n' "${VALIDATOR_WAR_SHA256}" | sha256sum -c -

# Explode the WAR here rather than letting Tomcat expand it on first boot, so
# its bundled jars can be patched below and so webapps/ needs no write access
# at runtime.
ARG MAVEN_REPO=https://repo1.maven.org/maven2
COPY files/jar-patches/ jar-patches/
COPY files/scripts/patch-war-jars.sh ./
RUN dnf -y install unzip \
 && dnf clean all \
 && unzip -q referenceccdaservice.war -d webapp \
 && rm referenceccdaservice.war \
 && sh patch-war-jars.sh webapp/WEB-INF/lib jar-patches \
 && chmod -R a+rX webapp

# Validator config tree, laid out where config_extra/referenceccdaservice.xml
# points. code_repository and scenarios_directory are read at startup, so they
# have to exist even while empty.
#
# configs_folder/ccdaReferenceValidatorConfig.xml is versioned with the WAR and
# ships separately from it, so it has to be refreshed from
# configuration/ccdaReferenceValidatorConfig.xml on every VALIDATOR_VERSION bump.
COPY files/configs_folder/ ccda/files/configs_folder/
COPY submodules/code-validator-api/codevalidator-api/docs/ValueSetsHandCreatedbySITE/ \
     ccda/files/validator_configuration/vocabulary/valueset_repository/VSAC/
RUN mkdir -p ccda/files/validator_configuration/vocabulary/code_repository \
             ccda/files/validator_configuration/scenarios_directory

# NOTE if you ever raise JAVA_VERSION: the JDK dropped javax.xml.bind in Java
# 11, and this app needs it (Hibernate threw NoClassDefFoundError:
# javax/xml/bind/JAXBException on 1.0.63 under Java 17). v1.1.4 happens to
# bundle the whole JAXB stack in WEB-INF/lib so it survives, but that is the
# WAR's choice to reverse, not a guarantee. On Java 8 the JDK provides it.

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
