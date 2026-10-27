# Ignid Examples

Three self-contained example programs showing what Ignid can do. Each one
compiles to a standalone `.exe` — no interpreter, no runtime, no dependencies.

## Examples

| Example | File | Description |
|---|---|---|
| **Calculator** | [`calculator.ig`](calculator.ig) | Interactive CLI calculator with history, memory, float support, and error handling |
| **JSON Saver** | [`json_saver.ig`](json_saver.ig) | Build key/value records and persist them as `.json` files |
| **File Tool** | [`file_tool.ig`](file_tool.ig) | Swiss-army-knife file utility — read, write, copy, search, and get stats |
| **Webengine** | [`webengine/`](webengine/) | Flask-style web framework and server: routes, HTML templates, static files of any type, debug mode, security hardening, a supervisor, and a 67-case attack test suite |

## How to Run

Make sure `ignid` is on your `PATH` (see the [Getting Started guide](https://github.com/endurasolution/ignid/blob/main/docs/GETTING_STARTED.md)), then:

```
ignid calculator.ig
ignid json_saver.ig
ignid file_tool.ig
```

Each program compiles instantly and runs as a native Windows executable.

## Prerequisites

- [Ignid](https://github.com/endurasolution/ignid) installed (Windows x86-64)
- NASM + MSVC link.exe (see the [Ignid README](https://github.com/endurasolution/ignid#installing) for setup)

## What You'll Learn

- **Variables & types** — `int`, `float`, `text`, `list`, `map`
- **Control flow** — `when`/`or`/`else`, `loop while`, `loop in`
- **Functions** — `fn`, `give` (return), recursion
- **Records** — `rec` (structs), field access, reference semantics
- **Error handling** — `try`/`catch`, `lasterror()`
- **File I/O** — `readfile`, `writefile`, `read_lines`, `write_lines`
- **Maps** — `map_new`, `map_set`, `map_get_text`, `map_keys`
- **Standard library** — string manipulation, math, list operations
