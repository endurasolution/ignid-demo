// file_tool.ig — File reading & writing multi-tool in Ignid
//
// Features:
//   - Write text to a file (create or overwrite)
//   - Append text to an existing file
//   - Read and display file contents
//   - Show line count, word count, character count
//   - Search for a word/phrase in a file
//   - Copy a file to a new path
//   - Show numbered lines (like `cat -n`)
//   - Find & replace text in a file
//
// Run:  ignid file_tool.ig

use "d:/Ignid/std.ig":

// ===== Word counter =====

fn count_words(text content) -> int [
    let int count = 0:
    let int in_word = 0:
    let int i = 0: let int n = len(content):
    loop while i < n [
        let text ch = content{i}:
        when is_space(ch) == 1 [
            when in_word == 1 [
                count = count + 1:
                in_word = 0:
            ]
        ]
        else [ in_word = 1: ]
        i = i + 1:
    ]
    // last word if text doesn't end with whitespace
    when in_word == 1 [ count = count + 1: ]
    give count:
]

// ===== Search for a needle in file content =====

fn search_in_file(text content, text needle) -> int [
    let list lines = split(content, "\n"):
    let int n = len(lines): let int matches = 0:
    let int i = 0:
    loop while i < n [
        when contains_str(lines{i}, needle) == 1 [
            iglog("  line " + totext(i + 1) + ": " + trim(lines{i})):
            matches = matches + 1:
        ]
        i = i + 1:
    ]
    give matches:
]

// ===== Show numbered lines =====

fn show_numbered(text content) -> int [
    let list lines = split(content, "\n"):
    let int n = len(lines): let int i = 0:
    let int width = len(totext(n)):
    loop while i < n [
        let text num = pad_left(totext(i + 1), width, " "):
        iglog("  " + num + " | " + lines{i}):
        i = i + 1:
    ]
    give n:
]

// ===== File copy =====

fn copy_file(text src, text dst) -> int [
    try [
        let text content = readfile(src):
        writefile(dst, content):
        iglog("  Copied: " + src + " -> " + dst):
        iglog("  (" + totext(len(content)) + " bytes)"):
        give 0:
    ]
    catch [
        iglog("  ERROR: " + lasterror()):
        give 1:
    ]
]

// ===== Find & replace in file =====

fn file_find_replace(text path, text old_text, text new_text) -> int [
    try [
        let text content = readfile(path):
        let int occurrences = str_count(content, old_text):
        when occurrences == 0 [
            iglog("  No occurrences of '" + old_text + "' found."):
            give 0:
        ]
        let text updated = replace(content, old_text, new_text):
        writefile(path, updated):
        iglog("  Replaced " + totext(occurrences) + " occurrence(s) of '" + old_text + "' with '" + new_text + "'."):
        give occurrences:
    ]
    catch [
        iglog("  ERROR: " + lasterror()):
        give 0:
    ]
]

// ===== Help =====

fn show_file_help() -> int [
    iglog(""):
    iglog("  ╔══════════════════════════════════════╗"):
    iglog("  ║     Ignid File Tool — Commands       ║"):
    iglog("  ╠══════════════════════════════════════╣"):
    iglog("  ║  write    — write text to a file      ║"):
    iglog("  ║  append   — append text to a file     ║"):
    iglog("  ║  read     — display file contents     ║"):
    iglog("  ║  lines    — show numbered lines       ║"):
    iglog("  ║  stats    — line/word/char counts     ║"):
    iglog("  ║  search   — find a word in a file     ║"):
    iglog("  ║  replace  — find & replace in file    ║"):
    iglog("  ║  copy     — copy file to new path     ║"):
    iglog("  ║  help     — show this message          ║"):
    iglog("  ║  q        — quit                       ║"):
    iglog("  ╚══════════════════════════════════════╝"):
    iglog(""):
    give 0:
]

// ===== Entry point =====

