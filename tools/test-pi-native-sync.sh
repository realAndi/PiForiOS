#!/usr/bin/env bash
# Local behavioural test of the pi-native wrapper's credential sync, against a
# stub keychain helper and a stub runtime. No SecItem involved: the stub stores
# blobs in a file and reproduces the helper's exit protocol (0 ok, 3 none,
# 1 error).
#
#   tools/test-pi-native-sync.sh
#
# Exits non-zero if any check fails. Needs zsh (the wrapper), pgrep and the
# usual coreutils -- all present on a Mac and guaranteed on device.
set -u

ROOT="$(mktemp -d)"
LIB="$ROOT/var/jb/usr/local/lib/pi-native"
HOME_DIR="$ROOT/home"
mkdir -p "$LIB" "$HOME_DIR"
trap 'rm -rf "$ROOT"' EXIT

# --- stub keychain ----------------------------------------------------------
STORE="$ROOT/keychain.bin"
touch "$STORE"
cat > "$LIB/pi-keychain" <<'EOF'
#!/usr/bin/env bash
STORE="${KCS_STORE:?}"
case "$1" in
  set) cat > "$STORE"; exit 0 ;;
  get)
    if [ -s "$STORE" ]; then cat "$STORE"; exit 0; else exit 3; fi ;;
  del) : > "$STORE"; exit 0 ;;
  probe) echo "probe: ok"; exit 0 ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$LIB/pi-keychain"

# --- stub runtime -----------------------------------------------------------
# Records its invocation, optionally rewrites auth.json mid-run (simulating a
# token refresh or /login), can exit with a code or die from SIGKILL.
mkdir -p "$LIB/runtime"
cat > "$LIB/runtime/pi" <<'EOF'
#!/usr/bin/env bash
[ -n "${KCS_LOG:-}" ] && echo "runtime invoked: $*" >> "$KCS_LOG"
case "${KCS_PI_DO:-}" in
  write)
    printf '{"anthropic":{"type":"oauth","key":"refreshed"}}' > "${KCS_AUTH:?}" ;;
  write_empty)
    printf '{}' > "${KCS_AUTH:?}" ;;
  crash)
    # Pretend the process was killed after writing: leave the file, die hard.
    printf '{"crashed":"left-behind"}' > "${KCS_AUTH:?}"
    kill -9 "$$" ;;
esac
exit "${KCS_PI_RC:-0}"
EOF
chmod +x "$LIB/runtime/pi"

# --- the wrapper under test, pointed at the sandbox -------------------------
sed -e "1s|^#!/var/jb/usr/bin/zsh|#!/usr/bin/env zsh|" \
    -e "s|^LIB=/var/jb/usr/local/lib/pi-native|LIB=$LIB|" \
    "$(cd "$(dirname "$0")/.." && pwd)/packaging/payload/pi-native" > "$LIB/pi-native"
chmod +x "$LIB/pi-native"

PASS=0; FAIL=0
check() { # check <name> <expected> <actual>
    if [ "$2" = "$3" ]; then PASS=$((PASS+1)); echo "ok   - $1"
    else FAIL=$((FAIL+1)); echo "FAIL - $1: expected [$2] got [$3]"; fi
}
state() { # state <present|absent> for the auth file
    [ -e "$1" ] && echo present || echo absent
}
auth="$HOME_DIR/.pi/agent/auth.json"
KCS_LOG="$ROOT/invocations.log"
kc_empty() { : > "$STORE"; }
run_pi()   { HOME="$HOME_DIR" KCS_STORE="$STORE" KCS_LOG="$KCS_LOG" "$LIB/pi-native" "$@"; }

# 1. empty keychain, no file: nothing happens, file stays absent
kc_empty; rm -rf "$HOME_DIR/.pi"
out=$(run_pi --version 2>&1); rc=$?
check "1 exit code clean" "0" "$rc"
check "1 wrapper quiet" "" "$out"
check "1 file absent after run" "absent" "$(state "$auth")"
check "1 keychain still empty" "" "$(cat "$STORE")"

# 2. keychain blob, no file: materialised for the run, removed after
kc_empty; printf '{"anthropic":{"key":"master"}}' > "$STORE"
run_pi --version >/dev/null
check "2 file removed after run" "absent" "$(state "$auth")"
check "2 keychain intact" '{"anthropic":{"key":"master"}}' "$(cat "$STORE")"

# 3. runtime rewrites auth.json mid-run (token refresh): new state synced, file removed
kc_empty; printf '{"old":"master"}' > "$STORE"
HOME="$HOME_DIR" KCS_STORE="$STORE" KCS_PI_DO=write KCS_AUTH="$auth" KCS_LOG="$KCS_LOG" \
    "$LIB/pi-native" -p hi >/dev/null
check "3 keychain updated from runtime write" '{"anthropic":{"type":"oauth","key":"refreshed"}}' "$(cat "$STORE")"
check "3 file removed after sync" "absent" "$(state "$auth")"

# 4. leftover differing file (a run killed before it could sync): imported
kc_empty; printf '{"old":"master"}' > "$STORE"
printf '{"new":"recovered"}' > "$auth"
run_pi --version >/dev/null
check "4 leftover file imported to keychain" '{"new":"recovered"}' "$(cat "$STORE")"
check "4 file removed after run" "absent" "$(state "$auth")"

# 5. leftover {} file, keychain populated: {} must NOT displace the keychain
kc_empty; printf '{"real":"master"}' > "$STORE"
printf '{}' > "$auth"
run_pi --version >/dev/null
check "5 {} did not displace keychain" '{"real":"master"}' "$(cat "$STORE")"

