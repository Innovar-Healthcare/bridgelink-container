<a name="top"></a>
# Table of Contents

* [Supported tags and respective Dockerfile links](#supported-tags)
* [Supported Architectures](#supported-architectures)
* [Quick Reference](#quick-reference)
* [What is BridgeLink (formerly Mirth Connect)](#what-is-connect)
* [How to use this image](#how-to-use)
  * [Start a BridgeLink instance](#start-bridgelink)
  * [Using `docker stack deploy` or `docker-compose`](#using-docker-compose)
  * [Environment Variables](#environment-variables)
    * [Common mirth.properties options](#common-mirth-properties-options)
    * [Other mirth.properties options](#other-mirth-properties-options)
  * [Using Docker Secrets](#using-docker-secrets)
  * [Using Volumes](#using-volumes)
    * [The appdata folder](#the-appdata-folder)
    * [Additional extensions](#additional-extensions)
* [License](#license)

------------

<a name="supported-tags"></a>
# Supported tags and respective Dockerfile links [↑](#top)

##### Rockylinux9 OpenJDK 17

* [4.6.0, latest](https://github.com/Innovar-Healthcare/bridgelink-container/blob/bl_4.6.0/Dockerfile)
* [4.5.4](https://github.com/Innovar-Healthcare/bridgelink-container/blob/bl_4.5.4/Dockerfile)
* [4.5.3](https://github.com/Innovar-Healthcare/bridgelink-container/blob/bl_4.5.3/Dockerfile)

------------

<a name="supported-architectures"></a>
# Supported Architectures [↑](#top)

Docker images for BridgeLink 4.6.0 and later versions support both `linux/amd64` and `linux/arm64` architectures. 
```
docker pull --platform linux/arm64 innovarhealthcare/bridgelink:latest
```

------------

<a name="quick-reference"></a>
# Quick Reference [↑](#top)

#### Where to get help:


* [Slack Channel](https://join.slack.com/t/bridgelink01/shared_invite/zt-338scfesm-06MB6s7SggDMc7PIYKs4cw)
* [BridgeLink GitHub](https://github.com/Innovar-Healthcare/BridgeLink/tree/bridgelink_development)
* [BridgeLink Docker GitHub](https://github.com/Innovar-Healthcare/bridgelink-container/tree/main)

#### Where to file issues:

* For issues relating to these Docker images:
  * https://github.com/Innovar-Healthcare/bridgelink-container/issues
* For issues relating to the Connect application itself:
  * https://github.com/Innovar-Healthcare/BridgeLink/issues

------------

<a name="what-is-BridgeLink"></a>
# What is BridgeLink [↑](#top)

An open-source message integration engine focused on healthcare. For more information please visit our [GitHub page](https://github.com/Innovar-Healthcare/BridgeLink/tree/bridgelink_development).

<img src="https://raw.githubusercontent.com/Innovar-Healthcare/BridgeLink/bridgelink_development/server/public_html/images/MirthConnect_Logo_WordMark_Big.png"/>

------------

<a name="how-to-use"></a>
# How to use this image [↑](#top)

<a name="start-bridgelink"></a>
## Start a Bridgelink instance [↑](#top)

Quickly start Bridgelink using embedded Derby database and all configuration defaults. At a minimum you will likely want to use the `-p` option to expose the 8443 port so that you can login with the Administrator GUI or CLI:

```bash
docker run -p 8443:8443 innovarhealthcare/bridgelink
```

You can also use the `--name` option to give your container a unique name, and the `-d` option to detach the container and run it in the background:

```bash
docker run --name mybridgelink -d -p 8443:8443 innovarhealthcare/bridgelink
```

To run a specific version of Connect, specify a tag at the end:

```bash
docker run --name mybridgelink -d -p 8443:8443 innovarhealthcare/bridgelink:4.6.0
```

To run using a specific architecture, specify it using the `--platform` argument:

```bash
docker run --name mybridgelink -d -p 8443:8443 --platform linux/arm64 innovarhealthcare/bridgelink:4.6.0
```

Look at the [Environment Variables](#environment-variables) section for more available configuration options.

------------

<a name="using-docker-compose"></a>
## Using [`docker stack deploy`](https://docs.docker.com/engine/reference/commandline/stack_deploy/) or [`docker-compose`](https://github.com/docker/compose) [↑](#top)

With `docker stack` or `docker-compose` you can easily setup and launch multiple related containers. For example you might want to launch both BridgeLink *and* a PostgreSQL database to run alongside it.

```bash
docker-compose -f stack.yml up
```

Here's an example `stack.yml` file you can use:

```yaml
version: "3.1"
services:
  mc:
    image: innovarhealthcare/bridgelink:4.6.0
    platform: linux/amd64
    environment:
        - MP_DATABASE=postgres
        - MP_DATABASE_URL=jdbc:postgresql://10.5.0.5:5432/bridgelinkdb
        - MP_DB_SCHEMA=bridgelinkdb
        - MP_DATABASE_USERNAME=bridgelinktest
        - MP_DATABASE_PASSWORD=bridgelinktest
        - MP_DATABASE_DBNAME=bridgelinkdb
        - MP_DATABASE_MAX__CONNECTIONS=20
        - MP_DATABASE_CONNECTION_MAXRETRY=2
        - MP_DATABASE_RETRY_WAIT=10000
        - SERVER_ID=xxxxxx-xxxxx-xxxxxx-xxxxxx
        - MP_KEYSTORE_KEYPASS=bridgelinkKeystore
        - MP_KEYSTORE_STOREPASS=bridgelinkKeypass
        - MP_VMOPTIONS=512
    ports:
      - 8080:8080/tcp
      - 8443:8443/tcp
    depends_on:
      - db
  db:
    image: postgres
    environment:
      - POSTGRES_USER=bridgelinktest
      - POSTGRES_PASSWORD=bridgelinktest
      - POSTGRES_DB=bridgelinktest
    expose:
      - 5432
```



------------

<a name="environment-variables"></a>
## Environment Variables [↑](#top)

You can use environment variables to configure the [mirth.properties](https://github.com/nextgenhealthcare/connect/blob/development/server/conf/mirth.properties) file or to add custom JVM options.

To set environment variables, use the `-e` option for each variable on the command line:

```bash
docker run -e MP_DATABASE='derby' -p 8443:8443 innovarhealthcare/bridgelink
```

You can also use a separate file containing all of your environment variables using the `--env-file` option. For example let's say you create a file **myenvfile.txt**:

```bash
MP_DATABASE=postgres
MP_DATABASE_URL=jdbc:postgresql://10.5.0.5:5432/bridgelinkdb
MP_DATABASE_USERNAME=bridgelinktest
MP_DATABASE_PASSWORD=bridgelinktest
MP_DATABASE_DBNAME=bridgelinkdb
MP_DATABASE_CONNECTION_MAXRETRY=2
MP_DATABASE_RETRY_WAIT=10000
SERVER_ID=xxxxx-xxxxxx-xxxxxx-xxxxx
MP_KEYSTORE_KEYPASS=bridgelinkKeystore
MP_KEYSTORE_STOREPASS=bridgelinkKeypass
MP_VMOPTIONS=512
```

```bash
docker run --env-file=myenvfile.txt -p 8443:8443 innovarhealthcare/bridgelink
```

------------

<a name="common-mirth-properties-options"></a>
### Common mirth.properties options [↑](#top)

<a name="env-database"></a>
#### `MP_DATABASE`

The database type to use for the BridgeLink Integration Engine backend database. Options:

* derby
* mysql
* postgres
* oracle
* sqlserver

<a name="env-database-url"></a>
#### `MP_DATABASE_URL`

The JDBC URL to use when connecting to the database. For example:
* `jdbc:postgresql://serverip:5432/mirthdb`

<a name="env-database-username"></a>
#### `MP_DATABASE_USERNAME`

The username to use when connecting to the database. If you don't want to use an environment variable to store sensitive information like this, look at the [Using Docker Secrets](#using-docker-secrets) section below.

<a name="env-database-password"></a>
#### `MP_DATABASE_PASSWORD`

The password to use when connecting to the database. If you don't want to use an environment variable to store sensitive information like this, look at the [Using Docker Secrets](#using-docker-secrets) section below.

<a name="env-database-max-connections"></a>
#### `MP_DATABASE_MAX__CONNECTIONS`

The maximum number of connections to use for the internal messaging engine connection pool.

<a name="env-database-max-retry"></a>
#### `MP_DATABASE_MAX_RETRY`

On startup, if a database connection cannot be made for any reason, Connect will wait and attempt again this number of times. By default, will retry 2 times (so 3 total attempts).

<a name="env-database-retry-wait"></a>
#### `MP_DATABASE_RETRY_WAIT`

The amount of time (in milliseconds) to wait between database connection attempts. By default, will wait 10 seconds between attempts.

<a name="env-keystore-storepass"></a>
#### `MP_KEYSTORE_STOREPASS`

The password for the keystore file itself. If you don't want to use an environment variable to store sensitive information like this, look at the [Using Docker Secrets](#using-docker-secrets) section below.

<a name="env-keystore-keypass"></a>
#### `MP_KEYSTORE_KEYPASS`

The password for the keys within the keystore, including the server certificate and the secret encryption key. If you don't want to use an environment variable to store sensitive information like this, look at the [Using Docker Secrets](#using-docker-secrets) section below.

<a name="env-keystore-type"></a>
#### `MP_KEYSTORE_TYPE`

The type of keystore.


<a name="env-vmoptions"></a>
#### `MP_VMOPTIONS`

A comma-separated list of JVM command-line options to place in the `.vmoptions` file. For example to set the max heap size and HTTPS proxy ports:

* 512,-Dhttp.proxyPort=9001,-Dhttps.proxyHost=9002,-Dhttps.proxyPort=9003


<a name="env-keystore-download"></a>
#### `KEYSTORE_DOWNLOAD`

A URL location of a BridgeLink keystore file. This file will be downloaded into the container and BridgeLink will use it as its keystore.

<a name ="env-extensions-download"></a>
#### `EXTENSIONS_DOWNLOAD`

A URL location of a zip file containing BridgeLink extension zip files. The extensions will be installed on the BridgeLink server.

<a name ="env-custom-jars-download"></a>
#### `CUSTOM_JARS_DOWNLOAD`

A URL location of a zip file containing JAR files. The JAR files will be installed into the `custom-jars` folder on the BridgeLink server, so they will be added to the server's classpath.

<a name ="env-custom-properties"></a>
#### `CUSTOM_PROPERTIES`

A URL location of a mirth.properties file. The properties file will replace the /opt/bridgelink/conf/mirth.properties file.
other MP_ variables still can be added into the custom mirth.properties.

<a name ="env-custom-vmoptions"></a>
#### `CUSTOM_VMOPTIONS`

A URL location of a blserver.vmoptions file. The vmoptions file will replace the /opt/bridgelink/blserver.vmoptions.


<a name="env-allow-insecure"></a>
#### `ALLOW_INSECURE`

Allow insecure SSL connections when downloading files during startup. This applies to keystore downloads, plugin downloads, and server library downloads. By default, insecure connections are disabled but you can enable this option by setting `ALLOW_INSECURE=true`.

<a name="env-server-id"></a>
#### `SERVER_ID`

Set the `server.id` to a specific value. Use this to preserve or set the server ID across restarts and deployments. Using the env-var is preferred over storing `appdata` persistently

------------

<a name="other-mirth-properties-options"></a>
### Other mirth.properties options [↑](#top)

Other options in the mirth.properties file can also be changed. Any environment variable starting with the `MP_` prefix will set the corresponding value in mirth.properties. Replace `.` with a single underscore `_` and `-` with two underscores `__`.

Examples:

* Set the server TLS protocols to only allow TLSv1.2 and 1.3:
  * In the mirth.properties file:
    * `https.server.protocols = TLSv1.3,TLSv1.2`
  * As a Docker environment variable:
    * `MP_HTTPS_SERVER_PROTOCOLS='TLSv1.3,TLSv1.2'`

* Set the max connections for the read-only database connection pool:
  * In the mirth.properties file:
    * `database-readonly.max-connections = 20`
  * As a Docker environment variable:
    * `MP_DATABASE__READONLY_MAX__CONNECTIONS='20'`

------------

<a name="using-docker-secrets"></a>
## Using Docker Secrets [↑](#top)

For sensitive information such as the database/keystore credentials, instead of supplying them as environment variables you can use a [Docker Secret](https://docs.docker.com/engine/swarm/secrets/). There are two secret names this image supports:

##### mirth_properties

If present, any properties in this secret will be merged into the mirth.properties file.

##### blserver_vmoptions

If present, any JVM options in this secret will be appended onto the blserver.vmoptions file.

------------

Secrets are supported with [Docker Swarm](https://docs.docker.com/engine/swarm/secrets/), but you can also use them with [`docker-compose`](#using-docker-compose).

For example let's say you wanted to set `keystore.storepass` and `keystore.keypass` in a secure way. You could create a new file, **secret.properties**:

```bash
keystore.storepass=changeme
keystore.keypass=changeme
```

Then in your YAML docker-compose stack file:

```yaml
version: '3.1'
services:
  mc:
    image: innovarhealthcare/bridgelink
    environment:
      - MP_VMOPTIONS=512
    secrets:
      - mirth_properties
    ports:
      - 8080:8080/tcp
      - 8443:8443/tcp
secrets:
  mirth_properties:
    file: /local/path/to/mirth_properties
```

The **secrets** section at the bottom specifies the local file location for each secret.  Change `/local/path/to/secret.properties` to the correct local path and filename.

Inside the configuration for the BridgeLink container there is also a **secrets** section that lists the secrets you want to include for that container.

------------

<a name="using-volumes"></a>
## Using Volumes [↑](#top)

<a name="the-appdata-folder"></a>
#### The appdata folder [↑](#top)

The application data directory (appdata) stores configuration files and temporary data created by BridgeLink after starting up. This usually includes the keystore file and the `server.id` file that stores your server ID. If you are launching BridgeLink as part of a stack/swarm, it's possible the container filesystem is already being preserved. But if not, you may want to consider mounting a **volume** to preserve the appdata folder.

```bash
docker run -v /local/path/to/appdata:/opt/bridgelink/appdata -p 8443:8443 innovarhealthcare/bridgelink
```

The `-v` option makes a local directory from your filesystem available to the Docker container. Create a folder on your local filesystem, then change the `/local/path/to/appdata` part in the example above to the correct local path.

You can also configure volumes as part of your docker-compose YAML stack file:

```yaml
version: '3.1'
services:
  mc:
    image: innovarhealthcare/bridgelink
    volumes:
      - ~/Documents/appdata:/opt/bridgelink/appdata
```

------------

<a name="additional-extensions"></a>
#### Additional extensions [↑](#top)

The entrypoint script will automatically look for any ZIP files in the `/opt/bridgelink/custom-extensions` folder and unzip them into the extensions folder before BridgeLink starts up. So to launch BridgeLink with any additional extensions not included in the base application, do this:

```bash
docker run -v /local/path/to/custom-extensions:/opt/bridgelink/custom-extensions -p 8443:8443 innovarhealthcare/bridgelink
```

Create a folder on your local filesystem containing the ZIP files for your additional extensions. Then change the `/local/path/to/custom-extensions` part in the example above to the correct local path.

As with the appdata example, you can also configure this volume as part of your docker-compose YAML file.

------------

## Known Limitations

Currently, only the Debian flavored images support the newest authentication scheme in MySQL 8. All others (the Alpine based images) will need the following to force the MySQL database container to start using the old authentication scheme:

```yaml
command: --default-authentication-plugin=mysql_native_password
```

Example:

```yaml
  db:
    image: mysql
    command: --default-authentication-plugin=mysql_native_password
    environment:
      ...
```

------------

<a name="license"></a>
# License [↑](#top)

The Dockerfiles, entrypoint script, and any other files used to build these Docker images are Copyright © Innovar Healthcare and licensed under the [Mozilla Public License 2.0](https://www.mozilla.org/en-US/MPL/2.0/).
