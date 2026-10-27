# Ignid Webengine 1.0.0

A hardened web framework and HTTP/1.1 server written entirely in Ignid. It does the
same job as Flask does for Python: routes in code, HTML templates, static files, and
a debug mode. The request parser, template engine, file server, security layer and
process supervisor are all `.ig` code compiled to one native Windows executable.

| Path | What it is |
|---|---|
| [`webengine.ig`](webengine.ig) | The engine. `use` it and define one function, `app_handle`. |
| [`site.ig`](site.ig) | Example site with pages, a form, a list, JSON, redirects, and error demos. |
| [`templates/`](templates/) | HTML templates (`{{ }}`, `{% include %}`, `{% if %}`), plus the custom `404.html`. |
| [`public/`](public/) | Static files of any type (CSS, JS, images, fonts, PDF, video). Only this folder is served as files. |
| [`guardian.ig`](guardian.ig) | Supervisor that keeps the site running. |
| [`tests/attack_test.ig`](tests/attack_test.ig) | 67 hostile and malformed requests, with the result each one must get. |

## Requirements

An Ignid build that includes the runtime builtins `sock_timeout`, `heap_used`,
`file_size` and `sock_send_file`, plus the `sock_recv` reset-crash fix. An older
Ignid fails at the assembly step with errors like
``symbol `ig_fn_sock_timeout' not defined``.

`tests/attack_test.ig` is a client, so it also needs `sock_connect` and
`sock_recv_all`.

## Run

From this folder:

```
ignid site.ig 8080             normal mode
ignid site.ig 8080 --debug     development mode (see Debugging)
```

Open <http://localhost:8080/>. Every request is logged with its status and timing:

```
[12] GET /users -> 200 (4ms)
```

For a server that stays up, build the site and the guardian, then run the site
under the guardian:

```
echo site.ig | ignidc
echo guardian.ig | ignidc
guardian.exe site.exe 8080
```

## Writing a site

```
use "webengine.ig":

fn app_handle(Request req, Response res) -> int [
    when req.path == "/" and req_is_get(req) == 1 [
        let map v = tpl_vars():
        map_set(v, "title", "Home"):
        map_set(v, "user", param(req_query(req), "user", "guest", 64)):
        give render(res, "home.html", v):
    ]
    give 0:   // not handled: serve the matching file from public/, or a 404
]

