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
3. `git push -u origin HEAD`.
4. Bei non-fast-forward oder veraltetem Branch `symphony-pull` ausführen,
   erneut validieren und pushen. `--force-with-lease` nur nach lokaler
   History-Umschreibung. Auth-/Berechtigungsfehler direkt melden.
5. PR sicherstellen: offene PR aktualisieren, fehlende PR erstellen, bei alter
   geschlossener/gemergter PR neue PR aus demselben Branch erstellen.
6. PR-Titel und Body müssen den gesamten aktuellen Scope beschreiben.
7. Neu erstellte oder noch nicht verknüpfte PR per `symphony-linear` mit
   `attachmentLinkGitHubPR` ans aktive Linear-Issue hängen.
8. PR-Body nach Repo-Konventionen/Vorlage schreiben; explizite
   Body-Validierung nur ausführen, wenn dokumentiert.
9. Mit der PR-URL abschließen.

## Kommandoskizze

```sh
branch=$(git branch --show-current)
<lokale Validierung aus Repo-/Ticket-Kontext>
git push -u origin HEAD

pr_state=$(gh pr view --json state -q .state 2>/dev/null || true)
pr_title="<klarer PR-Titel für diese Änderung>"
if [ -z "$pr_state" ] || [ "$pr_state" = "MERGED" ] || [ "$pr_state" = "CLOSED" ]; then
  gh pr create --title "$pr_title"
else
  gh pr edit --title "$pr_title"
fi

gh pr view --json url -q .url
```
