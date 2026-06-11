---
name: symphony-push
description:
  Veröffentlicht im Symphony-Issue-Workflow den aktiven Branch, erstellt oder
  aktualisiert die PR und verknüpft sie mit Linear.
---

# Push

## Voraussetzungen

- Laufender Symphony-Issue-Workflow auf `symphony/<IssueId>`.
- `gh` ist installiert und authentifiziert.

## Ablauf

1. Branch und Remote-Status prüfen.
2. Dokumentierte lokale Validierung ausführen.
   - Ausnahme: Wenn `symphony-push` aus `symphony-land` in `Merge (AI)` nur
     einen `<Issue-Key> Merge (AI) Autocommit` veröffentlicht, keine lokale
     Push-Validierung und kein lokales Voll-Gate ausführen. Der Merge-Schritt
     pusht nur den neuen Stand, verschiebt nach `Test (AI)` und stoppt.
3. `git push -u origin HEAD`.
4. Bei non-fast-forward oder veraltetem Branch `symphony-pull` ausführen,
   erneut validieren und pushen. Für die `Merge (AI)`-Autocommit-Ausnahme nach
   Schritt 2 nach dem Pull/Rebase nicht lokal validieren, sondern den
   aktualisierten Autocommit-Stand pushen, nach `Test (AI)` zurückspringen und
   stoppen. `--force-with-lease` nur nach lokaler History-Umschreibung.
   Auth-/Berechtigungsfehler direkt melden.
5. PR sicherstellen: offene PR aktualisieren, fehlende PR erstellen, bei alter
   geschlossener/gemergter PR neue PR aus demselben Branch erstellen.
6. Im `Merge (AI)`-Recovery-Pfad zusätzlich prüfen, dass die PR-Head-SHA nach
   dem Push dem lokalen `HEAD` entspricht. Bei Head-Mismatch stoppen und nicht
   als mergefähig dokumentieren.
7. PR-Titel und Body müssen den gesamten aktuellen Scope beschreiben.
8. Neu erstellte oder noch nicht verknüpfte PR per `symphony-linear` mit
   `attachmentLinkGitHubPR` ans aktive Linear-Issue hängen.
   - Wenn Linear für dieselbe GitHub-PR-URL einen Duplicate-/Already-exists-
     Fehler meldet, ist der Link idempotent als bereits vorhanden zu werten.
   - Andere Attachment-, Auth- oder Berechtigungsfehler bleiben Fehler und
     werden gemäß Linear-Zugriffsregeln behandelt.
9. PR-Body nach Repo-Konventionen/Vorlage schreiben; explizite
   Body-Validierung nur ausführen, wenn dokumentiert.
10. Mit der PR-URL und, im `Merge (AI)`-Recovery-Pfad, mit bestätigter
    PR-Head-SHA abschließen.

## Kommandoskizze

```sh
branch=$(git branch --show-current)
<lokale Validierung aus Repo-/Ticket-Kontext; in der Merge-Autocommit-Ausnahme überspringen>
git push -u origin HEAD

pr_state=$(gh pr view --json state -q .state 2>/dev/null || true)
pr_title="<klarer PR-Titel für diese Änderung>"
if [ -z "$pr_state" ] || [ "$pr_state" = "MERGED" ] || [ "$pr_state" = "CLOSED" ]; then
  gh pr create --title "$pr_title"
else
  gh pr edit --title "$pr_title"
fi

gh pr view --json url -q .url
gh pr view --json headRefOid -q .headRefOid
```
