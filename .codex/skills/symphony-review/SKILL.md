---
name: symphony-review
description:
  Lies den Skill `.codex/skills/sym-review/SKILL.md`, führe die dort definierten
  `Review (AI)`-Schritte aus, protokolliere jeden Review-Schritt im Codex
  Workpad als Checklistenpunkt, setze Fixes sofort um und starte den Review-
  Zyklus neu, bis der Workspace sauber ist oder `agent.max_turns` erreicht
  wurde.
---

# Symphony Review

Verwende diesen Skill, wenn ein Ticket den Status `Review (AI)` erreicht.

## Ziel

- Lies die repository-spezifischen Anweisungen aus dem Skill `sym-review` unter
  `.codex/skills/sym-review/SKILL.md`.
- Führe die dort definierte Review-Checkliste in der vorgegebenen Reihenfolge aus.
- Halte unter `### Review` jeden Review-Schritt als Checklistenpunkt mit kurzer Statusnotiz fest.
- Setze erforderliche Fixes sofort im selben Workspace um.
- Wenn der Review-Zyklus Fixes erzeugt, committe den resultierenden Stand vor Abschluss dieses Status mit `symphony-commit` und veröffentliche ihn anschließend mit `symphony-push`, damit Branch und PR auf dem aktuellen Stand sind oder erstmals angelegt werden.
- Starte die Checkliste nach jedem Fix wieder von vorn.
- Stoppe erst, wenn alle Schritte ohne Abweichung durchlaufen oder `agent.max_turns` erreicht ist.

## Repository-spezifische Anweisungen

- Öffne zu Beginn `.codex/skills/sym-review/SKILL.md` und lies die Datei vollständig.
- Verwende den Skill als maßgebliche Quelle für die konkrete Review-Checkliste und ihre Reihenfolge.
- Erfinde keine fehlenden Review-Schritte aus früheren Repository-Konventionen.
- Wenn `.codex/skills/sym-review/SKILL.md` fehlt oder nicht lesbar ist, dokumentiere das im Workpad und stoppe statt eine Checkliste zu raten.

## Workpad-Aktualisierung

- Nutze den vorhandenen Kommentar `## Codex Workpad`.
- Spiegele die Schritte aus `.codex/skills/sym-review/SKILL.md` unter `### Review`
  als Checkliste in derselben Reihenfolge.
- Pflege mit diesem Skill ausschließlich den Abschnitt `### Review`; ändere `### Test` nicht.
- Pflege dort pro Schritt genau einen kurzen Eintrag, zum Beispiel:
  - `- [x] Führe make all aus: erfolgreich`
  - `- [ ] Führe codex review --uncommitted aus: Findings offen, Fix in Arbeit`
- Verwende `### Review` nicht als zeitgestempeltes Befehls- oder Ergebnislog.
- Halte Befehle, Ergebnisse und Fix-Notizen weiterhin kurz unter `### Verlauf` fest.
- Wenn du Code änderst, ergänze unter `### Verlauf` eine kurze Notiz, was behoben wurde und warum die Checkliste erneut gestartet wird.

## Review-Schleife

1. Lies `.codex/skills/sym-review/SKILL.md` und beginne mit dem ersten dort
   definierten Schritt.
2. Aktualisiere nach jedem Schritt zuerst den zugehörigen Checklistenpunkt unter `### Review` und dokumentiere Details im `### Verlauf`, bevor du weitermachst.
3. Wenn ein Schritt fehlschlägt oder konkrete Änderungen verlangt:
   - setze den Fix sofort um,
   - aktualisiere das Workpad mit Fehlerbild und Fix-Zusammenfassung,
   - starte die Checkliste wieder beim ersten in
     `.codex/skills/sym-review/SKILL.md` definierten Schritt.
4. Wenn während der Schleife lokale Fixes entstanden sind, committe den finalen Stand vor dem Abschluss dieses Status mit `symphony-commit` und veröffentliche ihn anschließend mit `symphony-push`.
5. Wenn alle Schritte in einem ununterbrochenen Durchlauf erfolgreich sind, ist das Review abgeschlossen.
6. Wenn `agent.max_turns` erreicht ist, bevor ein sauberer Durchlauf abgeschlossen wurde:
   - dokumentiere die verbleibenden Abweichungen im Workpad,
   - committe und veröffentliche zuvor entstandene lokale Fixes noch mit `symphony-commit` und `symphony-push`, sofern das innerhalb dieses Turns noch möglich ist,
   - übergib nur dann nach `Test (AI)`, wenn kein unveröffentlichter lokaler Review-Fix mehr offen ist; andernfalls stoppe ohne Statuswechsel.

## Abschlussbedingung

- Wenn die Schleife abgeschlossen ist, verschiebe das Ticket von `Review (AI)` nach `Test (AI)`.
- Lasse den Workspace vor der Übergabe nach `Test (AI)` nicht mit offenen lokalen Git-Änderungen zurück.
