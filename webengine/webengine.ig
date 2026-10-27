// webengine.ig — a hardened, single-threaded HTTP/1.1 server engine in pure Ignid.
//
// Your program `use`s this file and defines ONE hook:
//
//     fn app_handle(Request req, Response res) -> int [ ... give 1 if handled, 0 if not ... ]
//
// then calls `we_run(port, "public")` from its `start` block.
// Requests the app doesn't handle fall through to the static file server.
// HTML templates live in ./templates and are rendered with render().
//
// Security / stability design (see README.md for the reasoning behind each):
//   - strict request parsing: request line, header names, header values, Host,
//     Content-Length are all validated; Transfer-Encoding and obs-fold are refused
//     (no request-smuggling ambiguity), hard caps on header size/count/URI/body
//   - static files: whitelist-only paths ([A-Za-z0-9._-/]), no dot-segments or
//     dotfiles, no Windows device names / trailing dots / streams / short names,
//     known file types only, size-capped, streamed straight from disk
//   - templates escape {{ values }} by default; raw output must be asked for
//   - every response carries security headers (CSP, nosniff, frame-deny, ...)
//   - app-supplied header values and redirect targets are checked for CR/LF
//     (no response splitting) and redirects must be same-site (no open redirect)
//   - each request runs inside try/catch: a bug becomes a 500, never a crash
//   - one request per connection (Connection: close) — a single-threaded server
//     must never sit idle on a keep-alive socket
//   - slow or silent clients are cut off: every socket gets a send/recv timeout
//     and every request an overall deadline (slowloris protection)
//   - the runtime heap is a 64MB bump allocator that is never freed, so the
//     process watches heap_used() and recycles itself (exit code 3) with plenty
//     of headroom left; guardian.ig restarts it immediately
//
// Needs an Ignid build with the sock_timeout(), heap_used(), file_size() and
// sock_send_file() builtins.
use "std.ig":

let text WE_VERSION = "1.0.0":

// ---- limits ----
let int WE_MAX_HEADER   = 8192:       // request line + headers, bytes
let int WE_MAX_HEADERS  = 64:         // header line count
let int WE_MAX_TARGET   = 2048:       // request-target (path + query), bytes
let int WE_MAX_BODY     = 65536:      // request body, bytes
let int WE_MAX_RECVS    = 48:         // recv() calls allowed for one request
let int WE_IO_TIMEOUT   = 5000:       // ms a single recv/send may block
let int WE_DEADLINE     = 10000:      // ms a whole request may take to arrive
let int WE_MAX_FILE     = 33554432:   // largest static file served, bytes (streamed, no heap)
let int WE_MAX_TEMPLATE = 262144:     // largest template file, bytes
let int WE_MAX_INCLUDE  = 8:          // template include nesting depth
let int WE_HEAP_LIMIT   = 41943040:   // recycle once 40MB of the 64MB heap is used
                                      // (24MB headroom covers the costliest single request)

// exit codes guardian.ig understands
let int WE_EXIT_RECYCLE = 3:          // planned restart
let int WE_EXIT_LISTEN  = 2:          // could not listen (port in use?)

// ---- engine state ----
let text we_root = "public":
let text we_tpl_root = "templates":
let int we_debug = 0:        // 1 = detailed error pages, no caching. Never in production.
let int we_conns = 0:
let int we_bad = 0:          // set by we_url_decode on malformed input
let text we_err_msg = "":    // engine error description for the current request
let int we_zero = 0:

rec Request [
    text method:    // "GET" / "HEAD" / "POST"
    text target:    // raw request-target, e.g. "/hello?name=x%20y"
    text path:      // percent-decoded path, e.g. "/hello"
    text query:     // raw query string (after "?"), not decoded
    text version:   // "HTTP/1.1" or "HTTP/1.0"
    map headers:    // lowercased name -> value
    text body:
]

rec Response [
    int status:
    text ctype:
    text body:
    text headers:   // extra header lines, already validated, each ending "\r\n"
    text cache:     // Cache-Control value
]

// ================================================================
// small character helpers (ord-based: one allocation per char, no
// O(n^2) string building)
// ================================================================

fn we_tchar(int c) -> int [
    when c >= 48 and c <= 57 [ give 1: ]
    when c >= 65 and c <= 90 [ give 1: ]
    when c >= 97 and c <= 122 [ give 1: ]
    // ! # $ % & ' * + - . ^ _ ` | ~
    when c == 33 or c == 35 or c == 36 or c == 37 or c == 38 or c == 39 or c == 42 [ give 1: ]
    when c == 43 or c == 45 or c == 46 or c == 94 or c == 95 or c == 96 or c == 124 or c == 126 [ give 1: ]
    give 0:
]

// RFC 9110 token (method names, header names)
fn we_is_token(text s) -> int [
    let int n = len(s):
    when n == 0 [ give 0: ]
    let int i = 0:
    loop while i < n [
        when we_tchar(ord(s{i})) == 0 [ give 0: ]
        i = i + 1:
    ]
    give 1:
]

// 1 if s holds a control character (anything < 32 except TAB, or DEL)
fn we_has_ctl(text s) -> int [
    let int n = len(s): let int i = 0:
    loop while i < n [
        let int c = ord(s{i}):
        when (c < 32 and c != 9) or c == 127 [ give 1: ]
        i = i + 1:
    ]
    give 0:
]

// 1 if every byte is visible ASCII (33..126) — request-targets must be
fn we_is_visible(text s) -> int [
    let int n = len(s): let int i = 0:
    loop while i < n [
        let int c = ord(s{i}):
        when c < 33 or c > 126 [ give 0: ]
        i = i + 1:
    ]
    give 1:
]

