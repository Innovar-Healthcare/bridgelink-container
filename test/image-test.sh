#!/usr/bin/env bash
#
# Automated acceptance tests for the BridgeLink container images — IRT-1356 (DHI), IRT-1391 (Rocky).
# Asserts boot + config-injection parity across the hardened (DHI) and Rocky images from one suite.
#
# Parameterized by env var:
#   IMAGE           image to test (default innovarhealthcare/bridgelink:dhi-test)
#   DOCKERFILE      Dockerfile to build when SKIP_BUILD!=1 (default Dockerfile.dhi; Dockerfile for Rocky)
#   EXPECTED_UID    non-root UID the image must run as (default 65532; 1000 for Rocky)
#   CHECK_NO_SHELL  1 = assert the runtime has no shell (DHI); 0 = skip (Rocky has a shell)
#   SKIP_BUILD      1 = test an existing IMAGE instead of building
#   EXPECT_NO_ADMIN_CLIENT  1 = assert the Swing Administrator (client-lib, public_html) is absent
#                           (WebAdmin-only image built with INCLUDE_ADMIN_CLIENT=false); 0 = skip
#   EXPECTED_JAVA   Java major the runtime must report (e.g. 17 or 21); empty = skip. CI passes the
#                   JAVA_MAJOR it built with, so a rebuild of an old release proves it stayed on 17.
#   JAVA_MAJOR      when building (SKIP_BUILD!=1): the JDK to build on (Dockerfile default 21).
#                   Set it together with EXPECTED_JAVA when building a pre-26.6.1 release.
#   DEFAULT_DB      backend for every container that does not name one itself: derby (default) or
#                   postgres. Set postgres for an image whose bundled Derby cannot run on its JDK
#                   (a 26.6.1-or-later release built on Java 17) — the server exits at startup on
#                   the shipped Derby default there, so 13 of the 15 containers below would fail for
#                   a reason that is not a defect. In that mode the suite starts its own postgres
#                   and gives each container its own database on it.
#   EXPECT_DERBY_EXIT  1 = additionally assert that the shipped Derby default is REFUSED on this
#                   image (test 3b). Pairs with DEFAULT_DB=postgres; default 0.
#
# Usage:
#   # DHI (defaults):
#   BINARY_URL="https://.../BridgeLink_unix_26_6_1.tar.gz" test/image-test.sh
#   IMAGE=innovarhealthcare/bridgelink:26.6.1-dhi SKIP_BUILD=1 test/image-test.sh
#   # Rocky:
#   BINARY_URL="https://.../..." IMAGE=innovarhealthcare/bridgelink:rocky-test \
#     DOCKERFILE=Dockerfile EXPECTED_UID=1000 CHECK_NO_SHELL=0 test/image-test.sh
#   # A pre-26.6.1 release, asserting it is on Java 17 (existing image, then build-and-test):
#   IMAGE=innovarhealthcare/bridgelink:26.3.1-dhi SKIP_BUILD=1 EXPECTED_JAVA=17 test/image-test.sh
#   BINARY_URL="https://.../BridgeLink_unix_26_3_1.tar.gz" JAVA_MAJOR=17 EXPECTED_JAVA=17 test/image-test.sh
#   # A 26.6.1-or-later release built on Java 17 (no usable embedded Derby):
#   IMAGE=innovarhealthcare/bridgelink:26.6.1-dhi-jdk17 SKIP_BUILD=1 EXPECTED_JAVA=17 \
#     DEFAULT_DB=postgres EXPECT_DERBY_EXIT=1 test/image-test.sh
#
# Requires: docker (with buildx), python3, curl. Building the DHI image needs `docker login dhi.io`.
set -u

IMAGE="${IMAGE:-innovarhealthcare/bridgelink:dhi-test}"
SKIP_BUILD="${SKIP_BUILD:-0}"
DOCKERFILE="${DOCKERFILE:-Dockerfile.dhi}"
EXPECTED_UID="${EXPECTED_UID:-65532}"
CHECK_NO_SHELL="${CHECK_NO_SHELL:-1}"
DEFAULT_DB="${DEFAULT_DB:-derby}"
EXPECT_DERBY_EXIT="${EXPECT_DERBY_EXIT:-0}"
# Fixture for the default-backend containers in DEFAULT_DB=postgres mode. Deliberately NOT the `pg`
# fixture test 6 starts: test 6c stops that one to prove the healthcheck's behaviour during a
# database outage and never restarts it, so anything sharing it would lose its backend mid-suite.
PGDEF="pgdef"
PGUSER="bridgelinktest"
PGPASS="bridgelinktest"
# First boot against a fresh external database is slower than against embedded Derby (test 6 already
# allows 120s for exactly that). Raised in postgres mode below; 90 keeps the derby path unchanged.
BOOT_TIMEOUT=90
NET="bl-test-net-$$"
WORK="$(mktemp -d)"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
PASS=0 FAIL=0

# ---- helpers ----------------------------------------------------------------------------------
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
bad()  { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }
info() { echo "== $1"; }

cleanup() {
  # ${CIDS[@]+...}: empty-array expansion is an "unbound variable" error under set -u on bash 3.2
  # (macOS /bin/bash), which would abort cleanup entirely.
  docker rm -f ${CIDS[@]+"${CIDS[@]}"} >/dev/null 2>&1 || true
  docker network rm "$NET" >/dev/null 2>&1 || true
  docker volume rm bl-dhi-appdata >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
CIDS=()
trap cleanup EXIT

# Start a BridgeLink container. In DEFAULT_DB=postgres mode, any container that does not name its
# own MP_DATABASE is pointed at the shared $PGDEF fixture instead of the image's embedded Derby
# default, and joined to $NET so it can reach it.
#
# Each container gets its OWN database on that one instance. A BridgeLink server takes ownership of
# its schema on first boot, and up to eleven of them are alive at once here (bl-boot survives until
# test 7), so a single shared database would mean concurrent first-boot DDL and shared configuration
# and channel state — the servers would fight rather than the tests failing cleanly. The name is
# derived from the container name, so a `docker restart` (tests 6c2 and 8) reattaches to the same
# database and the persistence assertions still mean what they say.
#
# ORDERING NOTE, load-bearing for test 5b: that test serves a CUSTOM_PROPERTIES file captured from
# another container, which in this mode carries that container's database URL. It is safe only
# because the bootstrap downloads CUSTOM_PROPERTIES *before* applying MP_ env vars
# (BridgeLinkBootstrap.java main(); scripts/entrypoint.sh does the same), so the injection below
# wins. Reversing that order would silently put two servers on one database.
run() {
  local name="$1"; shift
  CIDS+=("$name")
  local -a extra=()
  if [ "$DEFAULT_DB" = "postgres" ]; then
    local a has_net=0 has_db=0
    for a in "$@"; do
      case "$a" in
        --network|--network=*) has_net=1 ;;
        MP_DATABASE=*)         has_db=1 ;;
      esac
    done
    if [ "$has_db" = "0" ]; then
      local db
      db="bl_$(printf '%s' "$name" | tr -c '[:alnum:]' '_')"
      docker exec "$PGDEF" psql -U "$PGUSER" -d postgres -c "CREATE DATABASE $db" >/dev/null 2>&1 || true
      [ "$has_net" = "0" ] && extra+=(--network "$NET")
      # max-connections is capped well below the pool default: eleven servers at the stock size
      # would exhaust postgres' connection slots, which fails as an unrelated-looking boot timeout.
      extra+=(-e MP_DATABASE=postgres
              -e "MP_DATABASE_URL=jdbc:postgresql://$PGDEF:5432/$db"
              -e "MP_DATABASE_USERNAME=$PGUSER"
              -e "MP_DATABASE_PASSWORD=$PGPASS"
              -e MP_DATABASE_MAX__CONNECTIONS=8)
    fi
  fi
  # ${extra[@]+...}: empty-array expansion is an "unbound variable" error under set -u on bash 3.2
  # (macOS /bin/bash) — same guard as cleanup() above.
  docker run -d --name "$name" ${extra[@]+"${extra[@]}"} "$@" "$IMAGE" >/dev/null
}

