// json_saver.ig — Build and save JSON files interactively in Ignid
//
// Features:
//   - Create JSON objects with key/value pairs
//   - Supports text, int, float, bool, and list values
//   - Pretty-printed JSON output
//   - Save to file, load from file, view, edit, delete keys
//   - Multiple named documents in one session
//
// Run:  ignid json_saver.ig

use "d:/Ignid/std.ig":

// ===== JSON escape helper =====

fn json_escape(text s) -> text [
    let text result = "":
    let int i = 0: let int n = len(s):
    loop while i < n [
        let text ch = s{i}:
        when ch == "\"" [ result = result + "\\\"": ]
        or ch == "\\"   [ result = result + "\\\\": ]
        or ch == "\n"   [ result = result + "\\n": ]
        or ch == "\t"   [ result = result + "\\t": ]
        else            [ result = result + ch: ]
        i = i + 1:
    ]
    give result:
]

// ===== Value type detection =====

fn detect_type(text val) -> text [
    // booleans
    when val == "true" or val == "false" [ give "bool": ]

    // try int
    let int is_int = 1:
    let int i = 0: let int n = len(val):
    when n == 0 [ give "text": ]

    // allow leading minus
    when val{0} == "-" and n > 1 [ i = 1: ]
    loop while i < n [
        when is_digit_c(val{i}) == 0 [ is_int = 0: stop: ]
        i = i + 1:
    ]
    when is_int == 1 [ give "int": ]

    // try float (has exactly one '.')
    let int dots = str_count(val, "."):
    when dots == 1 [
        let int fi = 0: let int is_float = 1:
        when val{0} == "-" and n > 1 [ fi = 1: ]
        loop while fi < n [
            when is_digit_c(val{fi}) == 0 and val{fi} != "." [
                is_float = 0: stop:
            ]
            fi = fi + 1:
        ]
        when is_float == 1 [ give "float": ]
    ]

    give "text":
]

// ===== Format a single value as JSON =====

fn format_value(text val) -> text [
    let text vtype = detect_type(val):
    when vtype == "bool" or vtype == "int" or vtype == "float" [
        give val:
    ]
    give "\"" + json_escape(val) + "\"":
]

// ===== Format a map as pretty JSON =====

fn to_json(map m) -> text [
    let list keys = map_keys(m):
    let int n = len(keys):
    when n == 0 [ give "{}": ]

    let text json = "{\n":
    let int i = 0:
    loop while i < n [
        let text k = keys{i}:
        let text v = map_get_text(m, k):
        json = json + "    \"" + json_escape(k) + "\": " + format_value(v):
        when i < n - 1 [ json = json + ",": ]
        json = json + "\n":
        i = i + 1:
    ]
    json = json + "}":
    give json:
]

// ===== Show all keys =====

fn show_keys(map m) -> int [
    let list keys = map_keys(m):
    when len(keys) == 0 [
        iglog("  (empty — no keys yet)"):
        give 0:
    ]
    let int i = 0:
    loop while i < len(keys) [
        let text k = keys{i}:
        let text v = map_get_text(m, k):
        let text vtype = detect_type(v):
        iglog("  " + totext(i + 1) + ". " + k + " = " + v + "  [" + vtype + "]"):
        i = i + 1:
    ]
    give 0:
]

// ===== Help =====

fn show_json_help() -> int [
    iglog(""):
    iglog("  ╔══════════════════════════════════════╗"):
    iglog("  ║      Ignid JSON Saver — Commands     ║"):
    iglog("  ╠══════════════════════════════════════╣"):
    iglog("  ║  add    — add a key/value pair        ║"):
    iglog("  ║  del    — delete a key                ║"):
    iglog("  ║  view   — show current JSON           ║"):
    iglog("  ║  keys   — list all keys & types       ║"):
    iglog("  ║  save   — write JSON to a file        ║"):
    iglog("  ║  load   — read JSON keys from file    ║"):
    iglog("  ║  clear  — start over with empty doc   ║"):
    iglog("  ║  help   — show this message            ║"):
    iglog("  ║  q      — quit                         ║"):
    iglog("  ╚══════════════════════════════════════╝"):
    iglog(""):
    give 0:
]

// ===== Simple JSON line parser (key: value from our format) =====

