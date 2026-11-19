# agentiscale-action

Joins a GitHub Actions job to your [agentiscale](https://github.com/whiteredhouse/agentiscaled) network as a
short-lived node, with GitHub's OIDC token instead of a stored secret, and runs the
node in the background until the job ends. Agents in the job can then call the agents
in your network, and the other way round.

```yaml
jobs:
  agents:
    runs-on: ubuntu-latest # or macos-latest
    environment: ci # the environment your trust names
    permissions:
      id-token: write
      contents: read
    steps:
      - uses: whiteredhouse/agentiscale-action@v1
        id: agentiscale
        with:
          network-id: YOUR_NETWORK_ID
      # agentiscaled is on PATH and the node is connected.
      - run: agentiscaled status -data-dir "${{ steps.agentiscale.outputs.data-dir }}"
```

## Call an agent

Once the node is connected, a step can call any agent of your network with
`agentiscaled task send` (agentiscaled v0.12.0 or later) and use its answer. The
agent's steps show in the job log, the answer goes to standard output, and the step
fails unless the task completes:

```yaml
      - env:
          DATA_DIR: ${{ steps.agentiscale.outputs.data-dir }}
        run: >
          agentiscaled task send -data-dir "$DATA_DIR"
          -timeout 10m reviewer "Review the changes on this branch" > review.md
```

`-timeout` bounds the whole call; when it passes, the command cancels the task.

`-wait-agent 2m` waits for an agent whose node is still joining, for example one
started by another job; it works with `-no-wait` too.

To run several agents at once, send each task with `-no-wait`, which prints the
task's ID and returns, and collect the answers with `agentiscaled task wait`
(agentiscaled v0.14.0 or later). Each wait fails its step unless that task completes;
its `-timeout` bounds the wait, not the task:

```yaml
      - id: tasks
        env:
          DATA_DIR: ${{ steps.agentiscale.outputs.data-dir }}
        run: |
          review=$(agentiscaled task send -data-dir "$DATA_DIR" -no-wait reviewer "Review the changes on this branch")
          echo "review=$review" >> "$GITHUB_OUTPUT"
          tests=$(agentiscaled task send -data-dir "$DATA_DIR" -no-wait tester "Run the integration tests")
          echo "tests=$tests" >> "$GITHUB_OUTPUT"
      # Wait for every task that was sent, even when another step failed.
      - if: ${{ !cancelled() && steps.tasks.outputs.review }}
        env:
          DATA_DIR: ${{ steps.agentiscale.outputs.data-dir }}
          TASK: ${{ steps.tasks.outputs.review }}
        run: agentiscaled task wait -data-dir "$DATA_DIR" -timeout 15m reviewer "$TASK" > review.md
      - if: ${{ !cancelled() && steps.tasks.outputs.tests }}
        env:
          DATA_DIR: ${{ steps.agentiscale.outputs.data-dir }}
          TASK: ${{ steps.tasks.outputs.tests }}
        run: agentiscaled task wait -data-dir "$DATA_DIR" -timeout 15m tester "$TASK" > tests.md
      # Stop any task still running, however the job ended.
      - if: ${{ always() }}
        env:
          DATA_DIR: ${{ steps.agentiscale.outputs.data-dir }}
          REVIEW: ${{ steps.tasks.outputs.review }}
          TESTS: ${{ steps.tasks.outputs.tests }}
        run: |
          agentiscaled task cancel -data-dir "$DATA_DIR" -- reviewer "$REVIEW"
          agentiscaled task cancel -data-dir "$DATA_DIR" -- tester "$TESTS"
```

The last step needs agentiscaled v0.15.0 or later. `task cancel` leaves a task that
has already ended as it is and skips an empty ID, so it succeeds whichever tasks were
sent and finished.

The exit status says how a task went: 0 completed; 1 the command failed, for example
the agent could not be reached; 2 the task failed, was rejected or was cancelled; 3
the agent asks a question, which this flow does not answer; 4 the timeout passed and
the task still runs.

An agent runs one task at a time and rejects another, so send each agent at most one
task, and keep any runs that call the same agent from overlapping, whatever their
workflow or branch: give their jobs a `concurrency` group named after the agents, such
as `group: agentiscale-reviewer` with `cancel-in-progress: false`. Only the job's node
can follow or cancel its tasks: a task left running, for example when the runner
stops before the cleanup step, keeps its agent busy until it ends and later tasks for
that agent are rejected until then: up to 15 minutes of work, or up to an hour while
it waits for an answer to a question (exit 3). Set the job's `timeout-minutes` to the sum of its
waits plus a margin, and give the trust a node lifetime longer than the job. A wait
that fails can leave its output file empty.

See [Call an agent from the command
line](https://github.com/whiteredhouse/agentiscaled/blob/main/docs/connect-agents.md#call-an-agent-from-the-command-line).

## Before you start

Trust the workflow in the console, under **Settings > Trusted workloads**: its
repository, the workflow file and branch, and the GitHub environment its job runs in.
Your network's ID is shown in the console under your network's name. Each node is
removed when the trust's node lifetime ends, and a trust admits a limited number of
nodes at once. See [Nodes that join with a workload
token](https://github.com/whiteredhouse/agentiscaled/blob/main/docs/getting-started.md#nodes-that-join-with-a-workload-token).

## What it does

1. Installs [agentiscaled](https://github.com/whiteredhouse/agentiscaled) with its `install.sh`, checked
   against the release's checksums, and puts it on `PATH`.
2. Asks GitHub for a token whose audience is the control service's URL followed by
   `/networks/` and your network's ID, so it can join only that network.
3. Joins with it, then runs the node in the background with its API on a Unix socket
   only, and waits until it is connected.

Linux and macOS runners, x64 and ARM64.

## Inputs

| Input | Default | |
| --- | --- | --- |
| `network-id` | required | Your network's ID. |
| `version` | `latest` | Release of agentiscaled, like `v0.11.0` (v0.11.0 or later). |
| `hostname` | `github-<run>-<attempt>-<job>` | Name of the node in your member list. |
| `data-dir` | `$RUNNER_TEMP/agentiscale` | Data directory of the node. |
| `control-url` | `https://control.agentiscale.net` | URL of the control service. |
| `timeout-seconds` | `120` | How long to wait for the node to connect. |

## Outputs

| Output | |
| --- | --- |
| `data-dir` | Data directory of the node; pass it as `-data-dir` to other `agentiscaled` commands. |
| `peer-id` | The node's peer ID in your network. |
| `log` | File the node logs to. |

## Versions

Releases are tagged `v1.2.3`, and `v1` moves to the newest `v1.x.y`. Pin a full
version or a commit for a fixed action; `version` pins the node.

## License

Apache-2.0
