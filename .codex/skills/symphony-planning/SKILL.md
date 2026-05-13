---
name: symphony-planning
description:
  Verwende diesen Skill innerhalb eines Symphony-Issue-Workflows für
  Ticketbeschreibung, Umsetzungsplan und geplante Validierung.
---

# Symphony Planning

Dieser Skill bereitet ein Ticket für autonome Folgeschritte vor. Workpad-Aufbau
kommt aus `symphony-workpad`; Statusübergänge aus `WORKFLOW.md` bzw.
`WORKFLOW_INTERACTIVE.md`.

## Linear-Beschreibung

- Scope, Absicht und Grenzen müssen für Plan und Validierung reichen.
- Bei längeren Beschreibungen oben eine kurze Zusammenfassung ergänzen und mit
  `---` vom Haupttext trennen.
- In `Planung (AI)` darf die Beschreibung verbessert werden, wenn das für
  saubere Planung nötig ist; die Originalbeschreibung dann separat in Linear
  dokumentieren.
- Außerhalb von `Planung (AI)` bleibt die Beschreibung unverändert.
- Fehlende Informationen nicht erfinden: Annahme, Lücke und empfohlenen
  Lösungsvorschlag im Workpad bzw. für `Planung` dokumentieren.

## Workpad-Plan

- `### Plan` ist eine hierarchische Checkliste konkreter Umsetzungsschritte.
- Der Plan enthält explizit Entwicklung/Änderung und automatisierte Tests.
- `### Validierung` ist eine Checkliste der geplanten Nachweise.
- Ticketseitige `Validation`-, `Test Plan`- oder `Testing`-Abschnitte werden
  verpflichtend übernommen.
- Bei App-Dateien oder App-Verhalten passende Runtime-Validierung einplanen.

## Qualitätsmaßstab

- Plan und Validierung vor der Umsetzung kritisch prüfen und schärfen.
- Keine unscharfen Sammelpunkte als Hauptschritte.
- Am Ende von `Planung (AI)` entscheiden, ob autonome Umsetzung möglich ist.
  Wenn nicht, müssen offene Fragen und empfohlene Lösungen direkt entscheidbar
  sein.

## Spätere Anpassungen

- Plan- oder Validierungsänderungen sind erlaubt, wenn neue Erkenntnisse sie
  nötig machen.
- Jede Änderung mit Grund und Validierungsauswirkung im Workpad dokumentieren.
- Verpflichtende Ticketvorgaben nicht entfernen oder abschwächen.
- Bei unklarem oder erweitertem Scope keine Anforderungen erfinden; Workflow für
  Klärung oder Folge-Issue nutzen.
