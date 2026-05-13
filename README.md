# Symphony

Symphony ist ein deutschsprachiger, bewusst vorstrukturierter Fork von OpenAI Symphony fuer Teams, die Coding Agents nicht nur einsetzen, sondern verlässlich in ihren Entwicklungsprozess einbinden wollen. Das Projekt funktioniert besonders gut in Codebasen, die [Harness Engineering](https://openai.com/index/harness-engineering/) bereits eingefuehrt haben. Ziel ist der naechste Schritt nach dem reinen Einsatz einzelner Agents: weg vom Verwalten von Coding Agents, hin zur Orchestrierung konkreter Arbeit, die erledigt werden muss.

![Symphony Dashboard](.github/media/elixir-screenshot.png)

## Was dieses Repository macht

Dieses Repository enthaelt den Elixir-basierten Orchestrator von Symphony. Der Dienst:

- pollt Linear regelmaessig nach Tickets in aktiven Stati,
- legt pro Ticket einen isolierten Git-Worktree an,
- startet Codex pro Ticket in einem eigenen Workspace,
- steuert den Ablauf ueber eine zentrale, versionierte `WORKFLOW.md`,
- und stellt Beobachtbarkeit ueber Dashboard, Logs und API bereit.

Dadurch wird aus einzelnen Agentenlaeufen ein reproduzierbarer, repo-eigener Arbeitsprozess.

## Unterschiede zur Originalversion

Gegenueber OpenAI Symphony legt dieser Fork den Schwerpunkt auf einen deutschsprachigen, klar gefuehrten Team-Workflow:

- Deutsche Sprache in Workflow, Skills und Projektdokumentation
- Eine zentrale `WORKFLOW.md` als verbindlicher Workflow- und Prompt-Vertrag
- Git-Worktrees als Standard fuer isolierte Ticket-Workspaces
- Review und Test ueber repository-spezifische Skills statt ueber einen generischen Einheitsablauf

## Installation und Inbetriebnahme

### Voraussetzungen

- `mise` fuer die Elixir-/OTP-Versionen
- Git
- Zugriff auf Linear
- Fuer den vollen PR- und Merge-Ablauf zusaetzlich `gh`

### Einrichtung

1. Abhaengigkeiten installieren:

   ```bash
   mix setup
   ```

2. Umgebungsvariablen vorbereiten, zum Beispiel über `.symphony/.env.local`.
   Typisch benötigt werden:
   - `LINEAR_API_KEY`
   - `LINEAR_PROJECT_SLUG`
   - `LINEAR_ASSIGNEE`
   - `SYMPHONY_PROJECT_ROOT`
   - `SYMPHONY_PROJECT_WORKTREES_ROOT`

   `sym-codex <TicketId>` priorisiert für den Linear-MCP-Zugriff die
   `.symphony/.env(.local)` des aufrufenden Projekt-Roots auch gegenüber
   geerbten Shell-Werten. Dadurch können
   mehrere Projekte parallel mit unterschiedlichen `LINEAR_API_KEY`-Werten
   arbeiten; das Symphony-Source-Repository bleibt der Fallback, wenn kein
   Projekt-Root übergeben wird.

3. Symphony starten:

   ```bash
   ./symphony --port 4000
   ```

Der Wrapper `./symphony` verlinkt die mitgelieferten Skills in dein lokales Codex-Skill-Verzeichnis und startet anschliessend `bin/symphony`. Wenn ein Port gesetzt ist, ist das Dashboard danach typischerweise unter `http://127.0.0.1:4000/` erreichbar.

Für private, unbeaufsichtigte Projekte kann Symphony mit `./symphony --yolo` gestartet werden. In diesem Modus wird kein Assignee für das Routing benötigt, alle Tickets im Projekt werden unabhängig vom Assignee bearbeitet, die Freigaben `Freigabe Implementierung` und `Freigabe Review` werden wie durch passende Skip-Labels übersprungen, und das Dashboard zeigt `--yolo` statt des Assignees. Der manuelle Status `Planung` wird auch im `--yolo`-Modus nicht übersprungen.

### Qualitaetssicherung

Das wichtigste Projekt-Gate ist:

```bash
make all
```

Fuer die `@spec`-Pruefung steht zusaetzlich zur Verfuegung:

```bash
mix specs.check
```

## Dependency-Updates

Die Dependabot-Konfiguration in `.github/dependabot.yml` deckt die von GitHub
unterstuetzten Paketquellen dieses Repositories ab:

- `mix` fuer `mix.exs` und `mix.lock` im Repo-Root
- `docker` fuer `test/support/live_e2e_docker/Dockerfile`

Nicht automatisch durch Dependabot aktualisierbar sind aktuell:

- Toolchain-Versionen in `mise.toml`
- `apt-get`-Installationen im Dockerfile
- globales `npm install --global @openai/codex` im Dockerfile

## Workflow

Der Ablauf trennt bewusst zwischen automatisierten AI-Phasen und manuellen Klärungs- bzw. Freigabepunkten. `Planung` ist der manuelle Klärungspunkt nach `Planung (AI)`, falls Codex die Planung noch nicht für vollständig autonome Umsetzung ausreichend findet. `Review` bleibt die manuelle Abschlussstation nach dem Merge.
Wenn fuer einen Status ein passendes Label `Skip "<Status>"` gesetzt ist, laeuft Symphony direkt zum naechsten nicht uebersprungenen Status weiter; das gilt fuer die Freigabepunkte `Freigabe Implementierung` und `Freigabe Review`. Für `Planung` gibt es kein Skip-Label. Im `--yolo`-Modus gelten nur `Freigabe Implementierung` und `Freigabe Review` als übersprungen.

| Status | Rolle | Zweck | Regulaerer Uebergang |
| --- | --- | --- | --- |
| `Backlog` | Mensch | Ticket liegt noch ausserhalb der Automatisierung. | `Todo (AI)` |
| `Todo` | Mensch | Nicht automatisiertes Benutzer-Todo ausserhalb des Symphony-Scopes. | bleibt offen bis zum naechsten AI-Status |
| `Todo (AI)` | AI | Ticket wartet auf den Start der Bearbeitung. | `Planung (AI)` |
| `Planung (AI)` | AI | Ticketbeschreibung sowie Plan und Validierung vorbereiten und entscheiden, ob autonome Umsetzung möglich ist. | `In Arbeit (AI)` oder `Planung` |
| `Planung` | Mensch | Manueller Klärungs- und Planschärfungspunkt mit von Codex empfohlenen Lösungsvorschlägen. | `In Arbeit (AI)` oder `Planung (AI)` |
| `In Arbeit (AI)` | AI | Umsetzung auf Basis des vorbereiteten Plans, bei Bedarf begründete Plananpassung, lokale Validierung und Pflege des Workpads. | `PreReview (AI)` |
| `PreReview (AI)` | AI | Repository-spezifischer PreReview-/Fix-Zyklus. | `Freigabe Implementierung` |
| `Freigabe Implementierung` | Mensch | Manueller Review- und Commit-Schritt nach der Umsetzung. | `Review (AI)` oder `In Arbeit (AI)` oder `Planung (AI)` |
| `Review (AI)` | AI | Repository-spezifischer Review-/Fix-Zyklus. | `Freigabe Review` |
| `Freigabe Review` | Mensch | Manueller Freigabepunkt der reviewten Version vor dem Test-/Merge-Zyklus. | `Test (AI)` oder `In Arbeit (AI)` oder `Planung (AI)` |
| `Test (AI)` | AI | Vor den Tests per Pull auf den spaeteren Merge-Stand synchronisieren und den Test-/Fix-Zyklus auf diesem Stand ausfuehren. | `Merge (AI)` |
| `Merge (AI)` | AI | PR beobachten, gruene Checks abwarten und den Branch landen; bei mergebedingten Codeaenderungen zurueck nach `Test (AI)`. | `Review` |
| `BLOCKER` | Mensch | Kritische Abweichung oder externer Blocker; keine weitere Automatisierung, bis das Problem manuell geloest ist. | wartet auf menschliches Verschieben |
| `Abbruch (AI)` | AI | Stoppt laufende Arbeit und fuehrt Cleanup aus. | `Abgebrochen` |
| `Review` | Mensch | Manueller Endstatus nach dem Merge, bevor das Ticket ganz abgeschlossen wird. | `Fertig` |
| `Fertig` | Abschluss | Ticket ist abgeschlossen. | - |
| `Abgebrochen` | Abschluss | Ticket wurde bewusst verworfen oder bereinigt. | - |

Der typische Pfad ist damit:

`Todo (AI)` -> `Planung (AI)` -> `In Arbeit (AI)` -> `PreReview (AI)` -> `Freigabe Implementierung` -> `Review (AI)` -> `Freigabe Review` -> `Test (AI)` -> `Merge (AI)` -> `Review` -> `Fertig`

Wenn `Planung (AI)` noch Klärungsbedarf erkennt, verläuft der Pfad stattdessen über `Planung`; dort prüft der Benutzer die offenen Fragen und die empfohlenen Lösungsvorschläge und verschiebt das Ticket anschließend manuell weiter.

## Zentrale Dateien

- `WORKFLOW.md`: Workflow, Prompt-Vertrag und Runtime-Konfiguration
- `AGENTS.md`: Repository-spezifische Regeln fuer Codex
- `SPEC.md`: uebergeordnete Servicespezifikation
- `.codex/skills/`: repo-spezifische Skills für Planung, Workpad, Debugging, Review, Test, Push und Merge
