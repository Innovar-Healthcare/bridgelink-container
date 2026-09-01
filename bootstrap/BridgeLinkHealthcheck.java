/*
 * BridgeLinkHealthcheck — container readiness probe for both BridgeLink images (IRT-2015).
 *
 * Backs the Dockerfile HEALTHCHECK instruction and the Helm chart's startup/readiness probes.
 * Deliberately a SEPARATE class from BridgeLinkBootstrap: the probe runs many times over a
 * container's life, and it must be structurally impossible for it to re-enter the bootstrap's
 * config templating. It is compiled by the same javac invocation and lands in the same directory.
 *
 * Why Java rather than curl: the hardened (DHI) runtime has no shell, no coreutils and no curl,
 * and no package manager to add them with. Adding a static HTTP client to that image would give
 * back the CVE surface the image exists to avoid. Both images already ship a JRE, so this costs
 * nothing at build time and no packages at runtime. The HEALTHCHECK uses JSON exec form, which
 * runs the command directly without /bin/sh.
 *
 * What it checks, and why the obvious check is wrong:
 *
 *   GET /api/server/status  ->  0 OK | 1 UNAVAILABLE | 2 ENGINE_STARTING | 3 INITIAL_DEPLOY
 *
 * Mirth.java starts the web server BEFORE the engine and before the initial channel deploy, so
 * port 8443 completes a TLS handshake and serves the web root throughout startup. A port or
 * web-root check therefore reports healthy during precisely the window a dependent container
 * (config loader, CLI script) must not run in. Only status 0 means the database is reachable,
 * the engine is running and the startup deploy has finished.
 *
 * Three traps in this endpoint, all confirmed against a live server:
 *   1. It ALWAYS returns HTTP 200, with the status in the body — even when UNAVAILABLE. So
 *      fail-on-non-2xx (curl -f, or a Kubernetes httpGet probe) passes while the engine is down.
 *      The body must be parsed; that is the whole reason this class exists.
 *   2. The body is NOT a bare integer. /server/status has no @Produces(TEXT_PLAIN) of its own, so
 *      it inherits the servlet interface's XML/JSON pair: "<int>0</int>" by default, or {"int":0}
 *      with Accept: application/json. Comparing the body to "0" never matches.
 *   3. X-Requested-With is required by default (server.api.require-requested-with). The filter is
 *      registered on /* ahead of any per-endpoint auth annotation, so the endpoint being anonymous
 *      (@DontCheckAuthorized) does not exempt it. Without the header: HTTP 400.
 */
import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.security.SecureRandom;
import java.security.cert.X509Certificate;
import java.util.regex.Matcher;
import java.util.regex.Pattern;
import javax.net.ssl.HttpsURLConnection;
import javax.net.ssl.SSLContext;
import javax.net.ssl.TrustManager;
import javax.net.ssl.X509TrustManager;

public final class BridgeLinkHealthcheck {

    static final String HOME            = env("BL_HOME", "/opt/bridgelink");
    static final Path   PROPERTIES_FILE = Paths.get(HOME, "conf", "mirth.properties");
    static final String DEFAULT_PORT    = "8443";
    static final String STATUS_PATH     = "/api/server/status";

    /* One overall budget, enforced end to end, so the probe reports a decision rather than being
     * killed mid-flight by the HEALTHCHECK --timeout=5s / probes' timeoutSeconds: 5.
     *
     * It has to be a single deadline rather than a per-phase timeout. setConnectTimeout and
     * setReadTimeout are independent, and setReadTimeout applies per read() call, so a server that
     * accepts the connection and then trickles bytes can hold a naive probe open for
     * connect + (reads x timeout) — well past 5s, at which point docker records ITS kill message
     * and the probe's own reason is lost.
     *
     * Sized so the WHOLE PROCESS fits in 5s, JVM startup included (~0.3-0.5s, more on a loaded
     * node). A single read can still overshoot the deadline by up to READ_SLICE_MS, since a read
     * already in flight cannot be shortened — hence the slice cap rather than one 3s read timeout.
     * Worst case ~= 0.5 + 3.0 + 1.0 = 4.5s. Measured against a server trickling one byte every
     * 1.5s forever: 3s, exit 1, reason recorded. */
    static final int BUDGET_MS = 3000;

    /* Per-read ceiling. On loopback a 9-byte body needs microseconds; 1s is already pathological,
     * and bounding it is what keeps the last read from pushing the total past docker's timeout. */
    static final int READ_SLICE_MS = 1000;

    /* Bounds the read on a server that answers the socket but streams nothing useful. The real
     * body is 9 bytes; anything remotely this large is already a bug. */
    static final int MAX_BODY_BYTES = 8192;

    static final int STATUS_OK = 0;

