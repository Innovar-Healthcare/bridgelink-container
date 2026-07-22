<a name="top"></a>
# Table of Contents

* [Supported tags and respective Dockerfile links](#supported-tags)
* [Supported Architectures](#supported-architectures)
* [Pulling from Cloudsmith (licensed customers)](#cloudsmith)
* [Quick Reference](#quick-reference)
* [What is BridgeLink (formerly Mirth Connect)](#what-is-connect)
* [Hardened (DHI) image](#hardened-dhi-image)
* [Image security scanning](#image-security-scanning)
* [How to use this image](#how-to-use)
  * [Start a BridgeLink instance](#start-bridgelink)
  * [Using `docker stack deploy` or `docker-compose`](#using-docker-compose)
  * [Environment Variables](#environment-variables)
    * [Common mirth.properties options](#common-mirth-properties-options)
    * [Other mirth.properties options](#other-mirth-properties-options)
  * [Using Docker Secrets](#using-docker-secrets)
  * [Security Options](#security-options)
  * [Using Volumes](#using-volumes)
    * [The appdata folder](#the-appdata-folder)
    * [Additional extensions](#additional-extensions)
* [License](#license)

------------

<a name="supported-tags"></a>
# Supported tags and respective Dockerfile links [↑](#top)

##### Rockylinux9 OpenJDK 17

* [26.6.0, latest](https://github.com/Innovar-Healthcare/bridgelink-container/blob/bl_26.6.0/)
* [26.3.1](https://github.com/Innovar-Healthcare/bridgelink-container/blob/bl_26.3.1/)
* [26.3.0](https://github.com/Innovar-Healthcare/bridgelink-container/blob/bl_26.3.0/)
* [4.6.1](https://github.com/Innovar-Healthcare/bridgelink-container/blob/bl_4.6.1/Dockerfile)
* [4.6.0](https://github.com/Innovar-Healthcare/bridgelink-container/blob/bl_4.6.0/Dockerfile)
* [4.5.4](https://github.com/Innovar-Healthcare/bridgelink-container/blob/bl_4.5.4/Dockerfile)
* [4.5.3](https://github.com/Innovar-Healthcare/bridgelink-container/blob/bl_4.5.3/Dockerfile)

##### Amazon Corretto Debian 13 — Docker Hardened Image (DHI)

* [26.3.1-dhi](https://github.com/Innovar-Healthcare/bridgelink-container/blob/main/Dockerfile.dhi)
* [26.3.1-dhi-slim](https://github.com/Innovar-Healthcare/bridgelink-container/blob/main/Dockerfile.dhi) — WebAdmin-only (no bundled Swing Administrator)

------------

<a name="supported-architectures"></a>
# Supported Architectures [↑](#top)

Docker images for BridgeLink 26.3.0 and later versions support both `linux/amd64` and `linux/arm64` architectures.
```
docker pull --platform linux/arm64 innovarhealthcare/bridgelink:latest
```

------------

<a name="cloudsmith"></a>
# Pulling from Cloudsmith (licensed customers) [↑](#top)

BridgeLink source stays fully open on GitHub, and public releases continue. Licensed customers get
earlier, more frequent builds through **Cloudsmith**, including
security patches between public releases. The **26.6.0** packaged Docker image and installers are
available now to licensed customers from the Cloudsmith repository `innovarhealthcare/bridgelink`,
gated by your **entitlement token**. One token unlocks both the Docker image and the raw downloads.

> Your entitlement token is issued with your license. Treat it like a password — do not commit it or
> share it outside your organization.

## Docker image

Log in to the Cloudsmith Docker registry using your entitlement **token as the password**, then pull:

```bash
docker login docker.cloudsmith.io -u innovarhealthcare/bridgelink -p <ENTITLEMENT_TOKEN>
docker pull docker.cloudsmith.io/innovarhealthcare/bridgelink/bridgelink:<version>
```

For example, for 26.6.0:

```bash
docker pull docker.cloudsmith.io/innovarhealthcare/bridgelink/bridgelink:26.6.0
```

The image is multi-arch (`linux/amd64` and `linux/arm64`); Docker selects the right variant for your
host automatically.

> **Recommended:** mirror the image into your own internal registry **once per release** rather than
> pulling from Cloudsmith on every deploy. This avoids repeated authenticated pulls, protects you from
> transient registry outages, and keeps deployments fast:
>
> ```bash
> docker pull docker.cloudsmith.io/innovarhealthcare/bridgelink/bridgelink:26.6.0
> docker tag  docker.cloudsmith.io/innovarhealthcare/bridgelink/bridgelink:26.6.0 \
>             registry.internal.example.com/bridgelink:26.6.0
> docker push registry.internal.example.com/bridgelink:26.6.0
> ```

## Installer / archive downloads

The platform installers and archives are published as raw packages, one per file. Download any of
them with your token in the URL — the file name is all you need:

```
https://dl.cloudsmith.io/<TOKEN>/innovarhealthcare/bridgelink/<filename>
```

For example, to download the Linux `.tar.gz` for 26.6.0:

```bash
curl -fLO \
  "https://dl.cloudsmith.io/<TOKEN>/innovarhealthcare/bridgelink/BridgeLink_unix_26_6_0.tar.gz"
```

Available files for a release (26.6.0 shown; note the underscores in the version part of each name):

| Platform | Filename |
|---|---|
| Linux (RPM) | `BridgeLink_linux_26_6_0.rpm` |
| macOS (disk image) | `BridgeLink_macos_26_6_0.dmg` |
| macOS (archive) | `BridgeLink_macos_26_6_0.tgz` |
| Unix (installer script) | `BridgeLink_unix_26_6_0.sh` |
| Unix (archive) | `BridgeLink_unix_26_6_0.tar.gz` |
| Windows (installer) | `BridgeLink_windows-x64_26_6_0.exe` |
| Windows (MSI) | `BridgeLink_windows-x64_26_6_0.msi` |
| Windows (archive) | `BridgeLink_windows-x64_26_6_0.zip` |

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

<a name="hardened-dhi-image"></a>
# Hardened (DHI) image [↑](#top)

In addition to the default Rocky Linux image (`Dockerfile`), BridgeLink ships a **hardened image**
built on the [Amazon Corretto Debian 13 Docker Hardened Image](https://hub.docker.com/hardened-images/catalog/dhi/amazoncorretto)
(`Dockerfile.dhi`), for environments that require a minimal, near-zero-CVE base. The hardened
runtime has **no shell, no package manager, and runs as non-root UID `65532`**. Its config/startup
logic is handled by a small shell-free Java launcher (`bootstrap/BridgeLinkBootstrap.java`) instead
of the bash `entrypoint.sh` — **all environment variables, Docker secrets, and volumes documented
below work identically on both images.**

Key differences from the Rocky image:

| | Rocky image (`Dockerfile`) | Hardened image (`Dockerfile.dhi`) |
|---|---|---|
| Base | Rocky Linux 9 + OpenJDK 17 | Amazon Corretto 17 / Debian 13 DHI |
| Non-root UID | 1000 | **65532** |
| Shell / package manager | present | **none** (runtime) |
| Image tag suffix | *(none)* | `-dhi` |

**Published tags.** The hardened image lives in the **same** `innovarhealthcare/bridgelink`
repository — it's just additional tags: `26.3.1-dhi` (version-pinned) and `latest-dhi` (rolling),
sitting alongside the Rocky tags (`26.3.1`, `latest`). You choose the base by tag —
`…/bridgelink:26.3.1` for Rocky, `…/bridgelink:26.3.1-dhi` for hardened. Both are multi-arch
(amd64 + arm64). The two images are the same BridgeLink release and behave identically; only the
base OS/runtime and the non-root UID differ.

**Build** (the DHI base is pulled from the free Community registry — run `docker login dhi.io` first).
`BINARY_URL` points at a BridgeLink release tarball:

```
docker build -f Dockerfile.dhi \
  --build-arg BINARY_URL="https://.../BridgeLink_unix_26_3_1.tar.gz" \
  -t innovarhealthcare/bridgelink:26.3.1-dhi .
```

Only if you pull the tarball from a **private `s3://`** bucket (internal Innovar builds), also pass
AWS credentials as a build secret — the build reads it via `aws s3 cp`. It is not needed for a
public `https://` URL:

```
  --build-arg BINARY_URL="s3://your-bucket/BridgeLink_unix_26_3_1.tar.gz" \
  --secret id=aws_credentials,src=$HOME/.aws/credentials
```

**WebAdmin-only (slim) variant.** The new web-based BridgeLink Administrator (WebAdmin) replaces the
legacy Swing desktop client. For deployments that use WebAdmin, the `INCLUDE_ADMIN_CLIENT` build-arg
strips the Swing Administrator from the image:

* `INCLUDE_ADMIN_CLIENT=true` *(default)* — keeps the Swing client. The server serves it via Java
  Web Start, exactly as today.
* `INCLUDE_ADMIN_CLIENT=false` — removes the Swing client jars (`client-lib/`) and the Web Start
  landing page (`public_html/`), producing a smaller, lower-attack-surface image. **The server and
  its REST API are unaffected** — only Java Web Start launching of the Swing client and the `/`
  landing page are dropped (they return `404`). Manage the instance with WebAdmin (its own
  container) or the standalone WebAdmin download instead.

CI publishes this variant for the DHI image as `26.3.1-dhi-slim` / `latest-dhi-slim`, alongside the
full `-dhi` tags. The build-arg works on **both** Dockerfiles; the Rocky slim image is built the same
way (its publish is handled by the Rocky release process):

```
docker build \
  --build-arg BINARY_URL="https://.../BridgeLink_unix_26_3_1.tar.gz" \
  --build-arg INCLUDE_ADMIN_CLIENT=false \
  -t innovarhealthcare/bridgelink:26.3.1-slim .
```

> Note: this image contains BridgeLink **Core** without the Swing client — it does **not** bundle the
> WebAdmin/WebUI itself, which ships as its own separate container.

**Run.** The hardened image runs like the Rocky one; you just select it by tag and run as UID
`65532`. Any mounted `appdata` / `custom-extensions` directory must be owned by `65532` so the
container can write to it. A ready-to-use compose file, `docker-compose.dhi.yml`, is the DHI
counterpart of `docker-compose.yml` — pick which one by the `-f` you pass:

```
# Rocky image (default) — uses docker-compose.yml
docker compose up

# Hardened (DHI) image — uses docker-compose.dhi.yml
chown -R 65532:65532 ./appdata
docker compose -f docker-compose.dhi.yml up
```

For Kubernetes, deploy the Helm chart with `--set bridgelink.runAsUser=65532 --set bridgelink.runAsGroup=65532`.

Behavior notes specific to the hardened image:

* **`ALLOW_INSECURE` also applies to `KEYSTORE_DOWNLOAD`.** On the Rocky image the keystore
  download always verifies TLS regardless of `ALLOW_INSECURE`; the hardened image applies
  `ALLOW_INSECURE` consistently to *all* downloads (keystore, extensions, custom jars,
  custom properties/vmoptions). All downloads verify TLS by default on both images.
* **Graceful shutdown window.** On `docker stop` the launcher forwards the signal to the engine
  and allows up to 30 seconds for queues/DB connections to drain — but Docker's default stop
  timeout is 10 seconds, after which the container is killed. For queue-heavy deployments give it
  headroom: `docker stop -t 35`, compose `stop_grace_period: 35s`, or a pod
  `terminationGracePeriodSeconds: 35`.

**Test** the images (no-shell [DHI], boot, config/secret/extension injection, Postgres/MySQL, graceful
shutdown, persistence) with the acceptance suite `test/image-test.sh` — the same suite CI runs on PRs:

```
# Hardened (DHI) image — defaults:
BINARY_URL="<release tarball>" test/image-test.sh              # builds, then tests
IMAGE=innovarhealthcare/bridgelink:26.3.1-dhi SKIP_BUILD=1 test/image-test.sh   # test an existing image

# Rocky image (UID 1000, shell present -> no-shell check skipped):
BINARY_URL="<release tarball>" IMAGE=innovarhealthcare/bridgelink:26.3.1 \
  DOCKERFILE=Dockerfile EXPECTED_UID=1000 CHECK_NO_SHELL=0 test/image-test.sh

# WebAdmin-only (slim) image — also assert the Swing Administrator was stripped:
IMAGE=innovarhealthcare/bridgelink:26.3.1-dhi-slim SKIP_BUILD=1 \
  EXPECT_NO_ADMIN_CLIENT=1 test/image-test.sh
```

------------

<a name="image-security-scanning"></a>
# Image security scanning [↑](#top)

Both images are scanned for OS and library vulnerabilities with [Trivy](https://trivy.dev) in CI
(`.github/workflows/build-images.yml`) on every pull request and before publish.

- **Full results** (all severities, OS **and** library, including unfixed) are uploaded as SARIF to the
  repository **Security → Code scanning** tab, one category per image (`trivy-dhi`, `trivy-rocky`).
  Scanning the DHI image makes its near-zero-CVE base claim provable and catches regressions early.
- **Gate:** the build **fails on _fixable_ HIGH/CRITICAL findings in OS / base-image packages**
  (`--ignore-unfixed`, OS packages only) — the layer this repo controls. Unfixed OS CVEs (no upstream
  patch yet) don't fail the build but are still reported.
- **Library / application-JAR CVEs are _not_ gated here.** They come from the BridgeLink release
  tarball baked in via `BINARY_URL` (see [What this repo is](#what-this-repo-is)); this repo can't fix
  them — only a new Core release can. They are reported in the SARIF above and tracked against Core in
  [IRT-1396](https://innovarhealthcare.atlassian.net/browse/IRT-1396).

### Scan locally

```
trivy image innovarhealthcare/bridgelink:26.3.1          # Rocky — full report (OS + library)
trivy image innovarhealthcare/bridgelink:26.3.1-dhi      # DHI
# Reproduce the CI gate exactly (OS packages only):
trivy image --severity HIGH,CRITICAL --ignore-unfixed --pkg-types os --exit-code 1 <image>
```

### Triage / allowlist an OS finding

1. Review the finding in the **Security → Code scanning** tab (or the CI job's table output).
2. Fix it by bumping the base image (the Renovate PRs keep the digest-pinned bases current) and letting
   `yum update` / the hardened base pull the patched package.
3. If it must be accepted (false positive, not reachable in our configuration, or awaiting a Rocky/DHI
   erratum), add its CVE ID to [`.trivyignore`](.trivyignore) with a justification and a review date.
   Allowlisted entries are suppressed from the gate, so keep the list short and re-review dated entries.

For a library/app-JAR CVE, track it in the Core ticket
([IRT-1396](https://innovarhealthcare.atlassian.net/browse/IRT-1396)) — it is outside the CI gate
scope (the gate scans OS packages only) and stays visible on the Security tab regardless. Once Core
has assessed one as not-exploitable / unfixable, you may also record it in [`.trivyignore`](.trivyignore)
with that justification so local `trivy image` / `--pkg-types library` scans are clean; the CI SARIF
still shows it. (Example already present: Apache Derby `CVE-2022-46337`.)

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
docker run --name mybridgelink -d -p 8443:8443 innovarhealthcare/bridgelink:26.3.1
```

To run using a specific architecture, specify it using the `--platform` argument:

```bash
docker run --name mybridgelink -d -p 8443:8443 --platform linux/arm64 innovarhealthcare/bridgelink:26.3.1
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
    image: innovarhealthcare/bridgelink:26.3.1
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

<a name="security-options"></a>
## Security Options [↑](#top)

### `no-new-privileges`

The `no-new-privileges` flag prevents the container process and any child processes from gaining additional Linux privileges after startup — for example, via `setuid` or `setgid` binaries. This is a defense-in-depth measure: if the application is compromised, an attacker cannot escalate privileges inside the container.

To enable it, add a `security_opt` block to your docker-compose service:

```yaml
services:
  bl:
    image: innovarhealthcare/bridgelink:26.3.1
    security_opt:
      - no-new-privileges:true
```

> **Note:** This option is recommended for production deployments. Verify that all extensions and startup scripts function correctly with this flag enabled before rolling it out, as some tooling that requires privilege escalation during initialization may be affected.

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

The Dockerfiles, entrypoint script, Java bootstrap launcher, Helm chart, and any other files used to build these Docker images are Copyright © Innovar Healthcare and licensed under the [Mozilla Public License 2.0](https://www.mozilla.org/en-US/MPL/2.0/) (see [`LICENSE`](LICENSE)).

The hardened image (`Dockerfile.dhi`) is built on the Amazon Corretto Debian 13 Docker Hardened Image; see [`NOTICE`](NOTICE) for third-party attribution and redistribution details (Docker's Apache-2.0 DHI definitions, and the OpenJDK/glibc/Debian package licenses inside the base).
