---
name: symphony-prereview
description:
  Führt im Status `PreReview (AI)` die repo-lokale `sym-prereview`-Checkliste
  aus und wiederholt gezielt fehlgeschlagene Schritte.
---

# Symphony PreReview

Nur im Status `PreReview (AI)` verwenden.

## Ablauf

- `<aktives-repo-root>/.codex/skills/sym-prereview/SKILL.md` vollständig lesen.
- Nur diese Checkliste und Reihenfolge verwenden; fehlende Datei im Workpad
  dokumentieren und stoppen.
- Schritte unter `### Review` spiegeln, Details in `### Verlauf`.
- Bei Fehlern Fix umsetzen, Workpad aktualisieren, nur den fehlgeschlagenen
  Schritt wiederholen und danach fortsetzen.

## Abschluss

Wenn alle Schritte sauber sind, `### Review` vollständig abhaken, nach
`Freigabe Implementierung` verschieben und den Turn beenden. Keine Commits. Bei
offener, fehlender oder nicht explizit abgehakter `### Review`-Checkliste den
Hauptturn nicht final beenden: im selben Turn weiterarbeiten oder einen echten
Blocker im Workpad dokumentieren. Bei `agent.max_turns` verbleibende
Abweichungen dokumentieren und ohne Statuswechsel stoppen; `agent.max_turns` ist
kein normaler Phasenabschluss.
