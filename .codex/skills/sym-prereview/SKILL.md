---
name: sym-prereview
description: |
  Repository-spezifische Checkliste fuer den Workflow-Schritt `PreReview Codex`
  innerhalb eines laufenden Symphony-Issue-Workflows in Symphony Elixir.
---

# Sym PreReview

Verwende diesen Skill `sym-prereview` nur als massgebliche Checkliste fuer
`PreReview Codex`, wenn er innerhalb des laufenden Symphony-Issue-Workflows
ueber `symphony-prereview` aufgerufen wurde.

## Checkliste

1. `make all`

Fuehre die Checkliste strikt nacheinander aus. Falls es beim Review zu
Abweichungen kommt, behebe diese direkt. Wiederhole danach nur den
fehlgeschlagenen Schritt und setze anschliessend mit den folgenden Schritten
fort, statt die gesamte Checkliste neu zu starten.
