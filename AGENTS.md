# Symphony Elixir

Dieses Verzeichnis enthaelt den in Elixir geschriebenen Orchestrierungsdienst fuer Agents. Er pollt Linear, legt pro Ticket isolierte Workspaces an und startet Codex im App-Server-Modus.

## Umgebung

- Elixir: `1.19.x` (OTP 28) via `mise`
- Abhaengigkeiten installieren: `mix setup`
- Wichtigstes Qualitaets-Gate: `make all` (Format-Check, Lint, Coverage, Dialyzer)

## Projektspezifische Konventionen

- Die Laufzeitkonfiguration wird ueber den Front-Matter von `WORKFLOW.md` via `SymphonyElixir.Workflow` und `SymphonyElixir.Config` geladen.
- Halte die Implementierung nach Moeglichkeit in Einklang mit [SPEC.md](SPEC.md).
  - Die Implementierung darf eine Obermenge der Spezifikation sein.
  - Die Implementierung darf der Spezifikation nicht widersprechen.
  - Wenn Implementierungsaenderungen das beabsichtigte Verhalten wesentlich veraendern, aktualisiere nach Moeglichkeit die Spezifikation im selben Change, damit sie aktuell bleibt.
- Fuehre neue Konfigurationszugriffe bevorzugt ueber `SymphonyElixir.Config` ein, statt Umgebungsvariablen ad hoc direkt zu lesen.
- Workspace-Sicherheit ist kritisch:
  - Fuehre Codex niemals mit einem Turn-CWD im Source-Repository aus.
  - Workspaces muessen unterhalb des konfigurierten Workspace-Roots bleiben.
- Das Verhalten des Orchestrators ist zustandsbehaftet und nebenlaeufigkeitssensibel. Bewahre daher die Semantik fuer Retries, Reconciliation und Cleanup.
- Folge fuer Logging-Konventionen und die erforderlichen Issue-/Session-Kontextfelder der Datei `docs/logging.md`.

## Tests und Validierung

Fuehre waehrend der Iteration gezielte Tests aus und vor der Uebergabe die vollstaendigen Gates.

```bash
make all
```

## Verbindliche Regeln

- Oeffentliche Funktionen (`def`) in `lib/` muessen ein direkt benachbartes `@spec` haben.
- `defp`-Specs sind optional.
- Callback-Implementierungen mit `@impl` sind von der lokalen `@spec`-Pflicht ausgenommen.
- Halte Aenderungen eng am Scope; vermeide nicht zusammenhaengende Refactorings.
- Folge den bestehenden Modul- und Stilmustern in `lib/symphony_elixir/*`.

Validierungsbefehl:

```bash
mix specs.check
```

## Dokumentationspolitik

Wenn sich Verhalten oder Konfiguration aendern, aktualisiere die Dokumentation im selben PR:

- `WORKFLOW.md` fuer Aenderungen am Workflow- oder Konfigurationsvertrag
