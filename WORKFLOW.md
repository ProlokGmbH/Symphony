---
tracker:
  kind: linear
  project_slug: $LINEAR_PROJECT_SLUG
  assignee: $LINEAR_ASSIGNEE
  active_states:
    - Todo (AI)
    - In Arbeit
    - In Arbeit (AI)
    - PreReview (AI)
    - Review (AI)
    - Test (AI)
    - Abbruch (AI)
    - Merge (AI)
  terminal_states:
    - Review
    - Fertig
    - Abgebrochen
polling:
  interval_ms: 5000
workspace:
  root: $SYMPHONY_PROJECT_WORKTREES_ROOT
hooks:
  after_create: |
    workspace="$PWD"
    issue_key="$(basename "$workspace")"
    branch="symphony/$issue_key"
    source_repo="$SYMPHONY_PROJECT_ROOT"
    git -C "$source_repo" fetch origin
    if git -C "$source_repo" show-ref --verify --quiet "refs/heads/$branch"; then
      git -C "$source_repo" worktree add "$workspace" "$branch"
    elif git -C "$source_repo" show-ref --verify --quiet "refs/remotes/origin/$branch"; then
      git -C "$source_repo" worktree add --track -b "$branch" "$workspace" "origin/$branch"
    else
      git -C "$source_repo" worktree add -b "$branch" "$workspace" origin/main
    fi
    git -C "$source_repo" config "branch.$branch.remote" origin
    git -C "$source_repo" config "branch.$branch.merge" "refs/heads/$branch"
    if git -C "$source_repo" show-ref --verify --quiet "refs/remotes/origin/$branch"; then
      git -C "$workspace" pull --ff-only origin "$branch"
    fi
    if [ -f "$source_repo/.env.local" ]; then
      cp "$source_repo/.env.local" "$workspace/.env.local"
      chmod 600 "$workspace/.env.local"
    fi
  before_remove: |
    # Closes open PRs, deletes the matching remote and local branches, and removes the linked worktree.
    workspace="$PWD"
    cd "$SYMPHONY_WORKFLOW_DIR" && mise exec -- mix workspace.before_remove --workspace "$workspace" --source-repo "$SYMPHONY_PROJECT_ROOT"
agent:
  max_concurrent_agents: 10
  max_turns: 20
codex:
  command: >-
    common_dir="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)";
    if [ -z "$common_dir" ]; then
      echo "Unable to determine git common dir for sym-codex" >&2;
      exit 1;
    fi;
    source_repo="$(cd "$common_dir/.." && pwd -P)";
    exec "$source_repo/sym-codex" --observer
  approval_policy: never
  thread_sandbox: danger-full-access
  turn_sandbox_policy:
    type: dangerFullAccess
---

Du arbeitest an einem Linear-Ticket `{{ issue.identifier }}`

{% if attempt %}
Fortsetzungskontext:

- Dies ist Wiederholungsversuch Nr. {{ attempt }}, weil sich das Ticket weiterhin in einem aktiven Status befindet.
- Setze vom aktuellen Workspace-Zustand aus fort, statt von Grund auf neu zu beginnen.
- Wiederhole bereits abgeschlossene Untersuchung oder Validierung nicht, außer wenn sie für neue Codeänderungen erforderlich ist.
- Beende den Turn nicht, solange das Issue in einem aktiven Codex-Ausführungsstatus bleibt, außer du bist durch fehlende erforderliche Berechtigungen/Secrets blockiert. Ausnahme: Für `In Arbeit` endet der Turn regulär nach erfolgreichem Bootstrap von Worktree und Workpad; bei bestätigtem Erstkontakt gehört das einmalige `Erstkontakt-Protokoll für neue Items` noch zu diesem Bootstrap.
{% endif %}

Ticket-Kontext:
Identifier: {{ issue.identifier }}
Titel: {{ issue.title }}
Aktueller Status: {{ issue.state }}
Labels: {{ issue.labels }}
URL: {{ issue.url }}
Lokale Systemzeit für diesen Turn: {{ runtime.local_time }} ({{ runtime.timezone }})

Beschreibung:
{% if issue.description %}
{{ issue.description }}
{% else %}
Keine Beschreibung vorhanden.
{% endif %}

## Zweck und Grundregeln

1. Dies ist eine unbeaufsichtigte Orchestrierungssitzung. Frage niemals einen Menschen nach Folgeaktionen.
2. Stoppe nur bei einem echten Blocker frühzeitig (fehlende erforderliche Authentifizierung/Berechtigungen/Secrets). Wenn du blockiert bist, halte das im Workpad fest und verschiebe das Issue gemäß Workflow.
3. Die Abschlussnachricht darf nur abgeschlossene Aktionen und Blocker enthalten. Füge keine "next steps for user" hinzu.

