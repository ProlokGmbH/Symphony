---
tracker:
  kind: linear
  project_slug: $LINEAR_PROJECT_SLUG
  assignee: $LINEAR_ASSIGNEE
  active_states:
    - Todo Codex
    - In Arbeit
    - In Arbeit Codex
    - Review Codex
    - Test Codex
    - Abbruch Codex
    - Merge Codex
    - Neustart Codex
  terminal_states:
    - Closed
    - Cancelled
    - Canceled
    - Duplicate
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
      chmod 600 "$workspace/.env.local" 2>/dev/null || true
    fi
  on_worktree_commit: |
    cd "$SYMPHONY_WORKFLOW_DIR" && mise exec -- mix workspace.on_worktree_commit --source-repo "$SYMPHONY_PROJECT_ROOT" --workspace "$SYMPHONY_WORKSPACE" --branch "$SYMPHONY_BRANCH_NAME" --old-head "$SYMPHONY_PREV_HEAD_SHA" --new-head "$SYMPHONY_HEAD_SHA"
  before_remove: |
    # Closes open PRs, deletes the matching remote and local branches, and removes the linked worktree.
    workspace="$PWD"
    cd "$SYMPHONY_WORKFLOW_DIR" && mise exec -- mix workspace.before_remove --workspace "$workspace" --source-repo "$SYMPHONY_PROJECT_ROOT"
agent:
  max_concurrent_agents: 10
  max_turns: 20
codex:
  command: >-
    bash -lc '
      common_dir="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
      if [ -n "$common_dir" ]; then
        source_repo="$(cd "$common_dir/.." && pwd -P)"
        if [ -f "$source_repo/.venv/bin/activate" ]; then
          . "$source_repo/.venv/bin/activate"
        fi
      fi

      exec codex --config shell_environment_policy.inherit=all --config model_reasoning_effort=high --model gpt-5.4 app-server
    '
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
- Beende den Turn nicht, solange das Issue in einem aktiven Codex-Ausführungsstatus bleibt, außer du bist durch fehlende erforderliche Berechtigungen/Secrets blockiert. Ausnahme: Für `In Arbeit` endet der Turn regulär nach erfolgreichem Bootstrap von Worktree und leerem Workpad.
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
- Betrachte grundsätzlich nur Statuswerte mit `Codex` im Namen als automatische Arbeitsstatus. Die einzige Ausnahme ist `In Arbeit`; dort darfst du ausschließlich den Bootstrap von Git-Worktree und leerem Workpad ausführen.
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
- Wenn Linear, GitHub oder ältere Workpad-Notizen einen anderen Branchnamen anzeigen, behandle das als veraltete Metadaten und passe den lokalen Branch nicht daran an.

### Verwandte Skills

- `symphony-linear`: mit Linear interagieren.
- `symphony-push`: nach dem manuellen Commit den Remote-Branch aktualisieren und PR-Updates veröffentlichen.
- `symphony-pull`: den Branch vor der Übergabe mit dem neuesten `origin/main` synchronisieren.
- `symphony-review`: wenn das Ticket `Review Codex` erreicht, `.codex/skills/symphony-review/SKILL.md` explizit öffnen und befolgen; dort ist die repository-spezifische Review-Checkliste inklusive Review-/Fix-Schleife definiert.
- `symphony-test`: wenn das Ticket `Test Codex` erreicht, `.codex/skills/symphony-test/SKILL.md` explizit öffnen und befolgen; dort ist die repository-spezifische Test-Checkliste inklusive Test-/Fix-Schleife definiert.
- `symphony-land`: wenn das Ticket `Merge Codex` erreicht, `.codex/skills/symphony-land/SKILL.md` explizit öffnen und befolgen; dort ist die `symphony-land`-Schleife enthalten.

### Globale Arbeitsregeln

