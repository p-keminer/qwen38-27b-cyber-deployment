"""Fail the smoke run unless every expected Inspect task completed correctly."""

from __future__ import annotations

import argparse
from pathlib import Path
from typing import Any

from inspect_ai.log import read_eval_log


EXPECTED_TASKS = {"llm_smoke", "native_tool_smoke"}


def is_correct(value: Any) -> bool:
    if hasattr(value, "value"):
        value = value.value
    if isinstance(value, dict):
        value = value.get("value")
    if isinstance(value, bool):
        return value
    if isinstance(value, (int, float)):
        return value == 1
    return str(value).upper() in {"C", "CORRECT", "1", "1.0", "TRUE"}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("log_dir", type=Path)
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    paths = sorted(args.log_dir.glob("*.eval"))
    if not paths:
        raise SystemExit(f"No .eval logs found in {args.log_dir}")

    passed: set[str] = set()
    errors: list[str] = []
    for path in paths:
        log = read_eval_log(str(path))
        task_name = log.eval.task
        if task_name not in EXPECTED_TASKS:
            continue
        if str(log.status) != "success":
            errors.append(f"{task_name}: status={log.status}")
            continue
        samples = log.samples or []
        if len(samples) != 1:
            errors.append(f"{task_name}: expected one sample, found {len(samples)}")
            continue
        sample = samples[0]
        if sample.error is not None:
            errors.append(f"{task_name}: sample error={sample.error}")
            continue
        scores = sample.scores or {}
        if not scores or not all(is_correct(score) for score in scores.values()):
            values = {name: score.value for name, score in scores.items()}
            errors.append(f"{task_name}: non-passing scores={values}")
            continue
        passed.add(task_name)

    missing = EXPECTED_TASKS - passed
    if missing:
        errors.append(f"missing passing tasks={sorted(missing)}")
    if errors:
        raise SystemExit("Smoke verification failed:\n- " + "\n- ".join(errors))

    print("Verified passing Inspect logs: " + ", ".join(sorted(passed)))


if __name__ == "__main__":
    main()