# vmoptions assertions differ by launcher: the DHI bootstrap echoes the assembled JVM command line to
# stdout (so we grep the log — this also exercises the bootstrap's add-opens dedup logic); the Rocky
# ./blserver vendor launcher does not, so we inspect blserver.vmoptions on disk. Same net assertion.
vmopt_has() {   # <container> <fixed-string>  -> return 0 if present
  if [ "$CHECK_NO_SHELL" = "1" ]; then
    docker logs "$1" 2>&1 | grep -q -- "$2"
  else
    docker cp "$1:/opt/bridgelink/blserver.vmoptions" "$WORK/_vmo" >/dev/null 2>&1 && grep -q -- "$2" "$WORK/_vmo"
  fi
}
vmopt_count() {  # <container> <pattern>  -> echo occurrence count
  if [ "$CHECK_NO_SHELL" = "1" ]; then
    docker logs "$1" 2>&1 | grep -o "$2" | wc -l | tr -d ' '
  elif docker cp "$1:/opt/bridgelink/blserver.vmoptions" "$WORK/_vmo" >/dev/null 2>&1; then
    # grep -c prints "0" and exits 1 on no match; keep just the count, swallow the exit.
    grep -c "$2" "$WORK/_vmo" 2>/dev/null || true
  else
    echo 0
  fi
}

# Wait until a fixture webserver actually serves, rather than sleeping a fixed amount. `docker run -d`
# returns before nginx is listening, and on a loaded runner (or one that just pulled the image) two
# seconds is not enough — that flaked 5d(a) in CI while the later lanes, by then warm, passed.
#
# Probed with the curl already inside nginx:alpine rather than a helper container, so this adds no
# image to pull and no requirement beyond what the fixtures themselves need. Args: container name,
# then the URL as seen from inside it.
wait_for_fixture() {
  local name="$1" url="$2" timeout="${3:-60}" i=0
  while [ "$i" -lt "$timeout" ]; do
    docker exec "$name" curl -ksSf -m 3 -o /dev/null "$url" >/dev/null 2>&1 && return 0
    sleep 1; i=$((i+1))
  done
  return 1
}

# Wait until a postgres fixture accepts connections. wait_for_fixture above probes with the curl
# inside nginx:alpine; postgres:16-alpine has no curl, but does ship pg_isready.
#
# -h localhost is load-bearing: the official image runs a TEMPORARY server during initdb with
# listen_addresses='', then shuts it down and starts the real one. A socket probe answers during
# that window, so without -h this returns ready, the CREATE DATABASE in run() lands in the restart
# gap, and the first server boots against a database that does not exist. TCP is refused until the
# final server is up, which is the state actually being waited for.
wait_for_pg() {
  local name="$1" timeout="${2:-90}" i=0
  while [ "$i" -lt "$timeout" ]; do
    docker exec "$name" pg_isready -h localhost -U "$PGUSER" -d postgres >/dev/null 2>&1 && return 0
    sleep 1; i=$((i+1))
  done
  return 1
}

# Poll a container's logs for a pattern (default: successful start). Returns non-zero on timeout.
wait_for_log() {
  local name="$1" pattern="${2:-server successfully started}" timeout="${3:-$BOOT_TIMEOUT}" i=0
  while [ "$i" -lt "$timeout" ]; do
    docker logs "$name" 2>&1 | grep -qE "$pattern" && return 0
    sleep 1; i=$((i+1))
  done
  return 1
}

# Discover the ephemeral host port docker assigned to container port 8443.
https_port() { docker port "$1" 8443/tcp | head -1 | sed 's/.*://'; }

# Poll docker's own healthcheck verdict until it reaches $2 (default: healthy). Returns non-zero on
# timeout. Health goes through "starting" first, so a bare inspect right after `run` proves nothing.
wait_for_health() {
  local name="$1" want="${2:-healthy}" timeout="${3:-180}" i=0 got=
  while [ "$i" -lt "$timeout" ]; do
    got="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$name" 2>/dev/null)"
    [ "$got" = "$want" ] && return 0
    sleep 1; i=$((i+1))
  done
  echo "    (last health status: ${got:-unknown})"
  return 1
}

# Is 8443 answering TLS+HTTP at all, regardless of what it serves? `%{http_code}` is 000 when the
# connection or handshake fails and an HTTP status otherwise, so any non-000 means the port answered.
# Content-independent on purpose: the WebAdmin-only ("slim") image strips public_html, so the web
# root has nothing to serve and a status-code-sensitive check never succeeds there.
port_answers() {
  local code
  code="$(curl -k -s -o /dev/null -m 5 -w '%{http_code}' "https://localhost:$1/" 2>/dev/null)"
  [ -n "$code" ] && [ "$code" != "000" ]
}

# The reporter's exact healthcheck from issue #38, kept for the side-by-side. Note this FAILS
# outright on the slim image (no public_html to serve), which is its own argument for the probe.
reporter_check() { curl -kf -s -o /dev/null -m 5 "https://localhost:$1" 2>/dev/null; }

api_code() {
  curl -k -s -o /dev/null -w '%{http_code}' \
       -H 'X-Requested-With: XMLHttpRequest' "https://localhost:$1/api/server/version"
}

# ---- fixtures ---------------------------------------------------------------------------------
mkdir -p "$WORK/secrets" "$WORK/ext" "$WORK/httproot"
# Includes a raw Latin-1 byte (0xE9, é) — regression guard: a non-UTF-8 customer file must not
# crash the bootstrap (it reads/writes ISO-8859-1, the java.util.Properties charset).
printf 'secret.injected.prop = fromSecret\ndatabase.max-connections = 42\nsecret.latin1.prop = caf\xe9pass\n' > "$WORK/secrets/mirth_properties"
printf -- '-Dsecret.vmopt=enabled\n' > "$WORK/secrets/blserver_vmoptions"
python3 - "$WORK" <<'PY'
import os, sys, zipfile
w = sys.argv[1]
d = os.path.join(w, "myextension"); os.makedirs(d, exist_ok=True)
open(os.path.join(d, "plugin.txt"), "w").write("hello from custom extension\n")
for dest in (os.path.join(w, "ext", "myextension.zip"), os.path.join(w, "httproot", "myextension.zip")):
    with zipfile.ZipFile(dest, "w") as z:
        z.write(os.path.join(d, "plugin.txt"), "myextension/plugin.txt")
PY

