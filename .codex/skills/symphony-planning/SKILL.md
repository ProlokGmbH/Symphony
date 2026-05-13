---
name: symphony-planning
description:
  Verwende diesen Skill nur innerhalb eines laufenden Symphony-Issue-Workflows
  fuer Ticket- und Umsetzungsplanung. Er legt fest, wie die
  Linear-Beschreibung aufgebaut sein muss und wie `Plan` und `Validierung` im
  Symphony Workpad vorbereitet und gepflegt werden. Planänderungen sind auch
  nach `Planung (AI)` erlaubt, wenn neue Erkenntnisse sie erforderlich machen;
  Statuslogik bleibt in
  `WORKFLOW.md` bzw. `WORKFLOW_INTERACTIVE.md`.
---

# Symphony Planning

Verwende diesen Skill nur, wenn ein Ticket innerhalb des laufenden
Symphony-Issue-Workflows fuer die Umsetzung vorbereitet oder automatisiert neu
geplant werden muss.

## Zielsetzung

Ziel des Plans ist, in einem einzelnen Symphony-Ticket mit Beschreibung und
Symphony Workpad eine belastbare Planung eines Umsetzungsitems zu erfassen, die
in weiteren Schritten automatisiert durch Codex umgesetzt und bei neuen
Erkenntnissen nachvollziehbar angepasst werden kann.

## Abgrenzung

- Dieser Skill regelt Ticketbeschreibung, Detailplanung und geplante
  Validierung.
- Aufbau, Persistenz und Standardstruktur des Kommentars `## Symphony Workpad`
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
- Ausserhalb von `Planung (AI)` bleibt die Ticketbeschreibung unveraendert;
  Fortschritt, Review und Testnotizen gehoeren ausschliesslich in das eine
  persistente Workpad.
- Verwende fuer Lesen und Schreiben in Linear den Skill `symphony-linear`.
- Wenn die Beschreibung fuer sichere Planung nicht ausreicht, erfinde keine
  Anforderungen. Arbeite empfohlene Annahmen zunächst nachvollziehbar in den
  Plan ein, halte die Lücke im Workpad fest und bereite die offene Frage mit
  empfohlenem Lösungsvorschlag für den manuellen Status `Planung` vor.

## Detailplanung im Symphony Workpad

- Vor Beginn der Implementierung muss im `## Symphony Workpad` eine konkrete
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
- Prüfe am Ende von `Planung (AI)`, ob der Plan für eine vollständig autonome
  Umsetzung ausreicht. Wenn nicht, müssen die offenen Fragen und empfohlenen
  Lösungen so konkret sein, dass der Benutzer den Plan im Status `Planung`
  direkt freigeben oder gezielt ändern kann.

## Umgang mit automatischen Planänderungen

- In `Planung (AI)` werden `### Plan` und die geplanten Punkte in
  `### Validierung` initial erstellt oder geschärft.
- In späteren automatisierten Schritten dürfen `### Plan` und
  `### Validierung` inhaltlich angepasst werden, wenn neue Erkenntnisse aus der
  Umsetzung oder Validierung das erforderlich machen.
- Dokumentiere jede inhaltliche Planänderung knapp im Workpad, inklusive Grund
  und Auswirkung auf die Validierung.
- Entferne oder schwäche keine verpflichtenden Vorgaben aus Ticket-Abschnitten
  wie `Validation`, `Test Plan` oder `Testing`.
- Wenn eine Erkenntnis den Ticket-Scope unklar macht oder über den geplanten
  Scope hinausgeht, erfinde keinen neuen Scope; halte die Lücke im Workpad fest
  und folge für das weitere Vorgehen der Workflow-Datei.
- In interaktiven Sitzungen darf der Benutzer auch nach `Planung (AI)` noch
  Eingriffe in die Planung veranlassen.
