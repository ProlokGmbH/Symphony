---
name: symphony-planning
description:
  Verwende diesen Skill fuer Ticket- und Umsetzungsplanung in Symphony. Er legt
  fest, wie die Linear-Beschreibung aufgebaut sein muss und wie `Plan` und
  `Validierung` im Codex Workpad vorbereitet und gepflegt werden. Automatische
  Plan-Aenderungen sind nur in `Planung (AI)` erlaubt; Statuslogik bleibt in
  `WORKFLOW.md` bzw. `WORKFLOW_INTERACTIVE.md`.
---

# Symphony Planning

Verwende diesen Skill, wenn ein Ticket fuer die Umsetzung vorbereitet oder
automatisiert neu geplant werden muss.

## Zielsetzung

Ziel des Plans ist, in einem einzelnen Symphony-Ticket mit Beschreibung und
Codex Workpad eine vollstaendige Planung eines Umsetzungsitems zu erfassen, das
in weiteren Schritten vollstaendig automatisiert durch Codex umgesetzt werden
kann.

## Abgrenzung

- Dieser Skill regelt Ticketbeschreibung, Detailplanung und geplante
  Validierung.
- Aufbau, Persistenz und Standardstruktur des Kommentars `## Codex Workpad`
  kommen aus `.codex/skills/symphony-workpad/SKILL.md`.
- Statusuebergaenge und Schrittreihenfolgen bleiben ausschliesslich in
  `WORKFLOW.md` bzw. `WORKFLOW_INTERACTIVE.md`.

## Ticketbeschreibung in Linear

- Die Ticketbeschreibung muss den geplanten Scope ausfuehrlich beschreiben.
- Wenn die Beschreibung laenger ist, fuege am Anfang eine kurze Zusammenfassung
  ein und trenne sie mit einem horizontalen Trenner `---` vom Haupttext.
- Schreibe praezise genug, dass daraus ein konkreter Implementierungsplan und
  eine konkrete Validierung ableitbar sind.
- In `Planung (AI)` darf die Ticketbeschreibung automatisiert verbessert oder
  ergaenzt werden, wenn das fuer eine vollstaendige und sauber strukturierte
  Planung noetig ist.
- Wenn du die Ticketbeschreibung in `Planung (AI)` aenderst, hinterlasse in
  Linear einen separaten Kommentar mit der Originalbeschreibung, damit die
  Aenderung nachvollziehbar bleibt.
- Verwende fuer Lesen und Schreiben in Linear den Skill `symphony-linear`.
- Wenn die Beschreibung fuer sichere Planung nicht ausreicht, erfinde keine
  Anforderungen. Halte die Luecke im Workpad fest und befolge fuer das weitere
  Vorgehen die Workflow-Datei.

## Detailplanung im Codex Workpad

- Vor Beginn der Implementierung muss im `## Codex Workpad` eine konkrete
  Planung vorliegen.
- Pflege die inhaltliche Planung in den Abschnitten `### Plan` und
  `### Validierung`.
- `### Plan` muss eine hierarchische Checkliste mit den geplanten
  Umsetzungsschritten enthalten.
- Jeder Plan muss explizite Schritte fuer Entwicklung, Anpassung oder
  Erweiterung automatisierter Tests enthalten.
- `### Validierung` muss eine Checkliste der Nachweise enthalten, mit denen nach
  der Implementierung der Erfolg der Umsetzung belegt wird.
- Wenn Ticket-Beschreibung oder Kommentar-Kontext Abschnitte `Validation`,
  `Test Plan` oder `Testing` enthalten, uebernimm sie als verpflichtende Punkte
  in `### Validierung`.
- Wenn App-Dateien oder App-Verhalten betroffen sind, plane passende
  app-spezifische Laufzeitvalidierung in `### Validierung`.

## Planungspflege

- Fuehre vor Beginn der Umsetzung ein strenges Self-Review des Plans durch und
  schaerfe ihn, bis er fuer die Ausfuehrung ausreicht.
- Halte den Plan eng am Scope; fuehre keine unscharfen Sammelpunkte wie
  "Diverse Anpassungen" oder "Fixes" als Hauptschritte.
- Zerlege die Arbeit in nachvollziehbare, abhakbare Schritte.
- Plane Validierung nicht nachtraeglich als Freitext, sondern vorab als
  konkrete Checkliste.

## Grenze fuer automatische Plan-Aenderungen

- In automatisierten Workflow-Schritten duerfen `### Plan` und die geplanten
  Punkte in `### Validierung` ausschliesslich in `Planung (AI)` inhaltlich
  erstellt oder geaendert werden.
- In spaeteren automatisierten Schritten darfst du bestehende Punkte nur
  abarbeiten, abhaken und ihren Status im bestehenden Workpad dokumentieren.
- Wenn waehrend automatisierter Umsetzung neue Erkenntnisse eine inhaltliche
  Neuplanung erfordern, halte das knapp im Workpad fest und folge fuer das
  weitere Vorgehen der Workflow-Datei.
- In interaktiven Sitzungen darf der Benutzer auch nach `Planung (AI)` noch
  Eingriffe in die Planung veranlassen.