- Betrachte jeden vom Ticket vorgegebenen Abschnitt `Validation`, `Test Plan` oder `Testing` als nicht verhandelbare Akzeptanzvorgabe: spiegle ihn im Workpad wider und führe ihn aus, bevor du die Arbeit als abgeschlossen betrachtest.
- Wenn während der Ausführung sinnvolle Verbesserungen außerhalb des Scopes entdeckt werden, erstelle ein separates Linear-Issue, statt den Scope zu erweitern. Das Folge-Issue muss einen klaren Titel, eine Beschreibung und Akzeptanzkriterien enthalten, in `Backlog` eingeordnet sein, demselben Projekt wie das aktuelle Issue zugewiesen werden, das aktuelle Issue als `related` verknüpfen und `blockedBy` verwenden, wenn das Folge-Issue vom aktuellen Issue abhängt.
- Nutze den blocked-access escape hatch nur für echte externe Blocker (fehlende erforderliche Tools/Auth), nachdem dokumentierte Fallbacks ausgeschöpft wurden.

## Statusübersicht

| Status | Im Scope | Bedeutung / Verhalten | Nächster regulärer Status |
| --- | --- | --- | --- |
| `Backlog` | Nein | Außerhalb des Scopes dieses Workflows; nicht ändern. | Warten auf menschliches Verschieben nach `Todo Codex` |
| Nicht-terminale Stati ohne `Codex` im Namen, außer `In Arbeit` | Nein | Außerhalb des Scopes dieses Workflows; nicht pollen, nicht bearbeiten und nicht automatisch verschieben. | Warten auf menschliches Verschieben in einen Codex-Status |
| `In Arbeit` | Ja | Ausnahme vom Codex-Namensschema: beim Eintritt den kanonischen Git-Worktree unterhalb des konfigurierten Workspace-Roots sicherstellen und genau ein leeres `## Codex Workpad` erfassen. Keine weitere automatische Bearbeitung starten. | Warten auf menschliches Verschieben in einen Codex-Status |
| `Todo Codex` | Ja | In der Warteschlange; vor aktiver Arbeit sofort nach `In Arbeit Codex` verschieben. | `In Arbeit Codex` |
| `In Arbeit Codex` | Ja | Implementierung läuft aktiv. | `Review Codex` |
| `Review Codex` | Ja | Repository-spezifischen Review-/Fix-Zyklus ausführen. | `Review` |
| `Test Codex` | Ja | Repository-spezifischen Test-/Fix-Zyklus ausführen. | `Merge Codex` oder `Review` |
| `Review` | Nein | Außerhalb des aktiven Codex-Scopes; nichts tun und warten, bis ein Mensch weiter verschiebt. | `Test Codex`, `Merge Codex` oder `Neustart Codex` |
| `Merge Codex` | Ja | Merge-Ablauf mit `symphony-land` ausführen. | `Fertig` |
| `Neustart Codex` | Ja | Reviewer hat Änderungen angefordert; vollständigen Neustart ausführen. | `In Arbeit Codex` |
| `Abbruch Codex` | Ja | Laufende Arbeit sofort abbrechen und Cleanup ausführen. | `Abgebrochen` |
| `Fertig` | Nein | Terminaler Status; keine weitere Aktion erforderlich. | - |
| `Abgebrochen` | Nein | Terminaler Status nach explizitem Abbruch; keine weitere Aktion erforderlich. | - |

## Einstieg und Routing

1. Hole das Issue über die explizite Ticket-ID.
2. Lies den aktuellen Status.
3. Füge einen kurzen Kommentar hinzu, wenn Status und Issue-Inhalt nicht konsistent sind, und fahre dann mit dem sichersten Ablauf fort.
4. Leite in den passenden Ablauf weiter:
   - `Backlog` -> Issue-Inhalt/Status nicht ändern; stoppen und warten, bis ein Mensch es auf `Todo Codex` setzt.
   - Jeder nicht-terminale Status ohne `Codex` im Namen, außer `In Arbeit` (zum Beispiel `Review`) -> nichts tun und beenden; warten, bis ein Mensch das Issue wieder in einen Codex-Status verschiebt.
   - `In Arbeit` -> Ablauf `In Arbeit` ausführen.
   - `Todo Codex` -> Ablauf `Todo Codex` ausführen.
   - `In Arbeit Codex` -> Ablauf `In Arbeit Codex` ausführen.
   - `Review Codex` -> Ablauf `Review Codex` ausführen.
   - `Test Codex` -> Ablauf `Test Codex` ausführen.
   - `Abbruch Codex` -> Ablauf `Abbruch Codex` ausführen.
   - `Merge Codex` -> Ablauf `Merge Codex` ausführen.
   - `Neustart Codex` -> Ablauf `Neustart Codex` ausführen.
   - `Fertig` -> nichts tun und beenden.
   - `Abgebrochen` -> nichts tun und beenden.
