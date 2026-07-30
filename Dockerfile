# syntax=docker/dockerfile:1

# ---------------------------------------------------------------------------
# Base image: Amazon Linux 2023 + Amazon Corretto (headless).
#
# Why this one:
#   * ECR can actually scan it. AL2023 is a supported OS for both ECR basic
#     scanning (Clair) and ECR enhanced scanning (Amazon Inspector). The old
#     fedora:21 base was on neither list, so ECR reported UNSUPPORTED_IMAGE:
#     zero findings, which is not the same thing as zero vulnerabilities.
#   * Small footprint: ~130 rpms, and no wget/tar/unzip/perl/git in the
#     runtime layer. AWS publishes ALAS security updates for AL2023 into 2028.
#   * Distroless / Chainguard / Wolfi bases would be leaner still, but ECR
#     cannot enumerate their packages, which fails the scannability goal.
# ---------------------------------------------------------------------------
ARG JAVA_VERSION=17
ARG TOMCAT_VERSION=9.0.120
ARG BASE_IMAGE=amazoncorretto:${JAVA_VERSION}-al2023-headless

# --- Apache Tomcat, used only as a file source ------------------------------
# $CATALINA_HOME is pure Java, so it copies cleanly onto any base or arch.
# This replaces Fedora's `yum install tomcat`, which pinned us to whatever
# Tomcat the distro happened to carry.
FROM tomcat:${TOMCAT_VERSION}-jdk${JAVA_VERSION}-corretto AS tomcat-dist

# --- Build stage ------------------------------------------------------------
# Everything needing the network or the git submodules happens here, and stays
# here. The runtime image receives only finished artifacts.
FROM ${BASE_IMAGE} AS build

ARG VALIDATOR_VERSION=1.0.63
ARG VALIDATOR_WAR_SHA256=6388e3cb422b7e779bacbd104c21cb293a2de235f79e944c125fd392e0e85a59

WORKDIR /staging

RUN curl -fsSL -o referenceccdaservice.war \
      "https://github.com/siteadmin/reference-ccda-validator/releases/download/${VALIDATOR_VERSION}/referenceccdaservice.war" \
 && printf '%s  referenceccdaservice.war\n' "${VALIDATOR_WAR_SHA256}" | sha256sum -c -

# Validator config tree, laid out where config_extra/referenceccdaservice.xml
# points. code_repository and scenarios_directory are read at startup, so they
# have to exist even while empty.
COPY files/configs_folder/ ccda/files/configs_folder/
COPY submodules/code-validator-api/codevalidator-api/docs/ValueSetsHandCreatedbySITE/ \
     ccda/files/validator_configuration/vocabulary/valueset_repository/VSAC/
RUN mkdir -p ccda/files/validator_configuration/vocabulary/code_repository \
             ccda/files/validator_configuration/scenarios_directory

# Java 11 dropped JAXB from the JDK, but this app's Hibernate 5.0.7 still
# expects javax.xml.bind (without these it dies at startup on
# NoClassDefFoundError: javax/xml/bind/JAXBException). Restoring the five jars
# is preferable to pinning the image to Java 8, whose Corretto support window
# is nearly closed. Checksums are pinned in files/jaxb/jaxb.sha256; bump both
# together.
ARG MAVEN_REPO=https://repo1.maven.org/maven2
COPY files/jaxb/jaxb.sha256 lib/jaxb.sha256
RUN cd lib \
 && for path in \
      javax/xml/bind/jaxb-api/2.3.1/jaxb-api-2.3.1.jar \
      org/glassfish/jaxb/jaxb-runtime/2.3.9/jaxb-runtime-2.3.9.jar \
      org/glassfish/jaxb/txw2/2.3.9/txw2-2.3.9.jar \
      com/sun/istack/istack-commons-runtime/3.0.12/istack-commons-runtime-3.0.12.jar \
      com/sun/activation/javax.activation/1.2.0/javax.activation-1.2.0.jar \
    ; do curl -fsSLO "${MAVEN_REPO}/${path}"; done \
 && sha256sum -c jaxb.sha256 \
 && rm jaxb.sha256

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
COPY --from=build /staging/lib/ ${CATALINA_HOME}/lib/
COPY --from=build /staging/web.xml ${CATALINA_HOME}/conf/web.xml
COPY --from=build /staging/ccda /etc/ccda
COPY files/config_extra/referenceccdaservice.xml \
     ${CATALINA_HOME}/conf/Catalina/localhost/referenceccdaservice.xml
COPY --from=build /staging/referenceccdaservice.war \
     ${CATALINA_HOME}/webapps/referenceccdaservice.war

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
