# ============================================================
# Stage 1: Builder
# ============================================================
FROM --platform=linux/amd64 rockylinux:9 AS builder

# Install build tools and repositories
RUN yum install -y tar gzip openssl shadow-utils unzip python3 wget && \
    yum install -y https://download.postgresql.org/pub/repos/yum/reporpms/EL-8-x86_64/pgdg-redhat-repo-latest.noarch.rpm

# Install OpenJDK 21 (runtime & development) and set JAVA_HOME
RUN yum -y install java-21-openjdk java-21-openjdk-devel
ENV JAVA_HOME=/usr/lib/jvm/java-21-openjdk
ENV PATH=$JAVA_HOME/bin:$PATH

# Install python3-pip and required Python packages
RUN yum install -y python3-pip && \
    pip3 install boto3 && \
    pip3 install --no-cache-dir psycopg2-binary

# Install AWS CLI
RUN curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip" && \
    unzip awscliv2.zip && \
    /aws/install && \
    rm -rf aws*

# Create the bridgelink user with UID 1000
RUN useradd -u 1000 bridgelink

# Copy in the necessary scripts and ensure they are executable
COPY scripts/install.sh /opt/scripts/install.sh
COPY scripts/entrypoint.sh /opt/scripts/entrypoint.sh
RUN chmod +x /opt/scripts/install.sh /opt/scripts/entrypoint.sh

# (Optional) List the scripts to verify copy and permissions
RUN ls -l /opt/scripts/

# Run the installation script which sets up your application under /opt/bridgelink
RUN /opt/scripts/install.sh

# Create required directories for persistent data and set ownership
RUN mkdir -p /opt/bridgelink/appdata && chown bridgelink:bridgelink /opt/bridgelink/appdata && \
    mkdir -p /opt/bridgelink/custom-extensions && chown bridgelink:bridgelink /opt/bridgelink/custom-extensions

# Clean up unnecessary files from the application directory
WORKDIR /opt/bridgelink
RUN rm -r mirth-cli-launcher.jar mirth-manager-launcher.jar blmanager cli-lib

# Ensure the entrypoint script is executable and that the application files have proper ownership
RUN chmod 755 /opt/scripts/entrypoint.sh && \
    chown -R bridgelink:bridgelink /opt/bridgelink

# ============================================================
# Stage 2: Runtime
# ============================================================
FROM --platform=linux/amd64 rockylinux:9 AS final

# Install only the runtime dependencies. (Python3 may be needed by your app.)
RUN yum install -y java-21-openjdk python3 && yum clean all

# Set JAVA_HOME and update PATH for runtime
ENV JAVA_HOME=/usr/lib/jvm/java-21-openjdk
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
ENTRYPOINT ["/opt/scripts/entrypoint.sh"]
CMD ["./blserver"]