5. Bevor du einen aktiven Codex-Ausführungsablauf fortsetzt, prüfe, ob für den aktuellen Branch bereits eine PR existiert und ob sie geschlossen ist.
   - Wenn eine Branch-PR existiert und `CLOSED` oder `MERGED` ist, behandle die bisherige Branch-Arbeit für diesen Lauf als nicht wiederverwendbar.
   - Erstelle oder verwende den kanonischen Branch `symphony/{{ issue.identifier }}` von `origin/main` und starte den Ausführungsablauf als neuen Versuch neu.

## Ablauf für `Todo Codex`

### Ziel

Das Issue aus der Warteschlange in die aktive Bearbeitung überführen und den regulären Ausführungsablauf sauber starten.

### Voraussetzungen

- Das Issue befindet sich aktuell in `Todo Codex`.

### Ablauf

1. Für `Todo Codex`-Tickets muss die Startsequenz exakt in dieser Reihenfolge erfolgen:
   - `update_issue(..., state: "In Arbeit Codex")`
   - `## Codex Workpad`-Bootstrap-Kommentar finden/erstellen
   - erst danach Analyse-, Planungs- und Implementierungsarbeit beginnen.
2. Wenn bereits eine PR angehängt ist, beginne damit, alle offenen PR-Kommentare zu prüfen und zwischen erforderlichen Änderungen und expliziten Pushback-Antworten zu unterscheiden.

### Abschluss und nächster Status

- Nach der unmittelbaren Statusänderung und dem Workpad-Bootstrap geht der Ablauf in `In Arbeit Codex` über.

### Sonderfälle

- Wenn bereits eine PR angehängt ist, behandle das Ticket als Feedback-/Rework-Schleife: vollständigen PR-Feedback-Sweep ausführen, Feedback lokal adressieren oder explizit Pushback geben, erneut lokal validieren und anschließend nach `Review Codex` weiterreichen; erst nach abgeschlossenem `Review Codex`-Lauf geht es nach `Review`.

## Ablauf für `In Arbeit`

### Ziel

Beim Eintritt in `In Arbeit` die Arbeitsumgebung für das Ticket vorbereiten, ohne den regulären Codex-Ausführungsablauf zu starten.

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
4. Starte keine weitere Analyse-, Planungs- oder Implementierungsarbeit.
5. Ändere den Status nicht automatisch weiter.

### Abschluss und nächster Status

- Nach erfolgreichem Bootstrap endet dieser Ablauf ohne weiteren Statuswechsel.
- Das Issue bleibt in `In Arbeit`, bis ein Mensch es in einen Codex-Status verschiebt.

### Sonderfälle

- Wenn der Bootstrap an einem echten externen Blocker scheitert, halte den Blocker knapp im Workpad fest und beende den Turn.

## Ablauf für `In Arbeit Codex`

### Ziel

Planung, Implementierung, lokale Validierung und ungecommittete Übergabe nach `Review Codex`.

### Voraussetzungen

- Das Issue befindet sich aktuell in `In Arbeit Codex`, oder kommt unmittelbar aus `Todo Codex`.
- Wenn du von `Todo Codex` kommst, verzögere nicht mit weiteren Statuswechseln: Das Issue sollte bereits `In Arbeit Codex` sein, bevor dieser Schritt beginnt.

### Ablauf

