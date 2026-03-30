---
name: symphony-prereview
description:
  Lies den Skill `.codex/skills/sym-prereview/SKILL.md`, fuehre die dort
  definierten `PreReview (AI)`-Schritte aus, protokolliere jeden Review-Schritt
  im Codex Workpad als Checklistenpunkt, setze Fixes sofort um und wiederhole
  nach einem Fix nur den fehlgeschlagenen Schritt, bis der Workspace sauber ist
  oder `agent.max_turns` erreicht wurde.
---

# Symphony PreReview

Verwende diesen Skill, wenn ein Ticket den Status `PreReview (AI)` erreicht.

## Ziel

- Lies die repository-spezifischen Anweisungen aus dem Skill `sym-prereview` unter
  `.codex/skills/sym-prereview/SKILL.md`.
- Fuehre die dort definierte Review-Checkliste in der vorgegebenen Reihenfolge aus.
- Halte unter `### Review` jeden Review-Schritt als Checklistenpunkt mit kurzer Statusnotiz fest.
- Setze erforderliche Fixes sofort im selben Workspace um.
- Wiederhole nach einem Fix nur den fehlgeschlagenen Schritt und setze danach mit
  den folgenden Schritten fort.
- Stoppe erst, wenn alle Schritte ohne Abweichung durchlaufen oder `agent.max_turns` erreicht ist.

## Repository-spezifische Anweisungen

- Oeffne zu Beginn `.codex/skills/sym-prereview/SKILL.md` und lies die Datei vollstaendig.
- Verwende den Skill als massgebliche Quelle fuer die konkrete PreReview-Checkliste und ihre Reihenfolge.
- Erfinde keine fehlenden Review-Schritte aus frueheren Repository-Konventionen.
- Wenn `.codex/skills/sym-prereview/SKILL.md` fehlt oder nicht lesbar ist, dokumentiere das im Workpad und stoppe statt eine Checkliste zu raten.

## Workpad-Aktualisierung

- Nutze den vorhandenen Kommentar `## Codex Workpad`.
- Spiegele die Schritte aus `.codex/skills/sym-prereview/SKILL.md` unter `### Review`
  als Checkliste in derselben Reihenfolge.
- Pflege mit diesem Skill ausschliesslich den Abschnitt `### Review`; aendere `### Test` nicht.
- Pflege dort pro Schritt genau einen kurzen Eintrag, zum Beispiel:
  - `- [x] Fuehre make all aus: erfolgreich`
  - `- [ ] Fuehre codex review --uncommitted aus: Findings offen, Fix in Arbeit`
- Verwende `### Review` nicht als zeitgestempeltes Befehls- oder Ergebnislog.
- Halte Befehle, Ergebnisse und Fix-Notizen weiterhin kurz unter `### Verlauf` fest.
- Wenn du Code aenderst, ergaenze unter `### Verlauf` eine kurze Notiz, was behoben wurde und welcher Schritt jetzt erneut ausgefuehrt wird.

## PreReview-Schleife

1. Lies `.codex/skills/sym-prereview/SKILL.md` und beginne mit dem ersten dort definierten Schritt.
2. Aktualisiere nach jedem Schritt zuerst den zugehoerigen Checklistenpunkt unter `### Review` und dokumentiere Details im `### Verlauf`, bevor du weitermachst.
3. Wenn ein Schritt fehlschlaegt oder konkrete Aenderungen verlangt:
   - setze den Fix sofort um,
   - aktualisiere das Workpad mit Fehlerbild und Fix-Zusammenfassung,
   - wiederhole nur den fehlgeschlagenen Schritt,
   - setze danach mit den verbleibenden Schritten in Reihenfolge fort.
4. Wenn alle Schritte in einem vollstaendigen Durchlauf erfolgreich sind, ist das PreReview abgeschlossen.
5. Wenn `agent.max_turns` erreicht ist, bevor ein sauberer Durchlauf abgeschlossen wurde, beende die Schleife, dokumentiere die verbleibenden Abweichungen im Workpad und uebergib nach `Freigabe Implementierung`.

## Abschlussbedingung

- Wenn die Schleife abgeschlossen ist, verschiebe das Ticket von `PreReview (AI)` nach `Freigabe Implementierung`.
- Erstelle keine Commits. Der manuelle Commit-Schritt bleibt beim Entwickler im Status `Freigabe Implementierung`.
