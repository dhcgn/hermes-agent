# My Hermes Agent Docker Image

This repo provide the Docker Image ghcr.io/dhcgn/hermes-agent:latest which is based on nousresearch/hermes-agent and adds the ability to mount a read-only folder for configuration files.

Features:
- Only allow outgoing connections to host names listed in a file (one host name per line) in the read-only folder.
- Mount a read-only folder for configuration files.
- Image is kept up to date with the original image and is automatically rebuilt when the original image is updated.
- Image is extended with these tools:
  - githubcli "gh"
  - powershell "pwsh"
  - age-encryption tool "age"

Inspiration: https://github.com/anthropics/claude-code/tree/main/.devcontainer

## Original Docker Image

```powershell
$dataPath = Join-Path $env:USERPROFILE ".hermes-docker"
$devPath = "C:\dev"

docker run -it --rm `
    --mount "type=bind,source=$dataPath,target=/opt/data" `
    --mount "type=bind,source=$devPath,target=/opt/dev,readonly" `
    -p 8642:8642 `
    -p 9119:9119 `
    -e HERMES_DASHBOARD=1 `
    -e HERMES_DASHBOARD_BASIC_AUTH_USERNAME=admin `
    -e HERMES_DASHBOARD_BASIC_AUTH_PASSWORD=choose-a-strong-password `
    -e HERMES_DASHBOARD_BASIC_AUTH_SECRET=... `
    -e HERMES_DASHBOARD_HOST=127.0.0.1 `
    nousresearch/hermes-agent
```

## How to build

```powershell
docker build -t ghcr.io/dhcgn/hermes-agent:latest .
```

Build args (all optional, override with `--build-arg NAME=value`):

| Arg | Default | Purpose |
|---|---|---|
| `HERMES_BASE_IMAGE` | `nousresearch/hermes-agent:latest` | Upstream image to derive from. |
| `GH_VERSION` | `2.97.0` | GitHub CLI version. |
| `PWSH_VERSION` | `7.6.4` | PowerShell version. |
| `AGE_VERSION` | `1.3.1` | age-encryption version. |

The Dockerfile resolves `amd64`/`arm64` per-tool download URLs from
`TARGETARCH` (set automatically by BuildKit/buildx); only `amd64` has been
built and tested in this repo so far.

`docker compose build` builds the same Dockerfile for both the `hermes` and
`firewall-init` services (see "Hardened deployment" below) — no separate
build step needed for that path.

Neither `docker build` nor `docker compose build`/`run`/`up` checks for a
newer `nousresearch/hermes-agent:latest` on their own — once that base layer
is cached locally, it's reused indefinitely. Add `--pull` to force the check:

```powershell
docker build --pull -t ghcr.io/dhcgn/hermes-agent:latest .
# or, for the compose path:
docker compose build --pull
```

(This is what the auto-rebuild workflow already does on every CI run — see
`.github/workflows/rebuild-image.yml`.)

## How to run

Hermes is a terminal app (TUI/chat) by default — `docker run -it --rm` with
no trailing command already launches it interactively, no `--tui` flag or
special setup needed. On a brand-new `/opt/data` volume it first asks you to
pick a model provider (one-time; the answer is saved to the volume).

### Quick start: interactive chat

```powershell
$dataPath = Join-Path $env:USERPROFILE ".hermes-docker"

docker run -it --rm `
    --mount "type=bind,source=$dataPath,target=/opt/data" `
    ghcr.io/dhcgn/hermes-agent:latest
```

That's it — no ports, no dashboard env vars, no egress allowlist needed for a
one-off interactive session. `Ctrl+C` or `/exit` ends the session; `--rm`
removes the container afterwards. Re-run the same command later to continue
where you left off (state persists in `$dataPath`).

The sections below add a persistent background gateway (Telegram/Discord/API,
web dashboard) and the egress allowlist — skip them if you only want to chat.

### Egress allowlist

`MY_HOST_NAMES_FILE_PATH` points at a file with one hostname (or IPv4
literal/CIDR) per line — see [allowd_host_names.txt](allowd_host_names.txt)
for an example. Lines starting with `#` are comments.

- Env var unset → no enforcement (unrestricted egress, same as the original image).
- Env var set, file missing → fail-closed (all egress blocked except DNS).
- Env var set, file present → only the listed hosts are reachable. IPv6 egress
  is blocked entirely (no IPv6 allowlist support).

### Persistent gateway mode (single container)

For a background daemon reachable via Telegram/Discord/the web dashboard/API
instead of an interactive terminal session:

