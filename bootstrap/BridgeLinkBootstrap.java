/*
 * BridgeLinkBootstrap — shell-free container entrypoint for the Docker Hardened Image (DHI) build.
 *
 * The Rocky image uses scripts/entrypoint.sh (bash + sed/grep/tr/curl/unzip/jar) to template
 * config and launch the server at container start. The Corretto DHI *runtime* variant has no
 * shell, no coreutils, no curl/unzip and no package manager, so that logic is reimplemented here
 * using JDK-only APIs (java.util.zip, java.net.http, plain file I/O). BridgeLink already ships a
 * JRE in the image, so this needs zero extra tooling.
 *
 * This is a faithful, line-for-line port of scripts/entrypoint.sh — same env vars, same property
 * mapping, same ordering — so both images behave identically. See IRT-1356.
 *
 * The launch step starts the server via
 *   java <blserver.vmoptions flags> -jar mirth-server-launcher.jar
 * rather than the install4j ./blserver launcher (a shell script, unusable in a shell-less
 * runtime). Validated against the 26.3.1 release tarball.
 *
 * All config-file I/O uses ISO-8859-1: it is the java.util.Properties charset, every byte
 * sequence is valid in it (so a Latin-1-encoded customer file cannot crash startup the way a
 * UTF-8 decode would), and it round-trips bytes faithfully like the byte-oriented sed pipeline
 * this replaces.
 */
import java.io.IOException;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.nio.file.StandardCopyOption;
import java.nio.file.StandardOpenOption;
import java.security.SecureRandom;
import java.security.cert.X509Certificate;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.zip.ZipEntry;
import java.util.zip.ZipInputStream;
import javax.net.ssl.SSLContext;
import javax.net.ssl.TrustManager;
import javax.net.ssl.X509TrustManager;

public final class BridgeLinkBootstrap {

    static final String HOME             = env("BL_HOME", "/opt/bridgelink");
    static final Path   PROPERTIES_FILE  = Paths.get(HOME, "conf", "mirth.properties");
    static final Path   VMOPTIONS_FILE   = Paths.get(HOME, "blserver.vmoptions");
    static final Path   BASE_VMOPTIONS   = Paths.get(HOME, "docs", "mcservice-java9+.vmoptions");
    static final Path   SERVER_ID_FILE   = Paths.get(HOME, "appdata", "server.id");
    static final Path   KEYSTORE_FILE    = Paths.get(HOME, "appdata", "keystore.jks");
    static final Path   EXTENSIONS_DIR   = Paths.get(HOME, "extensions");
    static final Path   CUSTOM_JARS_DIR  = Paths.get(HOME, "custom-jars");
    static final Path   APPDATA_DIR      = Paths.get(HOME, "appdata");
    static final Path   CUSTOM_EXT_DIR   = Paths.get(HOME, "custom-extensions");
    static final Path   LAUNCHER_JAR     = Paths.get(HOME, "mirth-server-launcher.jar");

    static final boolean ALLOW_INSECURE = "true".equalsIgnoreCase(System.getenv("ALLOW_INSECURE"));

    public static void main(String[] args) throws Exception {
        // Mirrors scripts/entrypoint.sh order exactly.
        writeServerId();
        downloadOverwrite("CUSTOM_VMOPTIONS", VMOPTIONS_FILE);
        downloadOverwrite("CUSTOM_PROPERTIES", PROPERTIES_FILE);
        applyMpEnvVars();
        downloadAndExtract("EXTENSIONS_DOWNLOAD", EXTENSIONS_DIR);
        downloadAndExtract("CUSTOM_JARS_DOWNLOAD", CUSTOM_JARS_DIR);
        downloadKeystore();
        mergeSecretProperties();
        appendSecretVmoptions();
        extractCustomExtensionZips();
        launchServer();
    }

    // ---- 1. SERVER_ID -----------------------------------------------------------------------
    static void writeServerId() throws IOException {
        String id = System.getenv("SERVER_ID");
        if (isSet(id)) {
            Files.createDirectories(SERVER_ID_FILE.getParent());
            Files.writeString(SERVER_ID_FILE, "server.id = " + id + System.lineSeparator(),
                    StandardCharsets.ISO_8859_1);
        }
    }

