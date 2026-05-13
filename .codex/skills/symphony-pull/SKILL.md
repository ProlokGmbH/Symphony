---
name: symphony-pull
description:
  Synchronisiert im Symphony-Issue-Workflow den aktuellen Branch per Rebase mit
  `origin/main`.
---

# Pull

Nur verwenden, wenn der Workflow einen Pull-/Update-Branch-Schritt verlangt.

## Ablauf

1. `git status` prüfen. Uncommittete Änderungen mit
   `git stash push --include-untracked -m "symphony-pull: pre-rebase"` sichern
   und den Stash-Ref merken. Kein temporärer Commit.
2. `git config rerere.enabled true` und
   `git config rerere.autoupdate true` setzen.
3. Remote `origin` und aktuellen Branch prüfen.
4. `git fetch origin`.
5. Falls der Remote-Feature-Branch existiert:
   `git pull --ff-only origin $(git branch --show-current)`. Sonst knapp
   notieren und fortfahren.
6. `git -c merge.conflictStyle=zdiff3 rebase origin/main`.
7. Konflikte semantisch lösen, `git add <files>`,
   `git rebase --continue`.
8. Gesicherte Änderungen mit `git stash apply --index <stash-ref>`
   wiederherstellen und erst danach `git stash drop <stash-ref>`.
9. Erforderliche Projekt-Checks gemäß aufrufendem Workflow ausführen.
10. Im Workpad `pull skill evidence` notieren: Rebase-Quelle(n), Stash-Status
    und Ergebnis.

## Konflikte

- Vor dem Editieren Kontext lesen: `git status`, `git diff`, bei Bedarf
  Stage-Diffs.
- Absicht beider Seiten verstehen und das kleinste absichtswahrende Ergebnis
  herstellen.
- Generierte Dateien nach Möglichkeit aus Source-Dateien neu erzeugen.
- Nach der Lösung `git diff --check` ausführen.

## Blocker

Wenn eine Konfliktlösung trotz Code, Tests und lokaler Dokumentation nicht
sicher bestimmbar ist: Rebase abbrechen, Stash wiederherstellen, konkreten
Blocker im Workpad festhalten und nach `BLOCKER` verschieben, sofern der
aufrufende Workflow keinen spezifischeren Rücksprung vorgibt.
