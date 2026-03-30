---
tracker:
  kind: linear
  project_slug: $LINEAR_PROJECT_SLUG
  assignee: $LINEAR_ASSIGNEE
  active_states:
    - Todo (AI)
    - Planung (AI)
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
    set -eu
    workspace="$PWD"
    issue_key="$(basename "$workspace")"
    branch="symphony/$issue_key"
    source_repo="$SYMPHONY_PROJECT_ROOT"
    if ! git -C "$workspace" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
      rm -rf "$workspace"
    fi
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
    if [ -x "$source_repo/sym-codex" ]; then
      exec "$source_repo/sym-codex" --observer;
    fi;
    if command -v sym-codex >/dev/null 2>&1; then
      exec "$(command -v sym-codex)" --observer;
    fi;
    echo "sym-codex not found in $source_repo or PATH" >&2;
    exit 127
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
- Beende den Turn nicht, solange das Issue in einem aktiven Codex-Ausführungsstatus bleibt, außer du bist durch fehlende erforderliche Berechtigungen/Secrets blockiert.
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
- Betrachte grundsätzlich nur Statuswerte mit `(AI)` im Namen als automatische Arbeitsstatus.
- Starte jede Aufgabe damit, den verfolgenden Workpad-Kommentar zu öffnen und auf den neuesten Stand zu bringen, bevor neue Implementierungsarbeit beginnt.
- Investiere vor der Implementierung bewusst mehr Aufwand in Planung und Verifikationsdesign.
- Reproduziere zuerst: bestätige immer das aktuelle Verhalten bzw. Signal des Problems, bevor du Code änderst, damit das Ziel des Fixes eindeutig ist.
- Verwende für neue Zeitstempel im Abschnitt `Verlauf` immer lokale Systemzeit; schreibe dort keine UTC- oder `Z`-Zeitstempel.
- Halte die Ticket-Metadaten aktuell (Status, Checkliste, Validierung, Links).
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

- Betrachte jeden vom Ticket vorgegebenen Abschnitt `Validation`, `Test Plan` oder `Testing` als nicht verhandelbare Validierungsvorgabe: übernimm ihn als Punkte im Abschnitt `### Validierung` des Workpads und führe ihn aus, bevor du die Arbeit als abgeschlossen betrachtest.
- Wenn während der Ausführung sinnvolle Verbesserungen außerhalb des Scopes entdeckt werden, erstelle ein separates Linear-Issue, statt den Scope zu erweitern. Das Folge-Issue muss einen klaren Titel, eine Beschreibung und Validierungspunkte enthalten, in `Backlog` eingeordnet sein, demselben Projekt wie das aktuelle Issue zugewiesen werden, das aktuelle Issue als `related` verknüpfen und `blockedBy` verwenden, wenn das Folge-Issue vom aktuellen Issue abhängt.
- Nutze den blocked-access escape hatch nur für echte externe Blocker (fehlende erforderliche Tools/Auth), nachdem dokumentierte Fallbacks ausgeschöpft wurden.

## Statusübersicht

