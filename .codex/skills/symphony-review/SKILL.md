---
name: symphony-review
description:
  Führt im Status `Review (AI)` den gemeinsamen Review-Subagenten-Lauf
  inklusive repo-lokaler Zusatzhinweise und Review-/Fix-Schleife aus.
---

# Symphony Review

Nur im Status `Review (AI)` verwenden. Pull und der einmalige
`<Issue-Key> Review (AI) Autocommit` passieren vor dieser Schleife.

## Ablauf

- `<aktives-repo-root>/.codex/skills/sym-review/SKILL.md` lesen, sofern die
  Datei existiert.
- Aus `sym-review` nur `Zusätzliche Review-Hinweise` bzw. repo-spezifische
  Checklistenpunkte für den Review-Subagenten übernehmen. `sym-review`
  definiert nicht den Hauptablauf und ersetzt keinen Pflichtschritt.
- Fehlende `sym-review`-Datei oder leere Zusatzhinweise im Workpad knapp
  dokumentieren und ohne repo-spezifische Hinweise fortfahren.
- Vorhandene `Zusätzliche Review-Hinweise` aus dem aktiven Kontext unverändert
  mit den repo-spezifischen Hinweisen weiterreichen.
- `### Review` pflegen, Details knapp in `### Verlauf`.

## Pflicht-Review-Schritt

- Starte pro Durchlauf genau einen isolierten read-only Review-Subagenten per
  `spawn_agent` für den aktuellen Worktree gegen `origin/main`.
- Nutze `fork_context: false`, nicht `agent_type: "explorer"`, und wenn möglich
  das stärkste verfügbare Frontier-Modell bzw. sonst das geerbte
  Standardmodell.
- Übergib nur den engen Review-Auftrag plus nötige
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
- Isolierte read-only Review-Subagenten abwarten; ein Timeout ist kein Ergebnis.

## Review-/Fix-Schleife

1. Mit dem Pflicht-Review-Schritt beginnen.
2. Nach jedem Schritt den zugehörigen `### Review`-Punkt aktualisieren.
3. Bei Fehlern oder Findings:
   - Wenn `wait_agent` ein finales Ergebnis mit `Findings:` liefert, diese
     Findings sofort im Hauptturn behandeln; nicht final antworten und keinen
     neuen Review-Durchlauf starten, bevor die Findings dokumentiert, gefixt,
     validiert und im Workpad eingeordnet sind.
   - Review-Subagent-Findings, die behandelt werden sollen, vor den Fixes als
     separaten Linear-Issue-Kommentar posten.
   - Fixes selbst im aktuellen Workspace umsetzen.
   - nach den Änderungen aus Subagent-Findings einen separaten
     Linear-Issue-Kommentar mit Einordnung, Zweck und
     Finding-zu-Änderung-Zuordnung posten.
   - Workpad aktualisieren und die Checkliste wieder bei Schritt 1 starten.
4. Lokale Fixes bleiben ungecommittet.

## Abschluss

Solange die Review-Checkliste im Workpad offen, fehlend oder nicht explizit
abgehakt ist, keinen Statuswechsel vornehmen und den Hauptturn nicht final
beenden. Arbeite im selben Turn in der Review-/Fix-Schleife weiter oder
dokumentiere einen echten Blocker im Workpad. Wenn der Pflicht-Review-Schritt in
einem ununterbrochenen Durchlauf sauber ist, der Review-Subagent `Keine
Findings.` geliefert hat und der Workspace nach dem Review sauber ist, direkt
nach `Test (AI)` verschieben. Wenn Findings behandelt wurden, Review-Fixes
entstanden sind, Findings-/Fix-Evidenz in separaten Review-Kommentaren oder im
Workpad-Verlauf dokumentiert ist, der Workspace nach dem Review Änderungen
enthält oder das No-Findings-Signal nicht eindeutig ist, zuerst Findings/Fixes
behandeln und dokumentieren. Danach ohne `--yolo` oder `Skip "Freigabe Review"`
nach `Freigabe Review` verschieben; mit `--yolo` oder `Skip "Freigabe Review"`
direkt nach `Test (AI)` weitergeben. Bei jedem Statuswechsel den Turn sofort
beenden. Bei `agent.max_turns` Abweichungen dokumentieren und ohne Statuswechsel
stoppen; `agent.max_turns` ist kein normaler Phasenabschluss.
