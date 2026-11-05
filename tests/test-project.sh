#!/usr/bin/env bash
# Project mode (lib/project.sh): names, URLs and the command line.

# make_repo DIR -> a git repository with one commit at DIR.
make_repo() {
  mkdir -p "$1"
  git -C "$1" init -q -b main
  echo hi >"$1/README"
  git -C "$1" add README
  git -C "$1" -c user.name=t -c user.email=t@example.invalid commit -qm init
}

test_is_repo_url() {
  load_libs
  local u
  for u in https://github.com/a/shop.git git@github.com:a/shop.git ssh://h/x file:///tmp/x shop.git; do
    is_repo_url "$u" || fail "should be a URL: $u"
  done
  for u in list pull status shop; do
    ! is_repo_url "$u" || fail "should not be a URL: $u"
  done
}

test_project_dir_from_url() {
  load_libs
  assert_eq "$(project_dir_from_url https://github.com/a/shop.git)" shop
  assert_eq "$(project_dir_from_url git@github.com:a/shop.git)" shop
  assert_eq "$(project_dir_from_url git@github.com:shop.git)" shop
  assert_eq "$(project_dir_from_url https://gitlab.com/a/b/web-app/)" web-app
  assert_eq "$(project_dir_from_url file:///srv/git/shop/.git)" shop
}

test_project_base_name() {
  load_libs
  assert_eq "$(project_base_name /x/My_Shop)" my-shop
  assert_eq "$(project_base_name /x/42things)" things
  assert_eq "$(project_base_name /x/___)" project
  assert_eq "$(project_base_name /x/shop.v2-)" shop-v2
  [ "$(project_base_name "/x/$(printf 'a%.0s' {1..80})" | wc -c)" -le 51 ] || fail "name not shortened"
}

test_project_names_get_a_suffix_on_collision() {
  load_libs
  assert_eq "$(project_pick_name /a/shop)" shop
  config_set user_shop roy
  assert_eq "$(project_pick_name /a/shop)" shop-2
  config_set project_shop-2 /b/shop
  assert_eq "$(project_pick_name /c/shop)" shop-3
}

test_project_name_is_reused_for_the_same_path() {
  load_libs
  config_set project_shop "/a/my shop"
  config_set project_shop-2 /b/shop
  assert_eq "$(project_name_for "/a/my shop")" shop
  assert_eq "$(project_name_for /b/shop)" shop-2
  assert_eq "$(project_name_for /c/shop)" ""
}

test_project_mode_in_a_repo() {
  make_repo "$TMP/My_Shop"
  cd "$TMP/My_Shop"
  acage_run -n --disk 1   # small enough for any test machine's free space
  assert_rc 0
  assert_out "New cage 'my-shop'"
  assert_out "qemu backend"
}

test_repo_url_is_cloned_first() {
  acage_run -n https://example.invalid/a/shop.git
  assert_rc 0
  assert_out "git clone -- https://example.invalid/a/shop.git shop"
}

test_project_commands_need_a_project() {
  acage_run pull; assert_rc 1; assert_out "Not in a git repository"
  make_repo "$TMP/shop"
  cd "$TMP/shop"
  acage_run pull; assert_rc 1; assert_out "No cage for this project yet"
  acage_run status nosuch; assert_rc 1; assert_out "isn't a project cage"
}

test_named_vm_uses_its_saved_backend() {
  # The libvirt backend (the default) asks virsh about the VM; qemu never does.
  stub virsh "echo called >>'$TMP/virsh.log'; exit 1"
  acage_run start box --pool-dir "$POOL"
  [ -s "$TMP/virsh.log" ] || fail "libvirt didn't ask virsh"
  rm -f "$TMP/virsh.log"
  mkdir -p "$XDG_CONFIG_HOME/acage"
  echo backend_box=qemu >"$XDG_CONFIG_HOME/acage/config"
  acage_run start box
  [ ! -e "$TMP/virsh.log" ] || fail "the saved qemu backend wasn't used"
  assert_out "No VM named 'box'"
}

test_delete_forgets_project_settings() {
  mkdir -p "$XDG_CONFIG_HOME/acage"
  printf '%s\n' backend_shop=qemu project_shop=/a/shop project_copied_shop=1 \
    project_setup_shop=1 preview_port_shop=3000 other=1 >"$XDG_CONFIG_HOME/acage/config"
  acage_run delete shop -y
  assert_rc 0
  assert_eq "$(cat "$XDG_CONFIG_HOME/acage/config")" "other=1"
}