fn we_all_digits(text s) -> int [
    let int n = len(s):
    when n == 0 [ give 0: ]
    let int i = 0:
    loop while i < n [
        let int c = ord(s{i}):
        when c < 48 or c > 57 [ give 0: ]
        i = i + 1:
    ]
    give 1:
]

fn we_hexval(text ch) -> int [
    let int c = ord(ch):
    when c >= 48 and c <= 57 [ give c - 48: ]
    when c >= 65 and c <= 70 [ give c - 55: ]
    when c >= 97 and c <= 102 [ give c - 87: ]
    give -1:
]

// find needle in s starting at index `from`
fn we_find_from(text s, text needle, int from) -> int [
    let int sn = len(s): let int nn = len(needle):
    let int i = from:
    when i < 0 [ i = 0: ]
    loop while i + nn <= sn [
        when sub(s, i, i + nn) == needle [ give i: ]
        i = i + 1:
    ]
    give -1:
]

// ================================================================
// TextBuilder — linear-memory string building
//
// The heap never frees, and `s = s + piece` copies all of s every time, so
// building an n-byte string piece by piece costs O(n^2) bytes: a 60KB body
// full of "<" would need gigabytes to escape. A TextBuilder keeps small
// pieces in a list and merges them pairwise at the end: O(n log n).
// Use it for any output whose size depends on the request.
// ================================================================

rec TextBuilder [ list parts: text cur: ]

fn tb_new() -> TextBuilder [ give TextBuilder(list_new_text(), ""): ]

fn tb_add(TextBuilder b, text piece) -> int [
    when len(piece) >= 64 [
        when len(b.cur) > 0 [ push(b.parts, b.cur): b.cur = "": ]
        push(b.parts, piece):
        give 0:
    ]
    b.cur = b.cur + piece:
    when len(b.cur) >= 64 [ push(b.parts, b.cur): b.cur = "": ]
    give 0:
]

fn tb_text(TextBuilder b) -> text [
    when len(b.cur) > 0 [ push(b.parts, b.cur): b.cur = "": ]
    give we_join_tree(b.parts):
]

// Pairwise merge of a text list. Takes the list as a parameter on purpose: a
// local copied straight out of a record field loses its "holds text" tag, and
// `+` on its elements would then add pointers instead of joining strings.
fn we_join_tree(list parts) -> text [
    let list cur = parts:
    loop while len(cur) > 1 [
        let list nxt = list_new_text():
        let int i = 0: let int n = len(cur):
        loop while i < n [
            when i + 1 < n [ push(nxt, cur{i} + cur{i + 1}): ] else [ push(nxt, cur{i}): ]
            i = i + 2:
        ]
        cur = nxt:
    ]
    when len(cur) == 0 [ give "": ]
    give cur{0}:
]

// ================================================================
// Windows — linear-time scanning of long text
//
// Text is NUL-terminated with no stored length, so every s{i} and sub(s, ...)
// re-measures all of s. Walking a 48KB string char by char takes ~750ms.
// Long request data is cut into WE_WIN-byte windows once (one sub() each),
// and the per-character loops run on those short pieces instead.
// ================================================================

let int WE_WIN = 256:

fn we_windows(text s) -> list [
    let list out = list_new_text():
    let int n = len(s): let int k = 0:
    loop while k < n [
        push(out, sub(s, k, min(k + WE_WIN, n))):
        k = k + WE_WIN:
    ]
    give out:
]

// Splits s at ch (a 1-char text) into at most `limit` parts; the last part
// keeps any remaining separators.
fn we_split_char(text s, text ch, int limit) -> list [
    let list out = list_new_text():
    let TextBuilder cur = tb_new():
    loop w in we_windows(s) [
        let int last = 0: let int i = 0: let int n = len(w):
        loop while i < n [
            when len(out) < limit - 1 and w{i} == ch [
                tb_add(cur, sub(w, last, i)):
                push(out, tb_text(cur)):
                cur = tb_new():
                last = i + 1:
            ]
            i = i + 1:
        ]
        tb_add(cur, sub(w, last, n)):
    ]
    push(out, tb_text(cur)):
    give out:
]

// Percent-decode. Malformed escapes and decoded control characters set we_bad = 1.
fn we_url_decode(text s, int plus_is_space) -> text [
    when len(s) <= WE_WIN [ give we_url_decode_win(s, plus_is_space): ]
    let TextBuilder b = tb_new():
    let text carry = "":
    loop w in we_windows(s) [
        let text piece = carry + w:
        // an escape cut in half by the window edge waits for the next window
        let int pl = len(piece): let int cut = pl:
        when piece{pl - 1} == "%" [ cut = pl - 1: ]
        or pl >= 2 and piece{pl - 2} == "%" [ cut = pl - 2: ]
        carry = sub(piece, cut, pl):
        tb_add(b, we_url_decode_win(sub(piece, 0, cut), plus_is_space)):
        when we_bad == 1 [ give "": ]
    ]
    when len(carry) > 0 [ we_bad = 1: give "": ]
    give tb_text(b):
]

