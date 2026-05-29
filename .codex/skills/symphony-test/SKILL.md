---
name: symphony-test
description:
  Führt im Status `Test (AI)` die repo-lokale `sym-test`-Checkliste inklusive
  Test-/Fix-Schleife aus.
---

# Symphony Test

Nur im Status `Test (AI)` verwenden. Pull/Rebase ist Aufgabe des aufrufenden
Workflows.

## Ablauf

- `<aktives-repo-root>/.codex/skills/sym-test/SKILL.md` vollständig lesen.
- Nur diese Checkliste und Reihenfolge verwenden; fehlende Datei im Workpad
  dokumentieren und stoppen.
- Fehlende Pull-Evidence im Workpad ergänzen.
- `### Test` pflegen, Details knapp in `### Verlauf`.

## Test-/Fix-Schleife

1. Mit dem ersten repo-lokalen Testschritt beginnen.
2. Nach jedem Schritt den zugehörigen `### Test`-Punkt aktualisieren.
3. Bei Fehlern Fix umsetzen, Workpad aktualisieren und wieder bei Schritt 1
   starten.
4. Lokale Fixes dürfen mit `<Issue-Key> Test (AI) Autocommit` plus kurzem Body
   committet werden.

## Abschluss

Wenn alle Schritte sauber sind, `### Test` und die bindenden Punkte in
`### Validierung` vollständig abhaken, nach `Merge (AI)` verschieben und den
Turn beenden. Bei `agent.max_turns` Abweichungen dokumentieren und ohne
Statuswechsel stoppen.
