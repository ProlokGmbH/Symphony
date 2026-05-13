---
name: symphony-commit
description:
  Erstellt im Symphony-Issue-Workflow einen sauberen Commit, wenn der Workflow
  diesen Schritt ausdrücklich vorgibt.
---

# Symphony Commit

Nur für den vorgesehenen Commit-Schritt verwenden.

## Ablauf

- `git status --short --branch` prüfen und nur issue-bezogene Änderungen
  zusammenfassen.
- Relevante Diffs lesen.
- Verlangte Validierung ausführen.
- Mit vorgegebenem Betreff und kurzem Body committen; Body nennt Zweck,
  Snapshot-Charakter und Validierungsstand.
- Fremde oder unrelated Änderungen nicht revertieren.

Wenn Validierung nicht läuft oder fehlschlägt, den Grund dokumentieren statt
einen erfolgreichen Commit zu behaupten.