fn we_url_decode_win(text s, int plus_is_space) -> text [
    let TextBuilder b = tb_new(): let int last = 0:
    let int i = 0: let int n = len(s):
    loop while i < n [
        let text c = s{i}:
        when c == "%" [
            when i + 2 >= n [ we_bad = 1: give "": ]
            let int hi = we_hexval(s{i + 1}): let int lo = we_hexval(s{i + 2}):
            when hi < 0 or lo < 0 [ we_bad = 1: give "": ]
            let int v = hi * 16 + lo:
            when v < 32 or v == 127 [ we_bad = 1: give "": ]
            tb_add(b, sub(s, last, i)): tb_add(b, chr(v)):
            i = i + 3: last = i:
            skip:
        ]
        when c == "+" and plus_is_space == 1 [
            tb_add(b, sub(s, last, i)): tb_add(b, " "):
            i = i + 1: last = i:
            skip:
        ]
        i = i + 1:
    ]
    when last == 0 [ give s: ]
    tb_add(b, sub(s, last, n)):
    give tb_text(b):
]

// ================================================================
// output escaping — use these on ANY data that came from a request
// ================================================================

fn html_escape(text s) -> text [
    when len(s) <= WE_WIN [ give we_html_escape_win(s): ]
    let TextBuilder b = tb_new():
    loop w in we_windows(s) [ tb_add(b, we_html_escape_win(w)): ]
    give tb_text(b):
]

fn we_html_escape_win(text s) -> text [
    let TextBuilder b = tb_new(): let int last = 0: let int changed = 0:
    let int i = 0: let int n = len(s):
    loop while i < n [
        let int c = ord(s{i}):
        let text rep = "":
        when c == 38 [ rep = "&amp;": ]
        or c == 60 [ rep = "&lt;": ]
        or c == 62 [ rep = "&gt;": ]
        or c == 34 [ rep = "&quot;": ]
        or c == 39 [ rep = "&#39;": ]
        when len(rep) > 0 [
            tb_add(b, sub(s, last, i)): tb_add(b, rep):
            last = i + 1: changed = 1:
        ]
        i = i + 1:
    ]
    when changed == 0 [ give s: ]
    tb_add(b, sub(s, last, n)):
    give tb_text(b):
]

// JSON string-content escape. Also escapes < > & so JSON is safe to embed in HTML.
fn json_escape(text s) -> text [
    when len(s) <= WE_WIN [ give we_json_escape_win(s): ]
    let TextBuilder b = tb_new():
    loop w in we_windows(s) [ tb_add(b, we_json_escape_win(w)): ]
    give tb_text(b):
]

fn we_json_escape_win(text s) -> text [
    let TextBuilder b = tb_new(): let int last = 0: let int changed = 0:
    let int i = 0: let int n = len(s):
    let text hex = "0123456789abcdef":
    loop while i < n [
        let int c = ord(s{i}):
        let text rep = "":
        when c == 34 [ rep = "\\\"": ]
        or c == 92 [ rep = "\\\\": ]
        or c == 10 [ rep = "\\n": ]
        or c == 13 [ rep = "\\r": ]
        or c == 9 [ rep = "\\t": ]
        or c == 60 [ rep = "\\u003c": ]
        or c == 62 [ rep = "\\u003e": ]
        or c == 38 [ rep = "\\u0026": ]
        or c < 32 or c == 127 [
            rep = "\\u00" + hex{c / 16} + hex{c % 16}:
        ]
        when len(rep) > 0 [
            tb_add(b, sub(s, last, i)): tb_add(b, rep):
            last = i + 1: changed = 1:
        ]
        i = i + 1:
    ]
    when changed == 0 [ give s: ]
    tb_add(b, sub(s, last, n)):
    give tb_text(b):
]

fn json_str(text key, text val) -> text [ give "\"" + json_escape(key) + "\":\"" + json_escape(val) + "\"": ]
fn json_num(text key, int val) -> text [ give "\"" + json_escape(key) + "\":" + totext(val): ]
fn json_bool(text key, int val) -> text [
    when val != 0 [ give "\"" + json_escape(key) + "\":true": ]
    give "\"" + json_escape(key) + "\":false":
]
fn json_object(list fields) -> text [ give "{" + join(fields, ",") + "}": ]

// ================================================================
// request accessors for apps
// ================================================================

fn req_is_get(Request req) -> int [
    when req.method == "GET" or req.method == "HEAD" [ give 1: ]
    give 0:
]

fn req_header(Request req, text name) -> text [
    let text k = lower(name):
    when map_has(req.headers, k) == 1 [ give map_get_text(req.headers, k): ]
    give "":
]

// query string / form body -> map (keys and values percent-decoded, "+" = space).
// Malformed pairs are dropped rather than failing the whole request.
fn we_parse_pairs(text raw) -> map [
    let map m = map_new():
    when len(raw) == 0 [ give m: ]
    // 65 parts: up to 64 pairs, anything after the 64th "&" is ignored
    let list pairs = we_split_char(raw, "&", 65):
    let int count = 0:
    loop kv in pairs [
        count = count + 1:
        when count > 64 [ stop: ]
        when len(kv) == 0 [ skip: ]
        let list kvp = we_split_char(kv, "=", 2):
        let text k = kvp{0}: let text v = "":
        when len(kvp) == 2 [ v = kvp{1}: ]
        we_bad = 0:
        let text dk = we_url_decode(k, 1):
        let text dv = we_url_decode(v, 1):
        when we_bad == 1 or len(dk) == 0 [ skip: ]
        map_set(m, dk, dv):
    ]
    we_bad = 0:
    give m:
]

fn req_query(Request req) -> map [ give we_parse_pairs(req.query): ]

fn req_form(Request req) -> map [
    when starts_with(lower(req_header(req, "content-type")), "application/x-www-form-urlencoded") == 0 [ give map_new(): ]
    give we_parse_pairs(req.body):
]

// a query/form value or a default, length-capped so huge inputs can't blow up output
fn param(map m, text key, text dflt, int maxlen) -> text [
    when map_has(m, key) == 0 [ give dflt: ]
    let text v = map_get_text(m, key):
    when len(v) > maxlen [ v = sub(v, 0, maxlen): ]
    give v:
]

