---
name: symphony-land
description:
  Fuehre innerhalb eines laufenden Symphony-Issue-Workflows eine PR zum Merge,
  indem du Konflikte beobachtest, loest, auf Checks wartest und bei Gruen
  mergst; nutze den Skill nur fuer den vom Workflow vorgegebenen
  Land-/Merge-Schritt.
---

# Land

## Ziele

- Stelle sicher, dass die PR konfliktfrei zu main ist.
- Halte CI grün und behebe Fehler, wenn sie auftreten.
- Merge die PR per merge commit, sobald die Checks bestehen.
- Gib nicht an den Benutzer zurück, bevor die PR gemergt ist; halte die
  Watcher-Schleife am Laufen, solange nichts blockiert.
- Übernimm keine separaten Aufräumarbeiten außerhalb dessen, was der laufende
  Workflow oder das aktuelle Repository ausdrücklich verlangt.

## Voraussetzungen

- `gh` CLI ist authentifiziert.
- Du befindest dich auf dem PR-Branch.

## Schritte

1. Finde die PR für den aktuellen Branch.
2. Bestätige vor jedem Push, dass das vollständige lokale Qualitäts-Gate grün
   ist.
3. Falls der Working Tree uncommittete Änderungen enthält, committe sie in
   diesem Status sofort mit `git commit -am "Merge (AI) Autocommit"` oder
   `git add -A && git commit -m "Merge (AI) Autocommit"` und veröffentliche sie
   dann mit dem Skill `symphony-push`, bevor du fortfährst.
4. Prüfe Mergebarkeit und Konflikte gegenüber main.
5. Falls Konflikte bestehen, nutze den Skill `symphony-pull`, um
   `origin/main` zu holen/zu mergen und Konflikte zu lösen. Wenn dieser Pull
   oder seine Konfliktlösung Dateien ändert, committe sie mit
   `Merge (AI) Autocommit`, verschiebe das Issue zurück nach `Test (AI)` und
   stoppe, damit der Testzyklus auf dem gemergten Code erneut läuft. Nur wenn
   kein erneuter Lauf nötig ist, veröffentliche den aktualisierten Branch mit
   `symphony-push`.
6. Stelle sicher, dass Codex-Review-Kommentare (falls vorhanden) bestätigt sind
   und erforderliche Fixes vor dem Merge erledigt wurden.
7. Beobachte die Checks bis zum Abschluss.
8. Falls Checks fehlschlagen, ziehe die Logs, behebe das Problem, committe
   daraus entstehende Änderungen in diesem Status mit `Merge (AI) Autocommit`,
   veröffentliche sie mit `symphony-push` und starte die Checks erneut.
9. Wenn alle Checks grün sind und Review-Feedback erledigt ist, merge die PR
   mit dem merge-commit-Betreff `<IssueId>: <IssueTitle>`.
10. Bearbeite Review-Feedback autonom anhand von Ticketkontext, Plan, Code,
    Tests und lokaler Dokumentation; fuehre keinen Rueckfragepfad an Menschen
    als Normalfall aus.
11. Wenn du Feedback nicht uebernimmst, antworte inline mit Kenntnisnahme,
    Begruendung und einer konkreten Alternative oder Abgrenzung.
12. Wenn Review-Feedback trotz dieser Quellen semantisch nicht sicher
    aufloesbar ist, dokumentiere den konkreten Blocker im Workpad und im
    Review-Thread, verschiebe das Issue zurueck nach `Freigabe Review` und
    stoppe den Merge-Lauf statt einen Klaerungsdialog zu beginnen.
13. Wähle für jeden Review-Kommentar genau eines von: akzeptieren oder
    widersprechen. Antworte inline (oder im Issue-Thread für Codex-Reviews)
    mit diesem Modus vor der Codeänderung.
14. Antworte immer mit der beabsichtigten Aktion, bevor du Codeänderungen
    pushst (inline für Review-Kommentare, Issue-Thread für Codex-Reviews).

## Befehle