start [ we_run(8080, "public"): ]
```

### Templates (`templates/*.html`)

| Syntax | Meaning |
|---|---|
| `{{ name }}` | Inserts the value, HTML-escaped. This is the default and the safe choice. |
| `{{{ name }}}` | Inserts the value raw. Use it only for HTML you built yourself, such as rendered rows. |
| `{% include "header.html" %}` | Inserts another template, with the same variables. |
| `{% if name %} … {% else %} … {% endif %}` | True when `name` is set and isn't `""`, `"0"` or `"false"`. `if not name` inverts it, and ifs can nest. |

- **Lists** are rendered with a small partial per item: call `render_text("row.html", vars)`
  for each item, join the results with a `TextBuilder`, and pass them as a
  `{{{ rows }}}` variable. See `route_users` in `site.ig`.
- **Literal braces:** to show `{{` on a page, write `&#123;&#123;`.
- **Error pages:** `templates/404.html` (or any `<status>.html`) replaces the
  built-in error page for that status.

### API

**Request**
- `req.method`, `req.path` (decoded), `req.query` (raw), `req.body`
- `req_is_get(req)`, `req_header(req, name)`
- `req_query(req)` and `req_form(req)` return maps
- `param(map, key, default, maxlen)`, `path_parts(path)`

**Response**
- Templates: `render(res, name, vars)`, `render_text(name, vars)`
- Bodies: `res_html`, `res_text`, `res_json`, `res_send(res, status, type, body)`
- Headers and redirects: `res_header(res, name, value)`, `res_redirect(res, "/path")`

**Escaping:** `html_escape`, `json_escape`, and `json_str`, `json_num`,
`json_bool` and `json_object`.

**Large text:** `tb_new()`, `tb_add(b, piece)` and `tb_text(b)`. Use these instead
of `s = s + x` in loops (see [Runtime constraints](#runtime-constraints)).

**Other:** `WE_VERSION` (`"1.0.0"`) and `we_set_debug(1)`.

## Debugging

`--debug` (or `we_set_debug(1)` before `we_run`) turns on:

- **Error pages with details.** A 500 shows the error message (for example
  `template not found: templates/x.html` or `division by zero`), the request line,
  every header, and the body. All of it is escaped.
- **Template warnings.** A `{{ value }}` with no matching variable is logged.
- **No caching.** Static files are sent with `Cache-Control: no-cache`, so a reload
  shows your edits.

Templates and static files are read from disk on every request, so edits show up
immediately. Changes to `.ig` code need a restart.

Without `--debug`, visitors see a generic 500 page, and the details go only to the
server log. Try `/crash` and `/broken-template` on the example site in both modes.
**Never expose a server running with `--debug`.**

## Security measures

**Request parsing.** The parser is strict, and anything ambiguous is rejected
rather than guessed at:

- **Request line:** must be exactly `METHOD SP /target SP HTTP/1.x`.
- **Method:** must be a valid token; only `GET`, `HEAD` and `POST` are served.
- **Target:** must start with `/` and contain only visible ASCII. Absolute-form
  targets (`http://...`) are rejected.
- **Header names:** must be RFC 9110 tokens. `Host : x` (space before the colon)
  gets a 400.
- **Header values:** control characters are rejected.
- **Line folding:** obs-fold continuation lines get a 400, and so do bare-LF line
  endings.
- **Host:** required on HTTP/1.1, and a duplicate Host gets a 400.
- **Request smuggling:**
  - `Transfer-Encoding` of any kind gets a 501.
  - `Content-Length` must be digits only; a duplicate gets a 400.
  - Extra bytes after the body are discarded and the connection is closed.

**Size limits.** These are constants at the top of `webengine.ig`:

| Limit | Value | Response |
|---|---|---|
| Request line + headers | 8 KB | 431 |
| Header count | 64 | 431 |
| Request target | 2 KB | 414 |
| Body | 64 KB | 413 |
| Static file | 32 MB | 500 |
| Template file | 256 KB | 500 |
| Single recv/send | 5 s | connection dropped |
| Whole request | 10 s | 408 |

**Static files.** Paths are checked against a whitelist, not a blacklist:

- Only `[A-Za-z0-9._-/]` may appear after percent-decoding, so `..\`, `%5c`, `:`
  (drive letters and `::$DATA` streams) and `~` (8.3 short names) are impossible.
- No segment may start with `.`, which blocks `..`, `.git` and `.env`.
- No segment may end with `.`. Windows silently strips trailing dots.
- Windows device names (`CON`, `NUL`, `AUX`, `PRN`, `COM1`–`9`, `LPT1`–`9`) are
  refused.
- Only known file types are served: html, css, js, json, txt, md, csv, xml, svg,
  png, jpg, gif, webp, avif, ico, woff/woff2/ttf/otf, pdf, mp3/ogg/wav, mp4/webm,
  wasm and zip. `.ig`, `.exe`, `.bat`, config files and files without an extension
  never are.
- Only `public/` is served. `templates/` and the source files can't be reached.
- An unknown or disallowed path always gets the same 404, so the response doesn't
  reveal whether the file exists.

**Response headers.** Every response carries:

- `Content-Security-Policy: default-src 'self'; object-src 'none'; base-uri 'none'; frame-ancestors 'none'; form-action 'self'`
- `X-Content-Type-Options: nosniff`
- `X-Frame-Options: DENY`
- `Referrer-Policy: no-referrer`
- `Cross-Origin-Opener-Policy` and `Cross-Origin-Resource-Policy: same-origin`
- a restrictive `Permissions-Policy`

**Injection.**
- **Templates** escape by default; raw output needs `{{{ }}}`.
- **Production error pages** never echo request data or internal details.
- **`res_header`** refuses CR/LF and control characters, which prevents response
  splitting.
- **`res_redirect`** only accepts same-site paths. `//evil.com`, `/\evil.com` and
  `http://...` all get a 400.
- **`json_escape`** also escapes `<`, `>` and `&`, so JSON is safe to embed in a
  page.

## Stability measures

- **Crash isolation.** Each request's handler runs inside `try`/`catch`. A bug or a
  broken template becomes a 500 for that one request.
- **No idle keep-alive.** Every response sends `Connection: close`. A
  single-threaded server waiting on an idle keep-alive socket stops serving
  everyone else.
- **Slow-client defense.** Every connection gets a 5 s socket timeout and a 10 s
  overall deadline, so slowloris-style clients are cut off.
- **Memory recycling.** The site restarts itself before its memory runs out (see
  below), and the guardian brings it back within milliseconds.
- **Crash restarts.** The guardian restarts the site after a crash, with a growing
  back-off.

## Runtime constraints

These come from the Ignid runtime, and the engine is designed around each one:

1. **Memory is never freed.** The heap is a 64 MB bump allocator.
   - The engine checks `heap_used()` after every connection.
   - At 40 MB it exits with code 3, and the guardian starts a fresh process.
   - The remaining 24 MB covers the most expensive single request.
2. **Building strings with `+` costs O(n²) memory.** Each `s = s + x` copies all of
   `s`. Use `TextBuilder`; the engine's escapers, decoder and templates all do.
3. **Scanning text costs O(n²) time.** Strings store no length, so every `s{i}` and
   `sub()` re-measures the whole string. The engine cuts long data into 256-byte
   windows; escaping 48 KB went from 750 ms to 15 ms this way.
4. **Text cannot hold NUL bytes.** Static files therefore never pass through
   `text`: `sock_send_file` streams them from disk to the socket in 64 KB blocks.

## Measured results

On the development machine, with the site under the guardian:

- **Attack suite:** 67/67 pass.
- **Mixed load:** 6,100 requests of template pages, a PNG, CSS and 64 KB form
  posts, all answered 200. They averaged 13 ms (slowest 0.58 s), with a clean
  recycle about every 500 template pages.
- **Binary files:** a PNG and 3 MB of random bytes arrived byte-identical, using
  about 4 KB of heap each.

## Known limits

- **One request at a time.** There are no threads, because the runtime allocator
  has no locking. Good uses: internal tools, dashboards, docs sites and demos.
  Don't put it alone in front of heavy public traffic.
- **Plain HTTP only.** For a public site, put it behind a TLS reverse proxy (Caddy,
  nginx or IIS). The proxy can also add rate limiting, since the runtime doesn't
  expose client IP addresses.
- **Listens on all interfaces.** `sock_listen` binds `0.0.0.0`. Use Windows
  Firewall to keep it local.
- **No `{% for %}` in templates.** Map values are text only, so lists are rendered
  with partials (see above).
- **No sessions or cookies yet.** `res_header(res, "Set-Cookie", ...)` works, but
  there is no session store.
- **No auto-reload of `.ig` code.** Restart after editing; templates and static
  files reload by themselves.