// "/users/42" -> ["users", "42"]
fn path_parts(text path) -> list [
    let list out = list_new_text():
    loop seg in split(path, "/") [
        when len(seg) > 0 [ push(out, seg): ]
    ]
    give out:
]

// ================================================================
// response builders for apps
// ================================================================

fn res_send(Response res, int status, text ctype, text body) -> int [
    res.status = status: res.ctype = ctype: res.body = body:
    give 1:
]
fn res_html(Response res, int status, text body) -> int [ give res_send(res, status, "text/html; charset=utf-8", body): ]
fn res_text(Response res, int status, text body) -> int [ give res_send(res, status, "text/plain; charset=utf-8", body): ]
fn res_json(Response res, int status, text body) -> int [ give res_send(res, status, "application/json", body): ]

// Adds a response header. Refuses (returns 0) anything that could split the
// response or override the engine's own framing/security headers.
fn res_header(Response res, text name, text value) -> int [
    when we_is_token(name) == 0 or we_has_ctl(value) == 1 or len(value) > 1024 [
        iglog.warn("webengine: refused unsafe response header " + totext(len(name)) + "-char name"):
        give 0:
    ]
    let text k = lower(name):
    when k == "content-length" or k == "connection" or k == "transfer-encoding" or k == "content-type" [ give 0: ]
    res.headers = res.headers + name + ": " + value + "\r\n":
    give 1:
]

// Same-site redirect only: must be a path starting with exactly one "/".
// Anything else (//evil.com, http://..., /\evil, CR/LF) becomes a 400.
fn res_redirect(Response res, text location) -> int [
    let int ok = 1:
    when len(location) == 0 or len(location) > WE_MAX_TARGET [ ok = 0: ]
    or location{0} != "/" [ ok = 0: ]
    or len(location) > 1 and (location{1} == "/" or ord(location{1}) == 92) [ ok = 0: ]
    or we_is_visible(location) == 0 [ ok = 0: ]
    when ok == 0 [ give res_text(res, 400, "400 Bad Request: unsafe redirect target"): ]
    res_header(res, "Location", location):
    give res_text(res, 303, "See Other"):
]

// ================================================================
// templates (files in ./templates)
//
//   {{ name }}                 value from the vars map, HTML-escaped
//   {{{ name }}}               value inserted raw — only for HTML you built yourself
//   {% include "part.html" %}  another template, same vars
//   {% if name %} ... {% else %} ... {% endif %}
//                              true when name is set and not "" / "0" / "false";
//                              `if not name` inverts; ifs nest
//
// A missing variable renders as "" (and is logged in debug mode). For repeated
// rows, render a partial per item with render_text() and pass the joined
// result as a {{{ raw }}} variable.
// ================================================================

// Raises a runtime error the request's try/catch turns into a 500; the
// message shows on the debug error page and in the log.
fn we_fail(text msg) -> int [
    we_err_msg = msg:
    iglog.err("webengine: " + msg):
    give 1 / we_zero:
]

fn tpl_vars() -> map [ give map_new(): ]

fn we_tpl_load(text name) -> text [
    let text rel = we_static_rel("/" + name):
    when len(rel) == 0 [ we_fail("bad template name: " + name): ]
    let text path = we_tpl_root + "/" + rel:
    let int size = file_size(path):
    when size < 0 [ we_fail("template not found: " + path): ]
    when size > WE_MAX_TEMPLATE [ we_fail("template too large: " + path): ]
    give readfile(path):
]

fn we_tpl_truthy(map vars, text name) -> int [
    when map_has(vars, name) == 0 [ give 0: ]
    let text v = map_get_text(vars, name):
    when v == "" or v == "0" or v == "false" [ give 0: ]
    give 1:
]

fn we_tpl_value(map vars, text name, text file) -> text [
    when map_has(vars, name) == 1 [ give map_get_text(vars, name): ]
    when we_debug == 1 [ iglog.warn("template " + file + ": no value for {{ " + name + " }}"): ]
    give "":
]

// all entries of the if-stack are 1
fn we_tpl_on(list conds) -> int [
    loop c in conds [ when c == 0 [ give 0: ] ]
    give 1:
]

