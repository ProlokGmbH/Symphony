---
name: sym-review
description: |
  Repository-spezifische Checkliste fuer den Workflow-Schritt `Review Codex`
  innerhalb eines laufenden Symphony-Issue-Workflows in Symphony Elixir.
---

# Sym Review

Verwende diesen Skill `sym-review` nur als massgebliche Checkliste fuer
`Review Codex`, wenn er innerhalb des laufenden Symphony-Issue-Workflows ueber
`symphony-review` aufgerufen wurde.

## Checkliste

1. `make all`
2. `codex review --base origin/main`

Fuehre die Checkliste strikt nacheinander aus. Falls es beim Review zu
Abweichungen kommt, behebe diese direkt. Ueberspringe nach einem Fix keine
spaeteren Schritte, sondern starte wieder bei Schritt 1.
