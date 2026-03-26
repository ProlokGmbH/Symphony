# Symphony

Symphony ist ein deutschsprachiger Fork von OpenAI Symphony mit klaren Konventionen fuer den produktiven Einsatz von Coding Agents. Das Projekt funktioniert besonders gut in Codebasen, die [Harness Engineering](https://openai.com/index/harness-engineering/) bereits eingefuehrt haben. Ziel ist der naechste Schritt nach dem reinen Einsatz einzelner Agents: weg vom Verwalten von Coding Agents, hin zur Orchestrierung konkreter Arbeit, die erledigt werden muss.

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

Gegenueber OpenAI Symphony legt dieser Fork den Schwerpunkt auf einen deutschsprachigen, klar vorstrukturierten Team-Workflow:

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

Der Ablauf ist bewusst knapp gehalten: AI-Status treiben die Automatisierung, `Freigabe` ist der manuelle Review- und Commit-Schritt.

| Status | Rolle | Zweck | Regulaerer Uebergang |
| --- | --- | --- | --- |
| `Backlog` | Mensch | Ticket ist noch nicht fuer die Automatisierung vorgesehen. | `Todo (AI)` |
| `Todo (AI)` | AI | Ticket wartet auf den Start der Bearbeitung. | `In Arbeit (AI)` |
| `In Arbeit` | Mensch/AI | Sonderfall fuer den Bootstrap von Worktree und leerem Workpad, ohne eigentliche Umsetzung. | bleibt offen bis zum naechsten AI-Status |
| `In Arbeit (AI)` | AI | Planung, Umsetzung, lokale Validierung und Workpad-Pflege. | `Review (AI)` |
| `Review (AI)` | AI | Repository-spezifischer Review-/Fix-Zyklus. | `Freigabe` |
| `Freigabe` | Mensch | Manueller Review- und Commit-Schritt. | `In Arbeit (AI)`, `Test (AI)` oder `Merge (AI)` |
| `Test (AI)` | AI | Repository-spezifischer Test-/Fix-Zyklus auf sauberem Workspace. | `Merge (AI)` oder `Freigabe` |
| `Merge (AI)` | AI | Automatisiertes Landen der PR auf sauberem Stand. | `Fertig` |
| `Abbruch (AI)` | AI | Stoppt laufende Arbeit und fuehrt Cleanup aus. | `Abgebrochen` |
| `Fertig` | Abschluss | Ticket ist abgeschlossen. | - |
| `Abgebrochen` | Abschluss | Ticket wurde bewusst verworfen oder bereinigt. | - |

Der typische Pfad ist damit:

`Todo (AI)` -> `In Arbeit (AI)` -> `Review (AI)` -> `Freigabe` -> `Test (AI)` -> `Merge (AI)` -> `Fertig`

## Zentrale Dateien

- `WORKFLOW.md`: Workflow, Prompt-Vertrag und Runtime-Konfiguration
- `AGENTS.md`: Repository-spezifische Regeln fuer Codex
- `SPEC.md`: uebergeordnete Servicespezifikation
- `.codex/skills/`: repo-spezifische Skills fuer Review, Test, Push und Merge