1. Finde oder erstelle genau einen persistierenden Scratchpad-Kommentar für das Issue:
   - Durchsuche vorhandene Kommentare nach dem Marker-Header `## Codex Workpad`.
   - Ignoriere bereits aufgelöste Kommentare während der Suche; nur aktive/nicht aufgelöste Kommentare dürfen als Live-Workpad wiederverwendet werden.
   - Falls vorhanden, verwende genau diesen Kommentar weiter; erstelle keinen neuen Workpad-Kommentar.
   - Falls nicht vorhanden, erstelle einen Workpad-Kommentar und nutze ihn für alle Updates.
   - Speichere die ID des Workpad-Kommentars und schreibe Fortschrittsupdates nur in diese ID.
2. Gleiche das Workpad vor neuen Änderungen sofort ab:
   - Hake bereits erledigte Punkte ab.
   - Erweitere/korrigiere den Plan so, dass er für den aktuellen Scope vollständig ist.
   - Stelle sicher, dass `Akzeptanzkriterien` und `Validierung` aktuell sind und weiterhin zur Aufgabe passen.
3. Starte die Arbeit, indem du einen hierarchischen Plan im Workpad-Kommentar schreibst bzw. aktualisierst.
4. Stelle sicher, dass das Workpad oben einen kompakten Environment-Stamp als Code-Fence-Zeile enthält:
   - Format: `<host>:<abs-workdir>@<short-sha>`
   - Beispiel: `devbox-01:/home/dev-user/code/symphony-workspaces/MT-32@7bdde33bc`
   - Nimm keine Metadaten auf, die bereits aus den Linear-Issue-Feldern ableitbar sind (`issue ID`, `status`, `branch`, `PR link`).
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
    - Für Tickets, die als `Todo Codex` mit angehängter PR gestartet sind, führe das vollständige PR-Feedback-Sweep-Protokoll sofort nach dem Kickoff und vor neuer Feature-Arbeit aus.
13. Führe die für den Scope erforderlichen Validierungen/Tests aus.
    - Verpflichtendes Gate: Führe alle im Ticket vorgegebenen Anforderungen aus `Validierung`/`Test Plan`/`Testing` aus, wenn sie vorhanden sind; behandle unerfüllte Punkte als unvollständige Arbeit.
    - Bevorzuge einen gezielten Nachweis, der direkt das geänderte Verhalten zeigt.
    - Du darfst temporäre lokale Proof-Änderungen machen, um Annahmen zu validieren (zum Beispiel: einen lokalen Build-Input für `make` anpassen oder einen UI-Account/Response-Pfad hart codieren), wenn das die Sicherheit erhöht.
    - Nimm jede temporäre Proof-Änderung vor der Übergabe nach `Review Codex` wieder zurück.
    - Dokumentiere diese temporären Proof-Schritte und Ergebnisse in den Bereichen `Validierung`/`Verlauf` des Workpads, damit Reviewer den Nachweis nachvollziehen können.
    - Wenn die App berührt wird, führe vor der Übergabe die Validierung `launch-app` aus und erfasse/lade Medien über `github-pr-media` hoch.
14. Prüfe alle Akzeptanzkriterien erneut und schließe verbleibende Lücken.
15. Führe vor der Übergabe nach `Review Codex` die für deinen Scope erforderliche Validierung aus und bestätige, dass sie erfolgreich ist; falls nicht, behebe die Probleme und wiederhole den Lauf, bis alles grün ist.
16. Führe keine automatischen Commits aus. Alle Commits werden ausschließlich durch den Entwickler im Status `Review` erstellt.
17. Aktualisiere den Workpad-Kommentar mit dem finalen Checklistenstatus und den Validierungsnotizen.
    - Markiere abgeschlossene Punkte in Plan-/Akzeptanzkriterien-/Validierungs-Checklisten als erledigt.
    - Füge finale Übergabenotizen (lokaler Stand + Validierungszusammenfassung) im selben Workpad-Kommentar hinzu.
    - Halte explizit fest, dass der Arbeitsstand absichtlich ungecommittet für den `Review Codex`- und anschließenden manuellen Review-/Commit-Schritt übergeben wird.
    - Füge unten einen kurzen Abschnitt `### Unklarheiten` hinzu, wenn irgendein Teil der Ausführung unklar/verwirrend war, mit knappen Stichpunkten.
    - Poste keinen zusätzlichen Abschluss- oder Zusammenfassungs-Kommentar.
