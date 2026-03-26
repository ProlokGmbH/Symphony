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

2. Umgebungsvariablen vorbereiten, zum Beispiel ueber `.env.local`.
   Typisch benoetigt werden:
   - `LINEAR_API_KEY`
   - `LINEAR_PROJECT_SLUG`
   - `LINEAR_ASSIGNEE`
   - `SYMPHONY_PROJECT_ROOT`
   - `SYMPHONY_PROJECT_WORKTREES_ROOT`

3. Symphony starten:

   ```bash
   ./symphony --port 4000
   ```

Der Wrapper `./symphony` verlinkt die mitgelieferten Skills in dein lokales Codex-Skill-Verzeichnis und startet anschliessend `bin/symphony`. Wenn ein Port gesetzt ist, ist das Dashboard danach typischerweise unter `http://127.0.0.1:4000/` erreichbar.

### Qualitaetssicherung

Das wichtigste Projekt-Gate ist:

```bash
make all
```

Fuer die `@spec`-Pruefung steht zusaetzlich zur Verfuegung:

```bash
mix specs.check
```

## Workflow

Der Ablauf trennt bewusst zwischen automatisierten AI-Phasen und manuellen Uebergabepunkten. `Freigabe` ist der menschliche Review- und Commit-Schritt; nach dem Merge landet das Ticket in `Review` als manuelle Abschlussstation.

| Status | Rolle | Zweck | Regulaerer Uebergang |
| --- | --- | --- | --- |
| `Backlog` | Mensch | Ticket liegt noch ausserhalb der Automatisierung. | `Todo (AI)` |
| `Todo (AI)` | AI | Ticket wartet auf den Start der Bearbeitung. | `In Arbeit (AI)` |
| `In Arbeit` | Mensch/AI | Sonderfall fuer Bootstrap von Worktree und leerem Workpad ohne weitere Umsetzung. | bleibt offen bis zum naechsten AI-Status |
| `In Arbeit (AI)` | AI | Planung, Umsetzung, lokale Validierung und Pflege des Workpads. | `PreReview (AI)` |
| `PreReview (AI)` | AI | Repository-spezifischer PreReview-/Fix-Zyklus. | `Freigabe` |
| `Freigabe` | Mensch | Manueller Review- und Commit-Schritt. | `Review (AI)` oder `In Arbeit (AI)` |
| `Review (AI)` | AI | Repository-spezifischer Review-/Fix-Zyklus. | `Test (AI)` |
| `Test (AI)` | AI | Repository-spezifischer Test-/Fix-Zyklus auf sauberem Workspace. | `Merge (AI)` oder `Freigabe` |
| `Merge (AI)` | AI | PR beobachten, gruene Checks abwarten und den Branch landen. | `Review` |
| `Review` | Mensch | Manueller Endstatus nach dem Merge, bevor das Ticket ganz abgeschlossen wird. | `Fertig` |
| `Abbruch (AI)` | AI | Stoppt laufende Arbeit und fuehrt Cleanup aus. | `Abgebrochen` |
| `Fertig` | Abschluss | Ticket ist abgeschlossen. | - |
| `Abgebrochen` | Abschluss | Ticket wurde bewusst verworfen oder bereinigt. | - |

Der typische Pfad ist damit:

`Todo (AI)` -> `In Arbeit (AI)` -> `PreReview (AI)` -> `Freigabe` -> `Review (AI)` -> `Test (AI)` -> `Merge (AI)` -> `Review` -> `Fertig`

## Zentrale Dateien

- `WORKFLOW.md`: Workflow, Prompt-Vertrag und Runtime-Konfiguration
- `AGENTS.md`: Repository-spezifische Regeln fuer Codex
- `SPEC.md`: uebergeordnete Servicespezifikation
- `.codex/skills/`: repo-spezifische Skills fuer Review, Test, Push und Merge
