// attack_test.ig — sends hostile and malformed requests at a running webengine
// and checks every one is refused correctly and the server stays up.
//
//   1. start the server:   ignid site.ig 8080        (from the webengine folder)
//   2. in another window:   ignid tests/attack_test.ig 8080
use "std.ig":

let int g_port = 8080:
let int g_pass = 0:
let int g_fail = 0:

// send raw bytes, return the full raw response ("" if the connection failed)
fn raw(text request) -> text [
    let int s = sock_connect("127.0.0.1", g_port):
    when s == 0 [ give "": ]
    sock_send(s, request):
    let text resp = sock_recv_all(s):
    sock_close(s):
    give resp:
]

fn status_of(text resp) -> int [
    when starts_with(resp, "HTTP/1.1 ") == 0 or len(resp) < 12 [ give 0: ]
    let int st = 0:
    try [ st = toint(sub(resp, 9, 12)): ] catch [ st = 0: ]
    give st:
]

fn get(text target) -> text [ give raw("GET " + target + " HTTP/1.1\r\nHost: localhost\r\n\r\n"): ]

fn check(text name, int ok, text detail) -> int [
    when ok == 1 [ g_pass = g_pass + 1: iglog("  PASS  " + name): ]
    else [ g_fail = g_fail + 1: iglog("  FAIL  " + name + "   (" + detail + ")"): ]
    give ok:
]

// the response status must be one of the allowed ones
fn expect(text name, text resp, int a, int b) -> int [
    let int st = status_of(resp):
    let int ok = 0:
    when st == a or st == b [ ok = 1: ]
    give check(name, ok, "got " + totext(st)):
]

fn has(text s, text needle) -> int [
    when find(s, needle) >= 0 [ give 1: ]
    give 0:
]

