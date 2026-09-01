/*
 * Table-driven unit test for BridgeLinkHealthcheck.parseStatus — IRT-2015.
 *
 * Run by test/image-test.sh on the HOST (not inside an image): it needs javac, which the hardened
 * runtime deliberately does not guarantee, and it tests pure parsing that has nothing to do with a
 * running container.
 *
 * Why this exists rather than relying on the container assertions: the container tests can only
 * show the probe agreeing with a real server, which passes just as well for a sloppy parser. The
 * cases that matter are the ones a real server does not readily produce — an error page whose body
 * contains digits, and raw chunked framing. A "first integer in the body wins" parser passes every
 * container test in this suite and still reports a 404 error page as healthy.
 */
public class BridgeLinkHealthcheckParseTest {

    static int pass = 0, fail = 0;

    static void expect(String label, String body, Integer want) {
        Integer got = BridgeLinkHealthcheck.parseStatus(body);
        boolean ok = (want == null) ? got == null : want.equals(got);
        System.out.printf("  %s: parse %-38s -> %s (expected %s)%n",
                ok ? "PASS" : "FAIL", label, got, want);
        if (ok) pass++; else fail++;
    }

    public static void main(String[] args) {
        // The two shapes this endpoint actually returns. It has no @Produces(TEXT_PLAIN), so it
        // negotiates XML by default and JSON when asked — never a bare integer.
        expect("json ok",        "{\"int\":0}", 0);
        expect("xml ok",         "<int>0</int>", 0);
        expect("json spaced",    "{\"int\": 3}", 3);
        expect("xml spaced",     "<int> 2 </int>", 2);
        expect("unavailable",    "{\"int\":1}", 1);

        // Regression guards. Each of these is a case where a looser parser returns a number and
        // would therefore report a broken server as healthy.
        expect("404 error page",  "{\"servlet\":\"x-6fe9b66c\",\"message\":\"Not Found\",\"status\":\"404\"}", null);
        expect("html 400 page",   "<html><body>400 Bad Request</body></html>", null);
        // HttpsURLConnection de-chunks for us, so this should never reach the parser — but if a
        // future change hand-rolls the HTTP read again, the chunk-size prefix must not win.
        expect("chunked framing", "9\r\n{\"int\":0}\r\n0\r\n\r\n", 0);

        expect("empty body",      "", null);
        expect("null body",       null, null);

        System.out.printf("  parse cases: %d passed, %d failed%n", pass, fail);
        System.exit(fail == 0 ? 0 : 1);
    }
}
