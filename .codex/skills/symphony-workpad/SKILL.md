---
name: symphony-workpad
description:
  Verwende diesen Skill fuer Aufbau, Standardstruktur und Pflege des
  persistenten `## Codex Workpad`-Kommentars in Symphony. Er deckt das
  Finden/Anlegen des einen Workpads, Environment-Stamp, die kanonischen
  Abschnitte, Verlauf und den finalen Handoff-Zustand ab. Inhaltliche Planung
  von `Plan` und `Validierung` liegt beim Skill `symphony-planning`.
  Statuslogik bleibt in `WORKFLOW.md` bzw. `WORKFLOW_INTERACTIVE.md`.
---

# Symphony Workpad

Verwende diesen Skill, wenn du das persistente Codex Workpad eines Symphony-Tickets
finden, anlegen, strukturieren oder aktuell halten musst.

## Abgrenzung

- Dieser Skill regelt nur Aufbau und Pflege des Workpads.
- Statusuebergaenge, Escape Hatches und die Reihenfolge einzelner Workflow-Schritte
  bleiben ausschliesslich in `WORKFLOW.md` bzw. `WORKFLOW_INTERACTIVE.md`.
- Inhaltliche Regeln fuer Ticketbeschreibung, `Plan` und `Validierung` liegen in
  `.codex/skills/symphony-planning/SKILL.md`.
- Wenn Reihenfolge/Statuslogik und Workpad-Regeln gleichzeitig relevant sind, gilt:
  Die Workflow-Datei bestimmt wann etwas passiert; dieser Skill bestimmt wie das
  Workpad dabei aussieht und gepflegt wird.

## Persistenter Kommentar

- Verwende pro Issue genau einen persistierenden Kommentar mit dem Marker
  `## Codex Workpad`.
- Durchsuche vorhandene Kommentare nach diesem Marker.
- Nur aktive/nicht aufgeloeste Kommentare duerfen als Live-Workpad
  wiederverwendet werden.
- Wenn ein aktiver Workpad-Kommentar existiert, verwende genau ihn weiter und
  erstelle keinen zweiten.
- Wenn kein aktiver Workpad-Kommentar existiert, erstelle einen neuen Kommentar
  in der Standardstruktur dieses Skills.
- Schreibe Fortschritts-, Review-, Test- und Handoff-Notizen immer in dieselbe
  Kommentar-ID.

## Standardstruktur

Verwende fuer den persistierenden Kommentar exakt diese Struktur:

````md
## Codex Workpad

```text
<hostname>:<abs-path>@<short-sha>
```

### Plan

- [ ] 1\. Uebergeordnete Aufgabe
  - [ ] 1.1 Teilaufgabe
  - [ ] 1.2 Teilaufgabe
- [ ] 2\. Uebergeordnete Aufgabe

### Validierung

- [ ] gezielte Tests: `<command>`

### Review

- [ ] `<PreReview-/Review-Schritt aus dem aktiven Skill>`: `<kurze Statusnotiz>`

### Test

- [ ] `<Test-Schritt aus .codex/skills/sym-test/SKILL.md>`: `<kurze Statusnotiz>`

### Verlauf

- <kurze Fortschritts-/Review-/Test-Notiz mit Zeitstempel in lokaler Zeit>

### Unklarheiten

- <nur einfuegen, wenn waehrend der Ausfuehrung etwas unklar war>
````

## Pflege-Regeln

- Halte oben im Kommentar einen kompakten Environment-Stamp im Format
  `<host>:<abs-workdir>@<short-sha>`.
- Nimm in den Environment-Stamp keine Metadaten auf, die bereits aus den
  Linear-Issue-Feldern ableitbar sind, insbesondere keine Issue-ID, keinen
  Status und keinen Branchnamen.
- Fuehre `### Plan` als hierarchische Checkliste und halte die Parent-/Child-Struktur
  intakt.
- Fuehre `### Validierung` als explizite Checkliste, nicht als Freitext.
- Fuer die inhaltliche Pflege von `### Plan` und `### Validierung` ist
  `.codex/skills/symphony-planning/SKILL.md` die massgebliche Quelle.
- Halte `### Verlauf` fuer kurze, zeitgestempelte Notizen in lokaler Zeit. Nutze
  dort keine UTC- oder `Z`-Zeitstempel.
- `### Review` und `### Test` sind fuer die zugehoerigen Repo-Skills reserviert;
  detaillierte Logs bleiben in `### Verlauf`.
- Fuege `### Unklarheiten` nur ein, wenn waehrend der Ausfuehrung wirklich etwas
  unklar oder widerspruechlich war.

## Planung und laufende Aktualisierung

- Erfasse vor der Implementierung ein konkretes Reproduktionssignal im Abschnitt
  `### Verlauf`.
- Aktualisiere das Workpad unmittelbar nach jedem wesentlichen Meilenstein.
- Lasse abgeschlossene Arbeit niemals ungecheckt im Plan oder in den
  Validierungslisten stehen.
- Dokumentiere temporaere lokale Proof-Schritte knapp in `### Validierung`
  und/oder `### Verlauf`, wenn sie fuer den Nachweis wichtig sind.
- Halte den finalen Handoff-Zustand im selben Kommentar fest, inklusive lokalem
  Stand und Validierungszusammenfassung. Wenn die aktuelle Workflow-Phase einen
  ungecommitten Stand verlangt, muss das dort explizit stehen.
- Poste keine separaten Abschluss- oder Zusammenfassungs-Kommentare ausserhalb
  dieses Workpads.

## Ticket-Interaktionen

- Bearbeite den Issue-Body/die Beschreibung nicht fuer Fortschrittsverfolgung
  oder laufende Workpad-Pflege.
- Wenn Planungsaenderungen an der Ticketbeschreibung noetig sind, delegiere sie
  ausschliesslich an `.codex/skills/symphony-planning/SKILL.md`.
- Halte Abweichungen zwischen Status und Issue-Inhalt im bestehenden Workpad
  fest. Wenn vor dem ersten Workpad-Bootstrap noch kein Workpad existiert,
  uebernimm die Notiz beim Anlegen dieses ersten Kommentars statt dafuer einen
  zusaetzlichen Fortschrittskommentar anzulegen.
- Wenn `WORKFLOW.md` nach erstmaliger Workpad-Anlage das
  `Erstkontakt-Protokoll fuer neue Items` verlangt, nutze fuer Lesen/Schreiben in
  Linear den Skill `symphony-linear`.
- Halte im Workpad knapp fest, ob eine Erstkontakt-Korrektur durchgefuehrt wurde
  oder keine Aenderung noetig war.