18. Bevor du nach `Review Codex` verschiebst, prüfe vorhandenes PR-Feedback nur dann per Polling, wenn bereits eine PR an dem Ticket hängt:
    - Lies den PR-Kommentar `Manual QA Plan` (falls vorhanden) und nutze ihn, um die UI-/Runtime-Testabdeckung für die aktuelle Änderung zu verschärfen.
    - Führe in diesem Fall das vollständige PR-Feedback-Sweep-Protokoll aus.
    - Bestätige, dass jeder erforderliche ticketseitige Validierungs-/Test-Plan-Punkt im Workpad explizit als abgeschlossen markiert ist.
    - Öffne das Workpad vor dem Statuswechsel erneut und aktualisiere es, sodass `Plan`, `Akzeptanzkriterien` und `Validierung` exakt zur erledigten Arbeit passen.

### Abschluss und nächster Status

- Der reguläre Abschluss dieser Phase ist `Review Codex`, nicht direkt `Review`.
- Erst dann nach `Review Codex` verschieben.
  - Ein direkter Übergang von `In Arbeit Codex` nach `Review` ist nur über den blocked-access escape hatch zulässig.
  - Ausnahme: Wenn du gemäß blocked-access escape hatch durch fehlende erforderliche Nicht-GitHub-Tools/Auth blockiert bist, verschiebe nach `Review` und füge den Blocker-Hinweis sowie explizite Entblockungsaktionen hinzu.
- Für `Todo Codex`-Tickets, bei denen bereits beim Kickoff eine PR angehängt war:
  - Stelle sicher, dass sämtliches vorhandenes PR-Feedback geprüft und aufgelöst wurde, einschließlich Inline-Review-Kommentaren (durch Code-Änderungen oder eine explizite, begründete Pushback-Antwort).
  - Verschiebe erst dann nach `Review Codex`.
- Vor dem Wechsel nach `Review Codex` müssen alle folgenden Bedingungen erfüllt sein:
  - Die Checkliste aus diesem Ablauf ist vollständig abgeschlossen und korrekt im einen Workpad-Kommentar abgebildet.
  - Akzeptanzkriterien und erforderliche ticketseitige Validierungspunkte sind abgeschlossen.
  - Validation/Tests sind für den aktuellen lokalen Arbeitsstand grün.
  - Falls bereits eine PR existiert, ist der PR-Feedback-Sweep abgeschlossen und es gibt keine umsetzbaren Kommentare mehr.
  - Das Workpad dokumentiert den finalen ungecommitten Übergabestand und die bestandene lokale Validierung explizit.
  - Falls die App berührt wird, sind die Runtime-Validierungs-/Media-Anforderungen aus `App runtime validation (required)` abgeschlossen.

### Sonderfälle

- Wenn du blockiert bist und noch kein Workpad existiert, füge einen Blocker-Kommentar hinzu, der Blocker, Auswirkung und nächste Entblockungsaktion beschreibt.

## Ablauf für `Review Codex`

### Ziel

Den repository-spezifischen Review-/Fix-Zyklus vollständig ausführen und das Issue danach in den menschlichen Review übergeben.

### Voraussetzungen

- Das Issue befindet sich aktuell in `Review Codex`.

### Ablauf

1. Öffne `.codex/skills/symphony-review/SKILL.md` und führe den dort definierten Ablauf aus.
2. Der Skill enthält die repository-spezifische Review-Checkliste, deren checklistenartige Workpad-Protokollierung unter `### Review` sowie die Review-/Fix-Schleife.

### Abschluss und nächster Status

- Verschiebe das Issue erst danach nach `Review`.
  - Nur dieser Schritt verschiebt regulär von `Review Codex` nach `Review`.

### Sonderfälle

- Falls ein `Review Codex`-Lauf sauber endet, das Issue aber fälschlich noch in `Review Codex` steht, übernimmt Symphony den Statuswechsel nach `Review` als Fallback automatisch.

## Ablauf für `Test Codex`

### Ziel

