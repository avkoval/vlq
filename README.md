# vlq

Search [VictoriaLogs](https://docs.victoriametrics.com/victorialogs/) from Emacs, in the spirit of notmuch: a front page
with a search line and your saved queries (each with its current match count), results in a `logview-mode` buffer, the
same results in [lnav](https://lnav.org) with one key, and a command-line companion that shares the saved queries.

```
VictoriaLogs  http://logs.example.lan:9428

Search  (s) any LogsQL; queries without _time get the last 1h

Saved queries  RET run  l lnav  e edit  + add  d delete  g refresh
         3  mail-in-delivered   _time:7d SYSLOG_IDENTIFIER:stalwart _msg:="Message ingested"
        32  mail-in-smtp        _time:24h SYSLOG_IDENTIFIER:stalwart LISTENERID:smtp _msg:in(...)
       112  caddy               _time:24h _SYSTEMD_UNIT:caddy.service | unpack_json from _msg ...
       222  ssh-logins          _time:7d _SYSTEMD_UNIT:ssh.service "Accepted"
```

A results buffer, oldest line first, local time, application fields appended as `NAME=value`:

```
2026-10-21 10:39:56.741 NOTICE mail1/stalwart: SMTP MAIL FROM command  FROM=news@example.org REMOTEIP=203.0.113.25
2026-10-21 10:39:56.817 NOTICE mail1/stalwart: Mailbox does not exist  TO=nobody@example.com REMOTEIP=203.0.113.25
```

## Why

VictoriaLogs collects and stores (journald from several hosts, no agents, indexed, compressed, with retention), but its
web UI has no saved queries and little for reading. lnav and logview are excellent for reading, but don't collect or
store. vlq joins them: the server keeps the logs, saved queries are the bookmarks, and reading happens in Emacs or
lnav.

A saved query is a bookmark. A *pinned* one is a bookmark on an incident: its relative `_time:30m` is replaced by the
fixed `[start, end]` at the moment you pin it, so it fetches the same lines later (while the server still keeps them).

## Installation

Requirements: Emacs 29.1+, `curl`; optional: [logview](https://github.com/doublep/logview) (results buffers fall back
to `special-mode` without it), lnav, Python 3.12+ for `bin/vlq`.

```elisp
(use-package vlq
  :load-path "~/.emacs.d/vlq"
  :commands (vlq vlq-search))
```

Where the server is: `~/.config/vlq/endpoints` (`vlq-endpoints-file`), read by both `vlq.el` and `bin/vlq`, one
endpoint per line, tried in order:

```
# on the log server itself
http://127.0.0.1:9428
# the server's address on the local network
http://logs.example.lan:9428
# anywhere else: run curl on that SSH host (its own 127.0.0.1:9428)
ssh logs-host
```

The first endpoint that answers is used for the session (an `ssh` line is taken as is); `M-x vlq-reset-endpoint`
after changing networks. Without the file: `http://127.0.0.1:9428`. In Emacs, `vlq-endpoints` overrides the file.

For lnav: `lnav -i lnav/victorialogs_json.json`. Command line: link `bin/vlq` into your `PATH`.

## Usage

`M-x vlq` opens the front page:

| Key   | Action                                     |
|-------|--------------------------------------------|
| `RET` | run the saved query on this line           |
| `s`   | search: a saved name (completion) or LogsQL |
| `l`   | the query on this line in lnav             |
| `e`   | edit the saved query on this line          |
| `+`   | add a saved query                          |
| `d`   | delete the saved query on this line        |
| `g`   | redraw and recount                         |

In a results buffer (logview's own keys stay as they are — filters, `e`/`w`/`i` level views, navigation — so vlq's
keys are under `C-c`):

| Key       | Action                                                  |
|-----------|---------------------------------------------------------|
| `C-c C-r` | run the query again                                     |
| `C-c C-e` | edit the query and run it                               |
| `C-c C-s` | save the query under a name                             |
| `C-c C-p` | pin: save with the time range fixed to now              |
| `C-c C-l` | open the same lines in lnav                             |
| `C-c C-d` | all fields of the entry at point                        |
| `C-c C-h` | back to the front page                                  |

lnav runs in `vlq-terminal-command` (default `kitty --`) from a graphical frame, in vterm or a `term` buffer from a
terminal frame.

### Saved queries

`~/.config/vlq/queries` (`vlq-queries-file`), one per line, `#` comments:

```
mail-in-delivered: _time:7d SYSLOG_IDENTIFIER:stalwart _msg:="Message ingested"
stalwart-warn: _time:24h SYSLOG_IDENTIFIER:stalwart PRIORITY:<=4
caddy: _time:24h _SYSTEMD_UNIT:caddy.service | unpack_json from _msg fields (level, logger, msg) | format "<logger>: <msg>" as _msg | delete PRIORITY
```

Queries without a `_time` filter get `vlq-default-time` (1h). Results are the newest `vlq-limit` (20000) lines, shown
oldest first. Pipes are allowed; the last example turns Caddy's JSON lines into readable messages and lets Caddy's own
level decide the line's level.

### Command line

```
vlq @stalwart-warn                    run a saved query, open lnav
vlq '_time:24h _SYSTEMD_UNIT:ssh.service "Accepted"'
vlq -s name 'LogsQL'                  save, then run
vlq -p name 'LogsQL'                  pin, then run
vlq -l                                list saved queries
vlq -o 'LogsQL' > out.json            JSON lines to stdout
```

## Display details

- Level: from journald's `PRIORITY` (0–7 → EMERGENCY … DEBUG), else from a `level` field.
- Source: `host/SYSLOG_IDENTIFIER` (or the container name, unit, command).
- Extra fields: upper-case names (`vlq-shown-fields-regexp`), minus `vlq-hidden-fields`, with `vlq-field-order`
  first. Journald's own fields (`_PID`, `_SYSTEMD_UNIT`, …) are only in `C-c C-d`.
- The logview submode is named `vlq` (`TIMESTAMP LEVEL NAME:`, RFC 5424 levels, ISO 8601 with millis).

## Tests

```
emacs -Q --batch -L . -l test/vlq-test.el -f ert-run-tests-batch-and-exit
```

No server needed: query building, pinning, the saved-queries file, formatting and level mapping.

## License

MIT