- Arbeite nur in der bereitgestellten Repository-Kopie. Berühre keinen anderen Pfad.
- Beginne damit, den aktuellen Status des Tickets zu bestimmen, und folge dann dem passenden Ablauf für diesen Status.
- Betrachte grundsätzlich nur Statuswerte mit `(AI)` im Namen als automatische Arbeitsstatus. Die einzige Ausnahme ist `In Arbeit`; dort darfst du ausschließlich den Bootstrap von Git-Worktree und Workpad ausführen sowie bei bestätigtem Erstkontakt einmalig das `Erstkontakt-Protokoll für neue Items`.
- Starte jede Aufgabe damit, den verfolgenden Workpad-Kommentar zu öffnen und auf den neuesten Stand zu bringen, bevor neue Implementierungsarbeit beginnt.
- Investiere vor der Implementierung bewusst mehr Aufwand in Planung und Verifikationsdesign.
- Reproduziere zuerst: bestätige immer das aktuelle Verhalten bzw. Signal des Problems, bevor du Code änderst, damit das Ziel des Fixes eindeutig ist.
- Verwende für neue Zeitstempel im Abschnitt `Verlauf` immer lokale Systemzeit; schreibe dort keine UTC- oder `Z`-Zeitstempel.
- Halte die Ticket-Metadaten aktuell (Status, Checkliste, Akzeptanzkriterien, Links).
- Betrachte genau einen persistierenden Linear-Kommentar als maßgebliche Quelle für den Fortschritt.
- Verwende genau diesen einen Workpad-Kommentar für alle Fortschritts- und Übergabenotizen; poste keine separaten "done"/Zusammenfassungs-Kommentare.
- Wechsle den Status nur, wenn die entsprechende Qualitätsschwelle erreicht ist.
- Arbeite autonom von Anfang bis Ende, solange du nicht durch fehlende Anforderungen, Secrets oder Berechtigungen blockiert bist.

## Voraussetzungen und globale Kontrakte

### Linear-Zugriff

Der Agent sollte mit Linear kommunizieren können, entweder über einen konfigurierten Linear-MCP-Server oder über das injizierte Tool `linear_graphql`. Wenn keines von beiden vorhanden ist, stoppe und fordere den Nutzer auf, Linear zu konfigurieren.

### Git-Branch-Kontrakt

- Der kanonische Arbeitsbranch für dieses Issue heißt immer `symphony/{{ issue.identifier }}`.
- Wenn ein frischer Branch benötigt wird, erstelle oder verwende genau `symphony/{{ issue.identifier }}` von `origin/main`.
- Erstelle keine alternativen Branch-Namen mit persönlichen Präfixen, Slugs aus dem Titel oder anderen Abweichungen.
- Symphony synchronisiert das Linear-Feld `branchName` auf den aktuell genutzten Workspace-Branch, der diesem kanonischen `symphony/...`-Schema folgen muss.
- Wenn Linear oder ältere Workpad-Notizen einen anderen Branchnamen anzeigen, behandle das als veraltete Metadaten und passe den lokalen Branch nicht daran an.

### Verwandte Skills

- `symphony-linear`: mit Linear interagieren.
- `symphony-push`: nach lokalen Commits den Remote-Branch aktualisieren oder erstmals veröffentlichen, PR-Updates veröffentlichen und neu erzeugte PRs am aktiven Linear-Issue anhängen.
- `symphony-pull`: den Branch vor der Übergabe mit dem neuesten `origin/main` synchronisieren.
- `symphony-prereview`: wenn das Ticket `PreReview (AI)` erreicht, `.codex/skills/symphony-prereview/SKILL.md` explizit öffnen und befolgen; dort ist die repository-spezifische PreReview-Checkliste inklusive gezielter Schrittwiederholung definiert.
- `symphony-review`: wenn das Ticket `Review (AI)` erreicht, `.codex/skills/symphony-review/SKILL.md` explizit öffnen und befolgen; dort ist die repository-spezifische Review-Checkliste inklusive Review-/Fix-Schleife definiert.
- `symphony-test`: wenn das Ticket `Test (AI)` erreicht, `.codex/skills/symphony-test/SKILL.md` explizit öffnen und befolgen; dort ist die repository-spezifische Test-Checkliste inklusive Test-/Fix-Schleife definiert.
- `symphony-land`: wenn das Ticket `Merge (AI)` erreicht, `.codex/skills/symphony-land/SKILL.md` explizit öffnen und befolgen; dort ist die `symphony-land`-Schleife enthalten.

### Globale Arbeitsregeln

- Betrachte jeden vom Ticket vorgegebenen Abschnitt `Validation`, `Test Plan` oder `Testing` als nicht verhandelbare Akzeptanzvorgabe: spiegle ihn im Workpad wider und führe ihn aus, bevor du die Arbeit als abgeschlossen betrachtest.
- Wenn während der Ausführung sinnvolle Verbesserungen außerhalb des Scopes entdeckt werden, erstelle ein separates Linear-Issue, statt den Scope zu erweitern. Das Folge-Issue muss einen klaren Titel, eine Beschreibung und Akzeptanzkriterien enthalten, in `Backlog` eingeordnet sein, demselben Projekt wie das aktuelle Issue zugewiesen werden, das aktuelle Issue als `related` verknüpfen und `blockedBy` verwenden, wenn das Folge-Issue vom aktuellen Issue abhängt.
- Nutze den blocked-access escape hatch nur für echte externe Blocker (fehlende erforderliche Tools/Auth), nachdem dokumentierte Fallbacks ausgeschöpft wurden.

