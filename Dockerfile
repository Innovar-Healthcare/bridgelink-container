FROM amazoncorretto:17

ARG DATABASE
ARG DATABASE_URL
ARG DATABASE_MAX_CONNECTIONS
ARG DATABASE_USERNAME
ARG DATABASE_PASSWORD
ARG DATABASE_MAX_RETRY
ARG DATABASE_RETRY_WAIT
ARG KEYSTORE_STOREPASS
ARG KEYSTORE_KEYPASS
ARG VMOPTIONS

RUN yum install -y tar && yum install -y gzip

COPY scripts/install.sh /opt/scripts/install.sh
COPY scripts/updateVariables.sh /opt/scripts/updateVariables.sh

# Make the script executable
RUN chmod +x /opt/scripts/install.sh /opt/scripts/updateVariables.sh

# Check if the script exists and has execute permission
RUN ls -l /opt/scripts/

# Run the bash script
RUN /opt/scripts/install.sh
RUN /opt/scripts/updateVariables.sh

# Default command to keep the container running
CMD ["/bin/bash"]