# ---- build (optional) -------------------------------------------------------------------------
if [ "$SKIP_BUILD" != "1" ]; then
  info "Building $IMAGE from $DOCKERFILE"
  : "${BINARY_URL:?set BINARY_URL to build, or set SKIP_BUILD=1 to test an existing IMAGE}"
  docker build -f "$REPO_ROOT/$DOCKERFILE" --load \
    --build-arg BINARY_URL="$BINARY_URL" \
    ${JAVA_MAJOR:+--build-arg JAVA_MAJOR=$JAVA_MAJOR} \
    ${AWS_CREDENTIALS_FILE:+--secret id=aws_credentials,src=$AWS_CREDENTIALS_FILE} \
    -t "$IMAGE" "$REPO_ROOT" || { echo "BUILD FAILED"; exit 1; }
fi

docker network create "$NET" >/dev/null

# ---- 0. Unit: healthcheck response parsing (host-side, no container) --------------------------
# Guards the one piece of real logic in the probe. Skipped rather than failed where there is no JDK
# on the host: this suite's contract is to test an image, and a missing host javac is not an image
# defect. CI runners have one.
info "0. Healthcheck response parsing (unit)"
if command -v javac >/dev/null && command -v java >/dev/null; then
  if javac -d "$WORK/unit" "$REPO_ROOT/bootstrap/BridgeLinkHealthcheck.java" \
       "$SCRIPT_DIR/BridgeLinkHealthcheckParseTest.java" >"$WORK/javac.log" 2>&1; then
    if java -cp "$WORK/unit" BridgeLinkHealthcheckParseTest; then
      ok "parseStatus handles both response shapes and rejects digit-bearing error bodies"
    else
      bad "parseStatus unit cases failed (see above)"
    fi
  else
    bad "healthcheck probe did not compile"; cat "$WORK/javac.log"
  fi
else
  echo "  SKIP: no host JDK — parse unit cases not run"
fi

# ---- 1. Hardening: no shell / no bash in the runtime (DHI only) -------------------------------
if [ "$CHECK_NO_SHELL" = "1" ]; then
  info "1. Hardened runtime has no shell"
  if docker run --rm --entrypoint sh "$IMAGE" -c 'echo x' >/dev/null 2>&1; then bad "sh present"; else ok "no sh"; fi
  if docker run --rm --entrypoint /bin/bash "$IMAGE" -c 'echo x' >/dev/null 2>&1; then bad "bash present"; else ok "no bash"; fi
else
  info "1. No-shell check skipped (CHECK_NO_SHELL=0 — the Rocky image ships a shell by design)"
fi

# ---- 2. Runs non-root as the expected UID -----------------------------------------------------
info "2. Non-root UID $EXPECTED_UID"
U="$(docker image inspect "$IMAGE" --format '{{.Config.User}}')"
if printf '%s' "$U" | grep -qE '^[0-9]+$'; then
  RUID="$U"   # numeric USER directive (e.g. DHI 'USER 65532')
else
  # Rocky sets USER by name ('USER bridgelink'); resolve the effective uid via the shell it ships.
  RUID="$(docker run --rm --entrypoint id "$IMAGE" -u 2>/dev/null | tr -d '[:space:]')"
fi
[ "$RUID" = "$EXPECTED_UID" ] && ok "runs as non-root uid $EXPECTED_UID (User=$U)" || bad "uid=$RUID User=$U (expected $EXPECTED_UID)"

# ---- 2b. WebAdmin-only image: Swing Administrator stripped ------------------------------------
# Image-filesystem assertion (no running container needed). `docker export | tar -t` is
# shell-independent, so it works for the no-shell DHI runtime too. Boot + API parity for the
# stripped image is still covered by tests 3-8 below (they run against whatever IMAGE is given).
if [ "${EXPECT_NO_ADMIN_CLIENT:-0}" = "1" ]; then
  info "2b. Swing Administrator stripped (client-lib, public_html absent)"
  CTMP="$(docker create "$IMAGE")"; CIDS+=("$CTMP")
  if docker export "$CTMP" | tar -t 2>/dev/null | grep -qE 'opt/bridgelink/(client-lib|public_html)/'; then
    bad "client-lib/public_html still present (INCLUDE_ADMIN_CLIENT strip did not run)"
  else
    ok "client-lib and public_html absent"
  fi
fi

# ---- 2c. Runtime JDK major matches the JAVA_MAJOR the image was built with ----------------------
# Releases before 26.6.1 stay on Java 17 while 26.6.1+ need 21, and the weekly rebuild republishes
# both from the same Dockerfile. This is the assertion that a rebuilt old tag did not silently move.
# `java` is resolved via the image's own PATH, so it works for the no-shell DHI runtime too.
if [ -n "${EXPECTED_JAVA:-}" ]; then
  info "2c. Runtime JDK major $EXPECTED_JAVA"
  JV="$(docker run --rm --entrypoint java "$IMAGE" -XshowSettings:properties -version 2>&1 \
        | sed -n 's/^ *java\.specification\.version = //p' | tr -d '[:space:]')"
  [ "$JV" = "$EXPECTED_JAVA" ] && ok "runtime reports Java $JV" || bad "runtime reports Java '${JV:-?}' (expected $EXPECTED_JAVA)"
fi

# ---- 3-pre. Shared external database (DEFAULT_DB=postgres only) --------------------------------
# Started before test 3 because from here on every default-backend container needs it. See run()
# for why each container gets its own database, and the PGDEF comment for why this is not test 6's
# `pg` fixture.
if [ "$DEFAULT_DB" = "postgres" ]; then
  info "3-pre. Shared external database for the default-backend containers"
  # max_connections is raised because up to eleven servers are alive at once; the per-server pool is
  # capped in run() as well. Both are needed — either alone still runs out.
  docker run -d --name "$PGDEF" --network "$NET" \
    -e POSTGRES_USER="$PGUSER" -e POSTGRES_PASSWORD="$PGPASS" -e POSTGRES_DB=postgres \
    postgres:16-alpine -c max_connections=300 >/dev/null && CIDS+=("$PGDEF")
  if wait_for_pg "$PGDEF" 90; then
    ok "shared postgres fixture ready"
  else
    bad "shared postgres fixture never became ready"
    docker logs "$PGDEF" 2>&1 | tail -20
  fi
  BOOT_TIMEOUT=150
fi

# ---- 3b. The shipped Derby default must be refused ---------------------------------------------
# Only for an image whose bundled Derby cannot run on its JDK. This is the contract the image is
# published under, so it is asserted rather than assumed: the server must REFUSE to start, loudly
# and at startup, instead of booting and failing later somewhere harder to diagnose.
#
# The container is given no database configuration at all, which is what a customer who pulls the
# image and runs it with no environment gets.
if [ "$EXPECT_DERBY_EXIT" = "1" ]; then
  info "3b. Shipped Derby default is refused on this JDK"
  CIDS+=(bl-preflight)
  docker run -d --name bl-preflight "$IMAGE" >/dev/null
  PF_STATE="running"; PF_I=0
  while [ "$PF_I" -lt 90 ]; do
    PF_STATE="$(docker inspect bl-preflight --format '{{.State.Status}}' 2>/dev/null || echo unknown)"
    [ "$PF_STATE" != "running" ] && break
    sleep 1; PF_I=$((PF_I+1))
  done
  PF_EC="$(docker inspect bl-preflight --format '{{.State.ExitCode}}' 2>/dev/null || echo '?')"
  # Grep a stable fragment, not the whole sentence: the tail of the message is operator advice and
  # may be reworded upstream without the contract changing.
  PF_MSG=0
  docker logs bl-preflight 2>&1 | grep -q 'embedded Derby requires Java 21+' && PF_MSG=1
  if [ "$PF_STATE" != "running" ] && [ "$PF_EC" = "1" ] && [ "$PF_MSG" = "1" ]; then
    ok "refused the Derby default (exit 1, documented message)"
  else
    bad "the shipped Derby default was not refused as documented (state=$PF_STATE exit=$PF_EC message=$PF_MSG)"
    echo "    this image's bundled Derby cannot run on its JDK, so a container started with no"
    echo "    database configuration must exit 1 at startup — that refusal is the published contract"
    docker logs bl-preflight 2>&1 | tail -20
  fi
