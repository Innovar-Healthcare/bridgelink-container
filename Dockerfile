# ============================================================
# Stage 1: Builder
# ============================================================
FROM rockylinux:9 AS builder

# Update and install system tools and language support
RUN yum update -y && \
    yum install -y tar gzip openssl shadow-utils unzip python3 wget glibc-langpack-en

# Set UTF-8 locale environment variables
ENV LANG=en_US.UTF-8
ENV LANGUAGE=en_US:en
ENV LC_ALL=en_US.UTF-8

# Install OpenJDK 17 and set JAVA_HOME
RUN yum -y install java-17-openjdk java-17-openjdk-devel
ENV JAVA_HOME=/usr/lib/jvm/java-17-openjdk
ENV PATH=$JAVA_HOME/bin:$PATH

# Install AWS CLI (multi-arch: detects amd64/arm64)
RUN ARCH=$(uname -m) && \
    curl --retry 5 --retry-delay 5 "https://awscli.amazonaws.com/awscli-exe-linux-${ARCH}.zip" -o "awscliv2.zip" && \
    unzip awscliv2.zip && \
    /aws/install && \
    rm -rf aws*

# Create the bridgelink user with UID 1000
RUN useradd -u 1000 bridgelink

# Binary download URL — passed at build time (s3:// for internal, https:// for public release)
ARG BINARY_URL
ENV BINARY_URL=${BINARY_URL}

# Include the Swing Administrator (client-lib + public_html webstart landing page)? Default keeps it.
# Set to "false" to build a WebAdmin-only image — the server + REST API are unaffected (the server
# classpath never references client-lib); only Java Web Start launching of the Swing client is dropped.
ARG INCLUDE_ADMIN_CLIENT=true

# Copy in the necessary scripts and ensure they are executable
COPY scripts/install.sh /opt/scripts/install.sh
COPY scripts/entrypoint.sh /opt/scripts/entrypoint.sh
RUN chmod +x /opt/scripts/install.sh /opt/scripts/entrypoint.sh

# (Optional) List the scripts to verify copy and permissions
RUN ls -l /opt/scripts/

# Run the installation script which sets up your application under /opt/bridgelink
# AWS credentials are injected via build secret (never baked into the image)
RUN --mount=type=secret,id=aws_credentials,target=/root/.aws/credentials \
    /opt/scripts/install.sh

# Create required directories for persistent data and set ownership
RUN mkdir -p /opt/bridgelink/appdata && chown bridgelink:bridgelink /opt/bridgelink/appdata && \
    mkdir -p /opt/bridgelink/custom-extensions && chown bridgelink:bridgelink /opt/bridgelink/custom-extensions

# Clean up unnecessary files from the application directory. The CLI (blcommand) and manager
# (blmanager) are meant to run outside the server container, so their launchers, jars, and libs
# are all removed — leaving a launcher without its jar/libs produces a confusing
# ClassNotFoundException at runtime (see issue #13).
# The Swing Administrator (client-lib jars + the public_html webstart landing page) is stripped when
# INCLUDE_ADMIN_CLIENT=false, producing a WebAdmin-only image (see the ARG note above).
WORKDIR /opt/bridgelink
RUN rm -r mirth-cli-launcher.jar mirth-manager-launcher.jar blmanager blcommand cli-lib manager-lib && \
    if [ "$INCLUDE_ADMIN_CLIENT" != "true" ]; then \
      echo "INCLUDE_ADMIN_CLIENT=$INCLUDE_ADMIN_CLIENT — stripping Swing Administrator (client-lib, public_html)"; \
      rm -rf client-lib public_html; \
    fi

# Ensure the entrypoint script is executable and that the application files have proper ownership
RUN chmod 755 /opt/scripts/entrypoint.sh && \
    chown -R bridgelink:bridgelink /opt/bridgelink

# ============================================================
# Stage 2: Runtime
# ============================================================
FROM rockylinux:9 AS final

# Patch base OS packages (the base image ships stale packages; without this the runtime image keeps
# them — the builder stage's update does not carry over across the FROM). Then install runtime deps
# and locale support. Keeps the Trivy OS scan (IRT-1390) green on genuinely-patched packages.
RUN yum update -y && \
    yum install -y java-17-openjdk java-17-openjdk-devel python3 glibc-langpack-en && \
    yum clean all

# Set UTF-8 locale environment variables
ENV LANG=en_US.UTF-8
ENV LANGUAGE=en_US:en
ENV LC_ALL=en_US.UTF-8

# Set Java environment
ENV JAVA_HOME=/usr/lib/jvm/java-17-openjdk
ENV PATH=$JAVA_HOME/bin:$PATH

# Recreate the bridgelink user (ensuring the same UID as in the builder)
RUN useradd -u 1000 bridgelink

# Copy the built application and entrypoint script from the builder stage
COPY --from=builder /opt/bridgelink /opt/bridgelink
COPY --from=builder /opt/scripts/entrypoint.sh /opt/scripts/entrypoint.sh

# Ensure proper permissions for the entrypoint and application files
RUN chmod 755 /opt/scripts/entrypoint.sh && \
    chown -R bridgelink:bridgelink /opt/bridgelink

WORKDIR /opt/bridgelink

# Expose the required port and define volumes for persistent data
EXPOSE 8443
VOLUME /opt/bridgelink/appdata
VOLUME /opt/bridgelink/custom-extensions

# Switch to the bridgelink user and define the container’s entrypoint and command
USER bridgelink

# Entrypoint
ENTRYPOINT ["/opt/scripts/entrypoint.sh"]
CMD ["./blserver"]