```powershell
$dataPath = Join-Path $env:USERPROFILE ".hermes-docker"
$dataReadOnlyPath = Join-Path $env:USERPROFILE ".hermes-docker-readonly"
$devPath = "C:\dev"

# $allowd_host_names_file_path = Join-Path $dataReadOnlyPath "allowd_host_names.txt"

docker run -it --rm  --pull=always `
    --cap-add=NET_ADMIN `
    --cap-add=NET_RAW `
    --mount "type=bind,source=$dataPath,target=/opt/data" `
    --mount "type=bind,source=$devPath,target=/opt/dev,readonly" `
    --mount "type=bind,source=$dataReadOnlyPath,target=/opt/data-readonly,readonly" `
    -p 8642:8642 `
    -p 9119:9119 `
    -e HERMES_DASHBOARD=1 `
    -e HERMES_DASHBOARD_BASIC_AUTH_USERNAME=admin `
    -e HERMES_DASHBOARD_BASIC_AUTH_PASSWORD=choose-a-strong-password `
    -e HERMES_DASHBOARD_BASIC_AUTH_SECRET=... `
    -e HERMES_DASHBOARD_HOST=127.0.0.1 `
    -e MY_HOST_NAMES_FILE_PATH=/opt/data-readonly/allowd_host_names.txt `
    ghcr.io/dhcgn/hermes-agent:latest
```

This requires `--cap-add=NET_ADMIN --cap-add=NET_RAW` on `docker run` since
the container manages its own `iptables` rules — the kernel requires those
capabilities for that, there's no way around it. Without them the container
still starts, but egress is left unrestricted and a warning is logged.

The agent process itself (UID 10000) never actually uses these capabilities —
verified via `/proc/<pid>/status`, its `CapEff` is always zero. But the
capabilities stay available to *any* root process in the container for its
whole lifetime (e.g. `docker exec --user root`, or the root-run cont-init
hooks that execute on every boot), so a compromised agent that gains root
could run `iptables -F` and erase the very allowlist meant to contain it. See
"Hardened deployment" below to remove this risk entirely.

### Hardened deployment (zero capabilities on the agent container)

`docker-compose.yml` runs the same allowlist with `NET_ADMIN`/`NET_RAW` held
by neither the Hermes container. A tiny [`pause`](https://github.com/kubernetes/kubernetes/tree/master/build/pause)
container owns the shared network namespace; a one-shot `firewall-init`
container attaches to it, applies the `iptables` rules (it holds the
capabilities briefly), then exits. `hermes` then attaches to that
already-configured namespace, never granted `NET_ADMIN`/`NET_RAW` itself —
netfilter rules live in the namespace, not in whichever process added them.
Verified via `/proc/self/status`: `hermes`'s capability bounding set is
Docker's small default set (`CHOWN`/`SETUID`/`SETGID`/etc. — needed for the
base image's own root→hermes-user privilege drop on boot) with `NET_ADMIN`
confirmed absent. This is the same pattern Kubernetes uses to let init
containers configure a pod's network before the app container starts.

`hermes` intentionally does **not** use `cap_drop: [ALL]` — s6-overlay needs
`CAP_SETUID`/`CAP_SETGID`/`CAP_CHOWN` to drop from root to the `hermes` user
and chown `/opt/data` on first boot; stripping everything breaks that step
(`s6-applyuidgid: fatal: unable to set supplementary group list`) and the
container never becomes usable. Simply never adding `NET_ADMIN`/`NET_RAW` is
sufficient — that capability was never in Docker's default set to begin with.

Copy [.env.example](.env.example) to `.env` next to `docker-compose.yml` and
edit the three paths — Compose loads `.env` automatically, so you don't need
to re-export env vars in every new terminal session:

```powershell
docker compose up -d
```

Requires Docker Compose v2.20+ (for `depends_on: condition:
service_completed_successfully`). Trade-off versus the simple `docker run`
above: three containers instead of one, and startup takes one extra step
(`firewall-init` must finish before `hermes` starts) — but the agent
container itself never has network-admin privileges at any point.

This setup (`restart: unless-stopped`, no allocated TTY) is for the
persistent gateway, not an interactive session. For an interactive chat under
the same hardened network, attach a one-off run instead:

```powershell
docker compose run --rm hermes
```

### PowerShell shortcut: Start-Agent

Add a `Start-Agent` function to your `$PROFILE` to always rebuild with
`--pull` (see "How to build") before starting an interactive session, from
any directory:

```powershell
if (!(Test-Path $PROFILE)) { New-Item -ItemType File -Path $PROFILE -Force }
notepad $PROFILE
```

Add this function, then save:

```powershell
function Start-Agent {
    Push-Location "C:\dev\my-hermes-agent-docker"
    try {
        docker run --rm -it ghcr.io/dhcgn/hermes-agent:latest hermes
    } finally {
        Pop-Location
    }
}
```

```powershell
function Start-Agent-From-Source {
    Push-Location "C:\dev\my-hermes-agent-docker"
    try {
        docker compose build --pull && docker compose run --rm hermes
    } finally {
        Pop-Location
    }
}
```

Reload the profile (`. $PROFILE`, or open a new terminal), then just run:

```powershell
Start-Agent-From-Source
```

