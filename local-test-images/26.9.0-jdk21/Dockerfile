# Locally-assembled TEST image: BridgeLink 26.9.0 on JDK 21 with Derby 10.17.
#
# WHY THIS EXISTS
#   The migration-test harness (BridgeLink-internal migration-tests/run-migration-test.sh)
#   has a Derby backend leg (MTEST-12/13) that upgrades an embedded-Derby database
#   in place from an old release to 26.9.0. Embedded Derby 10.17 ships v63
#   classfiles and will NOT boot on JDK 17, so the 26.9.0 TO image must run JDK 21.
#   The normal release image is JDK 17, and a real 26.9.0 image can only be produced
#   by the full install4j release pipeline (licensed, Windows/EC2) -- tracked as the
#   Phase 19 -> Phase 27 hand-off. This image is the pragmatic local stand-in that
#   lets the Derby leg run on a developer machine now.
#
# WHAT IT IS / IS NOT
#   It overlays the current Derby 10.17 jars and a distro JDK 21 onto an EXISTING
#   innovarhealthcare/bridgelink:26.9.0-local image. It is a TEST image, not a
#   release build: the app bytes (other than the Derby jars) are whatever the base
#   26.9.0-local image already carried. It does NOT close the CI migration gap.
#
# BUILD: see build.sh in this directory (it stages the three Derby 10.17 jars from
#        a BridgeLink-internal checkout into the build context, then builds).
FROM innovarhealthcare/bridgelink:26.9.0-local

USER root

# 1. Install a native (matches the base image arch) JDK 21. The base image's
#    install4j bundled JRE (/opt/bridgelink/jre) is amd64 and unusable on an arm64
#    host; we force blserver onto this distro JDK instead (see ENV below).
RUN yum -y install java-21-openjdk java-21-openjdk-devel && yum clean all

# 2. Swap Derby 10.16.1.1 -> 10.17.1.0. The Mirth launcher globs
#    server-lib/database/*.jar, so replacing the files is enough (nothing references
#    the exact 10.16 filename).
RUN rm -f /opt/bridgelink/server-lib/database/derby-10.16.1.1.jar \
          /opt/bridgelink/server-lib/database/derbytools-10.16.1.1.jar \
          /opt/bridgelink/server-lib/database/derbyshared-10.16.1.1.jar
COPY --chown=bridgelink:bridgelink derby-10.17.1.0.jar derbytools-10.17.1.0.jar derbyshared-10.17.1.0.jar \
     /opt/bridgelink/server-lib/database/

# 3. Point blserver's install4j JRE search at JDK 21. INSTALL4J_JAVA_HOME_OVERRIDE
#    is tested first in search_jre() and short-circuits the rest (including the
#    bundled jre). JDK 21 passes blserver's own 17..21 version gate.
ENV JAVA_HOME=/usr/lib/jvm/java-21-openjdk
ENV PATH=/usr/lib/jvm/java-21-openjdk/bin:$PATH
ENV INSTALL4J_JAVA_HOME_OVERRIDE=/usr/lib/jvm/java-21-openjdk

USER bridgelink