    public static void main(String[] args) {
        String url = targetUrl();
        try {
            Response resp = get(url);
            Integer status = parseStatus(resp.body);
            if (resp.code != 200) {
                fail(url, "HTTP " + resp.code + " (expected 200)", resp.body);
            } else if (status == null) {
                fail(url, "could not parse a status code from the response body", resp.body);
            } else if (status != STATUS_OK) {
                fail(url, "server status " + status + " (" + describe(status) + "), not 0 (OK)", resp.body);
            } else {
                System.out.println("healthy: " + url + " -> status 0 (OK)");
                System.exit(0);
            }
        } catch (Exception e) {
            // Connection refused / TLS failure / timeout: not yet listening, or wedged.
            fail(url, e.getClass().getSimpleName() + ": " + e.getMessage(), null);
        }
    }

    /** Everything unhealthy exits 1, having said why — docker inspect .State.Health keeps this. */
    static void fail(String url, String reason, String body) {
        System.out.println("unhealthy: " + url + " -> " + reason
                + (body != null && !body.isEmpty() ? " [body: " + trim(body) + "]" : ""));
        System.exit(1);
    }

    static String describe(int status) {
        switch (status) {
            case 0:  return "OK";
            case 1:  return "UNAVAILABLE — database or engine not running";
            case 2:  return "ENGINE_STARTING";
            case 3:  return "INITIAL_DEPLOY";
            default: return "unrecognized";
        }
    }

    // ---- target ---------------------------------------------------------------------------------

    /**
     * BL_HEALTH_URL wins outright (lets an operator point the probe at http, another host, or a
     * non-default context path). Otherwise track https.port out of mirth.properties, since
     * MP_HTTPS_PORT can move it and a hardcoded 8443 would then probe a closed port forever.
     */
    static String targetUrl() {
        String override = System.getenv("BL_HEALTH_URL");
        if (isSet(override)) return override;
        return "https://127.0.0.1:" + readProperty("https.port", DEFAULT_PORT) + STATUS_PATH;
    }

    /**
     * Line-based lookup rather than java.util.Properties.load, matching how BridgeLinkBootstrap
     * writes the file ("key = value"), and ISO-8859-1 for the same reason it uses that charset:
     * every byte sequence is valid in it, so a Latin-1 customer file cannot make the probe throw.
     */
    static String readProperty(String key, String dflt) {
        try {
            if (!Files.isRegularFile(PROPERTIES_FILE)) return dflt;
            for (String line : Files.readAllLines(PROPERTIES_FILE, StandardCharsets.ISO_8859_1)) {
                String s = line.strip();
                if (s.startsWith("#")) continue;
                int eq = s.indexOf('=');
                if (eq < 0) continue;
                if (s.substring(0, eq).strip().equals(key)) {
                    String value = s.substring(eq + 1).strip();
                    if (!value.isEmpty()) return value;
                }
            }
        } catch (Exception ignored) {
            // An unreadable properties file is not itself a health verdict — fall back and probe.
        }
        return dflt;
    }

    // ---- request --------------------------------------------------------------------------------

    static final class Response {
        final int code; final String body;
        Response(int code, String body) { this.code = code; this.body = body; }
    }

    /**
     * HttpsURLConnection, not a hand-rolled SSLSocket + HTTP/1.1 request. Hand-rolling means owning
     * status-line parsing, header/body separation, de-chunking and Connection: close — HTTP/1.1
     * defaults to keep-alive, so a naive read-to-EOF blocks until the socket timeout on every
     * single probe. HttpURLConnection is in java.base and handles all of it.
     *
     * Certificate and hostname verification are disabled for a LOOPBACK target only — see
     * skipVerification(). setHostnameVerifier is the reason this is HttpsURLConnection rather than
     * java.net.http.HttpClient, whose hostname check cannot be disabled through an SSLContext (see
     * the note on ALLOW_INSECURE in BridgeLinkBootstrap).
     */
    static Response get(String url) throws Exception {
        long deadline = System.nanoTime() + BUDGET_MS * 1_000_000L;
        URL target = new URL(url);
        HttpURLConnection conn = (HttpURLConnection) target.openConnection();
        if (conn instanceof HttpsURLConnection) {
            // Verification is disabled only for a loopback target. See skipVerification().
            if (skipVerification(target)) {
                HttpsURLConnection https = (HttpsURLConnection) conn;
                https.setSSLSocketFactory(insecureSslContext().getSocketFactory());
                https.setHostnameVerifier((hostname, session) -> true);
            }
        }
        conn.setRequestMethod("GET");
        conn.setConnectTimeout(remainingMs(deadline));
        conn.setReadTimeout(Math.min(remainingMs(deadline), READ_SLICE_MS));
        conn.setInstanceFollowRedirects(false);
        // Required by default, and 400 without it — see trap 3 in the header comment.
        conn.setRequestProperty("X-Requested-With", "bridgelink-healthcheck");
        // Ask for JSON explicitly; without it the endpoint negotiates to XML. Both are parsed
        // below, so this is about pinning a predictable shape rather than a hard requirement.
        conn.setRequestProperty("Accept", "application/json");
        try {
            int code = conn.getResponseCode();
            // Read the error stream on a non-2xx: the body is what says why.
            InputStream in = code >= 400 ? conn.getErrorStream() : conn.getInputStream();
            return new Response(code, in == null ? "" : read(in, deadline));
        } finally {
            conn.disconnect();
        }
    }

