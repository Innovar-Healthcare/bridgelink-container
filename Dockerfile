FROM --platform=linux/amd64 amazoncorretto:17

RUN yum install -y tar gzip openssl shadow-utils

RUN useradd -u 1000 mirth

COPY scripts/install.sh /opt/scripts/install.sh
COPY scripts/entrypoint.sh /opt/scripts/entrypoint.sh

# Make the script executable
RUN chmod +x /opt/scripts/install.sh /opt/scripts/entrypoint.sh

# Check if the script exists and has execute permission
RUN ls -l /opt/scripts/
# Run the bash script
RUN /opt/scripts/install.sh

RUN mkdir -p /opt/connect/appdata && chown mirth:mirth /opt/connect/appdata
RUN mkdir -p /opt/connect/custom-extensions && chown mirth:mirth /opt/connect/custom-extensions
# RUN mkdir -p /opt/connect/s3 && chown mirth:mirth /opt/connect/s3

WORKDIR /opt/connect
RUN rm -r mirth-cli-launcher.jar mirth-manager-launcher.jar mcservice mcservice.vmoptions mcmanager cli-lib

RUN chmod 755 /opt/scripts/entrypoint.sh
ENTRYPOINT [ "/opt/scripts/entrypoint.sh" ] 

EXPOSE 8443

RUN chown -R mirth:mirth /opt/connect
USER mirth
VOLUME /opt/connect/appdata
VOLUME /opt/connect/custom-extensions

CMD ["/opt/connect/mcserver"]