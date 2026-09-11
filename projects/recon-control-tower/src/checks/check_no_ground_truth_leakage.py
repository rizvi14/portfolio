"""Fail the build if anything but the evaluation mart can see the answers.

This project measures its own matching engine instead of asserting that it
works: breaks are injected at known rates with labels, and
``agg_matching_rule_performance`` grades the pipeline's verdicts against them.
That number is only worth reading if the pipeline could not have peeked. One
``ref`` in one staging model - added innocently, to "enrich" a break code -
turns the whole scorecard into a tautology, and nothing in dbt would complain.

So the quarantine is enforced structurally. dbt already writes the full
dependency graph to ``target/manifest.json``; this walks it and asserts that
exactly one node has ``source.ground_truth.break_truth`` anywhere in its
ancestry.

The production analogue is real. Adjudicated outcomes, chargeback results and
analyst dispositions are all future knowledge relative to the run that had to
decide without them, and a feature built on them will score beautifully in
backtest and fail on day one. A repo that cannot express "this table may not
flow into that one" ends up relying on everyone remembering.

Usage:
    python -m src.checks.check_no_ground_truth_leakage
    python -m src.checks.check_no_ground_truth_leakage --manifest path/to/manifest.json
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

# The source dbt must keep quarantined, and the only node allowed to read it.
QUARANTINED_SOURCE = "source.recon_control_tower.ground_truth.break_truth"
PERMITTED_READERS = {"model.recon_control_tower.agg_matching_rule_performance"}

DEFAULT_MANIFEST = Path(__file__).resolve().parents[2] / "dbt" / "target" / "manifest.json"


def _load_graph(manifest_path: Path) -> tuple[dict[str, list[str]], set[str]]:
    """Return (node -> direct parents, set of quarantined source ids)."""
    with manifest_path.open(encoding="utf-8") as fh:
        manifest = json.load(fh)

    parents: dict[str, list[str]] = {}
    for unique_id, deps in manifest.get("parent_map", {}).items():
        parents[unique_id] = list(deps)

    # Match on the source's identity rather than a hardcoded string alone, so a
    # rename of the source in sources.yml fails loudly here instead of silently
    # disarming the check.
    quarantined = {
        unique_id
        for unique_id, node in manifest.get("sources", {}).items()
        if node.get("source_name") == "ground_truth"
    }
    if QUARANTINED_SOURCE not in quarantined:
        print(
            f"  the quarantined source {QUARANTINED_SOURCE!r} is not in the manifest.\n"
            f"  Found instead: {sorted(quarantined) or 'nothing under source ground_truth'}.\n"
            "  Either the source was renamed - update this check in the same change -\n"
            "  or the manifest is stale. Run `dbt parse` and try again.",
            file=sys.stderr,
        )
        raise SystemExit(2)

    return parents, quarantined


def _ancestors(node: str, parents: dict[str, list[str]]) -> set[str]:
    seen: set[str] = set()
    stack = list(parents.get(node, []))
    while stack:
        current = stack.pop()
        if current in seen:
            continue
        seen.add(current)
        stack.extend(parents.get(current, []))
    return seen


def _path_to(node: str, target: str, parents: dict[str, list[str]]) -> list[str]:
    """One concrete dependency path from node back to target, for the error."""
    stack: list[tuple[str, list[str]]] = [(node, [node])]
    seen: set[str] = set()
    while stack:
        current, path = stack.pop()
        if current == target:
            return path
        if current in seen:
            continue
        seen.add(current)
        for parent in parents.get(current, []):
            stack.append((parent, path + [parent]))
    return [node, target]


def check(manifest_path: Path) -> int:
    if not manifest_path.exists():
        print(
            f"  no manifest at {manifest_path}.\n"
            "  Run `dbt parse` (or any dbt build) first - this check reads the graph dbt writes.",
            file=sys.stderr,
        )
        return 2

    parents, quarantined = _load_graph(manifest_path)

    # Tests are allowed to read ground truth only if they are attached to a
    # permitted reader; in practice none are, and a leak through a test would
    # still contaminate nothing downstream. Models, marts and exposures are the
    # population that matters.
    candidates = [
        node
        for node in parents
        if node.startswith(("model.", "snapshot.", "exposure."))
    ]

    leaks: list[tuple[str, list[str]]] = []
    readers: list[str] = []
    for node in candidates:
        touched = _ancestors(node, parents) & quarantined
        if not touched:
            continue
        readers.append(node)
        if node not in PERMITTED_READERS:
            leaks.append((node, _path_to(node, sorted(touched)[0], parents)))

    if leaks:
        print("GROUND TRUTH LEAK - the scorecard cannot be trusted in this state.\n", file=sys.stderr)
        for node, path in sorted(leaks):
            print(f"  {node}", file=sys.stderr)
            print("      " + "\n   <- ".join(path), file=sys.stderr)
        print(
            "\n  Only these nodes may read the ground-truth source:\n"
            + "".join(f"    {n}\n" for n in sorted(PERMITTED_READERS))
            + "  Everything else has to reach its verdict without the answers, or the\n"
            "  precision and recall in agg_matching_rule_performance measure nothing.",
            file=sys.stderr,
        )
        return 1

    missing = PERMITTED_READERS - set(readers)
    if missing:
        # The scorecard silently losing its ground-truth dependency is just as
        # broken as a leak: the model would still build and still publish
        # numbers, but they would be graded against nothing.
        print(
            "The evaluation mart no longer reads ground truth:\n"
            + "".join(f"    {n}\n" for n in sorted(missing))
            + "  precision and recall would be computed against an empty label set.",
            file=sys.stderr,
        )
        return 1

    print(
        f"ground-truth quarantine intact: {len(candidates)} models checked, "
        f"{len(readers)} permitted reader(s), 0 leaks"
    )
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--manifest",
        type=Path,
        default=DEFAULT_MANIFEST,
        help="path to dbt's target/manifest.json (default: dbt/target/manifest.json)",
    )
    args = parser.parse_args()
    return check(args.manifest)


if __name__ == "__main__":
    raise SystemExit(main())