| Status | Im Scope | Bedeutung / Verhalten | Nächster regulärer Status |
| --- | --- | --- | --- |
| `Backlog` | Nein | Außerhalb des Scopes dieses Workflows; nicht ändern. | Warten auf menschliches Verschieben nach `Todo (AI)` |
| `Todo` | Nein | Außerhalb des Scopes dieses Workflows; Benutzer-Todo ohne Automatisierung. | Warten auf menschliches Verschieben nach `Todo (AI)` |
| `Todo (AI)` | Ja | In der Warteschlange; vor aktiver Arbeit sofort nach `Planung (AI)` verschieben. | `Planung (AI)` |
| `Planung (AI)` | Ja | Ticketbeschreibung und Workpad-Planung für die Umsetzung vorbereiten; noch nicht implementieren. | `Freigabe Planung` |
| `Freigabe Planung` | Nein | Manueller Plan-Freigabepunkt; keine weitere automatische Aktion bis zum nächsten menschlichen Statuswechsel. | Warten auf menschliches Verschieben |
| `In Arbeit (AI)` | Ja | Implementierung des bestehenden, zuvor manuell geprüften Plans läuft aktiv. | `PreReview (AI)` |
| `PreReview (AI)` | Ja | Repository-spezifischen PreReview-/Fix-Zyklus ausführen. | `Freigabe Implementierung` |
| `Freigabe Implementierung` | Nein | Manueller Review- und Commit-Schritt nach PreReview; keine weitere automatische Aktion bis zum nächsten menschlichen Statuswechsel. | Warten auf menschliches Verschieben |
| `Review (AI)` | Ja | Repository-spezifischen Review-/Fix-Zyklus ausführen; automatische Commits sind in diesem Status zulässig und resultierende Fix-Commits werden vor der Übergabe veröffentlicht. | `Test (AI)` |
| `Test (AI)` | Ja | Repository-spezifischen Test-/Fix-Zyklus ausführen; automatische Commits sind in diesem Status zulässig und resultierende Fix-Commits werden vor `Freigabe Final` veröffentlicht. | `Freigabe Final` |
| `Freigabe Final` | Nein | Manueller Final-Checkpoint vor dem Merge; keine weitere automatische Aktion bis zum nächsten menschlichen Statuswechsel. | Warten auf menschliches Verschieben |
| `Merge (AI)` | Ja | Merge-Ablauf mit `symphony-land` ausführen; automatische Commits sind in diesem Status zulässig. | `Review` |
| `BLOCKER` | Nein | Kritische Abweichung oder externer Blocker; keine weitere automatische Aktion, bis ein Mensch das Problem löst und das Ticket weiter verschiebt. | Warten auf menschliches Verschieben |
| `Abbruch (AI)` | Ja | Laufende Arbeit sofort abbrechen und Cleanup ausführen. | `Abgebrochen` |
| `Review` | Nein | Terminaler Übergabestatus nach dem Merge; keine weitere automatische Aktion, manuelles Verschieben nach `Fertig` bleibt beim Benutzer. | - |
| `Fertig` | Nein | Terminaler Status; keine weitere Aktion erforderlich. | - |
| `Abgebrochen` | Nein | Terminaler Status nach explizitem Abbruch; keine weitere Aktion erforderlich. | - |

## Einstieg und Routing

1. Hole das Issue über die explizite Ticket-ID.
2. Lies den aktuellen Status.
3. Füge einen kurzen Kommentar hinzu, wenn Status und Issue-Inhalt nicht konsistent sind, und fahre dann mit dem sichersten Ablauf fort.
4. Leite in den passenden Ablauf weiter:
   - `Backlog` -> Issue-Inhalt/Status nicht ändern; stoppen und warten, bis ein Mensch es auf `Todo (AI)` setzt.
   - `Todo` -> nichts tun und beenden; warten, bis ein Mensch das Issue auf `Todo (AI)` setzt.
   - `Todo (AI)` -> Ablauf `Todo (AI)` ausführen.
   - `Planung (AI)` -> Ablauf `Planung (AI)` ausführen.
   - `Freigabe Planung` -> nichts tun und beenden; warten, bis ein Mensch das Issue wieder in einen AI-Status verschiebt.
   - `In Arbeit (AI)` -> Ablauf `In Arbeit (AI)` ausführen.
   - `PreReview (AI)` -> Ablauf `PreReview (AI)` ausführen.
   - `Freigabe Implementierung` -> nichts tun und beenden; warten, bis ein Mensch das Issue wieder in einen AI-Status verschiebt.
   - `Review (AI)` -> Ablauf `Review (AI)` ausführen.
   - `Test (AI)` -> Ablauf `Test (AI)` ausführen.
   - `Freigabe Final` -> nichts tun und beenden; warten, bis ein Mensch das Issue wieder in einen AI-Status verschiebt.
   - `Abbruch (AI)` -> Ablauf `Abbruch (AI)` ausführen.
   - `Merge (AI)` -> Ablauf `Merge (AI)` ausführen.
   - `Review` -> nichts tun und beenden.
   - `Fertig` -> nichts tun und beenden.
   - `Abgebrochen` -> nichts tun und beenden.
