---
name: symphony-land
description:
  Führt im Status `Merge (AI)` eine PR bis zum Merge, beobachtet Checks und
  Review-Feedback und behandelt autonome Fixes.
---

# Land

Nur im Merge-Schritt des Workflows verwenden.

## Ziele

- PR für den aktuellen Branch finden.
- Konfliktfreiheit zu `main` sicherstellen.
- CI grün halten und behebbare Fehler autonom fixen.
- Review-Feedback vor dem Merge bestätigen oder bearbeiten.
- Lokale Volltests nicht pauschal wiederholen; `Test (AI)` bleibt der Status
  für das vollständige lokale Gate.
- GitHub-Checks nach Policy bewerten: `success` ist bestanden, `skipped` ist
  bei bewusster Skip-Policy akzeptabel, `neutral` ist neutral akzeptiert,
  echte Fehler bleiben blockierend. Skipped/neutral nie als bestandene CI
  ausgeben.
- Erst nach grünem Zustand per Merge-Commit mergen.

## Ablauf

1. PR-/Remote-Preflight ausführen: aktueller Branch muss
   `symphony/<IssueId>` sein, `origin/<branch>` muss existieren, eine offene PR
   für genau diesen Branch muss existieren und die PR-Head-SHA muss dem
   lokalen `HEAD` entsprechen. Fehlenden Remote-Branch, fehlende PR oder
   PR-Head-Mismatch nicht als mergefähig behandeln.
2. Keine pauschalen lokalen Volltests in `Merge (AI)` ausführen. Vorhandene
   Test-Evidenz aus `Test (AI)` ist das maßgebliche lokale Gate. Wenn
   GitHub-Checks durch bewusste Skip-Policy `skipped` sind, ersetzt das keine
   bestandene CI, sondern ist nur zusammen mit der lokalen Test-Evidenz aus
   `Test (AI)` mergefähig.
3. Falls beim Eintritt offene Änderungen vorhanden sind, diese als im
   Merge-Schritt übernommene Dateiänderungen behandeln: mit `<Issue-Key>
   Merge (AI) Autocommit` plus kurzem Body committen, über `symphony-push`
   veröffentlichen, nach `Test (AI)` zurückverschieben und stoppen.
4. Mergebarkeit prüfen.
5. Bei Konflikten `symphony-pull` nutzen. Wenn Pull/Rebase oder Konfliktlösung
   Dateien ändert, committen, pushen, nach `Test (AI)` zurückverschieben und
   stoppen.
6. Review-Kommentare und Codex-Review-Issue-Kommentare prüfen.
7. Feedback autonom anhand von Ticketkontext, Plan, Code, Tests und lokaler
   Dokumentation akzeptieren oder begründet ablehnen/zurückstellen. Wenn
   Feedback Dateiänderungen erfordert, vor Codeänderungen die beabsichtigte
   Aktion antworten, den Fix umsetzen, committen, pushen, nach `Test (AI)`
   zurückverschieben und stoppen.
8. Checks beobachten. `success` als bestanden melden, `skipped` als
   „GitHub checks acceptable: skipped by policy“ oder Mischform ausgeben,
   `neutral` als neutral akzeptiert ausgeben. Bei Fehlschlag Logs holen. Wenn
   eine Behebung Dateiänderungen erfordert, Fix umsetzen, committen, pushen,
   nach `Test (AI)` zurückverschieben und stoppen; reine CI-Neuläufe ohne
   Dateiänderungen dürfen weiter beobachtet werden.
9. Wenn GitHub-Checks bestanden oder gemäß Skip-/Neutral-Policy akzeptabel sind
   und Feedback erledigt ist, mit Merge-Commit-Betreff
   `<IssueId>: <IssueTitle>` mergen.
10. Nach erfolgreichem Merge vor jedem Statuswechsel im Workpad-Verlauf eine
    eindeutige Zeile im Format `Merge-Evidenz: PR #<nummer> gemergt,
    Merge-Commit <sha>.` dokumentieren.