    // ---- 2. CUSTOM_VMOPTIONS / CUSTOM_PROPERTIES: download-and-overwrite ---------------------
    static void downloadOverwrite(String envName, Path target) throws Exception {
        String url = System.getenv(envName);
        if (!isSet(url)) {
            System.out.println(envName + " is not set. Skipping download.");
            return;
        }
        System.out.println("Downloading " + envName + " from: " + url);
        Files.createDirectories(target.getParent());
        download(url, target);
        System.out.println("Successfully downloaded and saved to " + target);
    }

    // ---- 3. MP_* env vars -> mirth.properties / blserver.vmoptions --------------------------
    static void applyMpEnvVars() throws IOException {
        for (Map.Entry<String, String> e : System.getenv().entrySet()) {
            String var = e.getKey();
            if (!var.startsWith("MP_")) continue;
            String value = e.getValue();
            String withoutPrefix = var.substring(3);

            if ("VMOPTIONS".equals(withoutPrefix)) {
                applyMpVmoptions(value);
                continue;
            }
            // Special-case remap: MP_DATABASE_RETRY_WAIT -> database.connection.retrywaitinmilliseconds
            if ("DATABASE_RETRY_WAIT".equals(withoutPrefix)) {
                withoutPrefix = "DATABASE_CONNECTION_RETRYWAITINMILLISECONDS";
            }
            String property = mapPropertyName(withoutPrefix);
            updateProperty(PROPERTIES_FILE, property, value);
        }
    }

    /** __ -> '-', _ -> '.', lowercased; with camelCase corrections that lowercasing would mangle. */
    static String mapPropertyName(String withoutPrefix) {
        String property = withoutPrefix.toLowerCase().replace("__", "-").replace("_", ".");
        switch (withoutPrefix) {
            case "SERVER_ALLOWROOT": property = "server.allowRoot"; break;
            default: break;
        }
        return property;
    }

    /** Comma-split; a bare integer sets -Xmx<n>m, otherwise the option is appended if absent. */
    static void applyMpVmoptions(String raw) throws IOException {
        if (!isSet(raw)) return;
        List<String> lines = readLines(VMOPTIONS_FILE);
        for (String part : raw.split(",")) {
            String opt = part.strip().replaceAll("\\s*=\\s*", "=");
            if (opt.isEmpty()) continue;
            if (opt.matches("\\d+")) {
                setXmx(lines, opt + "m");
            } else if (!lines.contains(opt)) {
                lines.add(opt);
            }
        }
        writeLines(VMOPTIONS_FILE, lines);
    }

    static void setXmx(List<String> lines, String value) {
        for (int i = 0; i < lines.size(); i++) {
            if (lines.get(i).matches("^-Xmx[0-9]*[kKmMgG].*")) {
                lines.set(i, "-Xmx" + value);
                return;
            }
        }
        lines.add("-Xmx" + value);
    }

    /** Line-based update mirroring entrypoint.sh: replace "^property =.*" else append. Preserves
     *  file ordering/comments/spacing (java.util.Properties.store would reformat the whole file). */
    static void updateProperty(Path file, String property, String value) throws IOException {
        if (!isSet(value)) return;
        List<String> lines = readLines(file);
        String prefix = property + " =";
        boolean found = false;
        for (int i = 0; i < lines.size(); i++) {
            if (lines.get(i).startsWith(prefix)) {
                lines.set(i, property + " = " + value);
                found = true;
                break;
            }
        }
        if (!found) lines.add(property + " = " + value);
        writeLines(file, lines);
    }

    // ---- 4. EXTENSIONS_DOWNLOAD / CUSTOM_JARS_DOWNLOAD: download + extract -------------------
    static void downloadAndExtract(String envName, Path targetDir) throws Exception {
        String csv = System.getenv(envName);
        if (!isSet(csv)) return;
        System.out.println("Downloading from " + envName + ": " + csv);
        Files.createDirectories(targetDir);
        for (String url : csv.split(",")) {
            url = url.strip();
            if (url.isEmpty()) continue;
            System.out.println("Downloading from " + url);
            Path tmp = Files.createTempFile("bl-dl-", ".zip");
            try {
                download(url, tmp);
                System.out.println("Extracting contents of " + fileName(url));
                unzip(tmp, targetDir);
            } catch (Exception ex) {
                System.out.println("Problem with download/extract from " + url + ": " + ex);
                ex.printStackTrace();
            } finally {
                Files.deleteIfExists(tmp);
            }
        }
    }