## Ablauf für `Todo (AI)`

### Ziel

Das Issue aus der Warteschlange in die Planungsphase überführen und den regulären Ausführungsablauf sauber starten.

### Voraussetzungen

- Das Issue befindet sich aktuell in `Todo (AI)`.

### Ablauf

1. Für `Todo (AI)`-Tickets muss die Startsequenz exakt in dieser Reihenfolge erfolgen:
   - `update_issue(..., state: "Planung (AI)")`
   - `## Codex Workpad`-Bootstrap-Kommentar finden/erstellen
   - falls der Kommentar dabei erstmals neu angelegt wird, prüfe die Trigger-Bedingungen des `Erstkontakt-Protokolls für neue Items` und führe es nur bei bestätigtem Erstkontakt aus
   - erst danach in den Ablauf `Planung (AI)` übergehen.

### Abschluss und nächster Status

- Nach der unmittelbaren Statusänderung und dem Workpad-Bootstrap geht der Ablauf in `Planung (AI)` über.

### Sonderfälle

- Keine.

## Ablauf für `Planung (AI)`

### Ziel

Ticketbeschreibung, Workpad-Plan und geplante Validierung so vorbereiten, dass die
anschließende menschliche Prüfung in `Freigabe Planung` und danach die Umsetzung in
`In Arbeit (AI)` ohne autonome Neuplanung beginnen kann.

### Voraussetzungen

- Das Issue befindet sich aktuell in `Planung (AI)`, oder kommt unmittelbar aus `Todo (AI)`.

### Ablauf

1. Finde oder erstelle genau einen persistierenden Scratchpad-Kommentar für das Issue und befolge für Aufbau und Pflege des Kommentars den Skill `.codex/skills/symphony-workpad/SKILL.md`.
2. Führe die inhaltliche Planung mit `.codex/skills/symphony-planning/SKILL.md` aus:
   - prüfe, ob die Ticketbeschreibung ausführlich genug für sichere Umsetzung ist,
   - stelle bei langen Beschreibungen sicher, dass oben eine kurze Zusammenfassung mit Trenner `---` vor dem Haupttext steht,
   - du darfst die Ticketbeschreibung in diesem Status automatisiert ändern, wenn das für eine vollständige Planung nötig ist,
   - falls du die Ticketbeschreibung änderst, hinterlasse in Linear einen Kommentar mit der Originalbeschreibung, damit die Änderung nachvollziehbar bleibt,
   - erstelle oder aktualisiere `### Plan` als hierarchische Checkliste,
   - stelle sicher, dass der Plan explizite Schritte für automatisierte Tests enthält,
   - erstelle oder aktualisiere `### Validierung` als Checkliste des geplanten Nachweises.
3. Starte in diesem Status keine Implementierung.
4. Ändere den inhaltlichen Plan und die geplante Validierung nur in diesem Status; spätere automatische Schritte dürfen diese Inhalte nicht autonom umschreiben.

### Abschluss und nächster Status

- Wenn Ticketbeschreibung, `Plan` und `Validierung` ausreichend vorbereitet sind, verschiebe das Issue nach `Freigabe Planung`, damit ein Mensch den Plan vor der Umsetzung prüfen kann.

### Sonderfälle

- Wenn für sichere Planung erforderliche Informationen fehlen, erfinde keinen Scope. Halte die Lücke knapp im Workpad fest und handle anschließend gemäß den übrigen Workflow-Regeln weiter.

## Ablauf für `In Arbeit (AI)`

### Ziel

Umsetzung des bestehenden Plans, lokale Validierung und ungecommittete Übergabe
nach `PreReview (AI)`.

### Voraussetzungen