fi

# ---- 3. Boot + config injection ----------------------------------------------------------------
# Backend depends on DEFAULT_DB; every assertion here is backend-independent (server.id file, a
# mirth.properties key, and two vmoptions properties).
info "3. Boot on $DEFAULT_DB + MP_/SERVER_ID/MP_VMOPTIONS injection"
run bl-boot -p 8443 \
  -e SERVER_ID=11111111-2222-3333-4444-555555555555 \
  -e MP_KEYSTORE_STOREPASS=testStorePass123 \
  -e "MP_VMOPTIONS=512,-Dfoo.bar=baz"
if wait_for_log bl-boot; then
  ok "server started"
  P="$(https_port bl-boot)"
  [ "$(api_code "$P")" = "200" ] && ok "API 200" || bad "API not 200"
  docker cp bl-boot:/opt/bridgelink/appdata/server.id "$WORK/sid" >/dev/null 2>&1
  grep -q '11111111-2222-3333-4444-555555555555' "$WORK/sid" && ok "SERVER_ID written" || bad "SERVER_ID missing"
  docker cp bl-boot:/opt/bridgelink/conf/mirth.properties "$WORK/mp" >/dev/null 2>&1
  grep -q '^keystore.storepass = testStorePass123' "$WORK/mp" && ok "MP_ injected" || bad "MP_ not injected"
  vmopt_has bl-boot '-Xmx512m' && ok "MP_VMOPTIONS -Xmx applied" || bad "MP_VMOPTIONS not applied"
  # add-opens must appear exactly once (dedup)
  N="$(vmopt_count bl-boot 'add-opens=java.base/java.util=ALL-UNNAMED')"
  [ "$N" = "1" ] && ok "add-opens dedup (x1)" || bad "add-opens appears x$N"
else
  bad "server did not start ($DEFAULT_DB)"; docker logs bl-boot 2>&1 | tail -20
fi

# ---- 4. Docker secrets + custom-extensions zip ------------------------------------------------
info "4. Docker secrets + custom-extensions volume"
run bl-secrets -p 8443 \
  -v "$WORK/secrets/mirth_properties:/run/secrets/mirth_properties:ro" \
  -v "$WORK/secrets/blserver_vmoptions:/run/secrets/blserver_vmoptions:ro" \
  -v "$WORK/ext:/opt/bridgelink/custom-extensions:ro"
if wait_for_log bl-secrets; then
  docker cp bl-secrets:/opt/bridgelink/conf/mirth.properties "$WORK/mp2" >/dev/null 2>&1
  # Whitespace-tolerant around '=': entrypoint.sh (Rocky) writes "key  =  value", the bootstrap "key = value".
  grep -qE '^secret\.injected\.prop[[:space:]]*=[[:space:]]*fromSecret' "$WORK/mp2" && ok "properties secret merged" || bad "properties secret not merged"
  # -a: the 0xE9 byte makes grep treat the file as binary otherwise
  grep -aqE '^secret\.latin1\.prop[[:space:]]*=[[:space:]]*caf' "$WORK/mp2" && ok "Latin-1 secret survives (charset regression)" || bad "Latin-1 secret missing (charset regression)"
  vmopt_has bl-secrets '-Dsecret.vmopt=enabled' && ok "vmoptions secret appended" || bad "vmoptions secret missing"
  docker cp bl-secrets:/opt/bridgelink/extensions/myextension/plugin.txt "$WORK/pl" >/dev/null 2>&1 \
    && ok "custom-extension zip extracted" || bad "custom-extension not extracted"
else
  bad "server did not start (secrets)"
fi

# ---- 5. HTTP download knobs (all via the HttpClient curl-replacement) -------------------------
# Extra HTTP-served fixtures. custom.properties reuses the valid mirth.properties captured in test 3
# (download-and-overwrite needs a complete file), plus a marker to assert the overwrite happened.
cp "$WORK/mp" "$WORK/httproot/custom.properties"; echo "custom.download.marker = downloaded" >> "$WORK/httproot/custom.properties"
printf -- '-server\n-Xmx333m\n-Djava.awt.headless=true\n-Dcustom.vmopt.marker=downloaded\n' > "$WORK/httproot/custom.vmoptions"
head -c 2048 /dev/urandom > "$WORK/httproot/keystore.jks"   # dummy bytes: tests the download path, not JKS validity
python3 - "$WORK" <<'PY'
import os, sys, zipfile
w = sys.argv[1]; d = os.path.join(w, "cjar"); os.makedirs(d, exist_ok=True)
open(os.path.join(d, "lib.txt"), "w").write("custom jar payload\n")
with zipfile.ZipFile(os.path.join(w, "httproot", "custom-jars.zip"), "w") as z:
    z.write(os.path.join(d, "lib.txt"), "mycustomjar/lib.txt")
PY

docker run -d --name fileserver --network "$NET" \
  -v "$WORK/httproot:/usr/share/nginx/html:ro" nginx:alpine >/dev/null && CIDS+=(fileserver)
wait_for_fixture fileserver "http://127.0.0.1/myextension.zip" 60 \
  || echo "  WARNING: http fixture never served; downloads in 5a/5b will fail for that reason"

info "5a. EXTENSIONS_DOWNLOAD"
run bl-dl --network "$NET" -e EXTENSIONS_DOWNLOAD="http://fileserver/myextension.zip"
if wait_for_log bl-dl; then
  docker cp bl-dl:/opt/bridgelink/extensions/myextension/plugin.txt "$WORK/pl2" >/dev/null 2>&1 \
    && ok "downloaded + extracted via HttpClient" || bad "HTTP download/extract failed"
else
  bad "server did not start (download)"
fi

info "5b. CUSTOM_PROPERTIES / CUSTOM_VMOPTIONS / CUSTOM_JARS_DOWNLOAD"
run bl-knobs --network "$NET" \
  -e CUSTOM_PROPERTIES="http://fileserver/custom.properties" \
  -e CUSTOM_VMOPTIONS="http://fileserver/custom.vmoptions" \
  -e CUSTOM_JARS_DOWNLOAD="http://fileserver/custom-jars.zip"
if wait_for_log bl-knobs; then
  docker cp bl-knobs:/opt/bridgelink/conf/mirth.properties "$WORK/mp3" >/dev/null 2>&1
  grep -q '^custom.download.marker = downloaded' "$WORK/mp3" && ok "CUSTOM_PROPERTIES overwrote mirth.properties" || bad "CUSTOM_PROPERTIES not applied"
  vmopt_has bl-knobs '-Dcustom.vmopt.marker=downloaded' && ok "CUSTOM_VMOPTIONS applied" || bad "CUSTOM_VMOPTIONS not applied"
  docker cp bl-knobs:/opt/bridgelink/custom-jars/mycustomjar/lib.txt "$WORK/cj" >/dev/null 2>&1 && ok "CUSTOM_JARS_DOWNLOAD extracted" || bad "CUSTOM_JARS_DOWNLOAD not extracted"