fn we_tpl_render(text src, map vars, text file, int depth) -> text [
    let TextBuilder out = tb_new():
    let list conds = {}:
    let int on = 1:
    let int braces = 0:
    let int first = 1:
    // splitting at "{" is linear (windowed); tags are found at piece starts
    loop p in we_split_char(src, "{", 100000000) [
        when first == 1 [
            first = 0:
            tb_add(out, p):
            skip:
        ]
        braces = braces + 1:
        when len(p) == 0 [ skip: ]
        let text head = p:
        when len(p) > 300 [ head = sub(p, 0, 300): ]
        let int handled = 0:
        when braces >= 2 [
            let int raw = 0: let text close = "}}":
            when braces >= 3 [ raw = 1: close = "}}}": ]
            let int e = find(head, close):
            when e >= 0 [
                handled = 1:
                when on == 1 [
                    when braces > 2 + raw [ tb_add(out, repeat("{", braces - 2 - raw)): ]
                    let text v = we_tpl_value(vars, trim(sub(head, 0, e)), file):
                    when raw == 1 [ tb_add(out, v): ] else [ tb_add(out, html_escape(v)): ]
                    tb_add(out, sub(p, e + len(close), len(p))):
                ]
            ]
        ]
        or braces == 1 and head{0} == "%" [
            let int e = find(head, "%}"):
            when e > 0 [
                handled = 1:
                let list words = split(trim(sub(head, 1, e)), " "):
                let text kw = words{0}:
                when kw == "if" [
                    let int neg = 0: let int wi = 1:
                    when len(words) >= 3 and words{1} == "not" [ neg = 1: wi = 2: ]
                    when len(words) != wi + 1 [ we_fail(file + ": malformed {% if %}"): ]
                    let int t = we_tpl_truthy(vars, words{wi}):
                    when neg == 1 [ t = 1 - t: ]
                    push(conds, t):
                ]
                or kw == "else" [
                    when len(conds) == 0 [ we_fail(file + ": {% else %} without {% if %}"): ]
                    let int t = pop(conds):
                    push(conds, 1 - t):
                ]
                or kw == "endif" [
                    when len(conds) == 0 [ we_fail(file + ": {% endif %} without {% if %}"): ]
                    pop(conds):
                ]
                or kw == "include" [
                    when len(words) != 2 [ we_fail(file + ": malformed {% include %}"): ]
                    when on == 1 [
                        when depth >= WE_MAX_INCLUDE [ we_fail(file + ": includes nested too deep"): ]
                        let text inc = words{1}:
                        when len(inc) >= 2 [ inc = sub(inc, 1, len(inc) - 1): ]
                        tb_add(out, we_tpl_render(we_tpl_load(inc), vars, inc, depth + 1)):
                    ]
                ]
                else [ we_fail(file + ": unknown tag {% " + kw + " %}"): ]
                on = we_tpl_on(conds):
                when on == 1 [ tb_add(out, sub(p, e + 2, len(p))): ]
            ]
        ]
        when handled == 0 and on == 1 [
            tb_add(out, repeat("{", braces)):
            tb_add(out, p):
        ]
        braces = 0:
    ]
    when braces > 0 and on == 1 [ tb_add(out, repeat("{", braces)): ]
    when len(conds) > 0 [ we_fail(file + ": missing {% endif %}"): ]
    give tb_text(out):
]

// renders templates/<name> to text (for partials / emails / anything)
fn render_text(text name, map vars) -> text [
    give we_tpl_render(we_tpl_load(name), vars, name, 0):
]

// renders templates/<name> as the HTML response
fn render(Response res, text name, map vars) -> int [
    give res_html(res, 200, render_text(name, vars)):
]

// ================================================================
// low-level I/O
// ================================================================

// send() can accept less than everything; keep going until it's all out
fn we_send_all(int conn, text data) -> int [
    let int n = len(data): let int off = 0:
    loop while off < n [
        let text part = data:
        when off > 0 [ part = sub(data, off, n): ]
        let int s = sock_send(conn, part):
        // send's int result lands in rax unsign-extended, so SOCKET_ERROR shows up huge
        when s <= 0 or s > len(part) [ give 0: ]
        off = off + s:
    ]
    give 1:
]

fn we_reason(int s) -> text [
    when s == 200 [ give "OK": ]
    or s == 201 [ give "Created": ]
    or s == 204 [ give "No Content": ]
    or s == 301 [ give "Moved Permanently": ]
    or s == 302 [ give "Found": ]
    or s == 303 [ give "See Other": ]
    or s == 304 [ give "Not Modified": ]
    or s == 400 [ give "Bad Request": ]
    or s == 401 [ give "Unauthorized": ]
    or s == 403 [ give "Forbidden": ]
    or s == 404 [ give "Not Found": ]
    or s == 405 [ give "Method Not Allowed": ]
    or s == 408 [ give "Request Timeout": ]
    or s == 413 [ give "Content Too Large": ]
    or s == 414 [ give "URI Too Long": ]
    or s == 415 [ give "Unsupported Media Type": ]
    or s == 429 [ give "Too Many Requests": ]
    or s == 431 [ give "Request Header Fields Too Large": ]
    or s == 500 [ give "Internal Server Error": ]
    or s == 501 [ give "Not Implemented": ]
    or s == 503 [ give "Service Unavailable": ]
    or s == 505 [ give "HTTP Version Not Supported": ]
    give "Unknown":
]

fn we_head(int status, text ctype, int clen, text cache, text extra) -> text [
    give "HTTP/1.1 " + totext(status) + " " + we_reason(status) + "\r\n" +
         "Server: ignid-webengine\r\n" +
         "Content-Type: " + ctype + "\r\n" +
         "Content-Length: " + totext(clen) + "\r\n" +
         "Connection: close\r\n" +
         "Cache-Control: " + cache + "\r\n" +
         "X-Content-Type-Options: nosniff\r\n" +
         "X-Frame-Options: DENY\r\n" +
         "Referrer-Policy: no-referrer\r\n" +
         "Cross-Origin-Opener-Policy: same-origin\r\n" +
         "Cross-Origin-Resource-Policy: same-origin\r\n" +
         "Permissions-Policy: camera=(), microphone=(), geolocation=()\r\n" +
         "Content-Security-Policy: default-src 'self'; object-src 'none'; base-uri 'none'; frame-ancestors 'none'; form-action 'self'\r\n" +
         extra + "\r\n":
]

// head_only: 1 for HEAD — same headers (incl. Content-Length), no body
fn we_respond(int conn, int head_only, int status, text ctype, text body, text cache, text extra) -> int [
    when we_send_all(conn, we_head(status, ctype, len(body), cache, extra)) == 0 [ give 0: ]
    when head_only == 0 and len(body) > 0 [ give we_send_all(conn, body): ]
    give 1:
]

