---
name: sym-review
description: Repository-spezifische Review-Checkliste für Symphony Elixir.
---

# Sym Review

Nur über `symphony-review` verwenden.

## Checkliste

1. `make all`
2. Starte einen isolierten read-only Review-Subagenten für den aktuellen
   Worktree gegen `origin/main`.

## Subagent-Auftrag

- Nutze `fork_context: false`, nicht `agent_type: "explorer"`, und wenn möglich
  das stärkste verfügbare Frontier-Modell bzw. sonst das geerbte Standardmodell.
- Übergib nur den engen Review-Auftrag plus vorhandene
  `Zusätzliche Review-Hinweise`; keinen vollständigen Ticket-, Workflow- oder
  Workpad-Kontext.
- Der Subagent berücksichtigt Branch-Commits, gestagte, ungestagte und
  untracked Änderungen.
- Er bleibt strikt read-only und nimmt keine Datei-, Commit-, Workpad-, Linear-,
  Status- oder Subagent-Aktionen vor.
- Er meldet `Findings:` nur für klar belegbare, reviewer-relevante Probleme
  oder Spezifikationsabweichungen. Keine Stil-Nits, Vermutungen oder
  hypothetischen Risiken als Findings.
- Bei Unsicherheit meldet er `Keine Findings.` und nennt Restrisiken höchstens
  knapp nachgelagert.
- Bei Dokumentationshinweisen prüft er Konsistenz zwischen Code, `WORKFLOW.md`,
  Skills und `docs/`.
- Abschlussausgabe ist genau `Findings:` mit priorisierten Datei-/Zeilenbezügen
  oder `Keine Findings.`

Wenn der Subagent `Findings:` liefert, ist Schritt 2 nicht bestanden: Findings
vor den Fixes als separaten Linear-Issue-Kommentar posten, Fixes selbst
umsetzen, nach den Änderungen einen Kommentar mit
Finding-zu-Änderung-Zuordnung posten und die Checkliste wieder bei Schritt 1
starten. Schritt 2 ist erst nach einem erneuten Review mit `Keine Findings.`
abgeschlossen.