- Das Issue befindet sich aktuell in `In Arbeit (AI)`.
- Bevor dieser Schritt beginnt, müssen Ticketbeschreibung, `Plan` und `Validierung` bereits in `Planung (AI)` vorbereitet und anschließend im manuellen Status `Freigabe Planung` geprüft worden sein.

### Ablauf

1. Öffne den vorhandenen `## Codex Workpad`-Kommentar und behandle ihn gemäß `.codex/skills/symphony-workpad/SKILL.md` als aktive Ausführungs-Checkliste.
2. Verwende `### Plan` und `### Validierung` aus der vorherigen `Planung (AI)`-Phase als verbindliche Grundlage für die Ausführung.
3. Ändere `### Plan` und die geplanten Punkte in `### Validierung` in diesem Status nicht autonom inhaltlich um; hake vorhandene Punkte ab und dokumentiere Fortschritt im bestehenden Workpad.
4. Erfasse vor der Implementierung ein konkretes Reproduktionssignal im Abschnitt `### Verlauf`.
5. Implementiere entlang der vorhandenen Plan-Checkliste und aktualisiere den Workpad-Kommentar nach jedem wesentlichen Meilenstein.
6. Führe die für den Scope erforderlichen Validierungen/Tests aus.
   - Verpflichtendes Gate: Führe alle im Ticket vorgegebenen und in `### Validierung` des Workpads übernommenen Anforderungen aus `Validation`, `Test Plan` oder `Testing` aus; behandle unerfüllte Punkte als unvollständige Arbeit.
   - Bevorzuge einen gezielten Nachweis, der direkt das geänderte Verhalten zeigt.
   - Du darfst temporäre lokale Proof-Änderungen machen, um Annahmen zu validieren, wenn das die Sicherheit erhöht.
   - Nimm jede temporäre Proof-Änderung vor der Übergabe nach `PreReview (AI)` wieder zurück.
   - Dokumentiere diese temporären Proof-Schritte und Ergebnisse in `### Validierung` und/oder `### Verlauf`.
7. Wenn die Ausführung neue Erkenntnisse hervorbringt, die eine inhaltliche Neuplanung erfordern, halte das knapp im Workpad fest und verschiebe das Issue zurück nach `Planung (AI)`, statt den Plan in diesem Status autonom umzuschreiben.
8. Führe in `In Arbeit (AI)` keine automatischen Commits aus. Der Arbeitsstand muss für `PreReview (AI)` und den anschließenden manuellen Schritt `Freigabe Implementierung` bewusst ungecommittet bleiben.
9. Aktualisiere den Workpad-Kommentar mit dem finalen Checklistenstatus und den Validierungsnotizen.
   - Markiere abgeschlossene Punkte in Plan-/Validierungs-Checklisten als erledigt.
   - Füge finale Übergabenotizen (lokaler Stand + Validierungszusammenfassung) im selben Workpad-Kommentar hinzu.
   - Halte explizit fest, dass der Arbeitsstand absichtlich ungecommittet für den `PreReview (AI)`- und anschließenden manuellen Schritt `Freigabe Implementierung` übergeben wird.
   - Füge unten einen kurzen Abschnitt `### Unklarheiten` hinzu, wenn irgendein Teil der Ausführung unklar/verwirrend war, mit knappen Stichpunkten.
   - Poste keinen zusätzlichen Abschluss- oder Zusammenfassungs-Kommentar.
10. Bestätige vor dem Wechsel nach `PreReview (AI)`, dass jeder erforderliche ticketseitige Validierungs-/Test-Plan-Punkt im Workpad explizit als abgeschlossen markiert ist.
11. Öffne das Workpad vor dem Statuswechsel erneut und aktualisiere es, sodass `Plan` und `Validierung` exakt zur erledigten Arbeit passen.

### Abschluss und nächster Status

