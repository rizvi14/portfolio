# <Project name>

**One-line takeaway:** <the finding, stated as a claim — not "an analysis of X">

## The question

What decision does this inform, and for whom? Two or three sentences.

## Data

| Source | Grain | Rows | Period | How obtained |
|---|---|---|---|---|
| | | | | |

Known caveats: <missingness, sampling, definitional gotchas — say them up front>

## Method

1. **Extract** — `src/`
2. **Transform** — `sql/` or `src/`
3. **Analyse** — `notebooks/analysis.ipynb`

Call out the one or two choices a reviewer would challenge (how you handled
outliers, why this metric definition, why this model) and why you made them.

## Findings

- Finding, with the number attached.
- Finding.

## What I'd do next

Honest limitations and the obvious next step given more time or data.

## Reproduce

```bash
pip install -r requirements.txt
python src/extract.py      # or: see data/README for the download link
jupyter lab notebooks/analysis.ipynb
```
