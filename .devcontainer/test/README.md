# Tests

For working on the template, and for checking a copy after changing it.

## Unit tests

Run on the host, with no Docker and no network. Every external program is
stubbed.

```bash
bash .devcontainer/test/test-devc.sh
bash .devcontainer/test/test-dev-firewall.sh
bash .devcontainer/test/test-dev-own-volumes.sh
bash .devcontainer/test/test-dev-bootstrap.sh
```

To catch bashisms, run the three sh scripts under dash:

```bash
DEVC_SHELL=dash bash .devcontainer/test/test-devc.sh
DEV_FIREWALL_SHELL=dash bash .devcontainer/test/test-dev-firewall.sh
DEV_OWN_VOLUMES_SHELL=dash bash .devcontainer/test/test-dev-own-volumes.sh
```

## Smoke checks

Run against a real container and the real internet. Start with a freshly
started container (`.devcontainer/host/devc up`) and run them in this order:

```bash
.devcontainer/host/devc exec bash .devcontainer/test/smoke-dev-firewall.sh
bash .devcontainer/test/smoke-devc.sh
bash .devcontainer/test/smoke-dev-own-volumes.sh
```

| Check | Runs | What it proves |
| --- | --- | --- |
| `smoke-dev-firewall.sh` | inside the container, as `dev` | The firewall blocks, and `dev` can't turn it off. |
| `smoke-devc.sh` | on the host | The `devc` commands work, and the firewall comes back on after a restart. |
| `smoke-dev-own-volumes.sh` | on the host, in its own throwaway container | A volume inside the workspace is writable when the UID is remapped. |
