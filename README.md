# Data Portfolio — Mohammed Ali Rizvi

End-to-end data projects built to be read quickly: each one states the question,
the data, the method, and what the answer changes.

📫 [mo.rizvi@gmail.com](mailto:mo.rizvi@gmail.com) · [GitHub](https://github.com/rizvi14)

---

## Projects

| Project | Question it answers | Stack | Notes |
|---|---|---|---|
| _(add your first project here)_ | | | |

<!--
Row format — keep it to one line each:
| [Name](projects/name/) | "Which onboarding step loses the most trial users?" | Python · DuckDB · dbt | [Notebook](projects/name/notebooks/analysis.ipynb) |
-->

## How this repo is organised

```
projects/
  <project-name>/
    README.md        # question → data → method → findings
    data/raw/        # untouched source extracts (gitignored)
    data/processed/  # derived tables (gitignored)
    notebooks/       # exploration and the final write-up
    sql/             # queries and models
    src/             # reusable extract / transform code
```

`projects/_template/` is a starting point — copy it to begin a new project.

Data files are gitignored by default so the repo stays clonable. Where a project
needs data to be reproducible, it ships either a download script in `src/` or a
small `sample_*.csv` extract that is committed deliberately.

## Running a project

```bash
python -m venv .venv
source .venv/bin/activate       # Windows: .venv\Scripts\activate
pip install -r requirements.txt
jupyter lab
```

Any project with extra dependencies carries its own `requirements.txt`.
