// calculator.ig — Full-featured interactive calculator in Ignid
//
// Features:
//   - Basic arithmetic: +, -, *, /, %
//   - Float support via 'f' mode toggle
//   - Memory store/recall (ms, mr, mc)
//   - Expression history (last 10)
//   - Error handling for division by zero & bad input
//
// Run:  ignid calculator.ig

use "d:/Ignid/std.ig":

// ===== History tracking =====

rec History [ list entries: int count: ]

fn history_new() -> History [
    give History({}, 0):
]

fn history_add(History h, text entry) -> int [
    push(h.entries, entry):
    h.count = h.count + 1:
    // keep only last 10
    when h.count > 10 [
        h.entries = list_slice(h.entries, h.count - 10, h.count):
        h.count = 10:
    ]
    give 0:
]

fn history_show(History h) -> int [
    when h.count == 0 [
        iglog("  (no history yet)"):
        give 0:
    ]
    let int i = 0:
    loop while i < h.count [
        iglog("  " + totext(i + 1) + ". " + h.entries{i}):
        i = i + 1:
    ]
    give 0:
]

// ===== Calculator logic =====

fn calc_int(int a, text op, int b) -> text [
    when op == "+" [ give totext(a + b): ]
    when op == "-" [ give totext(a - b): ]
    when op == "*" [ give totext(a * b): ]
    when op == "/" [
        when b == 0 [ give "ERROR: division by zero": ]
        give totext(a / b):
    ]
    when op == "%" [
        when b == 0 [ give "ERROR: modulo by zero": ]
        give totext(a % b):
    ]
    give "ERROR: unknown operator '" + op + "'":
]

fn calc_float(float a, text op, float b) -> text [
    when op == "+" [ give totext(a + b): ]
    when op == "-" [ give totext(a - b): ]
    when op == "*" [ give totext(a * b): ]
    when op == "/" [
        when b == 0.0 [ give "ERROR: division by zero": ]
        give totext(a / b):
    ]
    when op == "%" [
        when b == 0.0 [ give "ERROR: modulo by zero": ]
        give totext(a % b):
    ]
    give "ERROR: unknown operator '" + op + "'":
]

// ===== Help text =====

fn show_help() -> int [
    iglog(""):
    iglog("  ╔══════════════════════════════════════╗"):
    iglog("  ║        Ignid Calculator — Help       ║"):
    iglog("  ╠══════════════════════════════════════╣"):
    iglog("  ║  Operators:  +  -  *  /  %           ║"):
    iglog("  ║  Commands:                            ║"):
    iglog("  ║    float  — toggle float mode         ║"):
    iglog("  ║    ms     — memory store last result  ║"):
    iglog("  ║    mr     — memory recall             ║"):
    iglog("  ║    mc     — memory clear              ║"):
    iglog("  ║    hist   — show calculation history   ║"):
    iglog("  ║    help   — show this message          ║"):
    iglog("  ║    q      — quit                       ║"):
    iglog("  ╚══════════════════════════════════════╝"):
    iglog(""):
    give 0:
]

// ===== Entry point =====

start [
    iglog(""):
    iglog("  ╔══════════════════════════════════════╗"):
    iglog("  ║       🔢 Ignid Calculator v1.0       ║"):
    iglog("  ╠══════════════════════════════════════╣"):
    iglog("  ║  Type 'help' for commands.            ║"):
    iglog("  ║  Type 'q' to quit.                    ║"):
    iglog("  ╚══════════════════════════════════════╝"):
    iglog(""):

    let int float_mode = 0:
    let int memory = 0:
    let float memory_f = 0.0:
    let text last_result = "0":
    let History hist = history_new():

    loop while true [
        // mode indicator
        let text mode_tag = "[int]":
        when float_mode == 1 [ mode_tag = "[float]": ]

        let text input_a = ask(mode_tag + " First number (or command): "):

        // ---- commands ----
        when input_a == "q" or input_a == "quit" [ stop: ]
        when input_a == "help" [ show_help(): skip: ]
        when input_a == "hist" [
            iglog("  -- History --"):
            history_show(hist):
            skip:
        ]
        when input_a == "float" [
            when float_mode == 0 [ float_mode = 1: iglog("  Switched to FLOAT mode."): ]
            else                 [ float_mode = 0: iglog("  Switched to INT mode."): ]
            skip:
        ]
        when input_a == "ms" [
            when float_mode == 1 [
                try [ memory_f = tofloat(last_result): iglog("  Memory stored:", last_result): ]
                catch [ iglog("  Cannot store — last result was not a number."): ]
            ]
            else [
                try [ memory = toint(last_result): iglog("  Memory stored:", last_result): ]
                catch [ iglog("  Cannot store — last result was not a number."): ]
            ]
            skip:
        ]
        when input_a == "mr" [
            when float_mode == 1 [ iglog("  Memory:", memory_f): ]
            else                 [ iglog("  Memory:", memory): ]
            skip:
        ]
        when input_a == "mc" [
            memory = 0: memory_f = 0.0:
            iglog("  Memory cleared."):
            skip:
        ]

        // ---- calculation ----
        let text op = ask(mode_tag + " Operator (+, -, *, /, %): "):
        let text input_b = ask(mode_tag + " Second number: "):

        let text answer = "":

        when float_mode == 1 [
            try [
                let float fa = tofloat(input_a):
                let float fb = tofloat(input_b):
                answer = calc_float(fa, op, fb):
            ]
            catch [
                answer = "ERROR: " + lasterror():
            ]
        ]
        else [
            try [
                let int ia = toint(input_a):
                let int ib = toint(input_b):
                answer = calc_int(ia, op, ib):
            ]
            catch [
                answer = "ERROR: " + lasterror():
            ]
        ]

        iglog("  => " + answer):
        last_result = answer:
        history_add(hist, input_a + " " + op + " " + input_b + " = " + answer):
    ]

    iglog(""):
    iglog("  Goodbye!"):
]
