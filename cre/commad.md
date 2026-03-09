## CRE simulation commands

### Market automation workflow

```bash
cre workflow simulate ./market-automation-workflow --target staging-settings --non-interactive --broadcast
```

### Market users workflow

```bash
cre workflow simulate ./market-users-workflow \
  --target staging-settings \
  --non-interactive \
  --trigger-index 0 \
  --http-payload "$(cat ./market-users-workflow/payload/sponsor.json)" \
  --broadcast

cre workflow simulate ./market-users-workflow \
  --target staging-settings \
  --non-interactive \
  --trigger-index 2 \
  --http-payload "$(cat ./market-users-workflow/payload/execute.json)" \
  --broadcast
```

### Agents workflow

```bash
cre workflow simulate ./agents-workflow \
  --target staging-settings \
  --non-interactive \
  --trigger-index 0 \
  --http-payload "$(cat ./agents-workflow/payload/agent-plan.json)" \
  --broadcast

cre workflow simulate ./agents-workflow \
  --target staging-settings \
  --non-interactive \
  --trigger-index 1 \
  --http-payload "$(cat ./agents-workflow/payload/agent-sponsor.json)" \
  --broadcast

cre workflow simulate ./agents-workflow \
  --target staging-settings \
  --non-interactive \
  --trigger-index 2 \
  --http-payload "$(cat ./agents-workflow/payload/agent-execute.json)" \
  --broadcast
```