```
# Branch- und PR-Kontext sicherstellen
branch=$(git branch --show-current)
pr_number=$(gh pr view --json number -q .number)
pr_body=$(gh pr view --json body -q .body)
issue_identifier="<IssueId aus aktuellem Aufgabenkontext>"
issue_title="<IssueTitle aus aktuellem Aufgabenkontext>"
merge_subject="$issue_identifier: $issue_title"

# Mergebarkeit und Konflikte prüfen
mergeable=$(gh pr view --json mergeable -q .mergeable)

if [ "$mergeable" = "CONFLICTING" ]; then
  # Den Skill `symphony-pull` für Fetch + Merge + Konfliktlösung ausführen.
  # Danach den Skill `symphony-push` zum Veröffentlichen des aktualisierten Branches ausführen.
fi

# Bevorzugt den asynchronen Watch-Helper unten verwenden. Die manuelle Schleife ist
# ein Fallback, wenn Python nicht läuft oder das Helper-Skript fehlt.
# Auf Review-Feedback warten: Codex-Reviews kommen als Issue-Kommentare, die
# mit "## Codex Review — <persona>" beginnen. Behandle sie wie Review-Feedback:
# antworte mit einem `[codex]`-Issue-Kommentar, der die Hinweise bestätigt und
# sagt, ob du sie jetzt bearbeitest oder zurückstellst.
while true; do
  gh api repos/{owner}/{repo}/issues/"$pr_number"/comments \
    --jq '.[] | select(.body | startswith("## Codex Review")) | .id' | rg -q '.' \
    && break
  sleep 10
done

# Checks beobachten
if ! gh pr checks --watch; then
  gh pr checks
  # Fehlgeschlagenen Run identifizieren und Logs prüfen
  # gh run list --branch "$branch"
  # gh run view <run-id> --log
  exit 1
fi

# Merge-Commit mit Linear-Issue-Betreff
gh pr merge --merge --subject "$merge_subject" --body "$pr_body"
```

## Asynchroner Watch-Helper

Bevorzugt: Nutze den asyncio-Watcher, um Review-Kommentare, CI und
Head-Updates parallel zu überwachen:

```
python3 .codex/skills/symphony-land/land_watch.py
```

Exit-Codes:

- 2: Review-Kommentare erkannt (Feedback bearbeiten)
- 3: CI-Checks fehlgeschlagen
- 4: PR-Head aktualisiert (Autofix-Commit erkannt)

## Fehlerbehandlung

- Wenn Checks fehlschlagen, hole Details mit `gh pr checks` und
  `gh run view --log`, behebe das Problem lokal, committe das Ergebnis in
  diesem Status mit `Merge (AI) Autocommit`, veröffentliche es mit
  `symphony-push` und starte den Watch erneut.
- Nutze Augenmaß, um instabile Fehler zu erkennen. Wenn ein Fehler nur ein
  Ausreißer ist (z. B. Timeout auf einer Plattform), darfst du ohne Fix
  fortfahren.
- Falls CI einen Auto-Fix-Commit pusht (von GitHub Actions), löst das keinen
  neuen CI-Lauf aus. Erkenne den aktualisierten PR-Head, ziehe ihn lokal,
  merge bei Bedarf `origin/main`, ergänze einen echten Autoren-Commit und
  `force-push`, um CI erneut auszulösen; starte dann die Check-Schleife neu.
- Wenn Merge oder CI an veralteten generierten Artefakten oder einem
  veralteten Branch scheitern, hole aktuelles `origin/main`, synchronisiere
  den PR-Branch sauber und starte die Checks erneut.
- Wenn die Mergebarkeit `UNKNOWN` ist, warte und prüfe erneut.
- Merge nicht, solange Review-Kommentare (menschlich oder Codex-Review) offen
  sind.
- Starte keinen manuellen Klärungsablauf über Zuweisung, Erwähnung oder Warten
  auf eine menschliche Antwort; dokumentiere stattdessen einen konkreten
  Blocker, wenn autonome Auflösung nicht möglich ist.
- Codex-Review-Jobs wiederholen sich bei Fehlern und blockieren nicht; nutze
  das Vorhandensein von `## Codex Review — <persona>`-Issue-Kommentaren
  (nicht den Job-Status) als Signal für verfügbares Review-Feedback.
- Aktiviere Auto-Merge nur, wenn der laufende Workflow und das aktuelle
  Repository es ausdrücklich verlangen; andernfalls merge erst nach
  bestätigten grünen Checks.
- Wenn der Remote-PR-Branch durch eigenen früheren force-push oder Merge
  weitergelaufen ist, vermeide redundante Merges; formatiere lokal bei Bedarf
  erneut und nutze `git push --force-with-lease`.

## Review-Umgang

- Codex-Reviews kommen jetzt als von GitHub Actions gepostete Issue-Kommentare.
  Sie beginnen mit `## Codex Review — <persona>` und enthalten Methodik und
  verwendete Guardrails des Reviewers. Behandle sie als Feedback, das vor dem
  Merge bestätigt werden muss.
- Menschliche Review-Kommentare blockieren und müssen vor neuer Review-Anfrage
  oder Merge beantwortet und aufgelöst werden.
- Wenn mehrere Reviewer im selben Thread kommentieren, antworte auf jeden
  Kommentar (gebündelt ist okay), bevor du den Thread schließt.
- Hole Review-Kommentare über `gh api` und antworte mit einem präfixierten
  Kommentar.
- Nutze Review-Comment-Endpunkte (nicht Issue-Kommentare), um Inline-Feedback
  zu finden:
  - PR-Review-Kommentare auflisten:
    ```
    gh api repos/{owner}/{repo}/pulls/<pr_number>/comments
    ```
  - PR-Issue-Kommentare (Diskussion auf oberster Ebene):
    ```
    gh api repos/{owner}/{repo}/issues/<pr_number>/comments
    ```
  - Auf einen bestimmten Review-Kommentar antworten:
    ```
    gh api -X POST /repos/{owner}/{repo}/pulls/<pr_number>/comments \
      -f body='[codex] <response>' -F in_reply_to=<comment_id>
    ```