// Error pages never echo anything from the request. templates/<status>.html,
// if present, is sent as-is (not template-processed, so it can't fail).
fn we_error(int conn, int head_only, int status, text extra) -> int [
    let text custom = we_tpl_root + "/" + totext(status) + ".html":
    let int size = file_size(custom):
    when size > 0 and size <= 65536 [
        let text page = "": let int ok = 1:
        try [ page = readfile(custom): ] catch [ ok = 0: ]
        when ok == 1 [ give we_respond(conn, head_only, status, "text/html; charset=utf-8", page, "no-store", extra): ]
    ]
    let text msg = totext(status) + " " + we_reason(status):
    let text body = "<!doctype html><html><head><meta charset=utf-8><title>" + msg +
                    "</title></head><body><h1>" + msg + "</h1></body></html>":
    give we_respond(conn, head_only, status, "text/html; charset=utf-8", body, "no-store", extra):
]

// debug mode only: a 500 page with the error and the request that caused it
fn we_debug_page(int conn, int head_only, Request req, text err) -> int [
    let TextBuilder b = tb_new():
    tb_add(b, "<!doctype html><html><head><meta charset=utf-8><title>500 — debug</title><style>"):
    tb_add(b, "body{font:15px/1.5 system-ui,sans-serif;margin:32px;color:#222}h1{color:#b91c1c}"):
    tb_add(b, "pre{background:#f4f4f2;padding:12px;overflow:auto}td{padding:2px 12px 2px 0;vertical-align:top}"):
    tb_add(b, "</style></head><body><h1>500 Internal Server Error</h1><pre>"):
    tb_add(b, html_escape(err)):
    tb_add(b, "</pre><h2>Request</h2><pre>"):
    tb_add(b, html_escape(req.method + " " + req.target + " " + req.version)):
    tb_add(b, "</pre><h2>Headers</h2><table>"):
    loop k in map_keys(req.headers) [
        tb_add(b, "<tr><td>" + html_escape(k) + "</td><td>" + html_escape(map_get_text(req.headers, k)) + "</td></tr>"):
    ]
    tb_add(b, "</table><h2>Body</h2><pre>"):
    let text body = req.body:
    when len(body) > 4096 [ body = sub(body, 0, 4096) + "\n... (" + totext(len(req.body)) + " bytes)": ]
    tb_add(b, html_escape(body)):
    tb_add(b, "</pre><p><small>ignid-webengine " + WE_VERSION +
              " — debug mode is on. This page shows internal details: never run with --debug in production.</small></p></body></html>"):
    give we_respond(conn, head_only, 500, "text/html; charset=utf-8", tb_text(b), "no-store", ""):
]

// ================================================================
// request reading + parsing
// returns 0 on success, -1 if the peer went away (send nothing),
// or an HTTP error status to answer with
// ================================================================

fn we_read_request(int conn, Request req) -> int [
    let text buf = "":
    let int hdr_end = -1:
    let int recvs = 0:
    let int t0 = clock():
    loop while hdr_end < 0 [
        when recvs >= WE_MAX_RECVS or clock() - t0 > WE_DEADLINE [ give 408: ]
        let text chunk = sock_recv(conn):
        recvs = recvs + 1:
        // "" = closed, reset, or timed out — nothing worth answering
        when len(chunk) == 0 [ give -1: ]
        // only search the new bytes (plus 3 of overlap), never the whole buffer
        let int from = len(buf) - 3:
        when from < 0 [ from = 0: ]
        buf = buf + chunk:
        let int at = we_find_from(sub(buf, from, len(buf)), "\r\n\r\n", 0):
        when at >= 0 [ hdr_end = from + at: ]
        when hdr_end < 0 and len(buf) > WE_MAX_HEADER [ give 431: ]
    ]
    when hdr_end > WE_MAX_HEADER [ give 431: ]

    // split on LF (windowed, linear); every line but the last must end in CR
    let list raw_lines = we_split_char(sub(buf, 0, hdr_end), "\n", WE_MAX_HEADERS + 2):
    when len(raw_lines) > WE_MAX_HEADERS + 1 [ give 431: ]
    let list lines = list_new_text():
    let int li = 0: let int nl = len(raw_lines):
    loop while li < nl [
        let text l = raw_lines{li}:
        when li < nl - 1 [
            when ends_with(l, "\r") == 0 [ give 400: ]
            l = sub(l, 0, len(l) - 1):
        ]
        push(lines, l):
        li = li + 1:
    ]

    // ---- request line: METHOD SP target SP version ----
    let list parts = split(lines{0}, " "):
    when len(parts) != 3 [ give 400: ]
    req.method = parts{0}: req.target = parts{1}: req.version = parts{2}:
    when we_is_token(req.method) == 0 [ give 400: ]
    when starts_with(req.version, "HTTP/") == 0 [ give 400: ]
    when req.version != "HTTP/1.1" and req.version != "HTTP/1.0" [ give 505: ]
    when len(req.target) > WE_MAX_TARGET [ give 414: ]
    when len(req.target) == 0 or req.target{0} != "/" [ give 400: ]
    when we_is_visible(req.target) == 0 [ give 400: ]

    // ---- header fields ----
    let int i = 1: let int n = len(lines):
    loop while i < n [
        let text ln = lines{i}:
        i = i + 1:
        when len(ln) == 0 [ give 400: ]
        let int c0 = ord(ln{0}):
        when c0 == 32 or c0 == 9 [ give 400: ]          // obs-fold
        let int colon = find(ln, ":"):
        when colon <= 0 [ give 400: ]
        let text name = sub(ln, 0, colon):
        when we_is_token(name) == 0 [ give 400: ]       // also rejects "Name : v"
        let text val = trim(sub(ln, colon + 1, len(ln))):
        when we_has_ctl(val) == 1 [ give 400: ]
        let text key = lower(name):
        when map_has(req.headers, key) == 1 [
            when key == "content-length" or key == "host" or key == "transfer-encoding" [ give 400: ]
            map_set(req.headers, key, map_get_text(req.headers, key) + ", " + val):
        ]
        else [ map_set(req.headers, key, val): ]
    ]
    when req.version == "HTTP/1.1" and map_has(req.headers, "host") == 0 [ give 400: ]
    when map_has(req.headers, "transfer-encoding") == 1 [ give 501: ]

    // ---- method ----
    when req.method != "GET" and req.method != "HEAD" and req.method != "POST" [
        when req.method == "PUT" or req.method == "DELETE" or req.method == "PATCH" or req.method == "OPTIONS" [ give 405: ]
        give 501:
    ]

    // ---- body (read fully even when unused, so closing doesn't reset the client) ----
    let int clen = 0:
    when map_has(req.headers, "content-length") == 1 [
        let text v = map_get_text(req.headers, "content-length"):
        when we_all_digits(v) == 0 or len(v) > 9 [ give 400: ]
        clen = toint(v):
        when clen > WE_MAX_BODY [ give 413: ]
    ]
    let text body = sub(buf, hdr_end + 4, len(buf)):
    loop while len(body) < clen [
        when recvs >= WE_MAX_RECVS or clock() - t0 > WE_DEADLINE [ give 408: ]
        let text chunk = sock_recv(conn):
        recvs = recvs + 1:
        when len(chunk) == 0 [ give -1: ]
        body = body + chunk:
    ]
    when len(body) > clen [ body = sub(body, 0, clen): ]
    req.body = body:

    // ---- path / query ----
    let int q = find(req.target, "?"):
    let text raw_path = req.target:
    when q >= 0 [
        raw_path = sub(req.target, 0, q):
        req.query = sub(req.target, q + 1, len(req.target)):
    ]
    we_bad = 0:
    req.path = we_url_decode(raw_path, 0):
    when we_bad == 1 [ we_bad = 0: give 400: ]
    give 0:
]

