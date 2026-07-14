# satisfactory-notify

Watches a Satisfactory dedicated server's container logs and sends a push
notification (via [ntfy](https://ntfy.sh)) whenever a player joins or
leaves.

It works by tailing `docker logs -f` on your Satisfactory server container
and matching Unreal Engine's own `LogNet` lines — no mods, no API token, no
changes to the game server required.

## Requirements

- Your Satisfactory dedicated server already running in a Docker container
  on the same host (or a host reachable via a shared Docker socket).
- Docker Compose.
- An ntfy topic to notify — either a topic on the public
  [ntfy.sh](https://ntfy.sh) service, or your own self-hosted instance.

## Setup

```sh
cp .env.example .env
vi .env   # set CONTAINER_NAME and NTFY_URL
docker compose up -d
```

`CONTAINER_NAME` must match the exact Docker container name (or ID) of your
Satisfactory dedicated server:

```sh
docker ps --format '{{.Names}}'
```

Subscribe to your `NTFY_URL` topic in the [ntfy app](https://ntfy.sh/app)
or via `curl -s https://ntfy.sh/your-topic-here/json` to receive the
notifications.

## How it works

The container mounts the host's Docker socket read-only and runs
`satisfactory-join-notify.sh`, which loops on `docker logs -f
"$CONTAINER_NAME"` and reacts to three log lines the game server emits:

- `LogNet: Login request:` — records the connecting player's name against
  their session's `RepData` identifier, so a later disconnect can be
  attributed to the right player.
- `LogNet: Join succeeded: <name>` — the player finished connecting; sends
  a "joined" notification.
- `UNetDriver::RemoveClientConnection` — a player disconnected; looks up
  the name recorded at login and sends a "left" notification.

Player state is kept in a small TSV file (`RepData` → name) in a named
Docker volume, so it survives container restarts and is never bundled into
the image or git repo.

## Notification delay

Notifications can lag the real join/leave event by well over a minute.
This isn't a bug in this script — it's a consequence of the Satisfactory
server's own stdout buffering. When a container has no TTY attached
(`docker inspect` → `"Tty": false`, which is the default for most
Satisfactory container images), the game engine's log output is
block-buffered by C stdio instead of line-buffered, so lines can sit in an
internal buffer for tens of seconds before Docker's log driver — and
therefore this script — ever sees the bytes. Nothing downstream of that
buffering (this script, `docker logs -f`, Docker's `json-file` driver) can
recover the time already lost before the byte was written out.

### Confirmed fix: give the server container a TTY

Adding `tty: true` and `stdin_open: true` to the *Satisfactory server's own*
Compose service (not this notifier's) fixes it. This has been confirmed in
practice: on an unpatched container, delays up to **394 seconds** were
measured; after adding both settings and redeploying, delay dropped to
**0 seconds**, confirmed across four consecutive join/leave events over a
longer bake-in period, not just one lucky sample.

```yaml
services:
  satisfactory-server:
    image: ghcr.io/wolveix/satisfactory-server:v1.9.10  # or your image/tag
    tty: true
    stdin_open: true
    # ...rest of your existing config
```

Both settings are needed — `tty: true` alone attaches a pseudo-terminal to
stdout (which is what fixes the buffering), but some images also probe
`stdin_open` as part of deciding they're running interactively.

One cosmetic side effect: warning-level log lines pick up ANSI color codes
once the game believes it's writing to a color-capable terminal. This
doesn't affect `satisfactory-notify` — the lines it parses (`LogNet: Login
request:`, `LogNet: Join succeeded:`, `UNetDriver::RemoveClientConnection`)
aren't warning-level and come through clean.

If you're running the server through a platform that doesn't expose a TTY
toggle (e.g. some app-catalog/marketplace deployments), you may need to
redeploy it as a hand-written Compose service to set this — there's
normally no other way to add it after the fact.

Each notification includes a `(delay: Ns)` suffix, computed from the game's
own embedded log timestamp vs. wall-clock time when the script processed
the line, so you can see how bad this is on your own setup without having
to manually diff `docker logs --timestamps` output.

## Known limitation

Satisfactory's official Dedicated Server HTTPS API (port 7777, `/api/v1`)
exposes `NumConnectedPlayers` as a count, but not individual player names —
so it can't replace the log-watching approach here if you want named
join/leave events. It could be used as a lower-latency "someone joined"
companion signal, but that hybrid isn't implemented in this script.

## Configuration reference

| Variable         | Required | Default | Description |
|------------------|----------|---------|--------------|
| `CONTAINER_NAME` | yes      | —       | Docker container name/ID of the Satisfactory dedicated server to watch |
| `NTFY_URL`       | yes      | —       | Full ntfy topic URL to POST notifications to |
| `NTFY_TITLE`     | no       | `Satisfactory` | Notification title header |
| `NTFY_TOKEN`     | no       | (empty) | Bearer token, if your ntfy topic requires auth |

## Validate

```sh
docker compose config --quiet
```

## About this project

The core join/leave-detection script started as a simple, homelab-specific
shell script I wrote by hand. Wrapping it up for public use — Docker
Compose, `.env`-driven configuration, a named volume for state, this
README — was straightforward but tedious, so I had
[Claude Code](https://claude.com/claude-code) do that part. I reviewed and
tested the result before publishing it.

## License

MIT — see [LICENSE](LICENSE).
