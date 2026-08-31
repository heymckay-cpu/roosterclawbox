# ClawBox agent worker

`agent-worker.sh` is the systemd-driven worker (`agent-worker.service`) that
watches the repos in `config.env` for issues labeled `agent-ready`, runs
Claude Code on them, and opens PRs. This copy is the version-controlled
source of truth; the live copy runs from `/home/clawbox/agent/` on the box.

`config.env.example` mirrors the live config with secret-like values
redacted — copy it to `/home/clawbox/agent/config.env` and fill in the
redacted values on a new box.

Deploying a change: edit here, commit, then copy to `/home/clawbox/agent/`
and `systemctl --user restart agent-worker` (or the system unit, as installed).