Den repository-spezifischen Test-/Fix-Zyklus auf einem sauberen Workspace ausführen und anhand des Ergebnisses den nächsten Status bestimmen.

### Voraussetzungen

- Das Issue befindet sich aktuell in `Test Codex`.
- Prüfe zuerst zuverlässig, dass im Workspace keine offenen Git-Änderungen aus dem manuellen `Review`-Schritt mehr vorhanden sind.

### Ablauf

1. Falls noch offene Änderungen vorhanden sind, verschiebe das Issue sofort zurück nach `Review`, damit der manuelle Commit-Schritt nachgeholt wird; den Test-Skill in diesem Fall nicht starten.
2. Nur mit sauberem Workspace `.codex/skills/symphony-test/SKILL.md` öffnen und den dort definierten Ablauf ausführen.
3. Der Skill enthält die repository-spezifische Test-Checkliste, deren checklistenartige Workpad-Protokollierung unter `### Test` sowie die Test-/Fix-Schleife.

### Abschluss und nächster Status

- Wenn der Testlauf ohne neue Workspace-Änderungen sauber endet, verschiebe das Issue nach `Merge Codex`.
- Wenn der Testlauf Codeänderungen erfordert und sauber endet, verschiebe das Issue zurück nach `Review`, damit der Entwickler die Änderungen erneut begutachten kann.

### Sonderfälle

- Falls ein `Test Codex`-Lauf sauber endet, das Issue aber fälschlich noch in `Test Codex` steht, übernimmt Symphony den passenden Statuswechsel als Fallback automatisch.

## Ablauf für `Review`

### Ziel

Den manuellen Review- und Commit-Schritt vollständig dem Entwickler überlassen und bis zum nächsten menschlichen Statuswechsel nichts automatisiert fortsetzen.

### Voraussetzungen

- Das Issue befindet sich aktuell in `Review`.

### Ablauf

1. Weder coden noch den Ticket-Inhalt ändern.
2. In diesem Status übernimmt der Entwickler den manuellen Review- und Commit-Schritt.
3. In diesem Status kein regelmäßiges Polling ausführen; warten, bis ein Mensch das Issue in einen anderen Status verschiebt.

### Abschluss und nächster Status

- Nach dem manuellen Review kann ein Mensch das Issue für einen zusätzlichen automatisierten Testlauf nach `Test Codex` verschieben oder nach abgeschlossenem manuellem Commit direkt nach `Merge Codex`.
- Wenn Review-Feedback Änderungen erfordert, verschiebt ein Mensch das Issue nach `Neustart Codex`.

### Sonderfälle

- Keine.

## Ablauf für `Merge Codex`

### Ziel

Den Merge-Ablauf mit `symphony-land` auf einem sauberen Workspace abschließen und das Issue danach nach `Fertig` verschieben.

### Voraussetzungen

- Das Issue befindet sich aktuell in `Merge Codex`.
- Prüfe zuerst zuverlässig, dass im Workspace keine offenen Git-Änderungen aus dem manuellen `Review`-Schritt mehr vorhanden sind.

### Ablauf

1. Falls noch offene Änderungen vorhanden sind, verschiebe das Issue sofort zurück nach `Review`, damit der manuelle Commit-Schritt nachgeholt wird; den Merge-Skill in diesem Fall nicht starten.
2. Nur mit sauberem Workspace `.codex/skills/symphony-land/SKILL.md` öffnen und befolgen und anschließend den Skill `symphony-land` in einer Schleife ausführen, bis die PR gemergt ist. `gh pr merge` nicht direkt aufrufen.

### Abschluss und nächster Status

- Nach abgeschlossenem Merge das Issue nach `Fertig` verschieben.

### Sonderfälle

- Keine.

## Ablauf für `Neustart Codex`

### Ziel

Einen vollständigen Reset des Vorgehens durchführen und die Bearbeitung anschließend sauber neu beginnen.

### Voraussetzungen

- Das Issue befindet sich aktuell in `Neustart Codex`.

### Ablauf

