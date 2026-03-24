# Symphony

Symphony orchestriert Codex-gestuetzte Ticketbearbeitung aus einem repositoryeigenen `WORKFLOW.md`.
Im Elixir-Service werden nur nicht-terminale Workflow-Status mit `Codex` im Namen aktiv
bearbeitet; der manuelle Handoff erfolgt anschliessend ueber `Review`.
