---
name: sym-prereview
description: |
  Repository-spezifische Checkliste fuer den Workflow-Schritt `PreReview Codex`
  in Symphony Elixir.
---

# Sym PreReview

Verwende diesen Skill `sym-prereview` als massgebliche Checkliste fuer `PreReview Codex` in
diesem Repository.

## Checkliste

1. `mix build`
2. `mix format`
3. `mix format --check-formatted`
4. `mix lint`
5. `codex review --uncommitted`

Fuehre die Checkliste strikt nacheinander aus. Falls es beim Review zu
Abweichungen kommt, behebe diese direkt. Wiederhole danach nur den
fehlgeschlagenen Schritt und setze anschliessend mit den folgenden Schritten
fort, statt die gesamte Checkliste neu zu starten.
