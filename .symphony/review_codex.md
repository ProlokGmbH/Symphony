## Codex Review

Führe die folgenden Schritte im Rahmen des `Review Codex` Workflow-Schritts aus:

1. `mix build`
2. `mix format`
3. `mix format --check-formatted`
4. `mix lint`
5. `codex review --base origin/main`

Führe die Checkliste strikt nacheinander aus. Falls es beim Review zu Abweichungen kommt, behebe diese direkt. Überspringe nach einem Fix keine späteren Schritte, sondern starte wieder bei Schritt 1.