else
  bad "server did not start (custom knobs)"
fi

info "5c. KEYSTORE_DOWNLOAD (verifies download writes appdata/keystore.jks)"
run bl-ks --network "$NET" -e KEYSTORE_DOWNLOAD="http://fileserver/keystore.jks"
# The download happens before launch; don't gate on the (deliberately bogus) keystore booting.
# Poll rather than fixed-sleep — a slow runner made a fixed sleep flaky.
KS_OK=1 i=0
while [ "$i" -lt 60 ]; do
  if docker cp bl-ks:/opt/bridgelink/appdata/keystore.jks "$WORK/ks-dl" >/dev/null 2>&1 \
     && cmp -s "$WORK/httproot/keystore.jks" "$WORK/ks-dl"; then KS_OK=0; break; fi
  sleep 1; i=$((i+1))
done
[ "$KS_OK" -eq 0 ] && ok "KEYSTORE_DOWNLOAD wrote appdata/keystore.jks" || bad "keystore download bytes differ/missing"

info "5d. ALLOW_INSECURE over self-signed https"
if command -v openssl >/dev/null; then
  mkdir -p "$WORK/tls"
  openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj "/CN=fileserver-https" \
    -keyout "$WORK/tls/key.pem" -out "$WORK/tls/cert.pem" >/dev/null 2>&1
  cat > "$WORK/tls/default.conf" <<'NG'
server {
  listen 443 ssl;
  ssl_certificate     /etc/nginx/certs/cert.pem;
  ssl_certificate_key /etc/nginx/certs/key.pem;
  location / { root /usr/share/nginx/html; }
}
NG
  # insecure-alias: a SECOND name for the same server, deliberately not the cert's CN, so lane (c)
  # below can fetch the same file through a name the certificate does not cover.
  docker run -d --name fileserver-https --network "$NET" --network-alias insecure-alias \
    -v "$WORK/httproot:/usr/share/nginx/html:ro" \
    -v "$WORK/tls:/etc/nginx/certs:ro" \
    -v "$WORK/tls/default.conf:/etc/nginx/conf.d/default.conf:ro" \
    nginx:alpine >/dev/null && CIDS+=(fileserver-https)
  wait_for_fixture fileserver-https "https://127.0.0.1/myextension.zip" 60 \
    || echo "  WARNING: https fixture never served; the ALLOW_INSECURE lanes below will fail for that reason"
  # (a) ALLOW_INSECURE=true -> self-signed cert accepted, download succeeds
  run bl-insec --network "$NET" -e ALLOW_INSECURE=true \
    -e EXTENSIONS_DOWNLOAD="https://fileserver-https/myextension.zip"
  if wait_for_log bl-insec; then
    docker cp bl-insec:/opt/bridgelink/extensions/myextension/plugin.txt "$WORK/pi" >/dev/null 2>&1 \
      && ok "ALLOW_INSECURE=true downloads over self-signed https" || bad "insecure https download failed"
  else bad "server did not start (insecure)"; fi
  # (b) no ALLOW_INSECURE -> cert rejected, extension absent, server still boots (failure is non-fatal)
  run bl-sec --network "$NET" -e EXTENSIONS_DOWNLOAD="https://fileserver-https/myextension.zip"
  if wait_for_log bl-sec; then
    if docker cp bl-sec:/opt/bridgelink/extensions/myextension/plugin.txt "$WORK/psf" >/dev/null 2>&1; then
      bad "self-signed https downloaded WITHOUT ALLOW_INSECURE (cert not verified)"
    else ok "self-signed https rejected without ALLOW_INSECURE"; fi
  else bad "server did not start (secure)"; fi

  # (c) HOSTNAME mismatch under ALLOW_INSECURE — regression guard for IRT-2015.
  #
  # Cases (a)/(b) above cannot catch the bug they look like they cover: the cert is issued for
  # CN=fileserver-https and fetched from exactly that name, so it matches (Java falls back to CN
  # when a cert carries no SAN). This lane fetches the SAME cert through a different hostname, so
  # the identity check has to fail unless it is genuinely disabled.
  #
  # What it caught: ALLOW_INSECURE=true made the DHI bootstrap trust any certificate but left
  # HttpClient's hostname verification on — that check is independent of the SSLContext and cannot
  # be switched off through it. Rocky's `curl -k` skips both, so this worked on one image and not
  # the other, contradicting the bootstrap's "both images behave identically" contract. Runs
  # against whichever IMAGE is under test, which is the point: it is a parity assertion.
  run bl-hostmm --network "$NET" -e ALLOW_INSECURE=true \
    -e EXTENSIONS_DOWNLOAD="https://insecure-alias/myextension.zip"
  if wait_for_log bl-hostmm; then
    docker cp bl-hostmm:/opt/bridgelink/extensions/myextension/plugin.txt "$WORK/phm" >/dev/null 2>&1 \
      && ok "ALLOW_INSECURE=true ignores a hostname mismatch (cert CN != URL host)" \
      || bad "hostname mismatch still rejected with ALLOW_INSECURE=true (IRT-2015 regression)"
  else bad "server did not start (hostname mismatch)"; fi
else
  echo "  SKIP: openssl not available — ALLOW_INSECURE lane"
fi

# ---- 6. Postgres backend ----------------------------------------------------------------------
info "6. Postgres backend"
docker run -d --name pg --network "$NET" \
  -e POSTGRES_USER=bridgelinktest -e POSTGRES_PASSWORD=bridgelinktest -e POSTGRES_DB=bridgelinkdb \
  postgres:16-alpine >/dev/null && CIDS+=(pg)
run bl-pg --network "$NET" -p 8443 \
  -e MP_DATABASE=postgres \
  -e MP_DATABASE_URL=jdbc:postgresql://pg:5432/bridgelinkdb \
  -e MP_DATABASE_USERNAME=bridgelinktest -e MP_DATABASE_PASSWORD=bridgelinktest
if wait_for_log bl-pg 'successfully started' 120; then
  docker logs bl-pg 2>&1 | grep -q ', postgres,' && ok "using postgres backend" || bad "not on postgres"
  [ "$(api_code "$(https_port bl-pg)")" = "200" ] && ok "API 200 (postgres)" || bad "API not 200 (postgres)"
else
  bad "server did not start (postgres)"; docker logs bl-pg 2>&1 | tail -20
fi

# ---- 6b. MySQL backend ------------------------------------------------------------------------
info "6b. MySQL backend"
docker run -d --name mysql --network "$NET" \
  -e MYSQL_ROOT_PASSWORD=rootpw -e MYSQL_DATABASE=bridgelinkdb \
  -e MYSQL_USER=bridgelinktest -e MYSQL_PASSWORD=bridgelinktest \
  mysql:8 >/dev/null && CIDS+=(mysql)
# allowPublicKeyRetrieval+useSSL=false: MySQL 8 defaults to caching_sha2_password, which needs one
# of these for first auth over a plaintext connection. MP_DATABASE_MAX_RETRY widens the retry
# window past MySQL 8's cold-init (~20-30s), which can exceed the default 2x10s on a cold runner.
run bl-mysql --network "$NET" -p 8443 \
  -e MP_DATABASE=mysql \
  -e MP_DATABASE_URL="jdbc:mysql://mysql:3306/bridgelinkdb?allowPublicKeyRetrieval=true&useSSL=false" \
  -e MP_DATABASE_USERNAME=bridgelinktest -e MP_DATABASE_PASSWORD=bridgelinktest \
  -e MP_DATABASE_MAX_RETRY=15
