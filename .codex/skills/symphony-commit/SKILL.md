---
name: symphony-commit
description:
  Erstelle aus den aktuellen Änderungen einen sauberen git-Commit mit
  Sitzungsverlauf für Begründung und Zusammenfassung; nutze den Skill bei
  Commit-Anfragen, für Commit-Messages oder zum Abschließen gestagter Arbeit.
---

# Commit

## Ziele

- Erzeuge einen Commit, der die tatsächlichen Codeänderungen und den
  Sitzungskontext abbildet.
- Folge üblichen git-Konventionen (Type-Präfix, kurzer Betreff, umbrochener
  Body).
- Nimm sowohl Zusammenfassung als auch Begründung in den Body auf.

## Eingaben

- Codex-Sitzungsverlauf für Absicht und Begründung.
- `git status`, `git diff` und `git diff --staged` für die tatsächlichen
  Änderungen.
- Repo-spezifische Commit-Konventionen, falls dokumentiert.

## Schritte

1. Lies den Sitzungsverlauf, um Scope, Absicht und Begründung zu erfassen.
2. Prüfe den Working Tree und gestagte Änderungen (`git status`, `git diff`,
   `git diff --staged`).
3. Stage die beabsichtigten Änderungen einschließlich neuer Dateien
   (`git add -A`), nachdem der Scope bestätigt ist.
4. Prüfe neu hinzugefügte Dateien auf Plausibilität; wenn etwas zufällig oder
   vermutlich ignoriert aussieht (Build-Artefakte, Logs, temporäre Dateien),
   weise den Benutzer vor dem Commit darauf hin.
5. Falls das Staging unvollständig ist oder unzusammenhängende Dateien enthält,
   korrigiere den Index oder hole eine Bestätigung ein.
6. Wähle einen üblichen Type und optionalen Scope passend zur Änderung
   (z. B. `feat(scope): ...`, `fix(scope): ...`, `refactor(scope): ...`).
7. Schreibe eine Betreffzeile im Imperativ, <= 72 Zeichen, ohne Punkt am Ende.
8. Schreibe einen Body mit:
   - Zusammenfassung der wesentlichen Änderungen (was geändert wurde).
   - Begründung und Trade-offs (warum es geändert wurde).
   - Ausgeführten Tests oder Validierungen (oder einem expliziten Hinweis,
     falls nichts lief).
9. Hänge einen `Co-authored-by`-Trailer für Codex mit
   `Codex <codex@openai.com>` an, sofern der Benutzer keine andere Identität
   verlangt.
10. Brich Body-Zeilen bei 72 Zeichen um.
11. Erstelle die Commit-Message mit Here-Doc oder temporärer Datei und nutze
    `git commit -F <file>`, damit Zeilenumbrüche wörtlich bleiben
    (vermeide `-m` mit `\n`).
12. Committe nur, wenn die Message zu den gestagten Änderungen passt: Falls der
    gestagte Diff unzusammenhängende Dateien enthält oder die Message nicht
    gestagte Arbeit beschreibt, korrigiere den Index oder überarbeite die
    Message vor dem Commit.

## Ergebnis

- Ein einzelner mit `git commit` erstellter Commit, dessen Message die
  Sitzung korrekt widerspiegelt.

## Vorlage

Type und Scope sind nur Beispiele; passe sie an Repo und Änderung an.

```
<type>(<scope>): <short summary>

Zusammenfassung:
- <was geändert wurde>
- <was geändert wurde>

Begründung:
- <warum>
- <warum>

Tests:
- <Befehl oder "nicht ausgeführt (Grund)">

Co-authored-by: Codex <codex@openai.com>
```