// ================================================================
// static files
// ================================================================

fn we_static_type(text ext) -> text [
    when ext == "html" or ext == "htm" [ give "text/html; charset=utf-8": ]
    or ext == "css" [ give "text/css; charset=utf-8": ]
    or ext == "js" or ext == "mjs" [ give "text/javascript; charset=utf-8": ]
    or ext == "json" [ give "application/json": ]
    or ext == "txt" or ext == "md" [ give "text/plain; charset=utf-8": ]
    or ext == "csv" [ give "text/csv; charset=utf-8": ]
    or ext == "xml" [ give "application/xml": ]
    or ext == "map" [ give "application/json": ]
    or ext == "webmanifest" [ give "application/manifest+json": ]
    or ext == "svg" [ give "image/svg+xml": ]
    or ext == "png" [ give "image/png": ]
    or ext == "jpg" or ext == "jpeg" [ give "image/jpeg": ]
    or ext == "gif" [ give "image/gif": ]
    or ext == "webp" [ give "image/webp": ]
    or ext == "avif" [ give "image/avif": ]
    or ext == "ico" [ give "image/x-icon": ]
    or ext == "woff" [ give "font/woff": ]
    or ext == "woff2" [ give "font/woff2": ]
    or ext == "ttf" [ give "font/ttf": ]
    or ext == "otf" [ give "font/otf": ]
    or ext == "pdf" [ give "application/pdf": ]
    or ext == "mp3" [ give "audio/mpeg": ]
    or ext == "ogg" [ give "audio/ogg": ]
    or ext == "wav" [ give "audio/wav": ]
    or ext == "mp4" [ give "video/mp4": ]
    or ext == "webm" [ give "video/webm": ]
    or ext == "wasm" [ give "application/wasm": ]
    or ext == "zip" [ give "application/zip": ]
    // anything else (.ig, .exe, .bat, .config, no extension, ...) is never served
    give "":
]

fn we_reserved_name(text seg) -> int [
    let text base = lower(seg):
    let int dot = find(base, "."):
    when dot >= 0 [ base = sub(base, 0, dot): ]
    when base == "con" or base == "prn" or base == "aux" or base == "nul" [ give 1: ]
    when len(base) == 4 and (starts_with(base, "com") == 1 or starts_with(base, "lpt") == 1) [
        let int d = ord(base{3}):
        when d >= 48 and d <= 57 [ give 1: ]
    ]
    give 0:
]

// decoded URL path -> relative file path under the root, or "" if it is not
// something we are willing to serve. Whitelist, not blacklist.
fn we_static_rel(text path) -> text [
    let text p = path:
    when ends_with(p, "/") == 1 [ p = p + "index.html": ]
    let text rel = sub(p, 1, len(p)):
    let int n = len(rel):
    when n == 0 or n > 255 [ give "": ]
    let int i = 0:
    loop while i < n [
        let int c = ord(rel{i}):
        let int ok = 0:
        when c >= 48 and c <= 57 [ ok = 1: ]
        or c >= 65 and c <= 90 [ ok = 1: ]
        or c >= 97 and c <= 122 [ ok = 1: ]
        or c == 45 or c == 46 or c == 95 or c == 47 [ ok = 1: ]
        when ok == 0 [ give "": ]
        i = i + 1:
    ]
    let list segs = split(rel, "/"):
    when len(segs) > 8 [ give "": ]
    loop seg in segs [
        let int sl = len(seg):
        when sl == 0 or sl > 64 [ give "": ]           // "//" or overlong
        when seg{0} == "." [ give "": ]                 // ".." "." ".git" ".env"
        when seg{sl - 1} == "." [ give "": ]            // Windows drops trailing dots
        when we_reserved_name(seg) == 1 [ give "": ]    // CON, NUL, COM1, LPT1.txt, ...
    ]
    let int dot = -1: let int j = n - 1:
    loop while j >= 0 [
        when rel{j} == "." [ dot = j: stop: ]
        when rel{j} == "/" [ stop: ]
        j = j - 1:
    ]
    when dot < 0 [ give "": ]
    when len(we_static_type(lower(sub(rel, dot + 1, n)))) == 0 [ give "": ]
    give rel:
]