- Der reguläre Abschluss dieser Phase ist `PreReview (AI)`, nicht direkt `Freigabe Implementierung`.
- Erst dann nach `PreReview (AI)` verschieben.
  - Ein direkter Übergang von `In Arbeit (AI)` nach `BLOCKER` ist nur über den blocked-access escape hatch zulässig.
  - Ausnahme: Wenn du gemäß blocked-access escape hatch durch fehlende erforderliche Tools/Auth blockiert bist, verschiebe nach `BLOCKER` und füge den Blocker-Hinweis sowie explizite Entblockungsaktionen hinzu.
- Vor dem Wechsel nach `PreReview (AI)` müssen alle folgenden Bedingungen erfüllt sein:
  - Die Checkliste aus diesem Ablauf ist vollständig abgeschlossen und korrekt im einen Workpad-Kommentar abgebildet.
  - Erforderliche ticketseitige Validierungspunkte sind abgeschlossen.
  - Validation/Tests sind für den aktuellen lokalen Arbeitsstand grün.
  - Das Workpad dokumentiert den finalen ungecommitten Übergabestand und die bestandene lokale Validierung explizit.
  - Falls die App berührt wird, sind die Runtime-Validierungsanforderungen aus `App runtime validation (required)` abgeschlossen.

### Sonderfälle

- Wenn du blockiert bist und noch kein Workpad existiert, füge einen Blocker-Kommentar hinzu, der Blocker, Auswirkung und nächste Entblockungsaktion beschreibt.

## Ablauf für `PreReview (AI)`

### Ziel

Den repository-spezifischen PreReview-/Fix-Zyklus vollständig ausführen und das Issue danach in den manuellen Schritt `Freigabe Implementierung` übergeben.

### Voraussetzungen

- Das Issue befindet sich aktuell in `PreReview (AI)`.

### Ablauf

1. Öffne `.codex/skills/symphony-prereview/SKILL.md` und führe den dort definierten Ablauf aus.
2. Der Skill enthält die repository-spezifische PreReview-Checkliste, deren checklistenartige Workpad-Protokollierung unter `### Review` sowie die gezielte Schrittwiederholung ohne kompletten Neustart.

### Abschluss und nächster Status

- Verschiebe das Issue erst danach nach `Freigabe Implementierung`.
  - Nur dieser Schritt verschiebt regulär von `PreReview (AI)` nach `Freigabe Implementierung`.

### Sonderfälle

- Falls ein `PreReview (AI)`-Lauf sauber endet, das Issue aber fälschlich noch in `PreReview (AI)` steht, übernimmt Symphony den Statuswechsel nach `Freigabe Implementierung` als Fallback automatisch.

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

Den repository-spezifischen Test-/Fix-Zyklus ausführen, notwendige Folge-Fixes in diesem Status committen dürfen und das Issue danach nach `Freigabe Final` übergeben.

### Voraussetzungen

- Das Issue befindet sich aktuell in `Test (AI)`.

### Ablauf

1. Öffne `.codex/skills/symphony-test/SKILL.md` und führe den dort definierten Ablauf aus.
2. Der Skill enthält die repository-spezifische Test-Checkliste, deren checklistenartige Workpad-Protokollierung unter `### Test` sowie die Test-/Fix-Schleife.
3. Wenn der Testlauf Fixes erzeugt, committe den resultierenden Stand in diesem Status und veröffentliche ihn anschließend mit `symphony-push`, damit vor `Freigabe Final` ein landbarer Remote-Branch existiert.

### Abschluss und nächster Status

- Verschiebe das Issue nur mit sauberem Workspace nach `Freigabe Final`.
  - Nur dieser Schritt verschiebt regulär von `Test (AI)` nach `Freigabe Final`.

### Sonderfälle

- Falls ein `Test (AI)`-Lauf sauber endet, das Issue aber fälschlich noch in `Test (AI)` steht, übernimmt Symphony den passenden Statuswechsel nach `Freigabe Final` als Fallback automatisch.

## Ablauf für `Freigabe Planung`

### Ziel

Die manuelle Planprüfung vollständig dem Entwickler überlassen und bis zum nächsten menschlichen Statuswechsel nichts automatisiert fortsetzen.