    /** Milliseconds left in the budget, floored at 1 — 0 would mean "no timeout" to the JDK. */
    static int remainingMs(long deadline) {
        long ms = (deadline - System.nanoTime()) / 1_000_000L;
        return ms < 1 ? 1 : (int) Math.min(ms, BUDGET_MS);
    }

    static String read(InputStream in, long deadline) throws IOException {
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        byte[] buf = new byte[1024];
        int n;
        // Stop on the shared deadline as well as the size cap: setReadTimeout bounds each read(),
        // not the sequence of them, so a trickling server would otherwise outlive the budget.
        while (out.size() < MAX_BODY_BYTES
                && System.nanoTime() < deadline
                && (n = in.read(buf)) > 0) {
            out.write(buf, 0, n);
        }
        return out.toString(StandardCharsets.UTF_8);
    }

    /**
     * Skip TLS verification only where doing so cannot be attacked: a loopback address, where the
     * peer is this container's own server presenting its own self-signed keystore (whose CN is
     * never 127.0.0.1, which is why plain verification cannot work).
     *
     * BL_HEALTH_URL can name another host, and there verification must stay ON by default: a probe
     * that trusts anything on a shared network lets anyone on the path forge the health verdict —
     * holding a dead node "healthy" under Swarm, or forcing restarts. BL_HEALTH_INSECURE=true is
     * the explicit opt-out for an operator who knowingly points this at a self-signed non-local
     * endpoint.
     */
    static boolean skipVerification(URL target) {
        if ("true".equalsIgnoreCase(System.getenv("BL_HEALTH_INSECURE"))) return true;
        String host = target.getHost();
        if (host == null) return false;
        String h = host.toLowerCase();
        if (h.startsWith("[") && h.endsWith("]")) h = h.substring(1, h.length() - 1);  // [::1]
        return h.equals("localhost") || h.equals("127.0.0.1") || h.equals("::1")
                || h.startsWith("127.");
    }

    // ---- parsing --------------------------------------------------------------------------------

    /**
     * Handles both shapes this endpoint can return — {"int":0} and <int>0</int> — by matching the
     * integer against the key/tag rather than grabbing the first digits in the response. A
     * first-integer-wins scan would happily read a chunk-size prefix or an HTML error page's
     * status number as a health verdict.
     */
    static final Pattern JSON_INT = Pattern.compile("\"int\"\\s*:\\s*(-?\\d+)");
    static final Pattern XML_INT  = Pattern.compile("<int>\\s*(-?\\d+)\\s*</int>");

    static Integer parseStatus(String body) {
        if (body == null) return null;
        for (Pattern p : new Pattern[] { JSON_INT, XML_INT }) {
            Matcher m = p.matcher(body);
            if (m.find()) {
                try {
                    return Integer.valueOf(m.group(1));
                } catch (NumberFormatException ignored) {
                    // Matched the shape but not a valid int — keep trying the other shape.
                }
            }
        }
        return null;
    }

    // ---- helpers --------------------------------------------------------------------------------

    static SSLContext insecureSslContext() throws Exception {
        TrustManager[] trustAll = { new X509TrustManager() {
            public void checkClientTrusted(X509Certificate[] c, String a) {}
            public void checkServerTrusted(X509Certificate[] c, String a) {}
            public X509Certificate[] getAcceptedIssuers() { return new X509Certificate[0]; }
        }};
        SSLContext ctx = SSLContext.getInstance("TLS");
        ctx.init(null, trustAll, new SecureRandom());
        return ctx;
    }

    static String trim(String s) {
        String one = s.replaceAll("\\s+", " ").strip();
        return one.length() > 200 ? one.substring(0, 200) + "..." : one;
    }

    static boolean isSet(String s) { return s != null && !s.isEmpty(); }

    static String env(String name, String dflt) {
        String v = System.getenv(name);
        return isSet(v) ? v : dflt;
    }

    private BridgeLinkHealthcheck() {}
}
