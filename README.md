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
      - run: >
          agentiscaled task send -data-dir "${{ steps.agentiscale.outputs.data-dir }}"
          -timeout 10m reviewer "Review the changes on this branch" > review.md
```

`-wait-agent 2m` waits for an agent whose node is still joining, for example one
started by another job.

To run several agents at once, send each task with `-no-wait`, which prints the
task's ID and returns, and collect the answers with `agentiscaled task wait`
(agentiscaled v0.14.0 or later). Each wait fails its step unless that task completes;
its `-timeout` bounds the wait, not the task:

```yaml
      - id: tasks
        env:
          DATA_DIR: ${{ steps.agentiscale.outputs.data-dir }}
        run: |
          echo "review=$(agentiscaled task send -data-dir "$DATA_DIR" -no-wait reviewer "Review the changes on this branch")" >> "$GITHUB_OUTPUT"
          echo "tests=$(agentiscaled task send -data-dir "$DATA_DIR" -no-wait tester "Run the integration tests")" >> "$GITHUB_OUTPUT"
      - run: >
          agentiscaled task wait -data-dir "${{ steps.agentiscale.outputs.data-dir }}"
          -timeout 10m reviewer "${{ steps.tasks.outputs.review }}" > review.md
      - run: >
          agentiscaled task wait -data-dir "${{ steps.agentiscale.outputs.data-dir }}"
          -timeout 10m tester "${{ steps.tasks.outputs.tests }}" > tests.md
```

The exit status says how a task went: 0 completed, 2 it failed, was rejected or
cancelled, 3 the agent asks a question, 4 the timeout passed. See [Call an agent from
the command
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