fn load_json_file(text path, map m) -> int [
    try [
        let text raw = readfile(path):
        let list lines = split(raw, "\n"):
        let int i = 0:
        loop while i < len(lines) [
            let text ln = trim(lines{i}):
            // skip braces and empty lines
            when ln != "{" and ln != "}" and ln != "" [
                // find the colon separator
                let int colon_pos = find(ln, ":"):
                when colon_pos > 0 [
                    // extract key (strip quotes and whitespace)
                    let text raw_key = trim(sub(ln, 0, colon_pos)):
                    // remove surrounding quotes
                    when len(raw_key) >= 2 and raw_key{0} == "\"" [
                        raw_key = sub(raw_key, 1, len(raw_key) - 1):
                    ]
                    // extract value (strip trailing comma)
                    let text raw_val = trim(sub(ln, colon_pos + 1, len(ln))):
                    when len(raw_val) > 0 and raw_val{len(raw_val) - 1} == "," [
                        raw_val = sub(raw_val, 0, len(raw_val) - 1):
                    ]
                    raw_val = trim(raw_val):
                    // remove quotes from text values
                    when len(raw_val) >= 2 and raw_val{0} == "\"" [
                        raw_val = sub(raw_val, 1, len(raw_val) - 1):
                    ]
                    map_set(m, raw_key, raw_val):
                ]
            ]
            i = i + 1:
        ]
        iglog("  Loaded from: " + path):
    ]
    catch [
        iglog("  ERROR loading file: " + lasterror()):
    ]
    give 0:
]

// ===== Entry point =====

start [
    iglog(""):
    iglog("  ╔══════════════════════════════════════╗"):
    iglog("  ║       📄 Ignid JSON Saver v1.0       ║"):
    iglog("  ╠══════════════════════════════════════╣"):
    iglog("  ║  Build JSON documents interactively.  ║"):
    iglog("  ║  Type 'help' for commands.            ║"):
    iglog("  ╚══════════════════════════════════════╝"):
    iglog(""):

    let map doc = map_new():
    let int saved = 0:

    loop while true [
        let text cmd = ask("[json] > "):
        let text c = lower(trim(cmd)):

        when c == "q" or c == "quit" [ stop: ]

        when c == "help" [ show_json_help(): skip: ]

        when c == "add" [
            let text key = ask("  Key: "):
            when len(trim(key)) == 0 [
                iglog("  Key cannot be empty."):
                skip:
            ]
            let text val = ask("  Value: "):
            map_set(doc, trim(key), val):
            let text vtype = detect_type(val):
            iglog("  Added: " + key + " = " + val + "  [" + vtype + "]"):
            saved = 0:
            skip:
        ]

        when c == "del" [
            let list keys = map_keys(doc):
            when len(keys) == 0 [
                iglog("  Nothing to delete — document is empty."):
                skip:
            ]
            show_keys(doc):
            let text dk = ask("  Key to delete: "):
            when map_has(doc, dk) == 1 [
                // rebuild map without this key
                let map new_doc = map_new():
                let int di = 0:
                loop while di < len(keys) [
                    when keys{di} != dk [
                        map_set(new_doc, keys{di}, map_get_text(doc, keys{di})):
                    ]
                    di = di + 1:
                ]
                doc = new_doc:
                iglog("  Deleted key: " + dk):
                saved = 0:
            ]
            else [ iglog("  Key not found: " + dk): ]
            skip:
        ]

        when c == "view" [
            iglog(""):
            iglog(to_json(doc)):
            iglog(""):
            skip:
        ]

        when c == "keys" [
            show_keys(doc):
            skip:
        ]

        when c == "save" [
            let text path = ask("  Save to file (e.g. data.json): "):
            let text json = to_json(doc):
            try [
                writefile(path, json):
                iglog("  Saved " + totext(len(map_keys(doc))) + " keys to: " + path):
                saved = 1:
            ]
            catch [
                iglog("  ERROR saving: " + lasterror()):
            ]
            skip:
        ]

        when c == "load" [
            let text path = ask("  Load from file: "):
            load_json_file(path, doc):
            skip:
        ]

        when c == "clear" [
            doc = map_new():
            iglog("  Document cleared."):
            saved = 0:
            skip:
        ]

        iglog("  Unknown command: " + c + "  (type 'help' for options)"):
    ]

    // warn about unsaved changes
    when saved == 0 and len(map_keys(doc)) > 0 [
        let text save_now = ask("  You have unsaved changes. Save before exit? (y/n): "):
        when save_now == "y" [
            let text path = ask("  Save to file: "):
            try [
                writefile(path, to_json(doc)):
                iglog("  Saved to: " + path):
            ]
            catch [ iglog("  ERROR: " + lasterror()): ]
        ]
    ]

    iglog(""):
    iglog("  Goodbye!"):
]