## Statusübersicht

| Status | Im Scope | Bedeutung / Verhalten | Nächster regulärer Status |
| --- | --- | --- | --- |
| `Backlog` | Nein | Außerhalb des Scopes dieses Workflows; nicht ändern. | Warten auf menschliches Verschieben nach `Todo (AI)` |
| Nicht-terminale Stati ohne `(AI)` im Namen, außer `In Arbeit` | Nein | Außerhalb des Scopes dieses Workflows; nicht pollen, nicht bearbeiten und nicht automatisch verschieben. | Warten auf menschliches Verschieben in einen AI-Status |
| `In Arbeit` | Ja | Ausnahme vom automatischen Statusschema: beim Eintritt den kanonischen Git-Worktree unterhalb des konfigurierten Workspace-Roots sicherstellen, das `## Codex Workpad` bootstrappen und bei bestätigtem Erstkontakt einmalig das `Erstkontakt-Protokoll für neue Items` ausführen. Keine weitere automatische Bearbeitung starten. | Warten auf menschliches Verschieben in einen AI-Status |
| `Todo (AI)` | Ja | In der Warteschlange; vor aktiver Arbeit sofort nach `In Arbeit (AI)` verschieben. | `In Arbeit (AI)` |
| `In Arbeit (AI)` | Ja | Implementierung läuft aktiv. | `PreReview (AI)` |
| `PreReview (AI)` | Ja | Repository-spezifischen PreReview-/Fix-Zyklus ausführen. | `Freigabe` |
| `Review (AI)` | Ja | Repository-spezifischen Review-/Fix-Zyklus ausführen; automatische Commits sind in diesem Status zulässig und resultierende Fix-Commits werden vor der Übergabe veröffentlicht. | `Test (AI)` |
| `Test (AI)` | Ja | Repository-spezifischen Test-/Fix-Zyklus ausführen; automatische Commits sind in diesem Status zulässig und resultierende Fix-Commits werden vor `Merge (AI)` veröffentlicht. | `Merge (AI)` |
| `Freigabe` | Nein | Außerhalb des aktiven AI-Scopes; nichts tun und warten, bis ein Mensch weiter verschiebt. | `Review (AI)` oder `In Arbeit (AI)` |
| `Merge (AI)` | Ja | Merge-Ablauf mit `symphony-land` ausführen; automatische Commits sind in diesem Status zulässig. | `Review` |
| `Review` | Nein | Terminaler Übergabestatus nach dem Merge; keine weitere automatische Aktion, manuelles Verschieben nach `Fertig` bleibt beim Benutzer. | - |
| `Abbruch (AI)` | Ja | Laufende Arbeit sofort abbrechen und Cleanup ausführen. | `Abgebrochen` |
| `Fertig` | Nein | Terminaler Status; keine weitere Aktion erforderlich. | - |
| `Abgebrochen` | Nein | Terminaler Status nach explizitem Abbruch; keine weitere Aktion erforderlich. | - |

## Einstieg und Routing

1. Hole das Issue über die explizite Ticket-ID.
2. Lies den aktuellen Status.
3. Füge einen kurzen Kommentar hinzu, wenn Status und Issue-Inhalt nicht konsistent sind, und fahre dann mit dem sichersten Ablauf fort.
4. Leite in den passenden Ablauf weiter:
   - `Backlog` -> Issue-Inhalt/Status nicht ändern; stoppen und warten, bis ein Mensch es auf `Todo (AI)` setzt.
   - Jeder nicht-terminale Status ohne `(AI)` im Namen, außer `In Arbeit` (zum Beispiel `Freigabe`) -> nichts tun und beenden; warten, bis ein Mensch das Issue wieder in einen AI-Status verschiebt.
   - `In Arbeit` -> Ablauf `In Arbeit` ausführen.
   - `Todo (AI)` -> Ablauf `Todo (AI)` ausführen.
   - `In Arbeit (AI)` -> Ablauf `In Arbeit (AI)` ausführen.
   - `PreReview (AI)` -> Ablauf `PreReview (AI)` ausführen.
   - `Review (AI)` -> Ablauf `Review (AI)` ausführen.
   - `Test (AI)` -> Ablauf `Test (AI)` ausführen.
   - `Abbruch (AI)` -> Ablauf `Abbruch (AI)` ausführen.
   - `Merge (AI)` -> Ablauf `Merge (AI)` ausführen.
   - `Review` -> nichts tun und beenden.
   - `Fertig` -> nichts tun und beenden.
   - `Abgebrochen` -> nichts tun und beenden.
## Ablauf für `Todo (AI)`

### Ziel

Das Issue aus der Warteschlange in die aktive Bearbeitung überführen und den regulären Ausführungsablauf sauber starten.

### Voraussetzungen

- Das Issue befindet sich aktuell in `Todo (AI)`.

### Ablauf

1. Für `Todo (AI)`-Tickets muss die Startsequenz exakt in dieser Reihenfolge erfolgen:
   - `update_issue(..., state: "In Arbeit (AI)")`
   - `## Codex Workpad`-Bootstrap-Kommentar finden/erstellen
   - falls der Kommentar dabei erstmals neu angelegt wird, prüfe die Trigger-Bedingungen des `Erstkontakt-Protokolls für neue Items` und führe es nur bei bestätigtem Erstkontakt aus
   - erst danach Analyse-, Planungs- und Implementierungsarbeit beginnen.

