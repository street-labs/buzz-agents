#!/usr/bin/env bash
# Mention retry: a reply with a non-member p-tag and two bad bare @tokens still posts,
# each token neutralized. A fake relay rejects one problem per send, like the real
# one. Run: bash test-mention-retry.sh
set -u
cd "$(dirname "$0")"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
# The send + retry block: from the first send up to the success branch.
python3 -c '
import re
s = open("agent-watcher.sh").read()
print(re.search(r"^  send_out=\"\$\(\"\$BUZZ\" messages send --channel.*?(?=^  if \[ \"\$send_rc\" -eq 0 \]; then)", s, re.S | re.M).group(0))' > "$T/block.sh"
cat > "$T/buzz" <<'FAKE'
#!/usr/bin/env python3
import sys
a = sys.argv[1:]
body = a[a.index("--content") + 1]
if "--mention" in a:
    print('{"error":"user_error","message":"pubkeys are not channel members"}'); sys.exit(1)
for tok in ("@reviewer", "@-mention"):
    if tok in body:
        print('{"error":"user_error","message":"mention \x27%s\x27 does not match a current channel member; retry with --mention <pubkey>"}' % tok); sys.exit(1)
open(sys.argv[0] + ".sent", "w").write(body)
FAKE
chmod +x "$T/buzz"
BUZZ="$T/buzz"; AGENT_NAME=test; channel_id=c; reply_target=r
reply='ask @reviewer to check, and use @-mention syntax. cc @reviewer'
mention_flags=(--mention abc)
. "$T/block.sh" > "$T/log"
fail=0
[ "$send_rc" -eq 0 ] || { echo "FAIL: reply was not sent (rc=$send_rc)"; cat "$T/log"; fail=1; }
sent="$(cat "$T/buzz.sent" 2>/dev/null)"
z=$(printf '\342\200\213')
[ "$sent" = "ask @${z}reviewer to check, and use @${z}-mention syntax. cc @${z}reviewer" ] || { echo "FAIL: sent body: $sent"; fail=1; }
[ "$reply" = "$sent" ] || { echo "FAIL: reply not updated to the sent body"; fail=1; }
# A rejection that names a token already neutralized must stop, not spin.
cat > "$T/buzz" <<'FAKE'
#!/usr/bin/env bash
echo '{"message":"mention '"'"'@ghost'"'"' does not match a current channel member"}'; exit 1
FAKE
reply='hi'; mention_flags=()
. "$T/block.sh" > "$T/log"
[ "$send_rc" -ne 0 ] && [ "$(grep -c retrying "$T/log")" -le 1 ] || { echo "FAIL: unfixable rejection should give up after one retry"; cat "$T/log"; fail=1; }
[ "$fail" = 0 ] && echo ok
exit "$fail"