    // ---- 5. KEYSTORE_DOWNLOAD ---------------------------------------------------------------
    static void downloadKeystore() throws Exception {
        Files.createDirectories(APPDATA_DIR);
        String url = System.getenv("KEYSTORE_DOWNLOAD");
        if (!isSet(url)) {
            System.out.println("KEYSTORE_DOWNLOAD is not set. Skipping keystore download.");
            return;
        }
        System.out.println("Downloading keystore from: " + url);
        download(url, KEYSTORE_FILE);
        System.out.println("Keystore successfully downloaded to: " + KEYSTORE_FILE);
    }

    // ---- 6. Docker secrets ------------------------------------------------------------------
    static void mergeSecretProperties() throws IOException {
        Path secret = Paths.get("/run/secrets/mirth_properties");
        if (!Files.isRegularFile(secret)) return;
        List<String> target = readLines(PROPERTIES_FILE);
        for (String line : Files.readAllLines(secret, StandardCharsets.ISO_8859_1)) {
            int eq = line.indexOf('=');
            if (eq < 0) continue;
            String key = line.substring(0, eq).strip();
            String value = line.substring(eq + 1).strip();
            if (key.isEmpty() || key.startsWith("#")) continue;
            String prefix = key + " =";
            boolean found = false;
            for (int i = 0; i < target.size(); i++) {
                if (target.get(i).strip().startsWith(prefix) || target.get(i).strip().startsWith(key + "=")) {
                    target.set(i, key + " = " + value);
                    found = true;
                    break;
                }
            }
            if (!found) target.add(key + " = " + value);
        }
        writeLines(PROPERTIES_FILE, target);
    }

    static void appendSecretVmoptions() throws IOException {
        Path secret = Paths.get("/run/secrets/blserver_vmoptions");
        if (!Files.isRegularFile(secret)) return;
        List<String> lines = readLines(VMOPTIONS_FILE);
        lines.addAll(Files.readAllLines(secret, StandardCharsets.ISO_8859_1));
        writeLines(VMOPTIONS_FILE, lines);
    }

    // ---- 7. Volume-mounted custom-extensions/*.zip ------------------------------------------
    static void extractCustomExtensionZips() throws IOException {
        if (!Files.isDirectory(CUSTOM_EXT_DIR)) return;
        Files.createDirectories(EXTENSIONS_DIR);
        try (var stream = Files.newDirectoryStream(CUSTOM_EXT_DIR, "*.zip")) {
            for (Path zip : stream) {
                System.out.println("Installing custom extension: " + zip.getFileName());
                unzip(zip, EXTENSIONS_DIR);
            }
        }
    }

    // ---- 8. Launch the server (replaces `exec ./blserver`) ----------------------------------
    static void launchServer() throws IOException, InterruptedException {
        String javaBin = Paths.get(System.getProperty("java.home"), "bin", "java").toString();

        // User/runtime vmoptions (-Xmx etc.). The packaged blserver.vmoptions already contains the
        // required --add-opens/--add-exports/--add-modules flags (the dashboard 500s without them
        // on 17), so start from it...
        List<String> vmopts = new ArrayList<>();
        if (Files.isRegularFile(VMOPTIONS_FILE)) vmopts.addAll(readOptionLines(VMOPTIONS_FILE));
        // ...then add any required flag that is missing (dedup — avoids doubling them, but still
        // guarantees them if a future blserver.vmoptions ever drops them).
        if (Files.isRegularFile(BASE_VMOPTIONS)) {
            for (String opt : readOptionLines(BASE_VMOPTIONS)) {
                if (!vmopts.contains(opt)) vmopts.add(opt);
            }
        }

        List<String> cmd = new ArrayList<>();
        cmd.add(javaBin);
        cmd.addAll(vmopts);
        cmd.add("-jar");
        cmd.add(LAUNCHER_JAR.toString());

        System.out.println("Launching BridgeLink: " + String.join(" ", cmd));
        Process p = new ProcessBuilder(cmd)
                .directory(Paths.get(HOME).toFile())
                .inheritIO()
                .start();
        // As PID 1 we must forward container stop signals to the server so it shuts down
        // gracefully (flush queues, close DB connections) instead of being SIGKILLed.
        Runtime.getRuntime().addShutdownHook(new Thread(() -> {
            p.destroy();                                    // SIGTERM to the server
            try {
                if (!p.waitFor(30, java.util.concurrent.TimeUnit.SECONDS)) p.destroyForcibly();
            } catch (InterruptedException ignored) {
                Thread.currentThread().interrupt();
            }
        }));
        // Propagate the server's exit code so the container reflects it.
        System.exit(p.waitFor());
    }

