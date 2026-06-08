---
name: symphony-linear
description: Nutze `linear_graphql` für rohe Linear-GraphQL-Operationen.
---

# Linear GraphQL

Nutze das bereitgestellte `linear_graphql`-Tool. Pro Call genau eine Operation
senden und Top-Level-`errors` als Fehler behandeln.

HTTP-Fehler werden im Tool-Payload mit `status`, `classification`,
`bodyExcerpt`, `errors`, `extensionsCodes` und bei Bedarf `rateLimit`
ausgegeben. Behandle `classification: "auth"` sowie HTTP 401/403 als fehlenden
Linear-Zugriff für den regulären Tool-Pfad. `extensionsCodes` wie
`RATELIMITED` und `rateLimit`-Header sind Rate-Limit-Signale, keine
Schemafehler.

## Issue-Lookup

### Ein Issue per Key, Team/Nummer oder id abfragen

Bevorzuge den engsten bestätigten Pfad.

```graphql
query BootstrapIssue($key: String!) {
  issue(id: $key) {
    id
    identifier
    title
    state { id name type }
  }
}
```

Wenn du dich am Repo-Lookup orientieren willst, splitte den Identifier in
Team-Key und Nummer:

```graphql
query BootstrapIssueByTeamAndNumber($teamKey: String!, $number: Float!) {
  issues(filter: { team: { key: { eq: $teamKey } }, number: { eq: $number } }, first: 1) {
    nodes {
      id
      identifier
      title
      state { id name type }
    }
  }
}
```

Danach die interne `id` verwenden:

```graphql
query IssueById($id: String!) {
  issue(id: $id) {
    id
    identifier
    title
  }
}
```

Nutze keinen Fallback `issues(filter: { identifier: ... })`. Nimm keine
spekulativen Felder wie `links` in die erste Anfrage aufzunehmen. Wenn du ein
Beispiel brauchst: vermeide spekulative Felder wie `links` in die erste Anfrage aufzunehmen.

## Häufige Operationen

Kommentar erstellen:

```graphql
mutation CreateComment($issueId: String!, $body: String!) {
  commentCreate(input: { issueId: $issueId, body: $body }) {
    success
    comment { id url body }
  }
}
```

Kommentar bearbeiten:

```graphql
mutation UpdateComment($id: String!, $body: String!) {
  commentUpdate(id: $id, input: { body: $body }) {
    success
    comment { id body }
  }
}
```

Status wechseln:

```graphql
mutation MoveIssueToState($id: String!, $stateId: String!) {
  issueUpdate(id: $id, input: { stateId: $stateId }) {
    success
    issue { id identifier state { id name } }
  }
}
```

Team-States laden:

```graphql
query IssueTeamStates($id: String!) {
  issue(id: $id) {
    team {
      states { nodes { id name type } }
    }
  }
}
```

GitHub-PR anhängen:

```graphql
mutation AttachGitHubPR($issueId: String!, $url: String!, $title: String) {
  attachmentLinkGitHubPR(issueId: $issueId, url: $url, title: $title, linkKind: links) {
    success
    attachment { id title url }
  }
}
```

## Lokaler Workpad-Fallback

Wenn der reguläre Kommentar-Edit-Pfad wegen fehlendem Tool, HTTP 401/403 oder
Auth-Ausfall nicht nutzbar ist, aktualisiere einen bestehenden Workpad-Kommentar
lokal über den Tracker-Helfer. Der Body muss den Marker `## Symphony Workpad`
enthalten und darf kein leerer Probe-/Placeholder-Body sein.

```bash
ISSUE_KEY=PRO-496 WORKPAD_BODY_FILE=/tmp/workpad.md mise exec -- mix run --no-start -e '
repo_root = System.cmd("git", ["rev-parse", "--show-toplevel"]) |> elem(0) |> String.trim()
:ok = SymphonyElixir.EnvFile.load(SymphonyElixir.EnvFile.config_dir(repo_root), override_existing: true)
{:ok, _} = Application.ensure_all_started(:req)
{:ok, issue} = SymphonyElixir.Tracker.fetch_issue_by_identifier(System.fetch_env!("ISSUE_KEY"))
body = File.read!(System.fetch_env!("WORKPAD_BODY_FILE"))
:ok = SymphonyElixir.Workpad.update_tracker_workpad(issue.id, body)
'
```

Erstelle einen separaten Blocker-Kommentar nur dann, wenn sowohl der reguläre
Kommentar-Edit-Pfad als auch dieser lokale Workpad-Update-Helfer scheitern.

## Introspection und Uploads

Nutze gezielte Introspection, wenn Mutations-, Feld- oder Input-Formen unklar
sind. Für Uploads: `fileUpload` holen, Bytes per `curl -X PUT` mit gelieferten
Headern senden und `assetUrl` in Kommentar-Mutationen verwenden. Keine
Shell-Helper mit Raw-Tokens einführen.