start [
    iglog(""):
    iglog("  ╔══════════════════════════════════════╗"):
    iglog("  ║     📁 Ignid File Tool v1.0          ║"):
    iglog("  ╠══════════════════════════════════════╣"):
    iglog("  ║  Read, write, search, and manage     ║"):
    iglog("  ║  files from the command line.         ║"):
    iglog("  ║  Type 'help' for commands.            ║"):
    iglog("  ╚══════════════════════════════════════╝"):
    iglog(""):

    loop while true [
        let text cmd = ask("[file] > "):
        let text c = lower(trim(cmd)):

        when c == "q" or c == "quit" [ stop: ]
        when c == "help" [ show_file_help(): skip: ]

        // ---- WRITE ----
        when c == "write" [
            let text path = ask("  File path: "):
            iglog("  Enter content (type END on its own line to finish):"):
            let text content = "":
            let int writing = 1:
            loop while writing == 1 [
                let text ln = ask("  > "):
                when ln == "END" [ writing = 0: ]
                else [
                    when len(content) > 0 [ content = content + "\n": ]
                    content = content + ln:
                ]
            ]
            try [
                writefile(path, content):
                let int wc = count_words(content):
                let list wlines = split(content, "\n"):
                iglog("  Written " + totext(len(wlines)) + " line(s), " + totext(wc) + " word(s) to: " + path):
            ]
            catch [ iglog("  ERROR: " + lasterror()): ]
            skip:
        ]

        // ---- APPEND ----
        when c == "append" [
            let text path = ask("  File path: "):
            let text existing = "":
            try [ existing = readfile(path): ]
            catch [ iglog("  (file doesn't exist yet, will create it)"): ]

            iglog("  Enter content to append (type END to finish):"):
            let text extra = "":
            let int appending = 1:
            loop while appending == 1 [
                let text ln = ask("  > "):
                when ln == "END" [ appending = 0: ]
                else [
                    when len(extra) > 0 [ extra = extra + "\n": ]
                    extra = extra + ln:
                ]
            ]
            try [
                let text final_content = existing:
                when len(existing) > 0 [ final_content = existing + "\n" + extra: ]
                else [ final_content = extra: ]
                writefile(path, final_content):
                iglog("  Appended to: " + path):
            ]
            catch [ iglog("  ERROR: " + lasterror()): ]
            skip:
        ]

        // ---- READ ----
        when c == "read" [
            let text path = ask("  File path: "):
            try [
                let text content = readfile(path):
                iglog(""):
                iglog("  --- " + path + " ---"):
                iglog(content):
                iglog("  --- end ---"):
                iglog(""):
            ]
            catch [ iglog("  ERROR: " + lasterror()): ]
            skip:
        ]

        // ---- NUMBERED LINES ----
        when c == "lines" [
            let text path = ask("  File path: "):
            try [
                let text content = readfile(path):
                iglog(""):
                iglog("  --- " + path + " ---"):
                let int n = show_numbered(content):
                iglog("  --- " + totext(n) + " line(s) ---"):
                iglog(""):
            ]
            catch [ iglog("  ERROR: " + lasterror()): ]
            skip:
        ]

        // ---- STATS ----
        when c == "stats" [
            let text path = ask("  File path: "):
            try [
                let text content = readfile(path):
                let list slines = split(content, "\n"):
                let int wc = count_words(content):
                let int cc = len(content):
                iglog(""):
                iglog("  File:       " + path):
                iglog("  Lines:      " + totext(len(slines))):
                iglog("  Words:      " + totext(wc)):
                iglog("  Characters: " + totext(cc)):
                iglog(""):
            ]
            catch [ iglog("  ERROR: " + lasterror()): ]
            skip:
        ]

        // ---- SEARCH ----
        when c == "search" [
            let text path = ask("  File path: "):
            let text needle = ask("  Search for: "):
            try [
                let text content = readfile(path):
                iglog("  Searching '" + path + "' for '" + needle + "'..."):
                let int matches = search_in_file(content, needle):
                when matches == 0 [ iglog("  No matches found."): ]
                else [ iglog("  " + totext(matches) + " matching line(s)."): ]
            ]
            catch [ iglog("  ERROR: " + lasterror()): ]
            skip:
        ]

        // ---- REPLACE ----
        when c == "replace" [
            let text path = ask("  File path: "):
            let text old_text = ask("  Find: "):
            let text new_text = ask("  Replace with: "):
            file_find_replace(path, old_text, new_text):
            skip:
        ]

        // ---- COPY ----
        when c == "copy" [
            let text src = ask("  Source file: "):
            let text dst = ask("  Destination: "):
            copy_file(src, dst):
            skip:
        ]

        iglog("  Unknown command: " + c + "  (type 'help' for options)"):
    ]

    iglog(""):
    iglog("  Goodbye!"):
]