1. Behandle `Neustart Codex` als vollständigen Reset des Vorgehens, nicht als inkrementelles Patchen.
2. Lies den kompletten Issue-Body und alle menschlichen Kommentare erneut; identifiziere explizit, was in diesem Versuch anders gemacht wird.
3. Schließe die bestehende PR, die mit dem Issue verknüpft ist.
4. Entferne den bestehenden Kommentar `## Codex Workpad` vom Issue.
5. Erstelle einen frischen Branch von `origin/main`.
   - Der Branchname muss exakt `symphony/{{ issue.identifier }}` sein.
6. Starte erneut mit dem normalen Kickoff-Ablauf:
   - Wenn der aktuelle Issue-Status `Todo Codex` ist, verschiebe nach `In Arbeit Codex`; andernfalls behalte den aktuellen Status.
   - Erstelle einen neuen Bootstrap-Kommentar `## Codex Workpad`.
   - Erstelle einen frischen Plan/eine frische Checkliste und arbeite sie end-to-end ab.

### Abschluss und nächster Status

- Nach dem Reset beginnt die Bearbeitung wieder im regulären Kickoff-Ablauf und läuft in Richtung `In Arbeit Codex`.

### Sonderfälle

- Keine.

## Ablauf für `Abbruch Codex`

### Ziel

Laufende Arbeit sofort stoppen, den Workspace bereinigen und das Issue sauber abbrechen.

### Voraussetzungen

- Das Issue befindet sich aktuell in `Abbruch Codex`.

### Ablauf

1. Brich laufende Arbeit sofort ab.
2. Entferne den zugehörigen Git-Worktree.
3. Lösche eine eventuell vorhandene PR und/oder den Remote-Branch über den bestehenden Cleanup-Ablauf.

### Abschluss und nächster Status

- Verschiebe das Issue danach nach `Abgebrochen`.

### Sonderfälle

- Keine.

## Verpflichtende Sonderprotokolle

### PR-Feedback-Sweep-Protokoll

Wenn an ein Ticket bereits eine PR angehängt ist, führe dieses Protokoll aus, bevor du es nach `Review Codex` verschiebst:

1. Ermittle die PR-Nummer aus Issue-Links/Attachments.
2. Sammle Feedback aus allen Kanälen:
   - Top-Level-PR-Kommentare (`gh pr view --comments`).
   - Inline-Review-Kommentare (`gh api repos/<owner>/<repo>/pulls/<pr>/comments`).
   - Review-Zusammenfassungen/-Status (`gh pr view --json reviews`).
3. Behandle jeden umsetzbaren Reviewer-Kommentar (Mensch oder Bot), einschließlich Inline-Review-Kommentaren, als blockierend, bis eine der folgenden Bedingungen erfüllt ist:
   - Code/Tests/Doku wurden aktualisiert, um ihn zu adressieren, oder
   - in genau diesem Thread wurde eine explizite, begründete Pushback-Antwort gepostet.
4. Aktualisiere Plan/Checkliste im Workpad, sodass jeder Feedback-Punkt und sein Auflösungsstatus enthalten sind.
5. Führe nach feedbackgetriebenen Änderungen die Validierung erneut lokal aus und dokumentiere, dass die resultierenden Änderungen für `Review Codex` und den anschließenden manuellen Commit in `Review` bereitliegen; nach dem manuellen Commit können Pushes/PR-Updates weiterhin folgen.
6. Wiederhole diesen Sweep, bis keine offenen umsetzbaren Kommentare mehr vorhanden sind.

### Blocked-access escape hatch

Nutze dies nur, wenn der Abschluss durch fehlende erforderliche Tools oder fehlende Auth/Berechtigungen blockiert ist, die in der laufenden Sitzung nicht auflösbar sind.

- GitHub ist vor `Review` standardmäßig **kein** gültiger Blocker. Automatische Commits gehören nicht in diesen Ablauf.
- Verschiebe nicht wegen GitHub-Zugriff/Auth nach `Review`; der Entwickler übernimmt dort den manuellen Commit-Schritt. Pushes und PR-Aktualisierungen können anschließend weiterhin erfolgen.
- Wenn ein erforderliches Nicht-GitHub-Tool fehlt oder erforderliche Nicht-GitHub-Auth nicht verfügbar ist, verschiebe das Ticket mit einem kurzen Blocker-Hinweis im Workpad nach `Review`. Dieser Hinweis muss enthalten:
  - was fehlt,
  - warum dadurch erforderliche Akzeptanz/Validierung blockiert wird,
  - welche exakte menschliche Aktion zum Entblocken nötig ist.
