# What the two backends actually publish about allowances

`rate-limits.jsonl` contains sanitized payloads captured from the CLIs. Their shapes are kept
because `AgentQuota` was derived from observed responses rather than a guess.

Line one was captured on 23 August 2026 from the installed `claude` binary, one turn of

    claude -p "Reply with the single word: ok" --output-format stream-json --verbose --model haiku

Line two has the same event shape after a warning threshold, adapted from
`session-basic.jsonl`.

Line three is Codex's `account/rateLimits/updated`, as recorded in `codex-turn.ndjson`.

Three facts follow, and all three are load-bearing.

Claude Code names one window per event and never sends two together, so what Bloom knows about a
Claude account accumulates over turns. It publishes `utilization` only after a warning threshold has
been passed, which is why usage is modelled as possibly unknown rather than as zero. And it has no
monthly window at all: `five_hour` and `seven_day` are the whole vocabulary observed.

Codex gives the window as a length in minutes rather than as a name, always carries `usedPercent`,
and calls its two slots `primary` and `secondary`, of which the second was null on the account
measured. It has no monthly window either.
