#!/bin/sh
# Watches a Satisfactory dedicated server's container logs and posts an
# ntfy.sh notification whenever a player joins or leaves.

: "${CONTAINER_NAME:?Set CONTAINER_NAME to the docker container name of your Satisfactory dedicated server}"
: "${NTFY_URL:?Set NTFY_URL to the ntfy topic URL to notify (e.g. https://ntfy.sh/your-topic)}"

CONTAINER="$CONTAINER_NAME"
NTFY_TITLE="${NTFY_TITLE:-Satisfactory}"
# Optional: set if your ntfy topic requires auth (e.g. a self-hosted instance).
NTFY_TOKEN="${NTFY_TOKEN:-}"

STATE_DIR="${STATE_DIR:-/config/state}"
STATE_FILE="${STATE_FILE:-$STATE_DIR/players.tsv}"

mkdir -p "$STATE_DIR"
touch "$STATE_FILE"

echo "$(date): starting Satisfactory join/leave watcher for $CONTAINER"
echo "$(date): using state file $STATE_FILE"

notify() {
  msg="$1"

  echo "$(date): sending ntfy: $msg"

  if [ -n "$NTFY_TOKEN" ]; then
    curl -fsS \
      -H "Title: $NTFY_TITLE" \
      -H "Authorization: Bearer $NTFY_TOKEN" \
      -d "$msg" \
      "$NTFY_URL" >/dev/null || echo "$(date): ntfy send failed"
  else
    curl -fsS \
      -H "Title: $NTFY_TITLE" \
      -d "$msg" \
      "$NTFY_URL" >/dev/null || echo "$(date): ntfy send failed"
  fi
}

dump_state() {
  echo "$(date): current player state:"
  if [ -s "$STATE_FILE" ]; then
    sed 's/^/  /' "$STATE_FILE"
  else
    echo "  <empty>"
  fi
}

remember_player() {
  repdata="$1"
  user="$2"

  [ -n "$repdata" ] || return
  [ -n "$user" ] || return

  grep -v "^${repdata}	" "$STATE_FILE" 2>/dev/null > "${STATE_FILE}.tmp" || true
  printf '%s\t%s\n' "$repdata" "$user" >> "${STATE_FILE}.tmp"
  mv "${STATE_FILE}.tmp" "$STATE_FILE"
}

forget_player() {
  repdata="$1"

  [ -n "$repdata" ] || return
  [ -f "$STATE_FILE" ] || return

  grep -v "^${repdata}	" "$STATE_FILE" > "${STATE_FILE}.tmp" || true
  mv "${STATE_FILE}.tmp" "$STATE_FILE"
}

player_name_for_repdata() {
  repdata="$1"

  [ -n "$repdata" ] || return
  [ -f "$STATE_FILE" ] || return

  awk -F '\t' -v id="$repdata" '$1 == id { print $2; exit }' "$STATE_FILE"
}

extract_repdata() {
  echo "$1" | sed -n 's/.*RepData=\[\([^]]*\)\].*/\1/p'
}

extract_login_name() {
  echo "$1" | sed -n 's/.*[?&]Name=\([^ ?]*\).*/\1/p'
}

# The game embeds its own internal clock in every log line, e.g.
# "[2026.07.14-02.47.30:958][346]LogNet: Join succeeded: Redshift" - this
# extracts that and converts it to epoch seconds, so we can measure how
# stale a line already was by the time this script actually saw it. See
# README.md's "Notification delay" section for why this can be large and
# isn't something this script can fix.
extract_log_epoch() {
  ts="$(echo "$1" | sed -n 's/^\[\([0-9][0-9][0-9][0-9]\)\.\([0-9][0-9]\)\.\([0-9][0-9]\)-\([0-9][0-9]\)\.\([0-9][0-9]\)\.\([0-9][0-9]\):[0-9][0-9][0-9]\].*/\1-\2-\3 \4:\5:\6/p')"
  [ -n "$ts" ] || return 1
  date -d "$ts" +%s 2>/dev/null
}

# Delay in seconds between the game's own internal timestamp on a line and
# right now (when this script actually got to process it). Empty string if
# the line had no parseable timestamp.
delay_for_line() {
  log_epoch="$(extract_log_epoch "$1")"
  [ -n "$log_epoch" ] || return
  now_epoch="$(date +%s)"
  echo "$((now_epoch - log_epoch))"
}

while true; do
  docker logs -f --since=0s "$CONTAINER" 2>&1 \
    | while IFS= read -r line; do

        if echo "$line" | grep -q "LogNet: Login request:"; then
          user="$(extract_login_name "$line")"
          repdata="$(extract_repdata "$line")"
          delay="$(delay_for_line "$line")"

          if [ -n "$user" ] && [ -n "$repdata" ]; then
            remember_player "$repdata" "$user"
            echo "$(date): learned $repdata = $user (log-to-seen delay: ${delay:-unknown}s)"
            dump_state
          fi

          continue
        fi

        if echo "$line" | grep -q "LogNet: Join succeeded:"; then
          user="${line##*Join succeeded: }"

          [ -n "$user" ] || continue

          delay="$(delay_for_line "$line")"
          echo "$(date): $user joined (log-to-seen delay: ${delay:-unknown}s)"
          notify "${user} joined satisfactory! (delay: ${delay:-?}s)"

          continue
        fi

        if echo "$line" | grep -q "UNetDriver::RemoveClientConnection"; then
          repdata="$(extract_repdata "$line")"
          user="$(player_name_for_repdata "$repdata")"
          delay="$(delay_for_line "$line")"

          if [ -n "$user" ]; then
            echo "$(date): $user left (log-to-seen delay: ${delay:-unknown}s)"
            notify "${user} left satisfactory! (delay: ${delay:-?}s)"
            forget_player "$repdata"
            dump_state
          else
            echo "$(date): unknown player left; repdata=$repdata (log-to-seen delay: ${delay:-unknown}s)"
            notify "A player left satisfactory! (delay: ${delay:-?}s)"
          fi

          continue
        fi
      done

  echo "$(date): docker logs exited; retrying in 10 seconds"
  sleep 10
done
