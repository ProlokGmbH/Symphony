---
name: symphony-pull
description:
  Ziehe innerhalb eines laufenden Symphony-Issue-Workflows das neueste
  `origin/main` per Rebase in den aktiven Workflow-Branch und löse
  Rebase-Konflikte (aka update-branch). Nutze den Skill nur für die vom
  Workflow geforderte rebase-basierte Synchronisierung, nicht für generische
  Git-Arbeit.
---

# Pull

Nutze diesen Skill nur, wenn der laufende Symphony-Issue-Workflow einen Pull-
oder Update-Branch-Schritt verlangt.

## Ablauf

1. Prüfe `git status`:
   - Wenn uncommittete Änderungen vorliegen, sichere sie vor Pull/Rebase mit
     `git stash push --include-untracked -m "symphony-pull: pre-rebase"`.
   - Merke dir den erzeugten Stash-Ref, zum Beispiel `stash@{0}` aus
     `git stash list --format=%gd -n 1`.
   - Verwende dafür keinen temporären Commit.
   - Ein expliziter Aufruf dieses Skills ist auch in Schritten zulässig, die
     sonst keine automatischen Commits erlauben.
2. Stelle sicher, dass `rerere` lokal aktiviert ist:
   - `git config rerere.enabled true`
   - `git config rerere.autoupdate true`
3. Prüfe Remotes und Branches:
   - Stelle sicher, dass der Remote `origin` existiert.
   - Stelle sicher, dass der aktuelle Branch per Rebase aktualisiert werden soll.
4. Hole die neuesten Refs:
   - `git fetch origin`
5. Synchronisiere zuerst den Remote-Feature-Branch:
   - Wenn `refs/remotes/origin/$(git branch --show-current)` existiert, ziehe
     ihn mit `git pull --ff-only origin $(git branch --show-current)`.
   - Wenn kein gleichnamiger Remote-Branch existiert, dokumentiere das knapp in
     den Notizen und fahre ohne Rückfrage mit dem Rebase auf `origin/main`
     fort.
   - Das zieht remote entstandene Branch-Updates (zum Beispiel einen
     GitHub-Auto-Commit), bevor der Branch auf `origin/main` rebased wird.
6. Rebase in dieser Reihenfolge:
   - Bevorzuge `git -c merge.conflictStyle=zdiff3 rebase origin/main`, damit der
     Konfliktkontext klarer ist.
7. Falls Konflikte auftreten, löse sie (siehe Hinweise unten) und dann:
   - `git add <files>`
   - `git rebase --continue`
8. Wenn du zu Beginn Änderungen gestasht hast, stelle sie nach abgeschlossenem
   Pull/Rebase wieder her:
   - Nutze `git stash apply --index <stash-ref>`.
   - Nutze nicht `git stash pop`, damit der Stash bei Konflikten erhalten
     bleibt.
   - Wenn das Anwenden Konflikte erzeugt, versuche sie selbstständig anhand der
     Hinweise unten zu lösen; stage gelöste Dateien, lasse die Änderungen aber
     ungecommittet.
   - Lösche den Stash erst nach erfolgreicher Wiederherstellung mit
     `git stash drop <stash-ref>`.
9. Verifiziere mit den Projekt-Checks (folge der Repo-Policy in `AGENTS.md`).
10. Fasse den Rebase zusammen:
   - Nenne die schwierigsten Konflikte/Dateien und wie sie gelöst wurden.
   - Halte Annahmen oder Follow-ups fest.
11. Ergänze eine kurze `pull skill evidence`-Notiz im aktiven Workpad:
   - Rebase-Quelle(n)
   - Stash: `not needed`, `restored` oder `restore conflicts resolved`
   - Ergebnis: `clean` oder `conflicts resolved`

## Hinweise zur Konfliktlösung (Best Practices)

