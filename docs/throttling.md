# Throttling: `Limits/`

The throttle surveys in `Tests/fixtures/` are the evidence for these rules
([testing.md](testing.md)).

- **`CPULimits`** sorts what is limiting the CPU into `LimitKind`s, from least to worst: normal
  (part of how turbo works, or not documented), power, thermal, macOS, and PROCHOT. The worst
  kind names the state.
- **`LimitBits`** holds the bit layouts by generation, chosen by `hw.cpufamily` as xnu does: 0x64F
  in Skylake's layout for the Skylake, Kaby Lake (Coffee Lake included), Ice Lake and Comet Lake
  families, and 0x690 in Haswell's for any other. Family codes aren't ordered, so it's a list,
  not a comparison.
- **`Limit+Meanings`** holds the tooltip text.

## Decisions, not to undo

- **Only the register's low 16 bits count.** They hold the current limit reasons. The high 16 log
  reasons since they were last cleared, and fill with brief limits even at idle. powermetrics'
  `perf_limit_reasons` mixes both halves.
- **macOS's own limits are taken as reported.** A hot Mac is often slowed by macOS lowering its
  speed limit while the processor gives no reason.
