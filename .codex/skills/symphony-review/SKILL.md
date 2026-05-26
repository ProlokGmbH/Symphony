---
name: symphony-review
description:
  Führt im Status `Review (AI)` die repo-lokale `sym-review`-Checkliste
  inklusive Review-/Fix-Schleife aus.
---

# Symphony Review

Nur im Status `Review (AI)` verwenden. Pull und der einmalige
`<Issue-Key> Review (AI) Autocommit` passieren vor dieser Schleife.

## Ablauf

- `<aktives-repo-root>/.codex/skills/sym-review/SKILL.md` vollständig lesen.
- Vorhandene `Zusätzliche Review-Hinweise` unverändert weiterreichen.
- Nur die repo-lokale Checkliste und Reihenfolge verwenden; fehlende Datei im
  Workpad dokumentieren und stoppen.
- Isolierte read-only Review-Subagenten abwarten; ein Timeout ist kein Ergebnis.
- `### Review` pflegen, Details knapp in `### Verlauf`.

## Review-/Fix-Schleife

1. Mit dem ersten repo-lokalen Schritt beginnen.
2. Nach jedem Schritt den zugehörigen `### Review`-Punkt aktualisieren.
3. Bei Fehlern oder Findings:
   - Review-Subagent-Findings, die behandelt werden sollen, vor den Fixes als
     separaten Linear-Issue-Kommentar posten.
   - Fixes selbst im aktuellen Workspace umsetzen.
   - nach den Änderungen aus Subagent-Findings einen separaten
     Linear-Issue-Kommentar mit Einordnung, Zweck und
     Finding-zu-Änderung-Zuordnung posten.
   - Workpad aktualisieren und die Checkliste wieder bei Schritt 1 starten.
4. Lokale Fixes bleiben ungecommittet.

## Abschluss

Wenn alle Schritte in einem ununterbrochenen Durchlauf sauber sind, der
Review-Subagent `Keine Findings.` geliefert hat und der Workspace nach dem
Review sauber ist, direkt nach `Test (AI)` verschieben. Wenn Findings behandelt
wurden, Review-Fixes entstanden sind, der Workspace nach dem Review Änderungen
enthält oder das No-Findings-Signal nicht eindeutig ist, greift der reguläre
Review-Handoff: grundsätzlich `Freigabe Review`, aber `--yolo` und das Label
`Skip "Freigabe Review"` überspringen diesen Freigabepunkt weiterhin auch bei
Findings oder Änderungen. Bei `agent.max_turns` Abweichungen dokumentieren und
ohne Statuswechsel stoppen.
