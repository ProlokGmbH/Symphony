---
name: sym-review
description: |
  Repository-spezifische Checkliste fuer den Workflow-Schritt `Review Codex`
  in Symphony Elixir.
---

# Sym Review

Verwende diesen Skill `sym-review` als massgebliche Checkliste fuer `Review Codex` in
diesem Repository.

## Checkliste

1. `mix build`
2. `mix format`
3. `mix format --check-formatted`
4. `mix lint`
5. `codex review --uncommitted`

Fuehre die Checkliste strikt nacheinander aus. Falls es beim Review zu
Abweichungen kommt, behebe diese direkt. Ueberspringe nach einem Fix keine
spaeteren Schritte, sondern starte wieder bei Schritt 1.
