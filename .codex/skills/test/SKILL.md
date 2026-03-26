---
name: test
description: |
  Repository-spezifische Checkliste fuer den Workflow-Schritt `Test Codex`
  in Symphony Elixir.
---

# Test

Verwende diesen Skill als massgebliche Checkliste fuer `Test Codex` in diesem
Repository.

## Checkliste

1. `mix test --cover`
2. `mix test`

Fuehre die Checkliste strikt nacheinander aus. Falls es beim Test zu
Abweichungen kommt, behebe diese direkt. Ueberspringe nach einem Fix keine
spaeteren Schritte, sondern starte wieder bei Schritt 1.
