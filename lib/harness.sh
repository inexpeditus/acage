#!/usr/bin/env bash
# Agent harnesses that can be installed in the VM. Sourced by agentcage.
#
# HARNESS is a comma-separated list (e.g. "pi,codex"), or "none".
# Each harness is installed globally with npm during first boot. Packages that
# do not need their install scripts get --ignore-scripts.

HARNESS_CHOICES="pi claude-code codex"

harness_list() { [ "$HARNESS" = none ] || echo "$HARNESS" | tr ',' ' '; }

harness_validate() {
  local h
  [ -n "$HARNESS" ] || die "--harness is empty (use 'none' for no agent)"
  [ "$HARNESS" = none ] && return 0
  for h in $(harness_list); do
    case "$h" in
      pi|claude-code|codex) ;;
      *) die "Unknown harness '$h' (choose from: $HARNESS_CHOICES, or none)" ;;
    esac
  done
}

harness_npm_package() {
  case "$1" in
    pi) echo "@earendil-works/pi-coding-agent" ;;
    claude-code) echo "@anthropic-ai/claude-code" ;;
    codex) echo "@openai/codex" ;;
  esac
}

# Claude Code's postinstall step links its native (musl) binary, so it needs
# install scripts; the others ship ready-to-run files.
harness_needs_scripts() { [ "$1" = claude-code ]; }

harness_command() {
  case "$1" in
    pi) echo pi ;;
    claude-code) echo claude ;;
    codex) echo codex ;;
  esac
}

# Extra Alpine packages. Claude Code's musl build needs the C++ runtime and,
# on Alpine, the system ripgrep instead of its bundled glibc one.
harness_packages() {
  case "$1" in
    claude-code) echo "libgcc libstdc++ ripgrep" ;;
    codex) echo "ripgrep" ;;
  esac
}

# Lines for /etc/profile.d/agentcage.sh in the guest.
harness_profile_lines() {
  case "$1" in
    claude-code) echo "export USE_BUILTIN_RIPGREP=0" ;;
  esac
}

# Which API key a harness can use: anthropic or openai.
harness_provider() {
  case "$1" in
    pi|claude-code) echo anthropic ;;
    codex) echo openai ;;
  esac
}

# What to tell the user about logging in without an API key.
harness_login_hint() {
  case "$1" in
    pi) echo "pi: put your Anthropic API key in ~/.pi/agent/auth.json" ;;
    claude-code) echo "claude-code: run 'claude' and log in with your Claude account, or set ANTHROPIC_API_KEY" ;;
    codex) echo "codex: run 'codex login' (ChatGPT account) or 'codex login --with-api-key'" ;;
  esac
}

# Shell snippet run in the VM that reads the API key from stdin and stores it
# where the harness looks for it. Keys are restricted to [A-Za-z0-9._-] by the
# caller, so they are safe to embed in JSON and shell.
harness_store_key_script() {
  case "$1" in
    pi)
      printf '%s\n' 'umask 077; mkdir -p "$HOME/.pi/agent"; IFS= read -r k; printf "{\n  \"anthropic\": { \"type\": \"api_key\", \"key\": \"%s\" }\n}\n" "$k" >"$HOME/.pi/agent/auth.json"' ;;
    claude-code)
      printf '%s\n' 'umask 077; d="$HOME/.config/agentcage"; mkdir -p "$d"; IFS= read -r k; touch "$d/env"; grep -v "^export ANTHROPIC_API_KEY=" "$d/env" >"$d/env.new" || true; printf "export ANTHROPIC_API_KEY=%s\n" "$k" >>"$d/env.new"; mv "$d/env.new" "$d/env"' ;;
    codex)
      printf '%s\n' 'codex login --with-api-key >/dev/null' ;;
  esac
}

harness_has_provider() {
  local h
  for h in $(harness_list); do [ "$(harness_provider "$h")" = "$1" ] && return 0; done
  return 1
}
