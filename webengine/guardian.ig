// guardian.ig — keeps a webengine site running.
//
//   guardian <site.exe> [port]
//
// Restarts the site immediately when it recycles itself (exit code 3), and
// after a short back-off if it crashes. Gives up after 5 failures in a row
// that each happen within 2 seconds of starting (port taken, missing exe, ...).
use "std.ig":

fn safe_arg(text s) -> int [
    when len(s) == 0 [ give 0: ]
    let int i = 0: let int n = len(s):
    loop while i < n [
        let int c = ord(s{i}):
        // nothing cmd.exe treats specially: no quotes, &, |, <, >, ^, %
        when c < 32 or c == 34 or c == 37 or c == 38 or c == 60 or c == 62 or c == 94 or c == 124 [ give 0: ]
        i = i + 1:
    ]
    give 1:
]

fn all_digits(text s) -> int [
    when len(s) == 0 or len(s) > 5 [ give 0: ]
    let int i = 0:
    loop while i < len(s) [
        let int c = ord(s{i}):
        when c < 48 or c > 57 [ give 0: ]
        i = i + 1:
    ]
    give 1:
]

start [
    when argc() < 1 [
        iglog.err("usage: guardian <site.exe> [port]"):
        quit(1):
    ]
    let text exe = argv(0):
    let text port = "8080":
    when argc() >= 2 [ port = argv(1): ]
    when safe_arg(exe) == 0 or ends_with(lower(exe), ".exe") == 0 [
        iglog.err("guardian: <site.exe> must be a plain path to an .exe"):
        quit(1):
    ]
    when all_digits(port) == 0 [
        iglog.err("guardian: port must be a number"):
        quit(1):
    ]
    // a bare name only runs from the current folder with an explicit .\ prefix
    when find(exe, "/") < 0 and find(exe, chr(92)) < 0 [ exe = "." + chr(92) + exe: ]
    let text cmd = "\"" + exe + "\" " + port:

    let int quick = 0: let int restarts = 0:
    loop while true [
        let int t0 = clock():
        let int rc = system(cmd):
        let int ran = clock() - t0:
        when rc == 3 [
            iglog("guardian: site recycled itself, restarting"):
            quick = 0:
            skip:
        ]
        restarts = restarts + 1:
        iglog.warn("guardian: site exited with code " + totext(rc) + " after " + totext(ran) +
                   "ms (restart #" + totext(restarts) + ")"):
        when ran < 2000 [ quick = quick + 1: ] else [ quick = 0: ]
        when quick >= 5 [
            iglog.err("guardian: 5 fast failures in a row, giving up (port in use? wrong path?)"):
            quit(1):
        ]
        // back off 1s, 2s, 3s... (ping is the one sleep every Windows box has)
        when quick > 0 [ system("ping -n " + totext(quick + 1) + " 127.0.0.1 >nul"): ]
    ]
]