fn we_serve_static(int conn, Request req) -> int [
    let int head_only = 0:
    when req.method == "HEAD" [ head_only = 1: ]
    when req_is_get(req) == 0 [ we_error(conn, head_only, 405, "Allow: GET, HEAD\r\n"): give 405: ]
    let text rel = we_static_rel(req.path):
    when len(rel) == 0 [ we_error(conn, head_only, 404, ""): give 404: ]

    let text ext = rel: let int k = len(rel) - 1:
    loop while k >= 0 [
        when rel{k} == "." [ ext = lower(sub(rel, k + 1, len(rel))): stop: ]
        k = k - 1:
    ]

    // directories (and anything else CreateFile won't open) report -1
    let text fspath = we_root + "/" + rel:
    let int size = file_size(fspath):
    when size < 0 [ we_error(conn, head_only, 404, ""): give 404: ]
    when size > WE_MAX_FILE [
        iglog.err("webengine: static file over size limit: " + rel):
        we_error(conn, head_only, 500, ""): give 500:
    ]

    let text cache = "public, max-age=300":
    when we_debug == 1 [ cache = "no-cache": ]
    when we_send_all(conn, we_head(200, we_static_type(ext), size, cache, "")) == 0 [ give 200: ]
    // streamed disk -> socket in 64KB blocks: binary-safe, no heap used
    when head_only == 0 [
        let int sent = sock_send_file(conn, fspath, size):
        when sent != size [ iglog.warn("webengine: sent " + totext(sent) + " of " + totext(size) + " bytes of " + rel): ]
    ]
    give 200:
]

// ================================================================
// connection + main loop
// ================================================================

fn we_handle(int conn) -> int [
    let int t0 = clock():
    we_err_msg = "":
    let Request req = Request("", "", "", "", "", map_new(), ""):
    let int st = we_read_request(conn, req):
    when st == -1 [ give -1: ]
    when st != 0 [
        we_error(conn, 0, st, ""):
        iglog("[" + totext(we_conns) + "] (rejected) -> " + totext(st)):
        give st:
    ]
    let int head_only = 0:
    when req.method == "HEAD" [ head_only = 1: ]

    let Response res = Response(0, "", "", "", "no-store"):
    let int handled = 0: let int failed = 0: let text err = "":
    try [
        handled = app_handle(req, res):
    ] catch [
        failed = 1:
        err = lasterror():
        when len(we_err_msg) > 0 [ err = we_err_msg: ]
        iglog.err("webengine: handler error on " + req.method + " " + req.path + ": " + err):
    ]
    let int status = 0:
    when failed == 1 and we_debug == 1 [
        we_debug_page(conn, head_only, req, err): status = 500:
    ]
    or failed == 1 [
        we_error(conn, head_only, 500, ""): status = 500:
    ]
    or handled == 1 and res.status > 0 [
        we_respond(conn, head_only, res.status, res.ctype, res.body, res.cache, res.headers):
        status = res.status:
    ]
    else [
        status = we_serve_static(conn, req):
    ]
    iglog("[" + totext(we_conns) + "] " + req.method + " " + req.target + " -> " + totext(status) +
          " (" + totext(clock() - t0) + "ms)"):
    give status:
]

// 1 = debug mode: error details on 500 pages, missing template values logged,
// static files not cached. Call before we_run(). Never in production.
fn we_set_debug(int on_off) -> int [
    we_debug = on_off:
    give 0:
]

// Serves until the heap fills up, then exits with WE_EXIT_RECYCLE so guardian.ig
// can start a fresh process. root: folder static files are served from.
fn we_run(int port, text root) -> int [
    we_root = root:
    let int listener = sock_listen(port):
    iglog("ignid-webengine " + WE_VERSION + ": serving ./" + root + " on http://localhost:" + totext(port) + "/"):
    when we_debug == 1 [
        iglog.warn("DEBUG MODE: error pages show internal details. Do not expose this server."):
    ]
    let int fails = 0:
    loop while true [
        let int conn = sock_accept(listener):
        when conn == -1 [
            fails = fails + 1:
            when fails >= 5 [
                iglog.err("webengine: cannot listen on port " + totext(port) + " (already in use?)"):
                quit(WE_EXIT_LISTEN):
            ]
            skip:
        ]
        fails = 0:
        we_conns = we_conns + 1:
        sock_timeout(conn, WE_IO_TIMEOUT):
        try [
            we_handle(conn):
        ] catch [
            iglog.err("webengine: connection error: " + lasterror()):
        ]
        sock_close(conn):
        when heap_used() >= WE_HEAP_LIMIT [
            iglog("webengine: recycling after " + totext(we_conns) + " connections (" +
                  totext(heap_used() / 1048576) + "MB heap used)"):
            sock_close(listener):
            quit(WE_EXIT_RECYCLE):
        ]
    ]
    give 0:
]