### Abschluss und nächster Status

- Nach der unmittelbaren Statusänderung und dem Workpad-Bootstrap geht der Ablauf in `In Arbeit (AI)` über.

### Sonderfälle

- Keine.

## Ablauf für `In Arbeit`

### Ziel

Beim Eintritt in `In Arbeit` die Arbeitsumgebung für das Ticket vorbereiten und nur bei bestätigtem Erstkontakt einmalig die Beschreibung korrigieren, ohne den regulären Codex-Ausführungsablauf zu starten.

### Voraussetzungen

- Das Issue befindet sich aktuell in `In Arbeit`.

### Ablauf

1. Prüfe, ob für das Issue bereits der kanonische Git-Worktree `symphony/{{ issue.identifier }}` unterhalb des konfigurierten Workspace-Roots existiert.
2. Falls der Worktree noch nicht existiert, lege ihn gemäß Git-Branch-Kontrakt an.
3. Finde oder erstelle genau einen persistierenden Scratchpad-Kommentar für das Issue:
   - Durchsuche vorhandene Kommentare nach dem Marker-Header `## Codex Workpad`.
   - Ignoriere bereits aufgelöste Kommentare während der Suche; nur aktive/nicht aufgelöste Kommentare dürfen als Live-Workpad wiederverwendet werden.
   - Falls vorhanden, verwende genau diesen Kommentar weiter; erstelle keinen neuen Workpad-Kommentar.
   - Falls nicht vorhanden, erstelle genau einen neuen, leeren Workpad-Kommentar in der Standardstruktur aus `## Workpad-Standard`, aber ohne bereits begonnene Planungs-, Implementierungs- oder Validierungsinhalte.
   - Falls du in diesem Turn den ersten Workpad-Kommentar neu anlegen musstest, prüfe unmittelbar danach die Trigger-Bedingungen des `Erstkontakt-Protokolls für neue Items` und führe es nur bei bestätigtem Erstkontakt aus.
4. Starte darüber hinaus keine weitere Analyse-, Planungs- oder Implementierungsarbeit.
5. Ändere den Status nicht automatisch weiter.

### Abschluss und nächster Status

- Nach erfolgreichem Bootstrap endet dieser Ablauf ohne weiteren Statuswechsel.
- Das Issue bleibt in `In Arbeit`, bis ein Mensch es in einen Codex-Status verschiebt.

### Sonderfälle

- Wenn der Bootstrap an einem echten externen Blocker scheitert, halte den Blocker knapp im Workpad fest und beende den Turn.

## Ablauf für `In Arbeit (AI)`

### Ziel

Planung, Implementierung, lokale Validierung und ungecommittete Übergabe nach `PreReview (AI)`.

### Voraussetzungen

- Das Issue befindet sich aktuell in `In Arbeit (AI)`, oder kommt unmittelbar aus `Todo (AI)`.
- Wenn du von `Todo (AI)` kommst, verzögere nicht mit weiteren Statuswechseln: Das Issue sollte bereits `In Arbeit (AI)` sein, bevor dieser Schritt beginnt.

### Ablauf

1. Finde oder erstelle genau einen persistierenden Scratchpad-Kommentar für das Issue:
   - Durchsuche vorhandene Kommentare nach dem Marker-Header `## Codex Workpad`.
   - Ignoriere bereits aufgelöste Kommentare während der Suche; nur aktive/nicht aufgelöste Kommentare dürfen als Live-Workpad wiederverwendet werden.
   - Falls vorhanden, verwende genau diesen Kommentar weiter; erstelle keinen neuen Workpad-Kommentar.
   - Falls nicht vorhanden, erstelle einen Workpad-Kommentar und nutze ihn für alle Updates.
   - Speichere die ID des Workpad-Kommentars und schreibe Fortschrittsupdates nur in diese ID.
   - Falls du in diesem Turn den ersten Workpad-Kommentar neu anlegen musstest, prüfe unmittelbar danach die Trigger-Bedingungen des `Erstkontakt-Protokolls für neue Items` und führe es nur bei bestätigtem Erstkontakt aus, bevor du Plan, Akzeptanzkriterien oder Validierung weiter ausarbeitest.
2. Gleiche das Workpad vor neuen Änderungen sofort ab:
   - Hake bereits erledigte Punkte ab.
   - Erweitere/korrigiere den Plan so, dass er für den aktuellen Scope vollständig ist.
   - Stelle sicher, dass `Akzeptanzkriterien` und `Validierung` aktuell sind und weiterhin zur Aufgabe passen.
3. Starte die Arbeit, indem du einen hierarchischen Plan im Workpad-Kommentar schreibst bzw. aktualisierst.
4. Stelle sicher, dass das Workpad oben einen kompakten Environment-Stamp als Code-Fence-Zeile enthält:
   - Format: `<host>:<abs-workdir>@<short-sha>`
   - Beispiel: `devbox-01:/home/dev-user/code/symphony-workspaces/MT-32@7bdde33bc`
   - Nimm keine Metadaten auf, die bereits aus den Linear-Issue-Feldern ableitbar sind (`issue ID`, `status`, `branch`).