# 6. empty keychain, {} file: no import, and {} is not stored afterwards
kc_empty; printf '{}' > "$auth"
run_pi --version >/dev/null
check "6 {} not stored" "" "$(cat "$STORE")"
check "6 {} file removed" "absent" "$(state "$auth")"

# 7. deliberate logout at exit: populated keychain, runtime rewrote to {}
kc_empty; printf '{"was":"signed-in"}' > "$STORE"
HOME="$HOME_DIR" KCS_STORE="$STORE" KCS_PI_DO=write_empty KCS_AUTH="$auth" KCS_LOG="$KCS_LOG" \
    "$LIB/pi-native" --version >/dev/null
check "7 logout stored to keychain" '{}' "$(cat "$STORE")"
check "7 file removed after logout" "absent" "$(state "$auth")"

# 8. migration: pre-keychain plaintext auth.json with real credentials
kc_empty; printf '{"legacy":"credential"}' > "$auth"
run_pi --version >/dev/null
check "8 plaintext migrated" '{"legacy":"credential"}' "$(cat "$STORE")"
check "8 plaintext removed after run" "absent" "$(state "$auth")"

# 9. PI_PLAINTEXT=1: file untouched, keychain untouched
kc_empty; printf '{"plain":"file-store"}' > "$STORE"
printf '{"plain":"file-store"}' > "$auth"
HOME="$HOME_DIR" KCS_STORE="$STORE" PI_PLAINTEXT=1 "$LIB/pi-native" --version >/dev/null
check "9 plaintext file kept" "present" "$(state "$auth")"
check "9 keychain untouched" '{"plain":"file-store"}' "$(cat "$STORE")"
rm -f "$auth"

# 10. broken keychain helper: warn, keep the file, still exit cleanly
kc_empty; printf '{"only":"copy"}' > "$auth"
mv "$LIB/pi-keychain" "$LIB/pi-keychain.bak"
printf '#!/bin/sh\nexit 1\n' > "$LIB/pi-keychain"; chmod +x "$LIB/pi-keychain"
out=$(HOME="$HOME_DIR" KCS_STORE="$STORE" KCS_LOG="$KCS_LOG" "$LIB/pi-native" --version 2>&1); rc=$?
check "10 clean exit despite broken keychain" "0" "$rc"
check "10 warning emitted once" "1" "$(printf '%s\n' "$out" | grep -c 'credential store unreadable')"
check "10 only copy kept" "present" "$(state "$auth")"
mv "$LIB/pi-keychain.bak" "$LIB/pi-keychain"
rm -f "$auth"

# 11. exit-code propagation, ordinary and signal-death
kc_empty
HOME="$HOME_DIR" KCS_STORE="$STORE" KCS_LOG="$KCS_LOG" KCS_PI_RC=7 "$LIB/pi-native" >/dev/null 2>&1
check "11 child exit code passes through" "7" "$?"
HOME="$HOME_DIR" KCS_STORE="$STORE" KCS_LOG="$KCS_LOG" KCS_PI_DO=crash KCS_AUTH="$auth" \
    "$LIB/pi-native" >/dev/null 2>&1
check "11 signal death propagates (137 = 128+9)" "137" "$?"
# The child was killed after writing, but the wrapper survived it -- so the
# exit sync still ran. (The unsyncable case is the wrapper itself dying, whose
# recovery is the leftover-file test above.)
check "11 sync still ran after child's signal death" "absent" "$(state "$auth")"
check "11 keychain updated from the killed child's write" '{"crashed":"left-behind"}' "$(cat "$STORE")"

# 12. concurrent session: another runtime/pi process visible -> file left in
# place, but the keychain is still updated (last writer wins)
kc_empty; printf '{"shared":"master"}' > "$STORE"; rm -f "$auth"
# A process whose argv[0] IS the runtime path, so pgrep -f finds it.
( exec -a "$LIB/runtime/pi" sleep 5 ) &
BLOCKER=$!
HOME="$HOME_DIR" KCS_STORE="$STORE" KCS_PI_DO=write KCS_AUTH="$auth" KCS_LOG="$KCS_LOG" \
    "$LIB/pi-native" --version >/dev/null
check "12 file kept while another session runs" "present" "$(state "$auth")"
check "12 keychain still updated" '{"anthropic":{"type":"oauth","key":"refreshed"}}' "$(cat "$STORE")"
kill "$BLOCKER" 2>/dev/null; wait "$BLOCKER" 2>/dev/null
run_pi --version >/dev/null
check "12 file removed by the last one out" "absent" "$(state "$auth")"

# 13. stale sync temp files are cleaned up, not left holding a secret copy
kc_empty; printf '{"master":"x"}' > "$STORE"; rm -rf "$HOME_DIR/.pi"
mkdir -p "$HOME_DIR/.pi/agent"
printf '{"stale":"partial"}' > "$HOME_DIR/.pi/agent/.auth.json.kcsync.999"
run_pi --version >/dev/null
leftover=$(ls -A "$HOME_DIR/.pi/agent" | grep -c kcsync || true)
check "13 stale kcsync cleaned" "0" "$leftover"

# 14. the child receives the arguments verbatim
kc_empty; : > "$KCS_LOG"
run_pi --version -p hello >/dev/null 2>&1
check "14 runtime received args" "runtime invoked: --version -p hello" "$(cat "$KCS_LOG")"

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" = 0 ]
