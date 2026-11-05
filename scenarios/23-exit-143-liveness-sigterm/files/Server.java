import com.sun.net.httpserver.HttpExchange;
import com.sun.net.httpserver.HttpServer;
import java.net.InetSocketAddress;
import java.time.Instant;
import java.util.concurrent.Executors;

// MODE=nohook   no shutdown code at all: the JVM's default SIGTERM behaviour
// MODE=hook     a shutdown hook drains, the JVM still exits 143
// MODE=handler  a SIGTERM handler drains and calls System.exit(0)
public class Server {
    static volatile boolean broken = false;
    static void log(String m) { System.out.println(Instant.now() + " " + m); }
    static void reply(HttpExchange x, int code, String body) throws java.io.IOException {
        byte[] b = body.getBytes();
        x.sendResponseHeaders(code, b.length);
        try (var o = x.getResponseBody()) { o.write(b); }
    }
    public static void main(String[] args) throws Exception {
        String mode = System.getenv().getOrDefault("MODE", "nohook");
        HttpServer s = HttpServer.create(new InetSocketAddress(8080), 128);
        s.setExecutor(Executors.newCachedThreadPool());
        s.createContext("/healthz", x -> reply(x, broken ? 500 : 200, "ok\n"));
        s.createContext("/break", x -> { broken = true; reply(x, 200, "broken\n"); });
        s.createContext("/slow", x -> {
            try { Thread.sleep(1000); } catch (InterruptedException e) { }
            reply(x, 200, "done\n");
        });
        s.start();
        log("listening, mode=" + mode);
        if (mode.equals("hook")) {
            Runtime.getRuntime().addShutdownHook(new Thread(() -> {
                log("shutdown hook: draining");
                s.stop(5);
                log("shutdown hook: drained");
            }));
        } else if (mode.equals("handler")) {
            sun.misc.Signal.handle(new sun.misc.Signal("TERM"), sig -> {
                log("SIGTERM handler: draining");
                s.stop(5);
                log("SIGTERM handler: drained, exit 0");
                System.exit(0);
            });
        }
    }
}
