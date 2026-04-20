---
name: symphony-linear
description: |
  Nutze Symphonys `linear_graphql`-Client-Tool für rohe Linear-GraphQL-
  Operationen wie Kommentarbearbeitung und Upload-Abläufe.
---

# Linear GraphQL

Nutze diesen Skill für rohe Linear-GraphQL-Arbeit in Symphony-app-server-
Sessions.

## Primäres Tool

Nutze das von Symphonys app-server-Session bereitgestellte
`linear_graphql`-Client-Tool. Es verwendet die in Symphony konfigurierte
Linear-Authentifizierung der Session wieder.

Tool-Eingabe:

```json
{
  "query": "Query- oder Mutation-Dokument",
  "variables": {
    "optional": "GraphQL-Variablenobjekt"
  }
}
```

Tool-Verhalten:

- Sende pro Tool-Call genau eine GraphQL-Operation.
- Behandle ein Top-Level-Array `errors` als fehlgeschlagene GraphQL-Operation,
  auch wenn der Tool-Call selbst erfolgreich war.
- Halte Queries/Mutations eng im Scope; frage nur die Felder ab, die du
  brauchst.

## Unbekannte Operationen erschließen

Wenn du eine unbekannte Mutation, einen unbekannten Input-Typ oder ein
unbekanntes Objektfeld brauchst, nutze gezielte Introspection über
`linear_graphql`.

Mutations auflisten:

```graphql
query ListMutations {
  __type(name: "Mutation") {
    fields {
      name
    }
  }
}
```

Ein bestimmtes Input-Objekt prüfen:

```graphql
query CommentCreateInputShape {
  __type(name: "CommentCreateInput") {
    inputFields {
      name
      type {
        kind
        name
        ofType {
          kind
          name
        }
      }
    }
  }
}
```

## Häufige Abläufe

### Ein Issue per Key, Team/Nummer oder id abfragen

Nutze einen abgesicherten Bootstrap:

- Wenn in deiner aktuellen Session bereits bestaetigt ist, dass
  `issue(id: $key)` Issue-Keys wie `MT-686` akzeptiert, beginne mit einer
  kleinen `issue(id: $key)`-Abfrage, die nur die sofort benoetigten Felder
  liest.
- Wenn dieser Direktpfad noch nicht bestaetigt ist oder du dich am bereits
  implementierten Repo-Lookup orientieren willst, splitte den Identifier in
  Team-Key und Nummer und frage ueber `issues(filter: {team, number})` ab.
- Sobald du die interne Issue-`id` kennst, bevorzuge `issue(id: $id)` fuer
  engere Folgeabfragen.
- Nutze keinen Fallback `issues(filter: { identifier: ... })`;
  `IssueFilter.identifier` ist in der aktuellen Linear-API nicht verfuegbar.
- Wenn du nicht sicher bist, ob ein Feld, ein Input-Typ oder eine Mutation
  existiert, fuehre zuerst gezielte Introspection aus, statt spekulative Felder
  wie `links` in die erste Anfrage aufzunehmen.

Bootstrap-Abfrage per Issue-Key:

```graphql
query BootstrapIssue($key: String!) {
  issue(id: $key) {
    id
    identifier
    title
    state {
      id
      name
      type
    }
  }
}
```

Repo-ausgerichteter Bootstrap per Team-Key und Nummer:

```graphql
query BootstrapIssueByTeamAndNumber($teamKey: String!, $number: Float!) {
  issues(filter: { team: { key: { eq: $teamKey } }, number: { eq: $number } }, first: 1) {
    nodes {
      id
      identifier
      title
      state {
        id
        name
        type
      }
    }
  }
}
```

Dasselbe Feld akzeptiert auch die interne Issue-`id`, sobald du sie kennst:

```graphql
query IssueById($id: String!) {
  issue(id: $id) {
    id
    identifier
    title
  }
}
```

Breitere Folgeabfrage, sobald die interne `id` bekannt ist:

```graphql
query IssueDetails($id: String!) {
  issue(id: $id) {
    id
    identifier
    title
    url
    description
    updatedAt
    state {
      id
      name
      type
    }
    project {
      id
      name
    }
    attachments {
      nodes {
        id
        title
        url
        sourceType
      }
    }
  }
}
```

### Team-Workflow-Status eines Issues abfragen

Nutze dies vor einem Statuswechsel, wenn du die exakte `stateId` brauchst:

