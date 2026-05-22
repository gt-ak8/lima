#!/bin/bash
# Shared user-mode provisioning for all VMs.
# Sets up known_hosts, git identity from PARAM_*, base rc wiring (PATH, TERM
# fallback, starship init, SSH agent socket stabilizer), bash safety net.
# Re-runs on every `limactl start`; every step must be idempotent.
#
# NOT -e: a single non-fatal failure must not abort the rest of user setup,
# otherwise zsh/starship/safety-net never get applied and the user lands in a
# half-configured shell.
set -ux

# --- shell ---------------------------------------------------------------
if [ "$(getent passwd "$USER" | cut -d: -f7)" != "/usr/bin/zsh" ]; then
  sudo usermod -s /usr/bin/zsh "$USER" || true
fi

# --- ssh known_hosts -----------------------------------------------------
mkdir -p ~/.ssh
chmod 700 ~/.ssh
ssh-keyscan -t rsa,ecdsa,ed25519 github.com ssh.github.com >>~/.ssh/known_hosts 2>/dev/null || true
sort -u ~/.ssh/known_hosts -o ~/.ssh/known_hosts || true
chmod 600 ~/.ssh/known_hosts

# --- git config ----------------------------------------------------------
# Identity + SSH commit signing. Signing relies on the forwarded SSH agent
# (base.yaml: forwardAgent: true): the VM never holds the private key on
# disk; ssh-agent on the host signs each commit. The `key::` prefix tells
# git the literal pubkey follows (no on-disk key file lookup needed).
# Values come from the VM's `param:` block (sourced from vms/<name>/.env).
git config --global user.name        "${PARAM_GIT_NAME}"
git config --global user.email       "${PARAM_GIT_EMAIL}"
git config --global gpg.format       ssh
git config --global user.signingkey  "${PARAM_GIT_SIGNING_KEY}"
git config --global commit.gpgsign   true
git config --global tag.gpgsign      true

# --- zsh rc base ---------------------------------------------------------
touch ~/.zshrc
grep -q '.local/bin' ~/.zshrc || echo 'export PATH="$HOME/.local/bin:$PATH"' >>~/.zshrc
# TERM fallback: hosts like ghostty/wezterm/kitty forward an exotic $TERM
# the guest does not have terminfo for, breaking backspace, `clear`, colors.
grep -q 'TERM fallback' ~/.zshrc || cat >>~/.zshrc <<'ZRC'
# TERM fallback
[ -n "$TERM" ] && ! infocmp "$TERM" >/dev/null 2>&1 && export TERM=xterm-256color
ZRC
grep -q 'starship init' ~/.zshrc || echo 'eval "$(starship init zsh)"' >>~/.zshrc

# SSH agent socket stabilizer. Zed's remote SSH terminal does NOT inherit
# SSH_AUTH_SOCK from the editor's ssh connection (zed#29438), and tmux
# freezes the value at first attach. Real `ssh lima-<vm>` logins refresh
# ~/.ssh/agent.sock to point at the live forwarded socket; every other
# shell reads that stable path instead of a stale per-session one.
grep -q 'agent.sock' ~/.zshrc || cat >>~/.zshrc <<'AGENTSOCK'
if [ -n "$SSH_AUTH_SOCK" ] && [ -S "$SSH_AUTH_SOCK" ] \
   && [ "$SSH_AUTH_SOCK" != "$HOME/.ssh/agent.sock" ]; then
  ln -sf "$SSH_AUTH_SOCK" "$HOME/.ssh/agent.sock"
fi
export SSH_AUTH_SOCK="$HOME/.ssh/agent.sock"
AGENTSOCK

# --- bash safety net -----------------------------------------------------
# `limactl shell` and even plain ssh can land in bash (e.g. when a stale
# ssh ControlMaster cached the pre-chsh shell). Bash login shells read
# ~/.bash_profile (or ~/.profile) but NOT ~/.bashrc, and Lima rewrites
# ~/.profile to a PATH-only stub that does not source ~/.bashrc, so the
# jump must live in ~/.bash_profile.
touch ~/.bash_profile
grep -q 'exec zsh' ~/.bash_profile || cat >>~/.bash_profile <<'PROF'
[ -f ~/.profile ] && . ~/.profile
[ -f ~/.bashrc ]  && . ~/.bashrc
# TERM fallback (see ~/.zshrc for rationale)
[ -n "$TERM" ] && ! infocmp "$TERM" >/dev/null 2>&1 && export TERM=xterm-256color
case $- in *i*) [ -z "$ZSH_VERSION" ] && exec zsh -l ;; esac
PROF