### Voraussetzungen

- Das Issue befindet sich aktuell in `Freigabe Planung`.

### Ablauf

1. Weder coden noch den Ticket-Inhalt ändern.
2. In diesem Status übernimmt der Entwickler die manuelle Planprüfung.
3. In diesem Status kein regelmäßiges Polling ausführen; warten, bis ein Mensch das Issue in einen anderen Status verschiebt.

### Abschluss und nächster Status

- Nach der manuellen Planfreigabe verschiebt ein Mensch das Issue regulär nach `In Arbeit (AI)`.
- Wenn Plan-Feedback Änderungen erfordert, verschiebt ein Mensch das Issue nach `Planung (AI)`.

### Sonderfälle

- Keine.

## Ablauf für `Freigabe Implementierung`

### Ziel

Den manuellen Review- und Commit-Schritt nach der Umsetzung vollständig dem Entwickler überlassen und bis zum nächsten menschlichen Statuswechsel nichts automatisiert fortsetzen.

### Voraussetzungen

- Das Issue befindet sich aktuell in `Freigabe Implementierung`.

### Ablauf

1. Weder coden noch den Ticket-Inhalt ändern.
2. In diesem Status übernimmt der Entwickler den manuellen Review- und Commit-Schritt nach `PreReview (AI)`.
3. In diesem Status kein regelmäßiges Polling ausführen; warten, bis ein Mensch das Issue in einen anderen Status verschiebt.

### Abschluss und nächster Status

- Nach der manuellen Freigabe verschiebt ein Mensch das Issue regulär nach `Review (AI)`.
- Wenn Freigabe-Feedback Änderungen erfordert, verschiebt ein Mensch das Issue nach `In Arbeit (AI)`.
- Wenn Freigabe-Feedback eine Neuplanung erforderlich macht, verschiebt ein Mensch das Issue nach `Planung (AI)`.

### Sonderfälle

- Keine.

## Ablauf für `Freigabe Final`

### Ziel

Die manuelle Finalfreigabe vor dem Merge vollständig dem Entwickler überlassen und bis zum nächsten menschlichen Statuswechsel nichts automatisiert fortsetzen.

### Voraussetzungen

- Das Issue befindet sich aktuell in `Freigabe Final`.

### Ablauf

1. Weder coden noch den Ticket-Inhalt ändern.
2. In diesem Status übernimmt der Entwickler die manuelle Finalprüfung des getesteten Branches.
3. In diesem Status kein regelmäßiges Polling ausführen; warten, bis ein Mensch das Issue in einen anderen Status verschiebt.

### Abschluss und nächster Status

- Nach der manuellen Finalfreigabe verschiebt ein Mensch das Issue regulär nach `Merge (AI)`.
- Wenn Final-Feedback Änderungen erfordert, verschiebt ein Mensch das Issue nach `In Arbeit (AI)`.
- Wenn Final-Feedback eine Neuplanung erforderlich macht, verschiebt ein Mensch das Issue nach `Planung (AI)`.

### Sonderfälle

- Keine.

## Ablauf für `Merge (AI)`

### Ziel

Den Merge-Ablauf mit `symphony-land` auf einem sauberen Workspace abschließen und das Issue danach nach `Review` verschieben.

### Voraussetzungen

- Das Issue befindet sich aktuell in `Merge (AI)`.
- Prüfe zuerst zuverlässig, dass im Workspace keine offenen Git-Änderungen mehr vorhanden sind.

### Ablauf

1. Falls noch offene Änderungen vorhanden sind, verschiebe das Issue sofort zurück nach `Freigabe Final`, damit der manuelle Final-Schritt nachgeholt wird; den Merge-Skill in diesem Fall nicht starten.
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