    // ---- helpers ----------------------------------------------------------------------------

    static void download(String url, Path target) throws Exception {
        HttpClient.Builder cb = HttpClient.newBuilder()
                .followRedirects(HttpClient.Redirect.NORMAL)
                .connectTimeout(java.time.Duration.ofSeconds(30));   // fail fast on an unreachable host
        if (ALLOW_INSECURE) cb.sslContext(insecureSslContext());
        HttpClient client = cb.build();
        HttpRequest req = HttpRequest.newBuilder(URI.create(url))
                .timeout(java.time.Duration.ofMinutes(10))           // bound a stalled transfer
                .GET().build();
        HttpResponse<Path> resp = client.send(req, HttpResponse.BodyHandlers.ofFile(
                target, StandardOpenOption.CREATE, StandardOpenOption.WRITE,
                StandardOpenOption.TRUNCATE_EXISTING));
        if (resp.statusCode() / 100 != 2) {
            throw new IOException("HTTP " + resp.statusCode() + " downloading " + url);
        }
    }

    /** Extract a zip/jar into destDir using JDK-only APIs (replaces `unzip`/`jar xf`). */
    static void unzip(Path zip, Path destDir) throws IOException {
        Path dest = destDir.toAbsolutePath().normalize();
        try (ZipInputStream zis = new ZipInputStream(Files.newInputStream(zip))) {
            ZipEntry entry;
            while ((entry = zis.getNextEntry()) != null) {
                Path out = dest.resolve(entry.getName()).normalize();
                if (!out.startsWith(dest)) {            // zip-slip guard
                    throw new IOException("Illegal zip entry (path traversal): " + entry.getName());
                }
                if (entry.isDirectory()) {
                    Files.createDirectories(out);
                } else {
                    Files.createDirectories(out.getParent());
                    Files.copy(zis, out, StandardCopyOption.REPLACE_EXISTING);
                }
                zis.closeEntry();
            }
        }
    }

    /** Read a .vmoptions file into individual args, skipping blanks and #-comments. */
    static List<String> readOptionLines(Path file) throws IOException {
        List<String> out = new ArrayList<>();
        for (String line : Files.readAllLines(file, StandardCharsets.ISO_8859_1)) {
            String s = line.strip();
            if (!s.isEmpty() && !s.startsWith("#")) out.add(s);
        }
        return out;
    }

    static List<String> readLines(Path file) throws IOException {
        return Files.isRegularFile(file)
                ? new ArrayList<>(Files.readAllLines(file, StandardCharsets.ISO_8859_1))
                : new ArrayList<>();
    }

    static void writeLines(Path file, List<String> lines) throws IOException {
        Path parent = file.toAbsolutePath().getParent();
        if (parent != null) Files.createDirectories(parent);
        Files.write(file, lines, StandardCharsets.ISO_8859_1);
    }

    static String fileName(String url) {
        int q = url.indexOf('?');
        String u = q >= 0 ? url.substring(0, q) : url;
        int slash = u.lastIndexOf('/');
        return slash >= 0 ? u.substring(slash + 1) : u;
    }

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

    static boolean isSet(String s) { return s != null && !s.isEmpty(); }

    static String env(String name, String dflt) {
        String v = System.getenv(name);
        return isSet(v) ? v : dflt;
    }

    private BridgeLinkBootstrap() {}
}