5. Füge explizite Akzeptanzkriterien und TODOs in Checklistenform in denselben Kommentar ein.
   - Wenn Änderungen nutzerseitig sichtbar sind, nimm ein UI-Walkthrough-Akzeptanzkriterium auf, das den End-to-End-Nutzerpfad zur Validierung beschreibt.
   - Wenn Änderungen App-Dateien oder App-Verhalten berühren, füge explizite app-spezifische Ablaufprüfungen in `Akzeptanzkriterien` des Workpads hinzu (zum Beispiel: Startpfad, geänderter Interaktionspfad und erwarteter Ergebnispfad).
   - Wenn die Ticket-Beschreibung oder der Kommentar-Kontext Abschnitte `Validation`, `Test Plan` oder `Testing` enthält, kopiere diese Anforderungen als verpflichtende Checkboxen in die Bereiche `Akzeptanzkriterien` und `Validierung` des Workpads (keine optionale Abschwächung).
6. Führe ein Self-Review des Plans im Stil eines Principal Engineers durch und verfeinere ihn im Kommentar.
7. Erfasse vor der Implementierung ein konkretes Reproduktionssignal und halte es im Abschnitt `Verlauf` des Workpads fest (Befehl/Ausgabe, Screenshot oder deterministisches UI-Verhalten).
9. Kontext komprimieren und mit der Ausführung fortfahren.
11. Lade den vorhandenen Workpad-Kommentar und behandle ihn als aktive Ausführungs-Checkliste.
    - Bearbeite ihn großzügig, sobald sich die Realität ändert (Scope, Risiken, Validierungsansatz, entdeckte Aufgaben).
12. Implementiere entlang der hierarchischen TODOs und halte den Kommentar aktuell:
    - Hake erledigte Punkte ab.
    - Füge neu entdeckte Punkte im passenden Abschnitt hinzu.
    - Halte die Parent-/Child-Struktur intakt, während sich der Scope weiterentwickelt.
    - Aktualisiere das Workpad unmittelbar nach jedem wesentlichen Meilenstein (zum Beispiel: Reproduktion abgeschlossen, Code-Änderung gelandet, Validierung gelaufen, Review-Feedback adressiert).
    - Lasse abgeschlossene Arbeit niemals ungecheckt im Plan stehen.
13. Führe die für den Scope erforderlichen Validierungen/Tests aus.
    - Verpflichtendes Gate: Führe alle im Ticket vorgegebenen Anforderungen aus `Validierung`/`Test Plan`/`Testing` aus, wenn sie vorhanden sind; behandle unerfüllte Punkte als unvollständige Arbeit.
    - Bevorzuge einen gezielten Nachweis, der direkt das geänderte Verhalten zeigt.
    - Du darfst temporäre lokale Proof-Änderungen machen, um Annahmen zu validieren (zum Beispiel: einen lokalen Build-Input für `make` anpassen oder einen UI-Account/Response-Pfad hart codieren), wenn das die Sicherheit erhöht.
    - Nimm jede temporäre Proof-Änderung vor der Übergabe nach `PreReview (AI)` wieder zurück.
    - Dokumentiere diese temporären Proof-Schritte und Ergebnisse in den Bereichen `Validierung`/`Verlauf` des Workpads, damit Reviewer den Nachweis nachvollziehen können.
    - Wenn die App berührt wird, führe vor der Übergabe die Validierung `launch-app` aus und dokumentiere die Ergebnisse im Workpad.
14. Prüfe alle Akzeptanzkriterien erneut und schließe verbleibende Lücken.
15. Führe vor der Übergabe nach `PreReview (AI)` die für deinen Scope erforderliche Validierung aus und bestätige, dass sie erfolgreich ist; falls nicht, behebe die Probleme und wiederhole den Lauf, bis alles grün ist.
16. Führe in `In Arbeit (AI)` keine automatischen Commits aus. Der Arbeitsstand muss für `PreReview (AI)` und den anschließenden manuellen Freigabe-/Commit-Schritt bewusst ungecommittet bleiben.
17. Aktualisiere den Workpad-Kommentar mit dem finalen Checklistenstatus und den Validierungsnotizen.
    - Markiere abgeschlossene Punkte in Plan-/Akzeptanzkriterien-/Validierungs-Checklisten als erledigt.
    - Füge finale Übergabenotizen (lokaler Stand + Validierungszusammenfassung) im selben Workpad-Kommentar hinzu.
    - Halte explizit fest, dass der Arbeitsstand absichtlich ungecommittet für den `PreReview (AI)`- und anschließenden manuellen Freigabe-/Commit-Schritt übergeben wird.
    - Füge unten einen kurzen Abschnitt `### Unklarheiten` hinzu, wenn irgendein Teil der Ausführung unklar/verwirrend war, mit knappen Stichpunkten.
    - Poste keinen zusätzlichen Abschluss- oder Zusammenfassungs-Kommentar.
