---
name: symphony-review
description:
  Lies innerhalb eines laufenden Symphony-Issue-Workflows den Skill
  `sym-review` aus dem aktuell bearbeiteten Repository/Worktree, führe die dort definierten
  `Review (AI)`-Schritte aus, protokolliere jeden Review-Schritt im Codex
  Workpad als Checklistenpunkt, setze Fixes sofort um und starte den Review-
  Zyklus neu, bis der Workspace sauber ist oder `agent.max_turns` erreicht
  wurde.
---

# Symphony Review

Verwende diesen Skill nur, wenn ein Ticket innerhalb des laufenden
Symphony-Issue-Workflows den Status `Review (AI)` erreicht.

## Ziel

- Lies die repository-spezifischen Anweisungen aus dem Skill `sym-review` unter
  `<aktives-repo-root>/.codex/skills/sym-review/SKILL.md`.
- Führe die dort definierte Review-Checkliste in der vorgegebenen Reihenfolge aus.
- Halte unter `### Review` jeden Review-Schritt als Checklistenpunkt mit kurzer Statusnotiz fest.
- Setze erforderliche Fixes sofort im selben Workspace um.
- Lasse dabei alle nach dem Einstieg entstehenden Änderungen ungecommittet; der einmalige Einstiegssnapshot `Review (AI) Autocommit` beim ersten Eintritt wird vom Workflow vor der Schleife erzeugt, weitere automatische Commits bleiben verboten.
- Starte die Checkliste nach jedem Fix wieder von vorn.
- Stoppe erst, wenn alle Schritte ohne Abweichung durchlaufen oder `agent.max_turns` erreicht ist.
- Führe keine zusätzlichen Review-Schritte aus, die hier nicht dokumentiert sind. Halte dich strikt an die Checkliste. Arbeite nur die dort vorgegebenen Punkte ab.
- Wenn du einen verpflichtenden read-only Review-Subagenten startest, dann isoliert mit `fork_context: false` und nur mit einem engen Review-Auftrag statt mit dem vollständigen Ticket-, Workflow- oder Workpad-Kontext.
- Wenn ein vorgeschriebener read-only Review-Subagent läuft, warte auf dessen finale Abschlussausgabe. Nutze dafür `wait_agent` mit langem Timeout; ein Timeout ist kein Review-Ergebnis.
- Nach einem `wait_agent`-Timeout darfst du weder Findings behaupten noch die Checkliste neu starten noch einen noch laufenden Review-Subagenten mit `close_agent` beenden.
- Wenn die erforderliche Isolation des Pflicht-Subagenten in der aktuellen Session nicht möglich ist, bleibt der Review-Schritt offen; ersetze ihn nicht durch ein lokales Review und verschiebe das Ticket nicht weiter.

## Repository-spezifische Anweisungen

- Öffne zu Beginn den repo-lokalen Skill `sym-review` unter
  `<aktives-repo-root>/.codex/skills/sym-review/SKILL.md` und lies die Datei vollständig.
- Wenn der aktuelle Prompt einen Abschnitt `Zusätzliche Review-Hinweise` enthält, übernimm diesen Hinweis in deinen Arbeitskontext und reiche ihn unter derselben Überschrift an den repo-lokalen `sym-review`-Skill weiter.
- Verwende den Skill als maßgebliche Quelle für die konkrete Review-Checkliste und ihre Reihenfolge.
- Erfinde keine fehlenden Review-Schritte aus früheren Repository-Konventionen.
- Suche den repo-lokalen Skill immer im aktuell bearbeiteten Repository/Worktree und nicht relativ zu diesem `symphony-review`-Verzeichnis.
- Wenn `<aktives-repo-root>/.codex/skills/sym-review/SKILL.md` fehlt oder nicht lesbar ist, dokumentiere das im Workpad und stoppe statt eine Checkliste zu raten.
- Falls du selbst nur als isolierter read-only Review-Subagent ohne Ticket- und Workpad-Verantwortung gestartet wurdest, führe diesen Skill nicht als `Review (AI)`-Hauptschleife aus.

## Workpad-Aktualisierung

- Nutze den vorhandenen Kommentar `## Codex Workpad`.
- Spiegele die Schritte aus `<aktives-repo-root>/.codex/skills/sym-review/SKILL.md` unter `### Review`
  als Checkliste in derselben Reihenfolge.
- Pflege mit diesem Skill ausschließlich den Abschnitt `### Review`; ändere `### Test` nicht.
- Pflege dort pro Schritt genau einen kurzen Eintrag, zum Beispiel:
  - `- [x] Führe make all aus: erfolgreich`
  - `- [ ] Führe den Review-Subagenten gegen den aktuellen Worktree aus: Findings offen, Fix in Arbeit`
- Verwende `### Review` nicht als zeitgestempeltes Befehls- oder Ergebnislog.
- Halte Befehle, Ergebnisse und Fix-Notizen weiterhin kurz unter `### Verlauf` fest.
- Wenn du Code änderst, ergänze unter `### Verlauf` eine kurze Notiz, was behoben wurde und warum die Checkliste erneut gestartet wird.

## Review-Schleife

1. Lies `<aktives-repo-root>/.codex/skills/sym-review/SKILL.md` und beginne mit dem ersten dort
   definierten Schritt.
2. Aktualisiere nach jedem Schritt zuerst den zugehörigen Checklistenpunkt unter `### Review` und dokumentiere Details im `### Verlauf`, bevor du weitermachst.
3. Wenn ein Schritt fehlschlägt oder konkrete Änderungen verlangt:
   - setze den Fix sofort um,
   - aktualisiere das Workpad mit Fehlerbild und Fix-Zusammenfassung,
   - starte die Checkliste wieder beim ersten in
     `<aktives-repo-root>/.codex/skills/sym-review/SKILL.md` definierten Schritt.
4. Wenn während der Schleife lokale Fixes entstanden sind, lasse sie ungecommittet im Workspace bestehen.
5. Wenn alle Schritte in einem ununterbrochenen Durchlauf erfolgreich sind, ist das Review abgeschlossen.
6. Wenn `agent.max_turns` erreicht ist, bevor ein sauberer Durchlauf abgeschlossen wurde:
   - dokumentiere die verbleibenden Abweichungen im Workpad,
   - lasse zuvor entstandene lokale Fixes ungecommittet im Workspace,
   - stoppe ohne Statuswechsel.
7. Wenn `wait_agent` für einen laufenden Pflicht-Subagenten nur `timed_out` zurückgibt oder kein finales Ergebnis enthält:
   - lasse den zugehörigen Punkt unter `### Review` offen,
   - warte weiter im aktuellen Turn oder im nächsten Fortsetzungsturn,
   - schließe den Subagenten nicht vorzeitig,
   - behandle den Review-Schritt bis zu einer finalen Antwort nicht als abgeschlossen.

## Abschlussbedingung

- Wenn die Schleife abgeschlossen ist, verschiebe das Ticket von `Review (AI)` nach `Freigabe Review`.
- Offene lokale Git-Änderungen sind bei der Übergabe nach `Freigabe Review` zulässig.