start [
    when argc() >= 1 [ g_port = toint(argv(0)): ]
    iglog("webengine attack test against 127.0.0.1:" + totext(g_port)):

    iglog("-- baseline"):
    let text home = get("/"):
    expect("GET / is 200", home, 200, 200):
    check("CSP header present", has(home, "Content-Security-Policy: default-src 'self'"), "missing"):
    check("nosniff header present", has(home, "X-Content-Type-Options: nosniff"), "missing"):
    check("frame-deny header present", has(home, "X-Frame-Options: DENY"), "missing"):
    check("Connection: close", has(home, "Connection: close"), "missing"):
    let text hd = raw("HEAD / HTTP/1.1\r\nHost: x\r\n\r\n"):
    check("HEAD has no body", has(hd, "</html>") == 0 and status_of(hd) == 200, "body sent or bad status"):

    iglog("-- path traversal / file disclosure"):
    expect("/../site.ig", get("/../site.ig"), 404, 400):
    expect("/%2e%2e/site.ig", get("/%2e%2e/site.ig"), 404, 400):
    expect("/%2e%2e%2fsite.ig", get("/%2e%2e%2fsite.ig"), 404, 400):
    expect("/..%5csite.ig (backslash)", get("/..%5csite.ig"), 404, 400):
    expect("/%252e%252e/site.ig (double-encoded)", get("/%252e%252e/site.ig"), 404, 400):
    expect("/public/../../site.ig", get("/public/../../site.ig"), 404, 400):
    expect("/site.ig (not a served type)", get("/site.ig"), 404, 404):
    expect("/C:/Windows/win.ini", get("/C:/Windows/win.ini"), 404, 400):
    expect("//etc/passwd", get("//etc/passwd"), 404, 400):
    expect("/.git/config (dotfile)", get("/.git/config"), 404, 400):
    expect("/index.html. (trailing dot)", get("/index.html."), 404, 400):
    expect("/index.html::$DATA (stream)", get("/index.html::$DATA"), 404, 400):
    expect("/INDEX~1.HTM (short name)", get("/INDEX~1.HTM"), 404, 400):
    expect("/con.html (device name)", get("/con.html"), 404, 400):
    expect("/nul.txt (device name)", get("/nul.txt"), 404, 400):
    expect("/COM1.css (device name)", get("/COM1.css"), 404, 400):
    expect("/index.html%00.txt (NUL byte)", get("/index.html%00.txt"), 400, 400):
    expect("/%zz (bad escape)", get("/%zz"), 400, 400):
    expect("/% (truncated escape)", get("/%"), 400, 400):

    iglog("-- request line / protocol"):
    expect("lowercase method 'get'", raw("get / HTTP/1.1\r\nHost: x\r\n\r\n"), 501, 501):
    expect("PUT", raw("PUT / HTTP/1.1\r\nHost: x\r\nContent-Length: 0\r\n\r\n"), 405, 405):
    expect("DELETE", raw("DELETE / HTTP/1.1\r\nHost: x\r\n\r\n"), 405, 405):
    expect("TRACE", raw("TRACE / HTTP/1.1\r\nHost: x\r\n\r\n"), 501, 501):
    expect("HTTP/2.0", raw("GET / HTTP/2.0\r\nHost: x\r\n\r\n"), 505, 505):
    expect("garbage request line", raw("HELLO\r\n\r\n"), 400, 400):
    expect("absolute-form target", raw("GET http://evil/ HTTP/1.1\r\nHost: x\r\n\r\n"), 400, 400):
    expect("missing Host on 1.1", raw("GET / HTTP/1.1\r\n\r\n"), 400, 400):
    expect("HTTP/1.0 without Host is fine", raw("GET / HTTP/1.0\r\n\r\n"), 200, 200):
    expect("URI over 2048 bytes", get("/" + repeat("a", 3000)), 414, 431):

    iglog("-- header / smuggling defenses"):
    expect("bare LF line ending", raw("GET / HTTP/1.1\nHost: x\r\n\r\n"), 400, 400):
    expect("space before colon", raw("GET / HTTP/1.1\r\nHost : x\r\n\r\n"), 400, 400):
    expect("obs-fold continuation", raw("GET / HTTP/1.1\r\nHost: x\r\nX-A: 1\r\n  folded\r\n\r\n"), 400, 400):
    expect("Transfer-Encoding: chunked", raw("POST /api/echo HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n"), 501, 501):
    expect("duplicate Content-Length", raw("POST /api/echo HTTP/1.1\r\nHost: x\r\nContent-Length: 1\r\nContent-Length: 2\r\n\r\nab"), 400, 400):
    expect("duplicate Host", raw("GET / HTTP/1.1\r\nHost: a\r\nHost: b\r\n\r\n"), 400, 400):
    expect("non-numeric Content-Length", raw("POST /api/echo HTTP/1.1\r\nHost: x\r\nContent-Length: 5x\r\n\r\n"), 400, 400):
    expect("negative Content-Length", raw("POST /api/echo HTTP/1.1\r\nHost: x\r\nContent-Length: -1\r\n\r\n"), 400, 400):
    expect("Content-Length over limit", raw("POST /api/echo HTTP/1.1\r\nHost: x\r\nContent-Length: 999999\r\n\r\n"), 413, 413):
    expect("control char in header value", raw("GET / HTTP/1.1\r\nHost: x\r\nX-A: a" + chr(1) + "b\r\n\r\n"), 400, 400):
    expect("header block over 8KB", raw("GET / HTTP/1.1\r\nHost: x\r\nX-Big: " + repeat("A", 9000) + "\r\n\r\n"), 431, 0):
    let text many = "GET / HTTP/1.1\r\nHost: x\r\n":
    loop i in 1 to 70 [ many = many + "X-H" + totext(i) + ": v\r\n": ]
    expect("more than 64 headers", raw(many + "\r\n"), 431, 431):

    iglog("-- output injection"):
    let text xss = get("/hello?name=%3Cscript%3Ealert(1)%3C%2Fscript%3E"):
    check("reflected <script> is escaped", has(xss, "&lt;script&gt;") == 1 and has(xss, "<script>") == 0, "raw tag in output"):
    let text jsbody = "</script>\"quote\"\n":
    let text js = raw("POST /api/echo HTTP/1.1\r\nHost: x\r\nContent-Length: " + totext(len(jsbody)) + "\r\n\r\n" + jsbody):
    check("JSON echo escapes < and quotes", has(js, "\\u003c/script\\u003e\\\"quote\\\"\\n") == 1, js):
    let text split = get("/go?to=/x%0d%0aSet-Cookie:%20pwned=1"):
    check("CRLF in redirect does not split response", has(split, "Set-Cookie") == 0, "header injected"):
    expect("open redirect //evil.com", get("/go?to=//evil.com"), 400, 400):
    expect("open redirect /\\evil.com", get("/go?to=/%5Cevil.com"), 400, 400):
    expect("open redirect http://evil.com", get("/go?to=http://evil.com"), 400, 400):
    let text okredir = get("/go?to=/about.html"):
    check("same-site redirect works", status_of(okredir) == 303 and has(okredir, "Location: /about.html") == 1, "got " + totext(status_of(okredir))):

    iglog("-- templates / static files"):
    let text users = get("/users"):
    check("template {{ value }} is escaped", has(users, "&lt;b&gt;not bold&lt;/b&gt;") == 1 and has(users, "<b>not bold") == 0, "raw HTML in output"):
    check("template include + if work", has(users, "ignid-webengine") == 1 and has(users, "<a href=\"/users\" class=\"on\">") == 1, "missing footer or nav"):
    expect("templates folder is not public", get("/templates/home.html"), 404, 404):
    expect("../templates is not reachable", get("/../templates/header.html"), 404, 400):
    let text png = raw("HEAD /images/logo.png HTTP/1.1\r\nHost: x\r\n\r\n"):
    check("binary file served with right type + length", status_of(png) == 200 and has(png, "Content-Type: image/png") == 1 and has(png, "Content-Length: 3185") == 1, png):
    expect("unknown file type never served", get("/images/logo.exe"), 404, 404):
    let text nf = get("/does-not-exist.html"):
    check("custom 404 page", status_of(nf) == 404 and has(nf, "404: page not found") == 1, "got " + totext(status_of(nf))):
    let text bt = get("/broken-template"):
    check("template error is a 500 that leaks nothing", status_of(bt) == 500 and has(bt, "does-not-exist") == 0, "got " + totext(status_of(bt))):

    iglog("-- robustness"):
    expect("handler that throws -> 500", get("/crash"), 500, 500):
    // a client that connects and closes without sending anything
    let int s = sock_connect("127.0.0.1", g_port):
    sock_close(s):
    // a body split across many small writes
    let int s2 = sock_connect("127.0.0.1", g_port):
    sock_send(s2, "POST /api/echo HTTP/1.1\r\nHost: x\r\nContent-Length: 10\r\n\r\n"):
    sock_send(s2, "01234"): sock_send(s2, "56789"):
    let text slow = sock_recv_all(s2): sock_close(s2):
    check("body arriving in pieces is reassembled", has(slow, "\"bytes\":10") == 1, "got " + totext(status_of(slow))):

    iglog("-- slow / silent clients (each takes ~5s to be cut off)"):
    let int silent = sock_connect("127.0.0.1", g_port):
    let int t0 = clock():
    let text after_silent = get("/"):
    let int waited = clock() - t0:
    sock_close(silent):
    check("silent connection is dropped, next client served", status_of(after_silent) == 200 and waited < 9000,
          "status " + totext(status_of(after_silent)) + " after " + totext(waited) + "ms"):
    let int half = sock_connect("127.0.0.1", g_port):
    sock_send(half, "GET / HTTP/1.1\r\nHost: x\r\n"):
    t0 = clock():
    let text after_half = get("/"):
    waited = clock() - t0:
    sock_close(half):
    check("half-sent request is dropped, next client served", status_of(after_half) == 200 and waited < 9000,
          "status " + totext(status_of(after_half)) + " after " + totext(waited) + "ms"):

    iglog("-- still alive after all of the above"):
    expect("GET / still 200", get("/"), 200, 200):

    iglog(""):
    iglog("passed " + totext(g_pass) + ", failed " + totext(g_fail)):
    when g_fail > 0 [ quit(1): ]
]
