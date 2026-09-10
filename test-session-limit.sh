#!/usr/bin/env bash
set -euo pipefail

WATCHER="$(cd "$(dirname "$0")" && pwd)/agent-watcher.sh"
eval "$(sed -n '/^session_limit_until()/,/^}/p' "$WATCHER")"

[ "$(date -r "$(session_limit_until "You've hit your session limit · resets 4pm (America/Indianapolis)")" +%H:%M)" = "16:00" ]
[ "$(date -r "$(session_limit_until "You've hit your session limit · resets 3:10pm (America/Indianapolis)")" +%H:%M)" = "15:10" ]
[ -z "$(session_limit_until "ordinary reply")" ]

echo "session-limit parser: ok"