18. Bestätige vor dem Wechsel nach `PreReview (AI)`, dass jeder erforderliche ticketseitige Validierungs-/Test-Plan-Punkt im Workpad explizit als abgeschlossen markiert ist.
19. Öffne das Workpad vor dem Statuswechsel erneut und aktualisiere es, sodass `Plan`, `Akzeptanzkriterien` und `Validierung` exakt zur erledigten Arbeit passen.

### Abschluss und nächster Status

- Der reguläre Abschluss dieser Phase ist `PreReview (AI)`, nicht direkt `Freigabe`.
- Erst dann nach `PreReview (AI)` verschieben.
  - Ein direkter Übergang von `In Arbeit (AI)` nach `Freigabe` ist nur über den blocked-access escape hatch zulässig.
  - Ausnahme: Wenn du gemäß blocked-access escape hatch durch fehlende erforderliche Tools/Auth blockiert bist, verschiebe nach `Freigabe` und füge den Blocker-Hinweis sowie explizite Entblockungsaktionen hinzu.
- Vor dem Wechsel nach `PreReview (AI)` müssen alle folgenden Bedingungen erfüllt sein:
  - Die Checkliste aus diesem Ablauf ist vollständig abgeschlossen und korrekt im einen Workpad-Kommentar abgebildet.
  - Akzeptanzkriterien und erforderliche ticketseitige Validierungspunkte sind abgeschlossen.
  - Validation/Tests sind für den aktuellen lokalen Arbeitsstand grün.
  - Das Workpad dokumentiert den finalen ungecommitten Übergabestand und die bestandene lokale Validierung explizit.
  - Falls die App berührt wird, sind die Runtime-Validierungsanforderungen aus `App runtime validation (required)` abgeschlossen.

### Sonderfälle

- Wenn du blockiert bist und noch kein Workpad existiert, füge einen Blocker-Kommentar hinzu, der Blocker, Auswirkung und nächste Entblockungsaktion beschreibt.

## Ablauf für `PreReview (AI)`

### Ziel

Den repository-spezifischen PreReview-/Fix-Zyklus vollständig ausführen und das Issue danach in den manuellen `Freigabe`-Schritt übergeben.

### Voraussetzungen

- Das Issue befindet sich aktuell in `PreReview (AI)`.

### Ablauf

1. Öffne `.codex/skills/symphony-prereview/SKILL.md` und führe den dort definierten Ablauf aus.
2. Der Skill enthält die repository-spezifische PreReview-Checkliste, deren checklistenartige Workpad-Protokollierung unter `### Review` sowie die gezielte Schrittwiederholung ohne kompletten Neustart.

### Abschluss und nächster Status

- Verschiebe das Issue erst danach nach `Freigabe`.
  - Nur dieser Schritt verschiebt regulär von `PreReview (AI)` nach `Freigabe`.

### Sonderfälle

- Falls ein `PreReview (AI)`-Lauf sauber endet, das Issue aber fälschlich noch in `PreReview (AI)` steht, übernimmt Symphony den Statuswechsel nach `Freigabe` als Fallback automatisch.

## Ablauf für `Review (AI)`

### Ziel

Den repository-spezifischen Review-/Fix-Zyklus vollständig ausführen, notwendige Folge-Fixes in diesem Status committen dürfen und das Issue danach nach `Test (AI)` übergeben.

### Voraussetzungen

- Das Issue befindet sich aktuell in `Review (AI)`.

### Ablauf

1. Öffne `.codex/skills/symphony-review/SKILL.md` und führe den dort definierten Ablauf aus.
2. Der Skill enthält die repository-spezifische Review-Checkliste, deren checklistenartige Workpad-Protokollierung unter `### Review` sowie die Review-/Fix-Schleife.
3. Wenn der Review-Lauf Fixes erzeugt, darfst du diese in diesem Status committen; veröffentliche den aktualisierten Stand anschließend mit `symphony-push`, damit der Remote-Branch auf dem aktuellen Stand ist.

### Abschluss und nächster Status

- Verschiebe das Issue erst danach nach `Test (AI)`.
  - Nur dieser Schritt verschiebt regulär von `Review (AI)` nach `Test (AI)`.

### Sonderfälle

- Falls ein `Review (AI)`-Lauf sauber endet, das Issue aber fälschlich noch in `Review (AI)` steht, übernimmt Symphony den Statuswechsel nach `Test (AI)` als Fallback automatisch.

## Ablauf für `Test (AI)`

### Ziel

Den repository-spezifischen Test-/Fix-Zyklus ausführen, notwendige Folge-Fixes in diesem Status committen dürfen und das Issue danach nach `Merge (AI)` übergeben.

### Voraussetzungen

- Das Issue befindet sich aktuell in `Test (AI)`.

### Ablauf

1. Öffne `.codex/skills/symphony-test/SKILL.md` und führe den dort definierten Ablauf aus.
2. Der Skill enthält die repository-spezifische Test-Checkliste, deren checklistenartige Workpad-Protokollierung unter `### Test` sowie die Test-/Fix-Schleife.
3. Wenn der Testlauf Fixes erzeugt, committe den resultierenden Stand in diesem Status und veröffentliche ihn anschließend mit `symphony-push`, damit vor `Merge (AI)` ein landbarer Remote-Branch existiert.

