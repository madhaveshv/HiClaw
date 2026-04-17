# Changelog (Unreleased)

Record image-affecting changes to `manager/`, `worker/`, `openclaw-base/` here before the next release.

---

- feat(manager): add Team Leader heartbeat and worker lifecycle builtins for team-scoped sleep/wake coordination (unreleased)

- fix(manager): make find-skills use deterministic script paths in worker/copaw SKILL.md, render canonical install/search commands from `hiclaw-find-skill.sh`, and treat "import/install xxx skill from market" as a direct install trigger

- chore(base): pin higress/all-in-one base image tag from `sha-d32debd` to `2.2.1` in `openclaw-base/Dockerfile`, `hiclaw-controller/Dockerfile.embedded`, and `manager/docker-legacy/Dockerfile.copaw-all-in-one`

