# Scoring

Every EdgeBench SWE task is a roadmap of several independent targets. The agent starts on a frozen source-version snapshot of a real open-source repository and has to implement the functionality the next release introduced. Each target has its own test suite, adapted from the project's own upstream tests, so a task is scored target by target rather than as one pass or fail.

## Two metrics

**Resolved Rate** is the strict measure. A task counts as resolved only when every target's test suite passes. The resolved rate of a model is the fraction of tasks it resolved.

**Completion Score** credits partial progress. Each target carries a weight proportional to its implementation complexity, and a task's score is the weighted fraction of targets whose tests pass. A model's completion score is the mean over tasks. A model that lands four of five targets scores well here and zero on the resolved rate, which is the point: the two numbers together show how far agents get and how often they finish.

Both metrics are computed from the same test runs. Nothing is judged by a model; a target passes when its tests pass inside the task's pinned environment.

## What the verifier does

`tests/test.sh` in each task builds the repository as the agent left it, runs the per-target test files in order, and writes one reward per target. The weights live with the task definition. The verifier runs with its own timeout (`[verifier] timeout_sec` in `task.toml`) after the agent's session ends.

## What the agent sees

The agent receives the source-version repository inside a Docker environment and `instruction.md`, which states each target's API signatures, parameter semantics, default values and exception behaviour. It does not state implementation details: no data structures, no algorithm hints, no repository or version identifiers. The test files, the target-version code and the oracle patch are withheld. Future branches and upstream access are blocked.

## How a task is validated before release

Two checks hold for every task before it is included:

| Check | Condition | Why |
|---|---|---|
| fail2pass | the tests score below 1.0 on the source version | the tested functionality is genuinely new, not already present |
| oracle | the tests score 1.0 with the target-version patch applied | the tests are solvable, with no unsatisfiable assertions |

After that, agents at several capability tiers attempt the task and every failure is attributed to a task-side defect or a model-side limitation. Confirmed defects are repaired and the task re-run, until the only failures left are the model's. A task is finalized only when it has no task-side errors, the oracle achieves full reward, and models of different tiers produce distinguishable scores.
