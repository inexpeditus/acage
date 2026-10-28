#!/usr/bin/env bash
# acage push (lib/push.sh), with a stand-in ssh that runs the receiving side
# in a fake home folder instead of a VM.

fake_vm_home() {
  REMOTE=$TMP/vm-home
  mkdir -p "$REMOTE"
  # The last argument ssh gets is the command to run in the VM.
  stub ssh 'for a; do last=$a; done; cd "'"$REMOTE"'" && exec sh -c "$last"'
  load_libs qemu
  SSH_HOST=127.0.0.1 SSH_PORT=2222
}

test_push_files_and_folders() {
  fake_vm_home
  mkdir -p "$TMP/src/proj/sub"
  echo a >"$TMP/src/notes.md"; echo b >"$TMP/src/proj/sub/x.txt"
  push_paths box agent . "$TMP/src/notes.md" "$TMP/src/proj" 2>/dev/null
  assert_eq "$(cat "$REMOTE/notes.md")" a
  assert_eq "$(cat "$REMOTE/proj/sub/x.txt")" b
}

test_push_into_a_folder_with_awkward_names() {
  fake_vm_home
  mkdir -p "$TMP/src"
  echo c >"$TMP/src/-dash name.txt"
  push_paths box agent "in box/deep" "$TMP/src/-dash name.txt" 2>/dev/null
  assert_eq "$(cat "$REMOTE/in box/deep/-dash name.txt")" c
}

test_push_sends_symlinks_as_symlinks() {
  fake_vm_home
  mkdir -p "$TMP/src/proj" "$TMP/private"
  echo secret >"$TMP/private/data"
  ln -s "$TMP/private/data" "$TMP/src/proj/link"
  push_paths box agent . "$TMP/src/proj" 2>/dev/null
  [ -L "$REMOTE/proj/link" ] || fail "symlink was followed"
  [ "$(find "$REMOTE" -type f -name data)" = "" ] || fail "the link's target was copied"
}

test_push_refuses_home_and_credentials() {
  fake_vm_home
  mkdir -p "$HOME/.ssh" "$HOME/.aws"
  assert_fails "is your home folder" push_paths box agent . "$HOME"
  assert_fails "holds credentials" push_paths box agent . "$HOME/.ssh"
  assert_fails "holds credentials" push_paths box agent . "$HOME/.aws"
  assert_fails "Refusing to push /" push_paths box agent . /
  assert_fails "No such file" push_paths box agent . "$TMP/nope"
  [ -z "$(ls -A "$REMOTE")" ] || fail "something was copied anyway"
}

test_push_warns_and_confirms_about_secrets() {
  fake_vm_home
  mkdir -p "$TMP/src/app"
  touch "$TMP/src/app/.env" "$TMP/src/app/id_ed25519" "$TMP/src/app/main.c"
  # Non-interactive without --yes: it warns, lists the matches, and refuses.
  OUT=$( (ASSUME_YES=0; push_paths box agent . "$TMP/src/app") 2>&1 ) && fail "expected push to refuse"
  assert_out "These look like secrets"
  assert_out "app/.env"
  assert_out "app/id_ed25519"
  assert_not_out "main.c"
  assert_out "pass --yes"
  [ -e "$REMOTE/app/.env" ] && fail "nothing should have been pushed" || true
  # With --yes: still warns, but proceeds, so the files arrive.
  ( ASSUME_YES=1; push_paths box agent . "$TMP/src/app" ) 2>/dev/null
  [ -f "$REMOTE/app/.env" ] || fail "expected .env to be pushed under --yes"
  [ -f "$REMOTE/app/main.c" ] || fail "expected main.c to be pushed under --yes"
}

test_push_command_line() {
  acage_run push box --backend qemu --pool-dir "$POOL"
  assert_rc 1; assert_out "What should be copied?"
  mkdir -p "$POOL/vms/box"
  printf 'C_RAM_MB=2048\nC_VCPUS=2\nC_SSH_PORT=2222\nC_SHARE_DIR=\n' >"$POOL/vms/box/config"
  acage_run push box "$TMP" --to x --user --backend qemu --pool-dir "$POOL"
  assert_rc 1; assert_out "'box' is not running"
}