`gh pr merge` nicht direkt aus dem Workflow heraus aufrufen; nutze diesen Skill
und bevorzugt den Watch-Helper.

## Watch-Helper

```sh
python3 .codex/skills/symphony-land/land_watch.py
```

Exit-Codes: `2` Review-Kommentare, `3` CI-Fehler, `4` PR-Head während des
Watch-Laufs aktualisiert, `5` Merge-Konflikt, `6` fehlende oder inkonsistente
PR-/Remote-Preflight-Evidenz.

## Review-Umgang

- Menschliche Inline-Kommentare über den PR-Review-Comment-Endpunkt beantworten.
- Codex-Reviews kommen als Issue-Kommentare mit `## Codex Review`; darauf im
  Issue-Thread antworten.
- Alle Agent-Kommentare beginnen mit `[codex]`.
- Für jedes Feedback entscheiden: akzeptieren, zurückstellen oder ablehnen. Bei
  correctness-Feedback konkrete Validierung liefern.
- File-changing Review-Fixes in `Merge (AI)` immer mit Commit-SHA und Ergebnis
  an derselben Stelle melden, nach `Test (AI)` zurückverschieben und stoppen.
- Wenn Feedback trotz vorhandener Quellen nicht sicher lösbar ist, Blocker im
  Workpad und Review-Thread dokumentieren, nach `Freigabe Review` verschieben
  und stoppen.

Nützliche Endpunkte:

```sh
gh api repos/{owner}/{repo}/pulls/<pr_number>/comments
gh api repos/{owner}/{repo}/issues/<pr_number>/comments
gh api -X POST /repos/{owner}/{repo}/pulls/<pr_number>/comments \
  -f body='[codex] <response>' -F in_reply_to=<comment_id>
```

## Fehlerbehandlung

- Instabile CI-Ausreißer nach Prüfung erneut beobachten.
- Wenn `origin/<branch>` oder eine offene PR fehlt, nicht mergen. Nur aus einem
  sauberen, lokal in `Test (AI)` validierten Stand per `symphony-push`
  veröffentlichen beziehungsweise erstellen, danach PR-Kontext und PR-Head-SHA
  erneut prüfen.
- Wenn die PR-Head-SHA nicht dem lokalen `HEAD` entspricht, nicht mergen:
  aktuellen Stand veröffentlichen oder lokalen Stand auf den PR-Head bringen,
  danach erneut beobachten.
- Auto-Fix-Commits von CI lokal übernehmen, bei Bedarf rebasen, mit eigenem
  Commit/Push veröffentlichen, nach `Test (AI)` zurückverschieben und stoppen.
- Bei `mergeable: UNKNOWN` warten und erneut prüfen.
- Nicht mergen, solange Review-Kommentare offen sind.
- Auto-Merge nur aktivieren, wenn Workflow und Repository es ausdrücklich
  verlangen.

## PR-Metadaten

PR-Titel und Beschreibung müssen den gesamten Änderungsscope abbilden. Nach
Fix-Batches einen knappen Root-Level-`[codex]`-Kommentar mit Deltas, Commits
und Tests schreiben, wenn das den Stand klärt. Neues Codex-Review nur anfordern,
wenn seit der letzten Anfrage neue Commits entstanden sind.

## Abschluss

Den Hauptturn erst final beenden, wenn der PR-Merge nachweislich abgeschlossen
ist und die `Merge-Evidenz` im Workpad steht, ein zulässiger Statuswechsel nach
`Test (AI)` oder `Review` erfolgt ist oder ein echter Blocker dokumentiert ist.
Ohne diese Evidenz keinen normalen Abschluss behaupten und den Hauptturn nicht
final beenden; im selben Turn die Merge-/Watch-Schleife fortsetzen oder einen
echten Blocker dokumentieren. Bei `agent.max_turns` Abweichungen dokumentieren
und ohne Statuswechsel stoppen; `agent.max_turns` ist kein normaler
Phasenabschluss.
