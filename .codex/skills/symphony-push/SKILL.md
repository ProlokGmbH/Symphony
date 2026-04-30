---
name: symphony-push
description:
  Veröffentliche innerhalb eines laufenden Symphony-Issue-Workflows den aktiven
  Branch nach `origin` und erstelle oder aktualisiere die zugehörige Pull
  Request; nutze den Skill nur für den vom Workflow vorgegebenen Branch- und
  PR-Kontext.
---

# Push

## Voraussetzungen

- Der Aufruf erfolgt innerhalb eines laufenden Symphony-Issue-Workflows.
- `gh` CLI ist installiert und in `PATH` verfügbar.
- `gh auth status` läuft für GitHub-Operationen in diesem Repo erfolgreich durch.

## Ziele

- Pushe aktuelle Branch-Änderungen sicher nach `origin`.
- Erstelle eine PR, wenn für den Branch noch keine existiert, sonst
  aktualisiere die bestehende.
- Halte die Branch-Historie sauber, wenn sich der Remote bewegt hat.

## Verwandte Skills

- `symphony-pull`: nutze diesen Skill, wenn ein Push abgelehnt wird oder die
  Synchronisierung nicht sauber ist (non-fast-forward, Rebase-Konfliktrisiko
  oder veralteter Branch).
- `symphony-linear`: nutze diesen Skill, um eine neu erzeugte GitHub-PR mit
  dem aktiven Linear-Issue zu verknüpfen, wenn der Branch dort noch keine PR
  angehängt hat.

## Linear-Issue-Kontext

- Wenn dieser Skill innerhalb eines Symphony-Issue-Workflows läuft, nutze das
  aktive Linear-Issue aus dem aktuellen Aufgabenkontext.
- Verwende in diesem Fall ausschliesslich den bereits aktiven Branch. Innerhalb
  des Workflows ist das der kanonische Branch `symphony/<IssueId>`; er darf
  nicht durch einen neuen Alternativ-Branch ersetzt werden.
- Wenn du die interne Linear-`issueId` schon hast, verwende sie direkt weiter.
- Andernfalls löse sie mit `symphony-linear` auf, bevor du die PR anhängst:
  - frage `issue(id: $key) { id attachments { nodes { url } } }` mit dem
    aktuellen Issue-Key aus dem Aufgabenkontext ab (zum Beispiel `PRO-45`).
  - vergleiche die PR-URL aus `gh pr view --json url -q .url` mit den
    zurückgegebenen Attachment-URLs.
  - rufe `attachmentLinkGitHubPR` nur auf, wenn diese PR-URL dort noch nicht
    angehängt ist.

## Schritte

1. Ermittle den aktuellen Branch und bestätige den Remote-Status.
2. Führe vor dem Push die für das aktuelle Repository oder Ticket dokumentierte
   lokale Validierung aus.
3. Pushe den Branch bei Bedarf mit Upstream-Tracking nach `origin` und nutze
   dabei die bereits konfigurierte Remote-URL.
4. Falls der Push nicht sauber läuft oder abgelehnt wird:
   - Wenn der Fehler ein non-fast-forward- oder Synchronisationsproblem ist,
     führe den Skill `symphony-pull` aus, rebase auf `origin/main`, löse
     Konflikte und führe die Validierung erneut aus.
   - Pushe erneut; nutze `--force-with-lease` nur, wenn Historie umgeschrieben
     wurde.
   - Falls der Fehler auf Auth, Berechtigungen oder Workflow-Restriktionen des
     konfigurierten Remotes beruht, stoppe und nenne den exakten Fehler, statt
     Remotes umzuschreiben oder als Workaround das Protokoll zu wechseln.

5. Stelle sicher, dass für den Branch eine PR existiert:
   - Wenn keine PR existiert, erstelle eine.
   - Wenn eine PR existiert und offen ist, aktualisiere sie.
   - Wenn der Branch bereits mit einer geschlossenen oder gemergten PR
     verbunden war, erstelle bei Bedarf eine neue PR aus demselben Branch, statt
     einen neuen Branch-Namen zu erfinden.
   - Schreibe einen sauberen PR-Titel, der das Änderungsergebnis klar beschreibt.
   - Prüfe bei Branch-Updates explizit, ob der aktuelle PR-Titel noch zum
     neuesten Scope passt; aktualisiere ihn andernfalls.
6. Wenn die PR neu erstellt wurde oder dem aktuellen Issue diese PR noch als
   Attachment fehlt, nutze `symphony-linear`, um die interne Linear-`issueId`
   aufzulösen, bestehende Attachments zu prüfen und die PR-URL dann mit
   `attachmentLinkGitHubPR` an das aktive Linear-Issue zurückzuverknüpfen.
