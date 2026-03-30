---
name: symphony-test
description:
  Lies den Skill `.codex/skills/sym-test/SKILL.md`, führe die dort definierten
  `Test (AI)`-Schritte aus, protokolliere jeden Test-Schritt im Codex Workpad
  als Checklistenpunkt, setze Fixes sofort um und starte den Test-Zyklus neu,
  bis der Workspace sauber ist oder `agent.max_turns` erreicht wurde.
---

# Symphony Test

Verwende diesen Skill, wenn ein Ticket den Status `Test (AI)` erreicht.

## Ziel

- Lies die repository-spezifischen Anweisungen aus dem Skill `sym-test` unter
  `.codex/skills/sym-test/SKILL.md`.
- Führe die dort definierte Test-Checkliste in der vorgegebenen Reihenfolge aus.
- Halte unter `### Test` jeden Test-Schritt als Checklistenpunkt mit kurzer Statusnotiz fest.
- Setze erforderliche Fixes sofort im selben Workspace um.
- Lasse dabei alle entstehenden Änderungen ungecommittet; automatische Commits bleiben in diesem Status verboten.
- Starte die Checkliste nach jedem Fix wieder von vorn.
- Stoppe erst, wenn alle Schritte ohne Abweichung durchlaufen oder `agent.max_turns` erreicht ist.

## Repository-spezifische Anweisungen

- Öffne zu Beginn `.codex/skills/sym-test/SKILL.md` und lies die Datei vollständig.
- Verwende den Skill als maßgebliche Quelle für die konkrete Test-Checkliste und ihre Reihenfolge.
- Erfinde keine fehlenden Test-Schritte aus früheren Repository-Konventionen.
- Wenn `.codex/skills/sym-test/SKILL.md` fehlt oder nicht lesbar ist, dokumentiere das im Workpad und stoppe statt eine Checkliste zu raten.

## Workpad-Aktualisierung

- Nutze den vorhandenen Kommentar `## Codex Workpad`.
- Spiegele die Schritte aus `.codex/skills/sym-test/SKILL.md` unter `### Test` als
  Checkliste in derselben Reihenfolge.
- Pflege mit diesem Skill ausschließlich den Abschnitt `### Test`; ändere `### Review` nicht.
- Pflege dort pro Schritt genau einen kurzen Eintrag, zum Beispiel:
  - `- [x] Führe make all aus: erfolgreich`
  - `- [ ] Führe <weiteren Testschritt> aus: Fehlerbild offen, Fix in Arbeit`
- Verwende `### Test` nicht als zeitgestempeltes Befehls- oder Ergebnislog.
- Halte Befehle, Ergebnisse und Fix-Notizen weiterhin kurz unter `### Verlauf` fest.
- Wenn du Code änderst, ergänze unter `### Verlauf` eine kurze Notiz, was behoben wurde und warum die Checkliste erneut gestartet wird.

## Test-Schleife

1. Lies `.codex/skills/sym-test/SKILL.md` und beginne mit dem ersten dort
   definierten Schritt.
2. Aktualisiere nach jedem Schritt zuerst den zugehörigen Checklistenpunkt unter `### Test` und dokumentiere Details im `### Verlauf`, bevor du weitermachst.
3. Wenn ein Schritt fehlschlägt oder konkrete Änderungen verlangt:
   - setze den Fix sofort um,
   - aktualisiere das Workpad mit Fehlerbild und Fix-Zusammenfassung,
   - starte die Checkliste wieder beim ersten in
     `.codex/skills/sym-test/SKILL.md` definierten Schritt.
4. Wenn während der Schleife lokale Fixes entstanden sind, lasse sie ungecommittet im Workspace bestehen.
5. Wenn alle Schritte in einem ununterbrochenen Durchlauf erfolgreich sind, ist der Testlauf abgeschlossen.
6. Wenn `agent.max_turns` erreicht ist, bevor ein sauberer Durchlauf abgeschlossen wurde, beende die Schleife, dokumentiere die verbleibenden Abweichungen im Workpad und stoppe ohne Statuswechsel.

## Abschlussbedingung

- Wenn der Testlauf erfolgreich abgeschlossen ist, verschiebe das Ticket von `Test (AI)` nach `Freigabe Final`. Offene lokale Git-Änderungen sind bei der Übergabe zulässig.