if wait_for_log bl-mysql 'successfully started' 180; then
  docker logs bl-mysql 2>&1 | grep -q ', mysql,' && ok "using mysql backend" || bad "not on mysql"
  [ "$(api_code "$(https_port bl-mysql)")" = "200" ] && ok "API 200 (mysql)" || bad "API not 200 (mysql)"
else
  bad "server did not start (mysql)"; docker logs bl-mysql 2>&1 | tail -20
fi

# ---- 6c. HEALTHCHECK: two-phase probe, and the thread leak it exists to avoid ----------------
# IRT-2015 / issue #38. Consumes the bl-pg + pg pair from test 6 (finished with them) — tests 7 and
# 8 use bl-boot and bl-persist, so nothing later depends on them.
#
# NOTE for DEFAULT_DB=postgres: the outage below stops the `pg` fixture and never restarts it. That
# is why the default-backend containers use a SEPARATE fixture ($PGDEF) — reusing `pg` here would
# pull the backend out from under bl-restart, bl-window and bl-persist mid-suite, and the resulting
# failures in tests 6c2, 6d and 8 would look like flake rather than like this decision.
#
# The probe polls /api/server/status until the server first reports ready, then switches to
# /api/server/version. That is not an optimisation: /status leaks one Jetty worker thread per request
# permanently whenever the database is unreachable (it blocks in the Hikari pool checkout and a
# client-side timeout does not release it — IRT-2018). A HEALTHCHECK polling it every 15s would leak
# ~240 threads/hour during an outage and eventually kill the JVM.
#
# So the assertions below deliberately do NOT expect health to flip on database loss any more. What
# they pin instead is that the leak is gone, and that the escape hatch still reports engine state.
info "6c. HEALTHCHECK"

HC="$(docker image inspect "$IMAGE" --format '{{if .Config.Healthcheck}}{{json .Config.Healthcheck.Test}}{{else}}none{{end}}')"
case "$HC" in
  none) bad "image declares no HEALTHCHECK" ;;
  *CMD-SHELL*) bad "HEALTHCHECK uses CMD-SHELL — needs /bin/sh, which the hardened runtime lacks ($HC)" ;;
  *BridgeLinkHealthcheck*) ok "image declares an exec-form HEALTHCHECK ($HC)" ;;
  *) bad "unexpected HEALTHCHECK: $HC" ;;
esac

# Thread metrics for the server JVM (PID 1).
#
# `docker exec ... sh -c` CANNOT be used here: the hardened runtime has no shell, which test 1 above
# asserts. An earlier version of this section used it and, on the DHI image, docker's own error text
# ("OCI runtime exec failed: ... \"sh\": executable file not found") was captured as the metric,
# reported the marker as absent, and then aborted the whole script under `set -u` when that text
# reached an arithmetic expansion. So: invoke jcmd directly (no shell needed, it is on PATH in both
# images) and do the counting on the HOST.
#
# digits() is the guard that matters. Any failure -- no jcmd, exec refused, container gone -- must
# yield an EMPTY string, never a number and never prose, so callers can tell "no measurement" from
# "measured zero". A missing measurement that defaults to 0 reads as a pass, which is how a broken
# metric hid a real defect during development.
digits() { printf '%s' "${1:-}" | tr -cd '0-9'; }
thread_dump() { docker exec "$1" jcmd 1 Thread.print 2>/dev/null; }
jvm_threads()     { digits "$(thread_dump "$1" | grep -c '^"' 2>/dev/null)"; }
stuck_in_status() { digits "$(thread_dump "$1" | grep -c 'Get status' 2>/dev/null)"; }
# Which endpoint did the probe last check? Read from docker's own health log, so it works on any
# image (no shell, no exec) and proves the phase actually SWITCHED rather than merely that a marker
# file exists. On the hardened image this doubles as proof that /tmp is writable for UID 65532,
# since the switch cannot happen unless the marker was written.
last_health_output() {
  docker inspect --format '{{range .State.Health.Log}}{{.Output}}{{end}}' "$1" 2>/dev/null | tail -1
}
# Poll until the probe is observed in $2 (default: version). Necessary, not defensive: the moment a
# container reports healthy, the newest health-log entry is the /status success that CAUSED it, and
# the switch to /version only shows up on the NEXT probe one interval later. Sampling once right
# after `healthy` reads "status" every time. Note docker also preserves Health.Log across a restart,
# so a single read after `docker restart` can return a stale pre-restart entry.
wait_for_phase() {
  local name="$1" want="${2:-version}" timeout="${3:-90}" i=0
  while [ "$i" -lt "$timeout" ]; do
    [ "$(health_phase "$name")" = "$want" ] && return 0
    sleep 1; i=$((i+1))
  done
  return 1
}

health_phase() {   # -> "version" | "status" | "" (unknown)
  local out; out="$(docker inspect --format '{{range .State.Health.Log}}{{.Output}}{{end}}' "$1" 2>/dev/null)"
  case "$(printf '%s' "$out" | grep -o '/api/server/[a-z]*' | tail -1)" in
    */version) echo version ;;
    */status)  echo status ;;
    *)         echo "" ;;
  esac
}

