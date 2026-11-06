# sgcFSearch

sgcFSearch is a whole-disk file search tool for Windows, written in Delphi. It keeps an index of the
names of every file and folder on your fixed drives, answers queries in milliseconds while you type,
and stays current through the NTFS change journal. A small search bar opens with a global hotkey, a
command line client (`sgcfs`) gives the same results in a terminal, and a local named pipe API lets
other programs ask questions too.

The project is inspired by [scry](https://github.com/R-Hatim/scry) and by fsearch. It is an
independent implementation: no code was copied from either project.

## Features

- Name index of every fixed drive, built by a multi-threaded crawler on the NT directory API and saved to `names.idx` for fast restarts.
- Live updates: the NTFS USN journal is read at startup to catch up on changes made while the app was closed, and watched while it runs.
- Search bar with a global hotkey, ranked results with icons, filter chips, search history, open, show in folder and copy.
- Ranking that learns from the files you open or copy (frecency).
- Rich query syntax: name modifiers, path tokens, extension, type, size, date, scope, regex and sort filters.
- Content index of text files under the content folders (your user folder by default), with `grep:`, `regex:` and `sym:` content search.
- `sgcfs` command line client: search, JSON output, a JSON lines bridge, status, stop and show.
- Named pipe API (JSON lines) restricted to the current user.
- Tray icon with the index status, a Folders dialog, Start at login and the daemon log.
- Two downloads, both digitally signed: a per user installer (recommended) and a zip. No administrator rights needed.

## Install

Two downloads, both digitally signed by eSeGeCe:

- **Installer (recommended):** https://download.esegece.com/sgcFSearch_setup.exe. It installs per user into `%LOCALAPPDATA%\Programs\sgcFSearch` with no administrator rights, adds a Start menu entry, and offers two tasks, both on by default: start at login, and add `sgcfs` to the user PATH. Run it again to update. Uninstall from Settings, Apps. This removes the PATH and login entries and keeps `%LOCALAPPDATA%\sgcFSearch`.
- **Zip for a manual installation:** https://download.esegece.com/sgcFSearch.zip. It holds `sgcFSearch.exe`, `sgcfs.exe`, `sgcFSearch-Help.html` and `sgcFSearch-Help.pdf`. Unzip it to any folder you own and run `sgcFSearch.exe`.
  - `sgcfs install` puts the folder on the user PATH, and `sgcfs install --login` also starts sgcFSearch at login.
  - To uninstall, run `sgcfs uninstall`, quit the app from the tray, delete the folder, and optionally delete `%LOCALAPPDATA%\sgcFSearch`.

Do not use both ways side by side.

## Search syntax

All words must match the file or folder name (case-insensitive, AND semantics). Filters use `key:value`; unknown keys are searched as plain words.

| Syntax | Meaning |
|---|---|
| `word` | fuzzy, case-insensitive name match |
| `'exact` | whole name |
| `^prefix`, `suffix$`, `^both$` | name starts with, ends with, equals |
| `!word` | exclude names that match (combinable: `!^tmp`) |
| `"my file"` | double quotes group spaces |
| `*.pas`, `report*`, `a?c` | wildcards: `*` any run of characters, `?` one character, the pattern matches the whole name, no typo tolerance |
| `src\main`, `node_modules\` | path tokens: the last part matches the name, earlier parts match ancestor folder names in order |
| `ext:pas,dfm` | extension list, no dot, files only |
| `type:images,code` | documents, images, videos, audio, code, archives, apps, fonts, folders |
| `kind:file`, `kind:dir` | only files or only folders (`kind:folder` also works) |
| `in:C:\Projects`, `in:~` | scope to a folder and its descendants, repeatable (OR), `~` is your user folder |
| `path:text` | substring of the full path, repeatable (AND) |
| `size:>10mb`, `size:<1k`, `size:1mb..5mb`, `size:empty` | size filters, units b k kb m mb g gb t tb (1024 based) |
| `mtime:today`, `mtime:week`, `mtime:<7d`, `mtime:>2026-01-01`, `mtime:2026-10-01..2026-10-31` | modified time; `today`, `yesterday`, `week`, `month`, `year`, relative units h d w y |
| `re:<regex>` | regular expression on the name |
| `limit:N` | maximum number of results |
| `sort:name`, `sort:size`, `sort:date`, `sort:rank` | sort order; add `-asc` or `-desc` to force the direction, a leading `-` reverses the default |
| `grep:<text>` | content search: lines of indexed text files containing the text |
| `regex:<pattern>` | content search with a regular expression |
| `sym:<name>` | content search for a symbol (identifier) |

With a content filter, plain words in the same query still have to appear in the file name. Name filters such as `ext:` and `in:` apply to content results too.

Examples: `report ext:pdf mtime:month`, `^setup ext:exe in:~\Downloads`, `invoice*2026*.pdf in:~\Documents`, `grep:TODO ext:pas in:~\Projects`.

## Keyboard shortcuts

| Key | Action |
|---|---|
| `Alt+Shift+Space` | show or hide the search bar (configurable; falls back to `Win+Shift+F`, then `Ctrl+Alt+F`, when the hotkey is taken) |
| `Up`, `Down` | move the selection, or step through the search history |
| `PgUp`, `PgDn` | move the selection one page |
| `Enter` | open the selected item |
| `Ctrl+Enter` | show the selected item in its folder |
| `Ctrl+C` | copy the selected file (when no text is selected in the search box) |
| `Ctrl+Shift+C` | copy the full path |
| `Esc` | hide the search bar |

## Command line

`sgcfs` talks to the running app. A search starts `sgcFSearch.exe --background` from the same folder when it is not running yet.

| Command | Description |
|---|---|
| `sgcfs <words...> [-n <limit>] [-l\|--long] [--json]` | search; `-l` adds size, modified time and path, `--json` prints the raw response |
| `sgcfs -- <words...>` | search words that look like commands |
| `sgcfs stdio` | JSON lines bridge: stdin to sgcFSearch to stdout |
| `sgcfs status` | daemon state, index counters, roots and log file |
| `sgcfs stop` | stop the daemon (it saves the index first) |
| `sgcfs show [text]` | open the search bar, optionally with initial text |
| `sgcfs install [--login]` | add the sgcfs folder to the user PATH; `--login` also starts sgcFSearch at login |
| `sgcfs uninstall` | remove the login entry and the PATH entry |
| `sgcfs bench [n]` | time a fixed query set n times (default 20) |
| `sgcfs help` | usage |

A query given as one argument, such as `sgcfs "notepad ext:exe"`, is used exactly as typed, while with several arguments an argument that contains spaces stays one phrase, as in `sgcfs "annual report" in:~\Documents`. `sgcfs show` follows the same rule.

Results go to stdout, one path per line (folders end with `\`, content hits as `path:line: text`). The summary goes to stderr. Exit code 0 means results, 1 no results, 2 an error or no daemon.

`sgcFSearch.exe` accepts `--background` (start in the tray without showing the bar). A second instance does not start a new index: it asks the running one to show its search bar and exits.

## Pipe API

The app listens on `\\.\pipe\sgcFSearch-<user SID>` (the environment variable `SGCFSEARCH_PIPE` overrides the name). Only the current user can connect, remote clients are rejected. Each request is one UTF-8 JSON object per line and gets exactly one response line; a connection can send many requests. Every request may carry an `"id"`, which the response echoes.

| Request | Response |
|---|---|
| `{"id":1,"q":"report ext:pdf","limit":50}` | `{"id":1,"ok":true,"total":..,"ms":..,"content":false,"results":[{"path":..,"name":..,"dir":false,"size":..,"mtime":"2026-11-03T10:15:00Z","score":..,"match":[0,6]}]}` |
| `{"grep":"TODO","mode":"literal","q":"ext:pas in:~","limit":50}` | same shape with `"content":true`; each result adds `line`, `text` and `tmatch` (`mode` is `literal`, `words`, `regex` or `sym`) |
| `{"status":true}` | `state`, `files`, `folders`, `crawled`, `content_pending`, `content_indexed`, `pid`, `version`, `roots`, `log` |
| `{"use":"C:\\Docs\\report.pdf","kind":"open"}` | `{"ok":true}`, feeds the ranking (`kind` is `open` or `copy`) |
| `{"show":true,"q":"optional text"}` | `{"ok":true}`, shows the search bar |
| `{"stop":true}` | `{"ok":true}`, then the app saves its index and exits |

For name results `total` is the number of matches, also when the limit returns fewer rows; for content results `total` counts the hit lines found, up to the limit.

Errors come back as `{"id":..,"ok":false,"error":"text"}`.

## Configuration

Settings live in `%LOCALAPPDATA%\sgcFSearch\config.json`. The tray menu entry Folders... edits them and restarts the app in the background.

| Key | Default | Meaning |
|---|---|---|
| `drives` | `[]` | drives to index, for example `["C:\\","D:\\"]`; empty means every fixed drive |
| `roots` | `["~"]` | content folders whose text files are indexed for `grep:`, `regex:` and `sym:`; `~` is your user folder |
| `skip` | `[]` | folders the crawler never opens |
| `hotkey` | `"Alt+Shift+Space"` | global hotkey of the search bar: modifiers `Ctrl`, `Alt`, `Shift`, `Win` plus a letter, digit, `F1` to `F24` or `Space` |
| `content_max_size_mb` | `16` | files larger than this are not content indexed |

The environment variable `SGCFSEARCH_HOME` replaces the data folder (used by the tests).

## Data files

All files are in the data folder, `%LOCALAPPDATA%\sgcFSearch` by default.

| File | Content |
|---|---|
| `config.json` | settings |
| `names.idx` | name index with the NTFS journal positions, saved every 5 minutes when changed and on exit |
| `content.idx` | content index of the content folders |
| `usage.json` | open and copy counts for the ranking |
| `history.json` | search bar history |
| `daemon.log` | log file, rotated at 2 MB |

## Building

Requirements: Delphi 13 (Studio 37.0) for Win64. The code uses only the RTL and the VCL.

| Command | Purpose |
|---|---|
| `build\build.bat [Debug\|Release]` | builds every project under `App`, `CLI` and `Tests` for Win64 |
| `build\_msb.bat <project.dproj> Win64 [Debug\|Release]` | builds one project, the log goes to `build\logs` |
| `build\run_tests.bat` | runs every `bin\Win64\Debug\Test_*.exe` and prints one line per test |

Executables go to `bin\Win64\<Config>`. To make the release zip, build `App\sgcFSearch.dproj` and `CLI\sgcfs.dproj` in Release and zip the two executables together with `sgcFSearch-Help.html` and `sgcFSearch-Help.pdf` from `docs\`.

The app icon is generated by `assets\make_icon.ps1`.

## Requirements

- Windows 10 version 1809 or later, or Windows 11, 64-bit.
- NTFS volumes for the live catch-up through the change journal. Other file systems are indexed by the crawler, without the journal catch-up.

Copyright (C) 2026 eSeGeCe, https://www.esegece.com
