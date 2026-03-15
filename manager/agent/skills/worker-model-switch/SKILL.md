---
name: worker-model-switch
description: Switch a Worker Agent's LLM model. Use when the human admin requests changing a Worker's model to a different one.
---

# Worker Model Switch

Switch a Worker's LLM model. The script tests connectivity first, then patches the Worker's `openclaw.json` in MinIO and notifies the Worker.

## Usage

```bash
bash /opt/hiclaw/agent/skills/worker-model-switch/scripts/update-worker-model.sh \
  --worker <WORKER_NAME> --model <MODEL_ID> [--context-window <SIZE>] [--no-reasoning]
```

Examples:
```bash
bash /opt/hiclaw/agent/skills/worker-model-switch/scripts/update-worker-model.sh \
  --worker alice --model claude-sonnet-4-6

bash /opt/hiclaw/agent/skills/worker-model-switch/scripts/update-worker-model.sh \
  --worker alice --model my-custom-model --context-window 300000

bash /opt/hiclaw/agent/skills/worker-model-switch/scripts/update-worker-model.sh \
  --worker alice --model deepseek-chat --no-reasoning
```

## What the script does

1. Strips any `hiclaw-gateway/` prefix from the model name
2. Tests the model via `POST /v1/chat/completions` on the AI Gateway — exits with error if unreachable
3. Pulls the Worker's `openclaw.json` from MinIO
4. If the model is already in the `models` array: switches `agents.defaults.model.primary` (hot-reload after file-sync)
5. If the model is new: adds it to the `models` array and switches primary, outputs `RESTART_REQUIRED`
6. Pushes the updated `openclaw.json` back to MinIO
7. Updates `workers-registry.json` with the new model name
8. Sends a Matrix @mention to the Worker asking it to file-sync (includes restart notice if needed)

## After running the script

Check the script output:
- If the output contains `RESTART_REQUIRED`, tell the human admin: **"The model has been added to the Worker's configuration, but a restart of the Worker container is needed for it to take effect. Would you like me to recreate the Worker?"**
- Otherwise the switch takes effect after the Worker runs file-sync, no further action needed.

## Reasoning control

By default, reasoning (extended thinking) is enabled. To disable it, pass `--no-reasoning`.

If the Worker container is stopped, the config is still updated in MinIO — it will take effect on next start.

## On failure

If the gateway test fails (non-200), the script prints an error with details. No changes are made to `openclaw.json` in this case.

## Switching to an unknown model

When the human admin requests switching a Worker to a model you don't recognize, you MUST:

1. **Ask the admin for the model's context window size** before running the script. Example: "This model is not in the known list. What is its context window size (in tokens)?"
2. Once the admin provides the context window, run the script with `--context-window`:
   ```bash
   bash /opt/hiclaw/agent/skills/worker-model-switch/scripts/update-worker-model.sh \
     --worker <WORKER_NAME> --model <MODEL_ID> --context-window <SIZE>
   ```
3. If the admin does not know the context window, use the default (150,000) by omitting `--context-window`.
4. If the admin wants to disable reasoning, add `--no-reasoning` to the command.

## Pre-configured models (for reference)

| Model | contextWindow | maxTokens |
|-------|--------------|-----------|
| gpt-5.4 | 1,050,000 | 128,000 |
| gpt-5.3-codex / gpt-5-mini / gpt-5-nano | 400,000 | 128,000 |
| claude-opus-4-6 | 1,000,000 | 128,000 |
| claude-sonnet-4-6 | 1,000,000 | 64,000 |
| claude-haiku-4-5 | 200,000 | 64,000 |
| qwen3.5-plus | 200,000 | 64,000 |
| deepseek-chat / deepseek-reasoner / kimi-k2.5 | 256,000 | 128,000 |
| glm-5 / MiniMax-M2.5 | 200,000 | 128,000 |
