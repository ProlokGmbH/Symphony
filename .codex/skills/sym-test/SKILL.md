---
name: sym-test
description: Repository-spezifische Test-Checkliste für Symphony Elixir.
---

# Sym Test

Nur über `symphony-test` verwenden.

## Checkliste

1. `make all`

`make all` verwendet den repo-lokalen Wrapper `scripts/mix-gate`. Keine
geerbten `SYMPHONY_*`-Runtime-Variablen manuell übernehmen und kein
dauerhaftes `mise trust` voraussetzen; der Wrapper vertraut eine vorhandene
`mise.toml` nur prozesslokal über `MISE_TRUSTED_CONFIG_PATHS`.

Bei Abweichungen direkt fixen und die Checkliste wieder bei Schritt 1 starten.