- `in_reply_to` muss die numerische Review-Comment-ID sein
  (z. B. `2710521800`), nicht die GraphQL-Node-ID (z. B. `PRRC_...`), und der
  Endpunkt muss die PR-Nummer enthalten (`/pulls/<pr_number>/comments`).
- Wenn die GraphQL-Review-Reply-Mutation verboten ist, nutze REST.
- Ein 404 beim Antworten bedeutet typischerweise einen falschen Endpunkt
  (fehlende PR-Nummer) oder unzureichenden Scope; prüfe das zuerst über das
  Auflisten der Kommentare.
- Alle von diesem Agenten erzeugten GitHub-Kommentare müssen mit `[codex]`
  beginnen.
- Auf Codex-Review-Issue-Kommentare antworte im Issue-Thread (nicht im
  Review-Thread) mit `[codex]` und nenne, ob du das Feedback jetzt bearbeitest
  oder zurückstellst (mit Begründung).
- Wenn Feedback Änderungen verlangt:
  - Für Inline-Review-Kommentare (menschlich) antworte mit den geplanten Fixes
    (`[codex] ...`) **als Inline-Antwort auf den ursprünglichen
    Review-Kommentar** über den Review-Comment-Endpunkt und `in_reply_to`
    (verwende dafür keine Issue-Kommentare).
  - Implementiere die Fixes, committe und pushe.
  - Antworte mit Fix-Details und Commit-SHA (`[codex] ...`) an derselben
    Stelle, an der du das Feedback bestätigt hast (Issue-Kommentar für
    Codex-Reviews, Inline-Antwort für Review-Kommentare).
  - Der Land-Watcher behandelt Codex-Review-Issue-Kommentare als offen, bis ein
    neuerer `[codex]`-Issue-Kommentar die Hinweise bestätigt.
- Fordere nur dann ein neues Codex-Review an, wenn ein erneuter Lauf nötig ist
  (z. B. nach neuen Commits). Fordere keines ohne Änderungen seit dem letzten
  Review an.
  - Bevor du ein neues Codex-Review anforderst, führe den Land-Watcher erneut
    aus und stelle sicher, dass keine offenen Review-Kommentare mehr existieren
    (alle haben `[codex]`-Inline-Antworten).
  - Nach neuen Commits wird der Codex-Review-Workflow bei PR-Synchronisation
    erneut laufen (oder du startest ihn manuell neu). Hinterlasse einen
    knappen Root-Level-Zusammenfassungskommentar, damit Reviewer das letzte
    Delta sehen:
    ```
    [codex] Änderungen seit dem letzten Review:
    - <kurze Stichpunkte zu den Deltas>
    Commits: <sha>, <sha>
    Tests: <ausgeführte Befehle>
    ```
  - Fordere nur dann ein neues Review an, wenn es seit der vorherigen Anfrage
    mindestens einen neuen Commit gibt.
  - Warte vor dem Merge auf den nächsten Codex-Review-Kommentar.

## Scope + PR-Metadaten

- PR-Titel und Beschreibung sollen den gesamten Scope der Änderung abbilden,
  nicht nur den letzten Fix.
- Wenn Review-Feedback den Scope erweitert, entscheide, ob du es jetzt
  einschließt oder zurückstellst. Du kannst Feedback akzeptieren,
  zurückstellen oder ablehnen. Wenn du es zurückstellst oder ablehnst, nenne
  das im Root-Level-`[codex]`-Update mit kurzem Grund
  (z. B. out-of-scope, widerspricht der Absicht, unnötig).
- Korrektheitsprobleme aus Review-Kommentaren sollten behoben werden. Wenn du
  ein Korrektheitsproblem zurückstellen oder ablehnen willst, validiere zuerst
  und erkläre, warum es hier nicht zutrifft.
- Ordne jeden Review-Kommentar einer Kategorie zu: correctness, design, style,
  clarification, scope.
- Für correctness-Feedback liefere konkrete Validierung
  (Test, Log oder Begründung), bevor du es schließt.
- Wenn du Feedback akzeptierst, nenne im Root-Level-Update eine einzeilige
  Begründung.
- Wenn du Feedback ablehnst, biete kurz eine Alternative oder einen
  Folgeanlass an.
- Bevorzuge nach einem Fix-Batch einen einzigen zusammengefassten
  Root-Level-Kommentar "Review erledigt" statt vieler kleiner Updates.
- Bei Dokumentations-Feedback bestätige, dass die Dokuänderung zum Verhalten
  passt (keine reinen Doku-Edits nur zur Beruhigung des Reviews).