- Halte den Hinweis knapp und handlungsorientiert; füge keine zusätzlichen Top-Level-Kommentare außerhalb des Workpads hinzu.

## Workpad-Standard

Verwende für den persistierenden Workpad-Kommentar exakt diese Struktur und halte sie während der gesamten Ausführung direkt an Ort und Stelle aktuell.

- Im Abschnitt `### Review` werden die Schritte aus `.symphony/review_codex.md` als Checkliste mit kurzen Statusnotizen geführt; laufende Logs zu Befehlen, Ergebnissen und Fixes bleiben im Abschnitt `### Verlauf`.
- Im Abschnitt `### Test` werden die Schritte aus `.symphony/test_codex.md` ebenfalls als Checkliste mit kurzen Statusnotizen geführt; detaillierte Test-Logs bleiben ebenfalls im Abschnitt `### Verlauf`.

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

- [ ] `<Review-Schritt aus .symphony/review_codex.md>`: `<kurze Statusnotiz>`

### Test

- [ ] `<Test-Schritt aus .symphony/test_codex.md>`: `<kurze Statusnotiz>`

### Verlauf

- <kurze Fortschritts-/Review-/Test-Notiz mit Zeitstempel in lokaler Zeit>

### Unklarheiten

- <nur einfügen, wenn während der Ausführung etwas unklar war>
````

## Leitplanken und Verbote

- Wenn die Branch-PR bereits geschlossen/gemergt ist, verwende diesen Branch oder den bisherigen Implementierungszustand nicht erneut für eine Fortsetzung.
- Für geschlossene/gemergte Branch-PRs erstelle oder verwende den kanonischen Branch `symphony/{{ issue.identifier }}` von `origin/main` und starte bei Reproduktion/Planung neu, als würdest du frisch beginnen.
- Wenn der Issue-Status `Backlog` ist, ändere ihn nicht; warte, bis ein Mensch ihn nach `Todo Codex` verschiebt.
- Bearbeite den Issue-Body/die Beschreibung nicht für Planung oder Fortschrittsverfolgung.
- Verwende pro Issue genau einen persistierenden Workpad-Kommentar (`## Codex Workpad`).
- Wenn Kommentarbearbeitung in der Sitzung nicht verfügbar ist, verwende das Update-Skript. Melde nur dann einen Blocker, wenn sowohl MCP-Bearbeitung als auch skriptbasierte Bearbeitung nicht verfügbar sind.
- Führe keine automatischen Commits aus. Alle Commits werden ausschließlich manuell durch den Entwickler im Status `Review` erstellt.
- Temporäre Proof-Änderungen sind nur für lokale Verifikation erlaubt und müssen vor der Übergabe nach `Review Codex` rückgängig gemacht werden.
- Wenn Verbesserungen außerhalb des Scopes gefunden werden, erstelle ein separates Backlog-Issue, statt den aktuellen Scope zu erweitern, und nimm einen klaren Titel/eine klare Beschreibung/klare Akzeptanzkriterien, dieselbe Projektzuweisung, einen `related`-Link zum aktuellen Issue und `blockedBy` auf, wenn das Folge-Issue vom aktuellen Issue abhängt.
- Verschiebe nicht nach `Review Codex`, solange die Abschlussbedingungen im Abschnitt `Ablauf für In Arbeit Codex` nicht erfüllt sind.
- In `Review` keine weiteren Codeänderungen vornehmen; auf manuellen Commit sowie gegebenenfalls nachgelagerte Push-/PR-Updates warten. Kein regelmäßiges Polling.
- Wenn der Status terminal ist (`Fertig` oder `Abgebrochen`), nichts tun und beenden.
- Halte den Ticket-Text knapp, spezifisch und reviewer-orientiert.