7. Schreibe oder aktualisiere den PR-Body anhand der im aktuellen Repository
   dokumentierten PR-Konventionen.
   - Falls es eine PR-Vorlage oder Pflichtabschnitte gibt, fülle sie mit
     konkretem Inhalt für diese Änderung.
   - Wenn bereits eine PR existiert, aktualisiere den Body so, dass er den
     gesamten PR-Scope widerspiegelt, nicht nur die neuesten Commits.
   - Verwende keinen veralteten Beschreibungstext aus früheren Iterationen
     wieder.
8. Führe eine dokumentierte PR-Body-Validierung nur dann aus, wenn das aktuelle
   Repository oder der Workflow sie ausdrücklich vorgibt.
9. Antworte mit der PR-URL aus `gh pr view`.

## Befehle

```sh
# Branch bestimmen
branch=$(git branch --show-current)

# Repo- oder ticketseitig dokumentierte lokale Validierung ausführen
<lokale Validierung aus Repo-/Ticket-Kontext>

# Erster Push: den aktuellen origin-Remote respektieren.
git push -u origin HEAD

# Falls das fehlschlug, weil sich der Remote bewegt hat, nutze den
# symphony-pull-Skill. Nach symphony-pull-Auflösung und erneuter Validierung
# den normalen Push wiederholen:
git push -u origin HEAD

# Wenn der konfigurierte Remote den Push wegen Auth, Berechtigungen oder
# Workflow-Restriktionen ablehnt, stoppen und den exakten Fehler nennen.

# Nur wenn die Historie lokal umgeschrieben wurde:
git push --force-with-lease origin HEAD

# Sicherstellen, dass eine PR existiert (nur erstellen, wenn sie fehlt)
pr_state=$(gh pr view --json state -q .state 2>/dev/null || true)
if [ "$pr_state" = "MERGED" ] || [ "$pr_state" = "CLOSED" ]; then
  echo "Aktueller Branch war bereits an eine geschlossene PR gebunden; erstelle bei neuen Commits eine neue PR aus demselben Branch." >&2
  pr_state=""
fi

# Einen klaren, menschenlesbaren Titel schreiben, der die gelieferte Änderung zusammenfasst.
pr_title="<klarer PR-Titel für diese Änderung>"
if [ -z "$pr_state" ]; then
  gh pr create --title "$pr_title"
else
  # Titel bei jedem Branch-Update neu prüfen; bei geändertem Scope anpassen.
  gh pr edit --title "$pr_title"
fi

pr_url=$(gh pr view --json url -q .url)

# Zuerst das aktive Linear-Issue auflösen und vorhandene Attachments prüfen:
#
# query IssueWithAttachments($key: String!) {
#   issue(id: $key) {
#     id
#     attachments {
#       nodes {
#         url
#       }
#     }
#   }
# }
#
# Wenn diese PR für das aktive Linear-Issue neu erstellt wurde oder das
# Attachment in der Liste fehlt, mit symphony-linear zurückverknüpfen:
#
# mutation AttachGitHubPR($issueId: String!, $url: String!, $title: String) {
#   attachmentLinkGitHubPR(
#     issueId: $issueId
#     url: $url
#     title: $title
#     linkKind: links
#   ) {
#     success
#   }
# }

# PR-Body passend zu den dokumentierten Konventionen des aktuellen Repos
# schreiben/bearbeiten.
# Beispielablauf:
# 1) Dokumentierte Vorlage oder Konvention öffnen und Body-Inhalt fuer diese PR entwerfen
# 2) gh pr edit --body-file /tmp/pr_body.md
# 3) bei Branch-Updates erneut prüfen, ob Titel/Body noch zum aktuellen Diff passen

# Falls das Repo eine PR-Body-Validierung dokumentiert, diese hier ausfuehren.

# PR-URL für die Antwort ausgeben
printf '%s\n' "$pr_url"
```

## Hinweise

- Nutze nicht `--force`; verwende `--force-with-lease` nur als letztes Mittel.
- Unterscheide Synchronisationsprobleme von Remote-Auth-/Berechtigungsproblemen:
  - Nutze den Skill `symphony-pull` bei non-fast-forward- oder
    Stale-Branch-Problemen.
  - Nenne Auth-, Berechtigungs- oder Workflow-Restriktionen direkt, statt
    Remotes oder Protokolle zu ändern.
