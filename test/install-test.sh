#!/usr/bin/env bash
#
# Host-side tests for scripts/install.sh, the build-stage download and extract both Dockerfiles share.
# No Docker and no real BridgeLink tarball: each case builds a tiny tarball, serves it to install.sh
# through a file:// BINARY_URL, and points DESTINATION_FOLDER and LOG_FILE at a temp directory.
#
# The cases:
#   - a release tarball rooted at BridgeLink/ ends at bridgelink/ (the install4j distribution);
#   - a tarball rooted at bridgelink/, as Core's ant build packages server/setup, ends at bridgelink/
#     too, with no blmanager or blcommand in it;
#   - a tarball with neither root fails, and the failure names both roots it accepts.
#
# Run directly (test/install-test.sh) or as test 0b of test/image-test.sh.
# Requires: bash, curl, tar, gzip.
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
INSTALL_SH="$REPO_ROOT/scripts/install.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
PASS=0 FAIL=0

ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
bad()  { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }
info() { echo "== $1"; }

# install.sh writes to /opt in the image. Run on a host, any write it makes outside this test's
# directory is a defect in the test setup or in install.sh's overrides, never something to allow, so
# tar and mv are wrapped to refuse a path outside $WORK. sleep is a no-op so a failed download does
# not spend install.sh's retry delays.
SHIMS="$WORK/shims"
mkdir -p "$SHIMS"
REAL_TAR="$(command -v tar)"
REAL_MV="$(command -v mv)"
cat > "$SHIMS/tar" <<EOF
#!/usr/bin/env bash
next=0
for a in "\$@"; do
  if [ "\$next" = "1" ]; then
    case "\$a" in
      "$WORK"/*) ;;
      *) echo "install-test: refused to extract into \$a, outside DESTINATION_FOLDER" >&2; exit 97 ;;
    esac
    next=0
  fi
  [ "\$a" = "-C" ] && next=1
done
exec "$REAL_TAR" "\$@"
EOF
cat > "$SHIMS/mv" <<EOF
#!/usr/bin/env bash
for a in "\$@"; do
  case "\$a" in
    -*|"$WORK"/*) ;;
    *) echo "install-test: refused to move \$a, outside DESTINATION_FOLDER" >&2; exit 97 ;;
  esac
done
exec "$REAL_MV" "\$@"
EOF
printf '#!/usr/bin/env bash\nexit 0\n' > "$SHIMS/sleep"
chmod +x "$SHIMS/tar" "$SHIMS/mv" "$SHIMS/sleep"

# make_tarball <name> <root> <file>...: a gzipped tarball whose entries are <root>/<file>.
make_tarball() {
  local name="$1" root="$2" f; shift 2
  mkdir -p "$WORK/src-$name/$root"
  for f in "$@"; do
    mkdir -p "$WORK/src-$name/$root/$(dirname "$f")"
    printf 'fixture\n' > "$WORK/src-$name/$root/$f"
  done
  "$REAL_TAR" -czf "$WORK/$name.tar.gz" -C "$WORK/src-$name" "$root"
}

# run_install <name>: runs install.sh on $WORK/<name>.tar.gz into $WORK/dest-<name>. Sets RC and OUT
# (stdout and stderr together). install.sh downloads into its working directory, so each case gets
# its own.
run_install() {
  local name="$1"
  mkdir -p "$WORK/dest-$name" "$WORK/cwd-$name"
  OUT="$(cd "$WORK/cwd-$name" && PATH="$SHIMS:$PATH" \
    BINARY_URL="file://$WORK/$name.tar.gz" \
    DESTINATION_FOLDER="$WORK/dest-$name" \
    LOG_FILE="$WORK/dest-$name.log" \
    bash "$INSTALL_SH" 2>&1)"
  RC=$?
}

show_output() { printf '%s\n' "$OUT" | grep -v '^[^ ]*/' | tail -8 | sed 's/^/    /'; }

# ---- release tarball, rooted at BridgeLink/ -----------------------------------------------------
info "install.sh: release tarball rooted at BridgeLink/"
make_tarball release BridgeLink blserver blmanager blcommand mirth-server-launcher.jar
run_install release
# find matches the stored name exactly, so this holds on a case-insensitive filesystem too, where
# -e BridgeLink would find bridgelink.
if [ "$RC" -eq 0 ] && [ -f "$WORK/dest-release/bridgelink/blserver" ] \
    && [ -z "$(cd "$WORK/dest-release" && find . -maxdepth 1 -name BridgeLink)" ]; then
  ok "BridgeLink/ tarball installed as bridgelink/"
else
  bad "BridgeLink/ tarball not installed as bridgelink/ (exit $RC)"; show_output
fi
if [ -s "$WORK/dest-release.log" ]; then
  ok "install.sh wrote the LOG_FILE it was given"
else
  bad "install.sh did not write the LOG_FILE it was given"
fi

# ---- Core's raw ant layout, rooted at bridgelink/ -----------------------------------------------
info "install.sh: Core ant layout rooted at bridgelink/"
make_tarball raw bridgelink mirth-server-launcher.jar docs/mcservice-java9+.vmoptions conf/mirth.properties
run_install raw
if [ "$RC" -eq 0 ] && [ -f "$WORK/dest-raw/bridgelink/mirth-server-launcher.jar" ] \
   && [ -f "$WORK/dest-raw/bridgelink/docs/mcservice-java9+.vmoptions" ]; then
  ok "bridgelink/ tarball installed in place"
else
  bad "bridgelink/ tarball not installed (exit $RC)"; show_output
fi

# ---- neither root --------------------------------------------------------------------------------
info "install.sh: tarball with neither root"
make_tarball other something-else mirth-server-launcher.jar
run_install other
if [ "$RC" -ne 0 ]; then
  ok "tarball with neither root fails the install (exit $RC)"
else
  bad "tarball with neither root was accepted"
fi
if printf '%s\n' "$OUT" | grep 'BridgeLink' | grep -q 'bridgelink'; then
  ok "the failure names both accepted roots"
else
  bad "no message naming both BridgeLink/ and bridgelink/"; show_output
fi

echo
echo "==================== install.sh: $PASS passed, $FAIL failed ===================="
[ "$FAIL" -eq 0 ]
