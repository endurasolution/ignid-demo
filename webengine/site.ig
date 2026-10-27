// site.ig — an example website running on webengine.ig.
//
//   ignid site.ig [port] [--debug]
//
// Pages are HTML templates in ./templates; CSS, images and other files are
// served from ./public. See README.md.
use "webengine.ig":

let int g_started = 0:

// every page shares a few variables (nav highlighting, version, ...)
fn page_vars(text title, text active) -> map [
    let map v = tpl_vars():
    map_set(v, "title", title):
    map_set(v, "nav_" + active, "1"):
    map_set(v, "version", WE_VERSION):
    give v:
]

fn route_home(Request req, Response res) -> int [
    give render(res, "home.html", page_vars("Home", "home")):
]

fn route_about(Request req, Response res) -> int [
    give render(res, "about.html", page_vars("About", "about")):
]

// GET /hello?name=...  — the template escapes {{ name }}, so a <script> is shown, not run
fn route_hello(Request req, Response res) -> int [
    let map v = page_vars("Hello", "hello"):
    map_set(v, "name", param(req_query(req), "name", "world", 64)):
    give render(res, "hello.html", v):
]

// GET shows the form, POST shows it again with the message (escaped) — nothing is stored
fn route_guestbook(Request req, Response res) -> int [
    let map v = page_vars("Guestbook", "guestbook"):
    when req.method == "POST" [
        map_set(v, "message", param(req_form(req), "message", "", 500)):
    ]
    give render(res, "guestbook.html", v):
]

// a list rendered with a partial template per row
fn route_users(Request req, Response res) -> int [
    let list names = list_new_text():
    push(names, "Ada"): push(names, "Grace"): push(names, "Linus"): push(names, "<b>not bold</b>"):
    let TextBuilder rows = tb_new():
    let int i = 0:
    loop n in names [
        i = i + 1:
        let map row = tpl_vars():
        map_set(row, "id", totext(i)):
        map_set(row, "name", n):
        tb_add(rows, render_text("user_row.html", row)):
    ]
    let map v = page_vars("Users", "users"):
    map_set(v, "rows", tb_text(rows)):
    map_set(v, "count", totext(len(names))):
    give render(res, "users.html", v):
]

// GET /users/:id — path parameter, validated
fn route_user(Request req, Response res, list parts) -> int [
    let text id = parts{1}:
    when we_all_digits(id) == 0 or len(id) > 9 [ give res_json(res, 400, "{\"error\":\"id must be a number\"}"): ]
    give res_json(res, 200, "{" + json_num("id", toint(id)) + "}"):
]

fn route_status(Request req, Response res) -> int [
    let list f = list_new_text():
    push(f, json_str("engine", "ignid-webengine")):
    push(f, json_str("version", WE_VERSION)):
    push(f, json_num("connections", we_conns)):
    push(f, json_num("uptime_ms", clock() - g_started)):
    push(f, json_num("heap_used", heap_used())):
    push(f, json_bool("ok", 1)):
    give res_json(res, 200, json_object(f)):
]

// POST /api/echo  — echoes the raw body back inside JSON
fn route_echo(Request req, Response res) -> int [
    when req.method != "POST" [
        res_header(res, "Allow", "POST"):
        give res_json(res, 405, "{\"error\":\"use POST\"}"):
    ]
    let list f = list_new_text():
    push(f, json_num("bytes", len(req.body))):
    push(f, json_str("body", req.body)):
    give res_json(res, 200, json_object(f)):
]

// GET /go?to=/somewhere — same-site redirects only (res_redirect enforces it)
fn route_go(Request req, Response res) -> int [
    give res_redirect(res, param(req_query(req), "to", "/", 512)):
]

// the one hook webengine.ig calls; give 0 to fall through to ./public
fn app_handle(Request req, Response res) -> int [
    let text p = req.path:
    let int get = req_is_get(req):
    when p == "/" and get == 1 [ give route_home(req, res): ]
    when p == "/about" and get == 1 [ give route_about(req, res): ]
    when p == "/hello" and get == 1 [ give route_hello(req, res): ]
    when p == "/guestbook" [ give route_guestbook(req, res): ]
    when p == "/users" and get == 1 [ give route_users(req, res): ]
    when starts_with(p, "/users/") == 1 and get == 1 [
        let list parts = path_parts(p):
        when len(parts) == 2 [ give route_user(req, res, parts): ]
    ]
    when p == "/api/status" and get == 1 [ give route_status(req, res): ]
    when p == "/api/echo" [ give route_echo(req, res): ]
    when p == "/go" and get == 1 [ give route_go(req, res): ]
    when p == "/crash" and get == 1 [
        // deliberately throws: a handler bug becomes a 500, never a dead server
        let int zero = 0:
        give 1 / zero:
    ]
    when p == "/broken-template" and get == 1 [
        // deliberately renders a missing template: shows what debug mode reports
        give render(res, "does-not-exist.html", tpl_vars()):
    ]
    give 0:
]

start [
    let int port = 8080:
    let int i = 0:
    loop while i < argc() [
        let text a = argv(i):
        when a == "--debug" [ we_set_debug(1): ]
        else [
            let int ok = 1:
            try [ port = toint(a): ] catch [ ok = 0: ]
            when ok == 0 or port < 1 or port > 65535 [
                iglog.err("usage: site [port] [--debug]"):
                quit(1):
            ]
        ]
        i = i + 1:
    ]
    g_started = clock():
    we_run(port, "public"):
]
