---
name: sym-test
description: |
  Repository-spezifische Checkliste fuer den Workflow-Schritt `Test Codex`
  innerhalb eines laufenden Symphony-Issue-Workflows in Symphony Elixir.
---

# Sym Test

Verwende diesen Skill `sym-test` nur als massgebliche Checkliste fuer
`Test Codex`, wenn er innerhalb des laufenden Symphony-Issue-Workflows ueber
`symphony-test` aufgerufen wurde.

## Checkliste

1. `make all`

Fuehre die Checkliste strikt nacheinander aus. Falls es beim Test zu
Abweichungen kommt, behebe diese direkt. Ueberspringe nach einem Fix keine
spaeteren Schritte, sondern starte wieder bei Schritt 1.
