# What `--mode` accepts, on every platform

One table, four implementations. It is repeated verbatim in the test suite of each, because the
only thing worse than a mode that does not parse is one that parses differently depending on which
machine typed it — a phone and a laptop disagreeing about what `summary` means is a bug nobody
would think to look for.

| Typed | Means | Why |
|---|---|---|
| `verbatim` | verbatim | |
| `raw`, `transcribe`, `none` | verbatim | the spellings people reach for |
| `rewrite` | rewrite, casual | a bare stage takes that stage's default |
| `rewrite:formal` | rewrite, formal | |
| `rewrite:concise` | rewrite, concise | |
| `rewrite:casual` | rewrite, casual | |
| `rewrite:` | rewrite, casual | an unfinished colon is not a style |
| `rewrite:verbatim` | rejected | verbatim is not a rewrite; `--mode verbatim` says it |
| `summary` | summary, brief | |
| `summary:brief` | summary, brief | |
| `summary:bullets` | summary, bullets | |
| `summary:actions` | summary, actions | |
| `summarise`, `summarize` | summary, brief | both spellings |
| `SUMMARY:Bullets` | summary, bullets | case is not significant |
| ` summary ` | summary, brief | surrounding space is not significant |
| `` (empty) | rejected | |
| `nonsense` | rejected | |
| `rewrite:nonsense` | rejected | a wrong style is not silently the default |

`rewrite:` and `summary:` used to differ: macOS took the default, Windows rejected it, Android
rejected it. Nothing depended on it, which is exactly why it went unnoticed.