### Abschluss und nächster Status

- Verschiebe das Issue erst danach nach `Merge (AI)`.
  - Nur dieser Schritt verschiebt regulär von `Test (AI)` nach `Merge (AI)`.

### Sonderfälle

- Falls ein `Test (AI)`-Lauf sauber endet, das Issue aber fälschlich noch in `Test (AI)` steht, übernimmt Symphony den passenden Statuswechsel als Fallback automatisch.

## Ablauf für `Freigabe`

### Ziel

Den manuellen Review- und Commit-Schritt vollständig dem Entwickler überlassen und bis zum nächsten menschlichen Statuswechsel nichts automatisiert fortsetzen.

### Voraussetzungen

- Das Issue befindet sich aktuell in `Freigabe`.

### Ablauf

1. Weder coden noch den Ticket-Inhalt ändern.
2. In diesem Status übernimmt der Entwickler den manuellen Review- und Commit-Schritt.
3. In diesem Status kein regelmäßiges Polling ausführen; warten, bis ein Mensch das Issue in einen anderen Status verschiebt.

### Abschluss und nächster Status

- Nach der manuellen Freigabe verschiebt ein Mensch das Issue regulär nach `Review (AI)`.
- Wenn Freigabe-Feedback Änderungen erfordert, verschiebt ein Mensch das Issue nach `In Arbeit (AI)`.

### Sonderfälle

- Keine.

## Ablauf für `Merge (AI)`

### Ziel

Den Merge-Ablauf mit `symphony-land` auf einem sauberen Workspace abschließen und das Issue danach nach `Review` verschieben.

### Voraussetzungen

- Das Issue befindet sich aktuell in `Merge (AI)`.
- Prüfe zuerst zuverlässig, dass im Workspace keine offenen Git-Änderungen mehr vorhanden sind.

### Ablauf

1. Falls noch offene Änderungen vorhanden sind, verschiebe das Issue sofort zurück nach `Freigabe`, damit der manuelle Commit-Schritt nachgeholt wird; den Merge-Skill in diesem Fall nicht starten.
2. Nur mit sauberem Workspace `.codex/skills/symphony-land/SKILL.md` öffnen und befolgen und anschließend den Skill `symphony-land` in einer Schleife ausführen, bis die PR gemergt ist. `gh pr merge` nicht direkt aufrufen.

### Abschluss und nächster Status

- Nach abgeschlossenem Merge das Issue nach `Review` verschieben.

### Sonderfälle

- Keine.

## Ablauf für `Abbruch (AI)`

### Ziel

Laufende Arbeit sofort stoppen, den Workspace bereinigen und das Issue sauber abbrechen.

### Voraussetzungen

- Das Issue befindet sich aktuell in `Abbruch (AI)`.

### Ablauf

1. Brich laufende Arbeit sofort ab.
2. Entferne den zugehörigen Git-Worktree.
3. Lösche eine eventuell vorhandene PR und/oder den Remote-Branch über den bestehenden Cleanup-Ablauf.

### Abschluss und nächster Status

- Verschiebe das Issue danach nach `Abgebrochen`.

### Sonderfälle

- Keine.

## Verpflichtende Sonderprotokolle

### Erstkontakt-Protokoll für neue Items

Führe dieses Protokoll nur dann aus, wenn alle folgenden Bedingungen gleichzeitig erfüllt sind:

1. Du hast in diesem Turn festgestellt, dass vorab kein aktiver `## Codex Workpad`-Kommentar existierte und musstest deshalb einen neuen Workpad-Kommentar anlegen.
2. Du hast zusätzlich per separater, vollständig paginierter Kommentarabfrage einschließlich aufgelöster Kommentare bestätigt, dass für dieses Issue außer dem Workpad-Kommentar, den du gerade in diesem Turn neu angelegt hast, noch nie ein `## Codex Workpad`-Kommentar existiert hat.
3. Wenn du diese Erstkontakt-Bedingung nicht zuverlässig verifizieren kannst, weil Kommentare oder Seiten nicht vollständig abrufbar sind, überspringe das Protokoll vollständig und lasse die Issue-Beschreibung unverändert.

Wenn die Trigger-Bedingungen erfüllt sind:

1. Lies den aktuellen Beschreibungstext des Issues direkt aus Linear.
2. Analysiere den Text auf Rechtschreibung, Grammatik, offensichtliche Spracherkennungsfehler und Formatierungsprobleme.
3. Korrigiere insbesondere falsche oder uneinheitliche Begriffe, die sich auf dieses Repository beziehen. Nutze dafür vorhandene Dateinamen, Modulnamen, Produktnamen, Workflow-Begriffe und andere repository-spezifische Referenzen als Quelle.
4. Bewahre die fachliche Bedeutung und den Scope des Tickets. Verbessere nur Sprache, Begriffswahl und Formatierung; füge keine neuen Anforderungen hinzu.
5. Speichere den bereinigten Beschreibungstext über den in der Sitzung verfügbaren Linear-Zugriff zurück in Linear. Nutze dazu den Linear-MCP-Server oder das injizierte Tool `linear_graphql` mit `issueUpdate(..., input: {description: ...})`, je nachdem was tatsächlich verfügbar ist, und nur wenn gegenüber dem Original tatsächlich eine qualitativ bessere, inhaltlich äquivalente Fassung entsteht.
6. Halte im Workpad knapp fest, ob die Erstkontakt-Korrektur durchgeführt wurde oder keine Änderung nötig war.
7. Führe dieses Protokoll niemals erneut aus, wenn bereits vor oder während eines früheren Turns ein Workpad-Kommentar für das Issue existiert hat.

