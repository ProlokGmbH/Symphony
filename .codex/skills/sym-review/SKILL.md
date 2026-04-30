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
   - Wenn `Zusätzliche Review-Hinweise` im aktuellen Prompt vorhanden sind, übergib sie unter genau dieser Überschrift unverändert an den Subagenten.
   - Weise den Subagenten an, alle Änderungen im aktuellen Worktree gegen `origin/main` zu berücksichtigen: Branch-Commits, gestagte Änderungen, ungestagte Änderungen und untracked Dateien.
   - Weise den Subagenten explizit an, `Findings:` nur für tatsächliche, klar belegbare und reviewer-relevante Probleme oder Spezifikationsabweichungen zu verwenden, die sich direkt aus dem gezeigten Code oder reproduzierbaren Signalen stützen lassen.
   - Weise den Subagenten explizit an, keine Vermutungen, hypothetischen Risiken ohne Nachweis, Stil-/Nitpick-Hinweise oder obskuren Low-Priority-Randfälle als Findings zu melden.
   - Weise den Subagenten explizit an, bei Unsicherheit oder nur schwachen Hinweisen kein `Findings:` zu erzwingen, sondern `Keine Findings.` zu melden und offene Restrisiken oder Testlücken höchstens knapp nachgelagert zu nennen.
   - Wenn diese Hinweise Dokumentationskonsistenz oder Dokumentationsdrift ansprechen, prüfe damit explizit Abweichungen zwischen Code, `WORKFLOW.md`, Skill-Texten und Inhalten unter `docs/`.
   - Weise den Subagenten explizit an, strikt read-only zu bleiben: keine Dateien ändern, keine Commits erzeugen und keine Fixes implementieren.
   - Weise den Subagenten explizit an, keine Workpad-, Linear- oder Statusänderungen vorzunehmen und keine weiteren Subagenten zu starten.
   - Weise den Subagenten explizit an, nur Findings zu liefern. Die Bewertung der Findings, die Umsetzung der Fixes und jedes erneute Review bleiben ausschließlich beim aufrufenden Agenten.
   - Verlange eine explizite Abschlussausgabe in genau einer der beiden Formen:
     - `Findings:` mit priorisierten, belastbaren Befunden inklusive Datei-/Zeilenreferenzen und knapper Begründung
     - `Keine Findings.` optional mit kurzen Restrisiken oder Testlücken
   - Wenn der Subagent `Findings:` meldet, gilt Schritt 2 als nicht bestanden. Markiere den Schritt nicht als erledigt, sondern behebe die Findings selbst im aktuellen Workspace und starte anschließend die Checkliste erneut bei Schritt 1.
   - Wenn der Subagent `Findings:` meldet und du diese Findings behandeln musst, poste die gelieferten Findings vor den Fixes als separaten Linear-Issue-Kommentar. Dieser Kommentar dient der Nachvollziehbarkeit am Issue und ersetzt nicht das Workpad.
   - Wenn du aufgrund dieser Findings Änderungen vornimmst, poste nach den Änderungen einen weiteren separaten Linear-Issue-Kommentar, der die Findings einordnet, den Zweck der Änderungen beschreibt und die Finding-zu-Änderung-Zuordnung festhält.
   - Schritt 2 ist erst dann erfolgreich abgeschlossen, wenn ein erneuter read-only Review-Durchlauf mit `Keine Findings.` endet.
   - Wenn diese Isolation in der aktuellen Session nicht möglich ist, bleibt Schritt 2 offen; ersetze ihn nicht durch ein lokales Review.

Führe die Checkliste strikt nacheinander aus. Ein beendeter read-only
Subagent ohne anschließende Fixes ist kein abgeschlossener Review-Schritt.
Falls es beim Review zu gefundenen Problemen kommt, behebe diese selbst.
Überspringe nach einem Fix keine späteren Schritte, sondern starte wieder bei
Schritt 1.
