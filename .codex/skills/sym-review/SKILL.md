---
name: sym-review
description: |
  Repository-spezifische Checkliste fuer den Workflow-Schritt `Review Codex`
  innerhalb eines laufenden Symphony-Issue-Workflows in Symphony Elixir.
---

# Sym Review

Verwende diesen Skill `sym-review` als massgebliche Checkliste fuer
`Review (AI)` in diesem Repository.

## Checkliste

1. `make all`
2. Starte einen read-only Review-Subagenten fuer den aktuellen Worktree gegen `origin/main` und verwende dessen Ausgabe ausschliesslich als Grundlage fuer deine eigenen Fixes.
   - Nutze den in der aktuellen Session zulaessigen Delegationspfad fuer diesen Pflicht-Review.
   - Starte den Pflicht-Subagenten isoliert mit `fork_context: false`.
   - Verwende dafür niemals `agent_type: "explorer"`. Der Review-Lauf braucht den normalen `default`-Agenten mit `reasoning_effort: "high"`, nicht einen Explorer-basierten Kurzpfad.
   - Verwende dafuer das staerkste in der Session verfuegbare Frontier-Modell oder andernfalls das geerbte Standardmodell; vermeide fest verdrahtete Modellnamen.
   - Übergib dem Subagenten nur den engen read-only Review-Auftrag und nötige `Zusätzliche Review-Hinweise`, aber nicht den vollständigen Ticket-, Workflow- oder Workpad-Kontext des Hauptagenten.
   - Weise den Subagenten an, alle Änderungen im aktuellen Worktree gegen `origin/main` zu berücksichtigen: Branch-Commits, gestagte Änderungen, ungestagte Änderungen und untracked Dateien.
   - Übergib zusätzliche Review-Hinweise aus dem aktuellen Prompt unter der Überschrift `Zusätzliche Review-Hinweise`, wenn solche Hinweise vorhanden sind.
   - Weise den Subagenten explizit an, strikt read-only zu bleiben: keine Dateien ändern, keine Commits erzeugen und keine Fixes implementieren.
   - Weise den Subagenten explizit an, keine Workpad-, Linear- oder Statusänderungen vorzunehmen und keine weiteren Subagenten zu starten.
   - Weise den Subagenten explizit an, nur Findings zu liefern. Die Bewertung der Findings, die Umsetzung der Fixes und jedes erneute Review bleiben ausschließlich beim aufrufenden Agenten.
   - Verlange eine explizite Abschlussausgabe in genau einer der beiden Formen:
     - `Findings:` mit priorisierten Befunden inklusive Datei-/Zeilenreferenzen
     - `Keine Findings.` optional mit kurzen Restrisiken oder Testlücken
   - Wenn der Subagent `Findings:` meldet, gilt Schritt 2 als nicht bestanden. Markiere den Schritt nicht als erledigt, sondern behebe die Findings selbst im aktuellen Workspace und starte anschließend die Checkliste erneut bei Schritt 1.
   - Schritt 2 ist erst dann erfolgreich abgeschlossen, wenn ein erneuter read-only Review-Durchlauf mit `Keine Findings.` endet.
   - Wenn diese Isolation in der aktuellen Session nicht möglich ist, bleibt Schritt 2 offen; ersetze ihn nicht durch ein lokales Review.

Führe die Checkliste strikt nacheinander aus. Ein beendeter read-only
Subagent ohne anschließende Fixes ist kein abgeschlossener Review-Schritt.
Falls es beim Review zu gefundenen Problemen kommt, behebe diese selbst.
Überspringe nach einem Fix keine späteren Schritte, sondern starte wieder bei
Schritt 1.