- Wenn ein erforderliches Tool fehlt oder erforderliche Auth nicht verfügbar ist, verschiebe das Ticket mit einem kurzen Blocker-Hinweis im Workpad nach `BLOCKER`. Dieser Hinweis muss enthalten:
  - was fehlt,
  - warum dadurch erforderliche Validierung blockiert wird,
  - welche exakte menschliche Aktion zum Entblocken nötig ist.
- Halte den Hinweis knapp und handlungsorientiert; füge keine zusätzlichen Top-Level-Kommentare außerhalb des Workpads hinzu.

## Workpad-Handhabung

Für Aufbau, Standardstruktur und Pflege des persistierenden Workpad-Kommentars ist
`.codex/skills/symphony-workpad/SKILL.md` die maßgebliche Quelle.

- Der Skill regelt insbesondere Wiederverwendung/Neuanlage des einen `## Codex Workpad`-Kommentars, die kanonische Kommentarstruktur sowie die Pflege-Regeln für `Plan`, `Validierung`, `Review`, `Test`, `Verlauf` und `Unklarheiten`.
- Die Schrittreihenfolge der einzelnen Workflow-Phasen und alle Statusübergänge bleiben ausschließlich in dieser `WORKFLOW.md` definiert.

## Planungs-Handhabung

Für Ticketbeschreibung, inhaltliche Planung und geplante Validierung ist
`.codex/skills/symphony-planning/SKILL.md` die maßgebliche Quelle.

- Automatische inhaltliche Änderungen an `Plan` und geplanter `Validierung` sind ausschließlich in `Planung (AI)` zulässig.
- Interaktive Sitzungen dürfen auf Benutzeranweisung später erneut in die Planung eingreifen.

## Leitplanken und Verbote

- Wenn der Issue-Status `Backlog` oder `Todo` ist, ändere ihn nicht; warte, bis ein Mensch ihn in den nächsten vorgesehenen AI-Status verschiebt.
- Bearbeite den Issue-Body/die Beschreibung nicht für Planung oder Fortschrittsverfolgung. Ausnahmen sind nur die automatisierte Beschreibungspflege in `Planung (AI)` und das einmalige `Erstkontakt-Protokoll für neue Items`.
- Verwende pro Issue genau einen persistierenden Workpad-Kommentar (`## Codex Workpad`).
- Wenn Kommentarbearbeitung in der Sitzung nicht verfügbar ist, verwende das Update-Skript. Melde nur dann einen Blocker, wenn sowohl MCP-Bearbeitung als auch skriptbasierte Bearbeitung nicht verfügbar sind.
- Automatische Commits sind ausschließlich in `Review (AI)`, `Test (AI)` und `Merge (AI)` zulässig. In allen anderen Status bleiben sie verboten.
- Temporäre Proof-Änderungen sind nur für lokale Verifikation erlaubt und müssen vor der Übergabe nach `PreReview (AI)` rückgängig gemacht werden.
- Wenn Verbesserungen außerhalb des Scopes gefunden werden, erstelle ein separates Backlog-Issue, statt den aktuellen Scope zu erweitern, und nimm einen klaren Titel/eine klare Beschreibung/klare Validierungspunkte, dieselbe Projektzuweisung, einen `related`-Link zum aktuellen Issue und `blockedBy` auf, wenn das Folge-Issue vom aktuellen Issue abhängt.
- Verschiebe nicht nach `PreReview (AI)`, solange die Abschlussbedingungen im Abschnitt `Ablauf für In Arbeit (AI)` nicht erfüllt sind.
- In `Freigabe Planung`, `Freigabe Implementierung` und `Freigabe Final` keine weiteren Codeänderungen vornehmen; auf den jeweiligen manuellen Schritt warten. Kein regelmäßiges Polling.
- In `BLOCKER` keine weiteren Codeänderungen vornehmen und kein regelmäßiges Polling ausführen; warten, bis ein Mensch den Blocker gelöst und das Ticket weiter verschoben hat.
- Wenn der Status terminal ist (`Fertig` oder `Abgebrochen`), nichts tun und beenden.
- Halte den Ticket-Text knapp, spezifisch und reviewer-orientiert.