if docker inspect bl-pg --format '{{.State.Running}}' 2>/dev/null | grep -q true; then
  PGPORT="$(https_port bl-pg)"
  if wait_for_health bl-pg healthy 180; then
    ok "container reports healthy once the engine is ready"

    # Phase switch: the marker is written on the first successful /status check.
    if wait_for_phase bl-pg version 90; then
      # Proves the marker was written and read back — on DHI that also proves /tmp is writable for
      # the hardened non-root UID, which is otherwise an untested assumption.
      ok "probe switched to the /version phase (marker written and honoured)"
    else
      bad "probe never switched to the /version phase (still '$(health_phase bl-pg)') — the marker was not written or not read, so an outage would leak a thread per probe"
      last_health_output bl-pg | sed 's/^/    last health output: /'
    fi

    # jcmd is present in the Rocky runtime (java-21-openjdk-devel) but is not guaranteed in the
    # hardened one, so the thread measurements are gated rather than silently returning nothing.
    T0=""; S0=""
    if [ "$CHECK_NO_SHELL" = "0" ]; then
      T0="$(jvm_threads bl-pg)"; S0="$(stuck_in_status bl-pg)"
    fi
    docker stop pg >/dev/null 2>&1
    # ~8 healthcheck intervals at 15s. If the probe were still polling /status this window alone
    # would strand roughly that many threads in the Get status handler, permanently.
    sleep 120
    T1=""; S1=""
    if [ "$CHECK_NO_SHELL" = "0" ]; then
      T1="$(jvm_threads bl-pg)"; S1="$(stuck_in_status bl-pg)"
    fi

    # Report explicitly when the metric is unavailable rather than defaulting to 0 and "passing".
    # An empty measurement that defaults to 0 turns the leak guard into a no-op that reads green,
    # which is exactly how a broken metric hid a real defect while this was being written.
    if [ -n "$T0" ] && [ -n "$T1" ] && [ -n "$S0" ] && [ -n "$S1" ]; then
      if [ "$S1" -le "$(( S0 + 1 ))" ]; then
        ok "no threads stranded in the status handler after 2 min of DB outage (was $S0, now $S1)"
      else
        bad "threads stranded in the status handler: $S0 -> $S1 — the probe is polling /status past first-ready (thread-leak regression)"
      fi
      # Jetty's pool flexes by a handful under load; a per-request leak is an order of magnitude more.
      GROWTH=$(( T1 - T0 ))
      if [ "$GROWTH" -le 12 ]; then
        ok "JVM thread count stable across the outage ($T0 -> $T1)"
      else
        bad "JVM threads grew by $GROWTH across a 2 min outage ($T0 -> $T1) — expected flat"
      fi
    elif [ "$CHECK_NO_SHELL" = "1" ]; then
      echo "  SKIP: thread counting needs jcmd, not guaranteed in the hardened runtime. The"
      echo "        thread-leak assertions did NOT run on this image — the Rocky lane covers them,"
      echo "        and the phase assertion above covers the mechanism that prevents the leak."
    else
      echo "  SKIP: thread metrics unavailable (T0='$T0' T1='$T1' S0='$S0' S1='$S1'). The leak"
      echo "        assertions did NOT run — treat this run as not having covered that regression."
    fi

    # Documented trade-off, asserted rather than noted. This started life as an informational NOTE
    # and that hedge hid a real bug: the probe sent Accept: application/json to /api/server/version,
    # which is @Produces(TEXT_PLAIN), so every post-ready probe got HTTP 406 and the container went
    # unhealthy for entirely the wrong reason -- through a 35/35 suite run. If behaviour we document
    # is worth documenting, it is worth failing on.
    H="$(docker inspect --format '{{.State.Health.Status}}' bl-pg 2>/dev/null)"
    if [ "$H" = "healthy" ]; then
      ok "post-ready phase reports liveness, so a DB outage leaves health healthy (documented trade-off)"
    else
      bad "health is '$H' after the outage; the /version phase should keep it healthy"
      docker inspect bl-pg --format '{{range .State.Health.Log}}{{.Output}}{{end}}' 2>/dev/null | tail -c 400; echo
    fi

    # /version must genuinely still answer — that is what the phase relies on.
    VCODE="$(curl -k -s -o /dev/null -m 10 -w '%{http_code}' -H 'X-Requested-With: XMLHttpRequest' \
               "https://localhost:$PGPORT/api/server/version" 2>/dev/null)"
    [ "$VCODE" = "200" ] \
      && ok "/api/server/version still 200 with the database down" \
      || bad "/api/server/version returned $VCODE with the database down — the post-ready phase has no signal"

    # The escape hatch still sees engine state: one explicit /status check must report unhealthy.
    if docker exec -e BL_HEALTH_ALWAYS_STATUS=true bl-pg \
         java -XX:TieredStopAtLevel=1 -XX:+UseSerialGC -XX:-UsePerfData -Xmx32m \
         -cp /opt/bridgelink/bootstrap BridgeLinkHealthcheck 2>&1 | grep -q 'unhealthy:'; then
      ok "BL_HEALTH_ALWAYS_STATUS=true still detects the engine is unavailable"
    else
      bad "BL_HEALTH_ALWAYS_STATUS=true did not report unhealthy with the database down"
    fi
  else
    bad "container never reported healthy"
    docker inspect bl-pg --format '{{json .State.Health}}' 2>/dev/null | head -c 600; echo
  fi
else
  bad "bl-pg is not running — cannot exercise the healthcheck (see test 6)"
fi

# ---- 6c2. A restart must re-prove readiness ---------------------------------------------------
# Regression guard for the bug this section exists because of. The ready marker lives in the
# container's writable layer, which SURVIVES `docker restart` -- so without clearing it at process
# start, the first probe after a restart takes the post-ready branch, checks /api/server/version and
# reports healthy the moment Jetty is listening: before the engine starts and before the startup
# deploy. Anything gated on `depends_on: service_healthy` with `restart: true` -- the reporter's exact
# configuration in issue #38 -- is then released into the not-ready window on every restart after the
# first. Both launchers now delete the marker on boot; this proves it.
# Backend-independent: what is asserted is that the readiness marker is cleared on restart and
# health returns, which is the bootstrap's behaviour and not the database's.
info "6c2. Restart re-proves readiness"
run bl-restart -p 8443
if wait_for_health bl-restart healthy 180 && wait_for_phase bl-restart version 90; then
  # Confirm the marker exists before the restart, so its absence afterwards means something.
  docker cp bl-restart:/tmp/.bridgelink-was-ready - >/dev/null 2>&1 \
    && ok "marker present before restart (precondition for this test)" \
    || bad "marker absent before restart — cannot test that a restart clears it"
  docker restart bl-restart >/dev/null 2>&1
  # The marker file is the unambiguous signal. Health.Log is NOT: docker preserves it across a
  # restart, so reading a phase straight after `docker restart` can return a pre-restart entry.
  CLEARED=0; i=0
  while [ "$i" -lt 60 ]; do
    docker cp bl-restart:/tmp/.bridgelink-was-ready - >/dev/null 2>&1 || { CLEARED=1; break; }
    sleep 1; i=$((i+1))
  done
  if [ "$CLEARED" = "1" ]; then
    ok "marker cleared on restart — readiness is re-proved from scratch, so dependents are not released into the not-ready window"
  else
    bad "marker survived the restart — the first probe would report liveness instead of readiness (issue #38 window reopened on every restart)"
  fi
  # Both launchers report this now, so it is an assertion rather than an informational note. It is
  # also the only evidence distinguishing "cleared on boot" from "never written in the first place".
  docker logs bl-restart 2>&1 | grep -q 'Cleared stale healthcheck marker' \
    && ok "launcher logged clearing the stale marker on restart" \
    || bad "launcher did not report clearing the marker — cannot tell a cleared marker from one that was never written"
  wait_for_health bl-restart healthy 180 \
    && ok "healthy again after restart, having re-proved engine readiness" \
    || bad "did not become healthy again after restart"
else
  bad "bl-restart did not reach the /version phase before the restart test"
fi

# ---- 6d. The startup window: why a port check is the wrong check ------------------------------
# The point of issue #38, measured rather than argued. The engine calls startWebServer() BEFORE the
# engine starts and before the startup channel deploy, so `curl -kf https://localhost:8443` — the
# reporter's check — goes green well before the server can be driven. A dependent container gated on
# it starts too early.
#
# Timed, not sampled at an instant, so it is not a race: record when the bare port first answers and
# when docker first reports healthy. The probe is only worth having if the second is strictly later.
#
# Sampled at 200ms with millisecond timestamps. At 1s resolution the observed window was 6s on one
# run and 2s on the next, and two samples cannot distinguish "no window" from "a window shorter than
# the sampling interval". python3 is already a requirement of this suite, and macOS `date` has no %N.
#
# Read the reported gap as an upper bound on the port side and a coarse figure on the health side:
# HEALTHY_AT is quantized by docker's healthcheck interval, so part of what it measures is probe
# scheduling rather than the true readiness moment. The strict comparison is still safe -- healthy
# requires a successful probe, which requires the port -- so healthy-before-port cannot happen.
# Backend-independent: the window exists because Mirth.java calls startWebServer() before the
# engine starts, whatever the backend is. An external database shifts the absolute timings but
# not the inequality this asserts.
info "6d. Startup window (port answers before the engine is ready)"
now_ms() { python3 -c 'import time;print(int(time.time()*1000))'; }
run bl-window -p 8443
WPORT=""; PORT_AT=""; CURL_AT=""; HEALTHY_AT=""; W0=$(now_ms)
for i in $(seq 1 1200); do
  [ -z "$WPORT" ] && WPORT="$(https_port bl-window 2>/dev/null)"
  if [ -n "$WPORT" ]; then
    [ -z "$PORT_AT" ] && port_answers "$WPORT" && PORT_AT=$(( $(now_ms) - W0 ))
    [ -z "$CURL_AT" ] && reporter_check "$WPORT" && CURL_AT=$(( $(now_ms) - W0 ))
    [ -z "$HEALTHY_AT" ] && [ "$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{end}}' bl-window 2>/dev/null)" = healthy ] \
      && HEALTHY_AT=$(( $(now_ms) - W0 ))
  fi
  [ -n "$PORT_AT" ] && [ -n "$HEALTHY_AT" ] && break
  sleep 0.2
