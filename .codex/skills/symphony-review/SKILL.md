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
- Vorhandene `Zusätzliche Review-Hinweise` aus dem aktiven Kontext nur
  weiterreichen, wenn sie repo-spezifisch sind und keinen Linear-Issue-,
  Ticket-, Workpad- oder Workflow-Zusammenfassungskontext enthalten.
- `### Review` pflegen, Details knapp in `### Verlauf`.

## Pflicht-Review-Schritt

- Starte pro Durchlauf genau einen isolierten read-only Review-Subagenten per
  `spawn_agent` für den aktuellen Worktree gegen `origin/main`.
- Nutze `fork_context: false`, nicht `agent_type: "explorer"`, und wenn möglich
  das stärkste verfügbare Frontier-Modell bzw. sonst das geerbte
  Standardmodell.
- Übergib nur den engen Review-Auftrag plus nötige
  `Zusätzliche Review-Hinweise`; der Auftrag darf keine Issue-Beschreibung,
  keinen Issue-Titel, keine Issue-URL, keine Ticketabsicht, keine
  Akzeptanzkriterien und keine Workpad-/Workflow-Zusammenfassung enthalten.
- Der Subagent berücksichtigt Branch-Commits, gestagte, ungestagte und
  untracked Änderungen gegen `origin/main` sowie daraus folgende repo-lokale
  Konsistenz zwischen Code, `WORKFLOW.md`, Skills und `docs/`. Er gleicht die
  Änderungen nicht gegen Linear-Issue, Workpad, Ticketabsicht oder
  Akzeptanzkriterien ab.
- Er bleibt strikt read-only und nimmt keine Datei-, Commit-, Workpad-, Linear-,
  Status- oder Subagent-Aktionen vor.
- Er meldet `Findings:` nur für klar belegbare, reviewer-relevante Probleme
  oder Spezifikationsabweichungen gegen repo-lokale Specs, Dokumentation,
  `WORKFLOW.md`, Skills oder Code-Verträge. Keine Stil-Nits, Vermutungen,
  hypothetischen Risiken oder Abweichungen von Linear-Issue-Anforderungen als
  Findings.
- Er prüft vor seiner finalen Antwort den vollständigen relevanten
  Review-Scope und bricht nicht nach den ersten ein oder zwei Findings ab.
- Er meldet alle klar belegbaren Findings, die für einen Reviewer relevant
  sind, priorisiert mit Datei-/Zeilenbezug.
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
     neuen Review-Durchlauf starten, bevor die Findings im Workpad erfasst,
     bewertet, gefixt, validiert und eingeordnet sind.
   - Vor den Fixes keinen separaten Findings-Kommentar in Linear posten.
   - Fixes selbst im aktuellen Workspace umsetzen.
   - Nach der Behandlung genau einen kombinierten
     Linear-Issue-Kommentar pro behandeltem Finding posten. Dieser Kommentar
     beschreibt in einem Stück, welches Finding erkannt wurde, warum es
     relevant war, welche Änderung es gefixt hat und falls nötig, warum das
     Finding anders behandelt oder nicht umgesetzt wurde.
   - Bei einem behandelten Finding entsteht genau ein kombinierter
     Nach-Fix-Kommentar. Bei zwei behandelten Findings entstehen genau zwei
     kombinierte Nach-Fix-Kommentare, nicht vier.
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
entstanden sind, kombinierte Finding-/Fix-Evidenz in Review-Kommentaren oder
im Workpad-Verlauf dokumentiert ist, der Workspace nach dem Review Änderungen
enthält oder das No-Findings-Signal nicht eindeutig ist, zuerst Findings/Fixes
behandeln und dokumentieren. Danach ohne `--yolo` oder `Skip "Freigabe Review"`
nach `Freigabe Review` verschieben; mit `--yolo` oder `Skip "Freigabe Review"`
direkt nach `Test (AI)` weitergeben. Bei jedem Statuswechsel den Turn sofort
beenden. Bei `agent.max_turns` Abweichungen dokumentieren und ohne Statuswechsel
stoppen; `agent.max_turns` ist kein normaler Phasenabschluss.