### Blocked-access escape hatch

Nutze dies nur, wenn der Abschluss durch fehlende erforderliche Tools oder fehlende Auth/Berechtigungen blockiert ist, die in der laufenden Sitzung nicht auflösbar sind.

- Wenn ein erforderliches Tool fehlt oder erforderliche Auth nicht verfügbar ist, verschiebe das Ticket mit einem kurzen Blocker-Hinweis im Workpad nach `Freigabe`. Dieser Hinweis muss enthalten:
  - was fehlt,
  - warum dadurch erforderliche Akzeptanz/Validierung blockiert wird,
  - welche exakte menschliche Aktion zum Entblocken nötig ist.
- Halte den Hinweis knapp und handlungsorientiert; füge keine zusätzlichen Top-Level-Kommentare außerhalb des Workpads hinzu.

## Workpad-Standard

Verwende für den persistierenden Workpad-Kommentar exakt diese Struktur und halte sie während der gesamten Ausführung direkt an Ort und Stelle aktuell.

- Im Abschnitt `### Review` werden während `PreReview (AI)` die Schritte aus `.codex/skills/sym-prereview/SKILL.md` und während `Review (AI)` die Schritte aus `.codex/skills/sym-review/SKILL.md` als Checkliste mit kurzen Statusnotizen geführt; laufende Logs zu Befehlen, Ergebnissen und Fixes bleiben im Abschnitt `### Verlauf`.
- Im Abschnitt `### Test` werden die Schritte aus `.codex/skills/sym-test/SKILL.md` ebenfalls als Checkliste mit kurzen Statusnotizen geführt; detaillierte Test-Logs bleiben ebenfalls im Abschnitt `### Verlauf`.

````md
## Codex Workpad

```text
<hostname>:<abs-path>@<short-sha>
```

### Plan

- [ ] 1\. Übergeordnete Aufgabe
  - [ ] 1.1 Teilaufgabe
  - [ ] 1.2 Teilaufgabe
- [ ] 2\. Übergeordnete Aufgabe

### Akzeptanzkriterien

- [ ] Kriterium 1
- [ ] Kriterium 2

### Validierung

- [ ] gezielte Tests: `<command>`

### Review

- [ ] `<PreReview-/Review-Schritt aus dem aktiven Skill>`: `<kurze Statusnotiz>`

### Test

- [ ] `<Test-Schritt aus .codex/skills/sym-test/SKILL.md>`: `<kurze Statusnotiz>`

### Verlauf

- <kurze Fortschritts-/Review-/Test-Notiz mit Zeitstempel in lokaler Zeit>

### Unklarheiten

- <nur einfügen, wenn während der Ausführung etwas unklar war>
````

## Leitplanken und Verbote

- Wenn der Issue-Status `Backlog` ist, ändere ihn nicht; warte, bis ein Mensch ihn nach `Todo (AI)` verschiebt.
- Bearbeite den Issue-Body/die Beschreibung nicht für Planung oder Fortschrittsverfolgung. Die einzige Ausnahme ist das einmalige `Erstkontakt-Protokoll für neue Items`.
- Verwende pro Issue genau einen persistierenden Workpad-Kommentar (`## Codex Workpad`).
- Wenn Kommentarbearbeitung in der Sitzung nicht verfügbar ist, verwende das Update-Skript. Melde nur dann einen Blocker, wenn sowohl MCP-Bearbeitung als auch skriptbasierte Bearbeitung nicht verfügbar sind.
- Automatische Commits sind ausschließlich in `Review (AI)`, `Test (AI)` und `Merge (AI)` zulässig. In allen anderen Status bleiben sie verboten.
- Temporäre Proof-Änderungen sind nur für lokale Verifikation erlaubt und müssen vor der Übergabe nach `PreReview (AI)` rückgängig gemacht werden.
- Wenn Verbesserungen außerhalb des Scopes gefunden werden, erstelle ein separates Backlog-Issue, statt den aktuellen Scope zu erweitern, und nimm einen klaren Titel/eine klare Beschreibung/klare Akzeptanzkriterien, dieselbe Projektzuweisung, einen `related`-Link zum aktuellen Issue und `blockedBy` auf, wenn das Folge-Issue vom aktuellen Issue abhängt.
- Verschiebe nicht nach `PreReview (AI)`, solange die Abschlussbedingungen im Abschnitt `Ablauf für In Arbeit (AI)` nicht erfüllt sind.
- In `Freigabe` keine weiteren Codeänderungen vornehmen; auf den manuellen Commit warten. Kein regelmäßiges Polling.
- Wenn der Status terminal ist (`Fertig` oder `Abgebrochen`), nichts tun und beenden.
- Halte den Ticket-Text knapp, spezifisch und reviewer-orientiert.