```graphql
query IssueTeamStates($id: String!) {
  issue(id: $id) {
    id
    team {
      id
      key
      name
      states {
        nodes {
          id
          name
          type
        }
      }
    }
  }
}
```

### Einen bestehenden Kommentar bearbeiten

Nutze `commentUpdate` über `linear_graphql`:

```graphql
mutation UpdateComment($id: String!, $body: String!) {
  commentUpdate(id: $id, input: { body: $body }) {
    success
    comment {
      id
      body
    }
  }
}
```

### Einen Kommentar erstellen

Nutze `commentCreate` über `linear_graphql`:

```graphql
mutation CreateComment($issueId: String!, $body: String!) {
  commentCreate(input: { issueId: $issueId, body: $body }) {
    success
    comment {
      id
      url
    }
  }
}
```

### Ein Issue in einen anderen Status verschieben

Nutze `issueUpdate` mit der Ziel-`stateId`:

```graphql
mutation MoveIssueToState($id: String!, $stateId: String!) {
  issueUpdate(id: $id, input: { stateId: $stateId }) {
    success
    issue {
      id
      identifier
      state {
        id
        name
      }
    }
  }
}
```

### Eine GitHub-PR an ein Issue anhängen

Nutze beim Verlinken einer PR die GitHub-spezifische Attachment-Mutation:

```graphql
mutation AttachGitHubPR($issueId: String!, $url: String!, $title: String) {
  attachmentLinkGitHubPR(
    issueId: $issueId
    url: $url
    title: $title
    linkKind: links
  ) {
    success
    attachment {
      id
      title
      url
    }
  }
}
```

Wenn du nur ein einfaches URL-Attachment brauchst und
GitHub-spezifische Link-Metadaten egal sind, nutze:

```graphql
mutation AttachURL($issueId: String!, $url: String!, $title: String) {
  attachmentLinkURL(issueId: $issueId, url: $url, title: $title) {
    success
    attachment {
      id
      title
      url
    }
  }
}
```

### Introspection-Muster für Schema-Erkundung

Nutze diese Muster, wenn die exakte Feld- oder Mutationsform unklar ist:

```graphql
query QueryFields {
  __type(name: "Query") {
    fields {
      name
    }
  }
}
```

```graphql
query IssueFieldArgs {
  __type(name: "Query") {
    fields {
      name
      args {
        name
        type {
          kind
          name
          ofType {
            kind
            name
            ofType {
              kind
              name
            }
          }
        }
      }
    }
  }
}
```

### Ein Video an einen Kommentar hochladen

Gehe in drei Schritten vor:

1. Rufe `linear_graphql` mit `fileUpload` auf, um `uploadUrl`, `assetUrl` und
   nötige Upload-Header zu erhalten.
2. Lade die lokalen Dateibytes mit `curl -X PUT` an `uploadUrl` hoch und nutze
   exakt die von `fileUpload` zurückgegebenen Header.
3. Rufe `linear_graphql` erneut mit `commentCreate` (oder `commentUpdate`) auf
   und nimm die resultierende `assetUrl` in den Kommentartext auf.

Nützliche Mutationen:

```graphql
mutation FileUpload(
  $filename: String!
  $contentType: String!
  $size: Int!
  $makePublic: Boolean
) {
  fileUpload(
    filename: $filename
    contentType: $contentType
    size: $size
    makePublic: $makePublic
  ) {
    success
    uploadFile {
      uploadUrl
      assetUrl
      headers {
        key
        value
      }
    }
  }
}
```

## Nutzungsregeln

- Nutze `linear_graphql` für Kommentarbearbeitungen, Uploads und ad-hoc-
  Abfragen an die Linear-API.
- Bevorzuge den engsten Issue-Lookup, der zu deinem Wissensstand passt:
  Key -> Identifier-Suche -> interne id.
- Hole für Statuswechsel zuerst die Team-States und nutze die exakte `stateId`,
  statt Namen in Mutations fest zu verdrahten.
- Bevorzuge `attachmentLinkGitHubPR` gegenüber einem generischen
  URL-Attachment, wenn du eine GitHub-PR an ein Linear-Issue hängst.
- Führe keine neuen Shell-Helper mit Raw-Tokens für GraphQL-Zugriff ein.
- Wenn du Shell-Arbeit für Uploads brauchst, nutze sie nur für signierte
  Upload-URLs aus `fileUpload`; diese URLs tragen die nötige Autorisierung
  bereits mit.