done
if [ -n "$PORT_AT" ] && [ -n "$HEALTHY_AT" ]; then
  GAP=$(( HEALTHY_AT - PORT_AT ))
  if [ "$GAP" -gt 0 ]; then
    ok "port answered at ${PORT_AT}ms but healthy only at ${HEALTHY_AT}ms — a ${GAP}ms window in which a port check is green and the server is not ready"
    # Whether the reporter's exact check (`curl -kf` on the web root) also went green in that window.
    # On the slim image it never goes green at all, because public_html is stripped — so their
    # healthcheck could not have worked there under any circumstances.
    if [ -n "$CURL_AT" ]; then
      echo "      (the reporter's \`curl -kf\` went green at ${CURL_AT}ms, i.e. $(( HEALTHY_AT - CURL_AT ))ms before ready)"
    else
      echo "      (the reporter's \`curl -kf\` never succeeded on this image — no public_html to serve,"
      echo "       so their healthcheck would never report healthy here at all)"
    fi
  else
    # Not a pass: if healthy is not strictly later, this run did not demonstrate the gap the probe
    # exists to close, and a probe that passes before the port even answers would be a real defect.
    bad "healthy (${HEALTHY_AT}ms) was not later than the port answering (${PORT_AT}ms) — the startup window was not observed, so this run does not exercise the difference"
  fi
else
  bad "did not observe both signals (port=${PORT_AT:-never} healthy=${HEALTHY_AT:-never})"
  docker logs bl-window 2>&1 | tail -10
fi

# ---- 7. Graceful shutdown (SIGTERM forwarding) ------------------------------------------------
# What this image owes: PID 1 forwards docker's SIGTERM to the server, which then closes down of its
# own accord instead of being SIGKILLed when the grace period expires.
#
# Asserted on two race-free signals:
#   exit 143 (128+SIGTERM) -- the signal reached the server and it exited on it. A force-kill at the
#                             end of the grace period would be 137, and a crash some other code.
#   "Database shut down normally." -- written straight to stdout by the database layer rather than
#                             through the application logger, so it is proof the shutdown actually
#                             ran to completion and not merely that the process died.
#
# The server's own "shutting down" log line is deliberately NOT the assertion. It is emitted from a
# JVM shutdown hook, and hooks run concurrently in unspecified order, so the logger's teardown hook
# can drop the message even on a perfectly clean shutdown -- measured at 2 losses in 40 local runs,
# and it failed CI runs 30803286012 and 31367340279 while the shutdown itself was fine. Kept below as
# an informational note so a change in logging behaviour is still visible without gating the build.
#
# -t 30 leaves a loaded CI runner room to finish before docker escalates to SIGKILL, without hiding a
# genuine hang: a hang still lands on 137 and fails.
#
# "Database shut down normally" is printed by EMBEDDED DERBY as it closes, so it exists only on the
# derby path. With an external backend there is no equivalent: the server's own shutdown line is
# unreliable for the reason above, and counting server-side connections after the stop cannot tell a
# clean pool close from a dropped TCP connection. So the postgres path asserts the weaker pair of
# exit 143 (the signal was handled, not escalated to SIGKILL) and completion well inside the grace
# period (it unwound rather than hanging until docker gave up). Weaker is stated, not hidden: the
# derby path keeps the strong assertion and is what the Java 21 images are gated on.
info "7. Graceful shutdown"
SHUT_T0="$(date +%s)"
docker stop -t 30 bl-boot >/dev/null 2>&1
SHUT_ELAPSED=$(( $(date +%s) - SHUT_T0 ))
SHUT_EC="$(docker inspect bl-boot --format '{{.State.ExitCode}}' 2>/dev/null || echo '?')"
if [ "$DEFAULT_DB" = "derby" ]; then
  DB_CLOSED=0
  docker logs bl-boot 2>&1 | grep -q 'Database shut down normally' && DB_CLOSED=1
  if [ "$SHUT_EC" = "143" ] && [ "$DB_CLOSED" = "1" ]; then
    ok "graceful shutdown (exit 143 on SIGTERM, database closed normally)"
  else
    bad "no graceful shutdown (exit=$SHUT_EC, database-closed=$DB_CLOSED)"
    docker logs bl-boot 2>&1 | tail -20
  fi
else
  if [ "$SHUT_EC" = "143" ] && [ "$SHUT_ELAPSED" -lt 25 ]; then
    ok "graceful shutdown (exit 143 on SIGTERM, unwound in ${SHUT_ELAPSED}s of a 30s grace period)"
  else
    bad "no graceful shutdown (exit=$SHUT_EC, took ${SHUT_ELAPSED}s of a 30s grace period)"
    docker logs bl-boot 2>&1 | tail -20
  fi
fi
docker logs bl-boot 2>&1 | grep -qi 'shutting down' \
  || echo "  NOTE: server shutdown log line absent (known logger-teardown race; graceful shutdown is" \
          "asserted above on exit code and backend-appropriate evidence, not on this line)"

# ---- 8. appdata persistence across restart ----------------------------------------------------
# Backend-independent: both assertions compare files in the appdata VOLUME (server.id, the
# generated keystore) across a restart, not database rows. In postgres mode the container also
# reattaches to the same database, because run() derives the name from the container name.
info "8. Persistence across restart"
docker volume create bl-dhi-appdata >/dev/null
run bl-persist -p 8443 -v bl-dhi-appdata:/opt/bridgelink/appdata \
  -e SERVER_ID=abcdef00-0000-0000-0000-000000000000
if wait_for_log bl-persist; then
  docker cp bl-persist:/opt/bridgelink/appdata/server.id "$WORK/sidA" >/dev/null 2>&1
  docker cp bl-persist:/opt/bridgelink/appdata/keystore.jks "$WORK/ksA" >/dev/null 2>&1
  docker restart bl-persist >/dev/null
  if wait_for_log bl-persist; then
    docker cp bl-persist:/opt/bridgelink/appdata/server.id "$WORK/sidB" >/dev/null 2>&1
    docker cp bl-persist:/opt/bridgelink/appdata/keystore.jks "$WORK/ksB" >/dev/null 2>&1
    cmp -s "$WORK/sidA" "$WORK/sidB" && ok "server.id persisted" || bad "server.id changed"
    cmp -s "$WORK/ksA" "$WORK/ksB" && ok "keystore persisted" || bad "keystore changed"
  else
    bad "did not restart"
  fi
else
  bad "server did not start (persist)"
fi
docker volume rm bl-dhi-appdata >/dev/null 2>&1 || true

# ---- summary ----------------------------------------------------------------------------------
echo
echo "==================== RESULT: $PASS passed, $FAIL failed ===================="
[ "$FAIL" -eq 0 ]