- Prüfe den Kontext vor dem Editieren:
  - Nutze `git status`, um konfliktbehaftete Dateien aufzulisten.
  - Nutze `git diff`, um Konflikt-Hunks zu sehen.
  - Nutze `git diff :1:path/to/file :2:path/to/file` und
    `git diff :1:path/to/file :3:path/to/file`, um base vs ours/theirs auf
    Dateiebene zu vergleichen.
  - Mit `merge.conflictStyle=zdiff3` enthalten Konfliktmarker:
    - `<<<<<<<` ours, `|||||||` base, `=======` split, `>>>>>>>` theirs.
    - Gleiche Zeilen am Anfang/Ende werden aus dem Konfliktbereich gekürzt;
      fokussiere dich daher auf den abweichenden Kern.
  - Fasse die Absicht beider Änderungen zusammen, entscheide das semantisch
    korrekte Ergebnis und editiere erst dann:
    - Benenne, was jede Seite erreichen will
      (Bugfix, Refactor, Umbenennung, Verhaltensänderung).
    - Bestimme das gemeinsame Ziel, falls es eines gibt, und ob eine Seite die
      andere überholt.
    - Entscheide zuerst das Endverhalten; forme erst danach den Code passend zu
      dieser Entscheidung.
    - Bevorzuge den Erhalt von Invarianten, API-Verträgen und sichtbarem
      Benutzerverhalten, sofern der Konflikt nicht klar auf eine beabsichtigte
      Änderung zeigt.
  - Öffne Dateien und verstehe die Absicht beider Seiten, bevor du dich auf
    eine Lösung festlegst.
- Bevorzuge minimale, absichtswahrende Edits:
  - Halte das Verhalten konsistent mit dem Zweck des Branches.
  - Vermeide versehentliche Löschungen oder stille Verhaltensänderungen.
- Löse eine Datei nach der anderen und führe Tests nach jedem logischen Batch
  erneut aus.
- Nutze `ours/theirs` nur, wenn du sicher bist, dass eine Seite vollständig
  gewinnen soll.
- Suche bei komplexen Konflikten nach verwandten Dateien oder Definitionen, um
  dich am restlichen Codebestand auszurichten.
- Bei generierten Dateien zuerst nicht generierte Konflikte lösen, dann neu
  generieren:
  - Löse bevorzugt Source-Dateien und handgeschriebene Logik, bevor du
    generierte Artefakte anfasst.
  - Führe den CLI-/Tooling-Befehl aus, der die generierte Datei erzeugt hat,
    um sie sauber neu zu erstellen, und stage dann die regenerierte Ausgabe.
- Bei Import-Konflikten mit unklarer Absicht zunächst beide Seiten akzeptieren:
  - Behalte alle möglichen Imports vorübergehend, schließe den Rebase ab und
    führe dann Lint-/Type-Checks aus, um ungenutzte oder falsche Imports sicher
    zu entfernen.
- Stelle nach der Lösung sicher, dass keine Konfliktmarker übrig sind:
  - `git diff --check`
- Wenn du unsicher bist, notiere die Annahmen und triff eine bestmögliche,
  reviewbare Entscheidung anhand von Code, Tests und benachbarter
  Dokumentation.

## Eskalation in unbeaufsichtigten Läufen

- Starte keine menschlichen Rückfragen aus diesem Skill heraus.
- Wenn die korrekte Konfliktlösung trotz Code, Tests und lokaler Dokumentation
  nicht sicher bestimmbar ist, dokumentiere den konkreten Blocker im Workpad
  des aufrufenden Workflows, brich einen laufenden Rebase mit `git rebase --abort`
  ab, verschiebe das Issue in einen nicht-aktiven manuellen Status und stoppe
  statt einen Klärungsdialog zu beginnen.
- Wenn der aufrufende Workflow keinen spezielleren Rücksprung für diesen Fall
  definiert, verwende dafür `BLOCKER`, damit der Lauf nicht im aktiven
  Retry-Zustand hängen bleibt.
