#!/bin/bash
# BrettVision Mac installer. Safe to re-run: every stage checks before it acts.
#   curl -fsSL https://raw.githubusercontent.com/clausefreedom/brettvision-install/main/install.sh | bash
# Env knobs (testing): BV_HOME BV_BUNDLE_URL BV_TEST=1 BV_SKIP_BREW BV_SKIP_TAILSCALE BV_SKIP_CLAUDE BV_SKIP_SUDO BV_SKIP_WAIT
set -u
BV_HOME="${BV_HOME:-$HOME/brettvision}"
BV_BUNDLE_URL="${BV_BUNDLE_URL:-https://github.com/clausefreedom/brettvision-install/releases/latest/download/brettvision-field.tar.gz}"
G=$'\033[32m'; R=$'\033[31m'; Y=$'\033[33m'; N=$'\033[0m'
say() { printf '%s\n' "$*"; }
ok() { say "${G}PASS${N} $1"; }
warn() { say "${Y}NOTE${N} $1"; }
die() { say "${R}FAIL${N} $1"; say ""; say "Nothing is broken by stopping here. Fix the line above, then paste the install line again."; say "If unsure, copy this whole window and send it to Johnny/Clause."; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

say "=== BrettVision install $(date '+%Y-%m-%d %H:%M') ==="

# 1. platform
if [ -z "${BV_TEST:-}" ]; then
  [ "$(uname -s)" = "Darwin" ] || die "This installer is for a Mac."
  ver="$(sw_vers -productVersion)"; major="${ver%%.*}"
  [ "$major" -ge 12 ] 2>/dev/null || die "macOS $ver is too old (need 12 Monterey or newer). Update via System Settings > Software Update."
  ok "macOS $ver ($(uname -m))"
else
  warn "BV_TEST set: skipping Mac checks"
fi

# 2. sudo once, keep it alive (Homebrew, Tailscale service, sleep settings)
if [ -z "${BV_SKIP_SUDO:-}" ]; then
  say "Your Mac password is needed once (typing shows nothing; that is normal)."
  sudo -v || die "Could not get admin rights. This Mac account must be an Administrator."
  ( while true; do sudo -n true; sleep 50; kill -0 "$$" 2>/dev/null || exit; done ) 2>/dev/null &
fi

# 3. Xcode command-line tools (git, compilers). Dialog appears; click Install.
if [ -z "${BV_SKIP_BREW:-}" ]; then
  if ! xcode-select -p >/dev/null 2>&1; then
    say "A window is asking to install the developer tools. Click Install and wait (5-15 min)."
    xcode-select --install >/dev/null 2>&1
    until xcode-select -p >/dev/null 2>&1; do sleep 10; done
  fi
  ok "developer tools"

  # 4. Homebrew
  for b in /opt/homebrew/bin/brew /usr/local/bin/brew; do [ -x "$b" ] && eval "$("$b" shellenv)"; done
  if ! have brew; then
    say "Installing Homebrew (a few minutes)..."
    NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" || die "Homebrew install failed."
    for b in /opt/homebrew/bin/brew /usr/local/bin/brew; do [ -x "$b" ] && eval "$("$b" shellenv)"; done
  fi
  have brew || die "Homebrew not found after install."
  # shellcheck disable=SC2016
  line='eval "$($(ls /opt/homebrew/bin/brew /usr/local/bin/brew 2>/dev/null | head -1) shellenv)"'
  touch "$HOME/.zprofile"; grep -qF 'brew shellenv' "$HOME/.zprofile" || printf '%s\n' "$line" >> "$HOME/.zprofile"
  ok "Homebrew $(brew --prefix)"

  # 5. tools
  for f in uv git; do brew list --formula "$f" >/dev/null 2>&1 || brew install "$f" || die "brew install $f failed."; done
  ok "uv, git"
fi

# 6. the BrettVision code (public field bundle: capture + detection only, no personal data)
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
say "Downloading BrettVision..."
curl -fsSL "$BV_BUNDLE_URL" -o "$tmp/b.tgz" || die "Download failed ($BV_BUNDLE_URL). Check the internet connection."
mkdir -p "$BV_HOME"
tar -xzf "$tmp/b.tgz" -C "$BV_HOME" || die "Bundle is corrupt; re-run."
ok "code in $BV_HOME"

# 7. Python env (uv fetches its own Python; no system Python needed)
have uv || export PATH="$HOME/.local/bin:$PATH"
have uv || die "uv missing."
(cd "$BV_HOME" && uv venv --python 3.12 --allow-existing .venv >/dev/null && uv pip install --python .venv/bin/python -q -r requirements-field.txt) || die "Python setup failed."
"$BV_HOME/.venv/bin/python" -c "import numpy, scipy, serial" || die "Python libraries did not import."
ok "Python environment"

# 8. Tailscale (lets Clause reach this Mac remotely) + remote login
if [ -z "${BV_SKIP_TAILSCALE:-}" ]; then
  brew list --formula tailscale >/dev/null 2>&1 || brew install tailscale || die "brew install tailscale failed."
  sudo brew services start tailscale >/dev/null 2>&1 || warn "could not start tailscale service"
  sleep 3
  if ! tailscale status >/dev/null 2>&1; then
    say ""; say ">>> Open the link below in a browser and sign in to Tailscale (same account as your phone):"
    tailscale up --ssh --hostname=brettvision-mac 2>&1 | head -6 &
    for _ in $(seq 1 60); do tailscale status >/dev/null 2>&1 && break; sleep 3; done
  fi
  if tailscale status >/dev/null 2>&1; then ok "Tailscale $(tailscale ip -4 2>/dev/null | head -1)"; else warn "Tailscale not signed in yet; double-click Start BrettVision later to retry."; fi
  # belt and braces: normal ssh with Clause's public key
  mkdir -p "$HOME/.ssh"; chmod 700 "$HOME/.ssh"; touch "$HOME/.ssh/authorized_keys"; chmod 600 "$HOME/.ssh/authorized_keys"
  key="$(cat "$BV_HOME/mac/vps_key.pub")"; grep -qF "$key" "$HOME/.ssh/authorized_keys" || printf '%s\n' "$key" >> "$HOME/.ssh/authorized_keys"
  sudo systemsetup -setremotelogin on >/dev/null 2>&1 || warn "Remote Login not enabled (Tailscale SSH still works)."
fi

# 9. power: no sleep on AC
if [ -z "${BV_SKIP_SUDO:-}" ]; then
  if sudo pmset -c sleep 0 displaysleep 15 >/dev/null 2>&1; then ok "Mac stays awake on power"; else warn "could not change sleep settings; keep lid open and plugged in."; fi
fi

# 10. Claude Code (native installer, no Node needed)
if [ -z "${BV_SKIP_CLAUDE:-}" ]; then
  have claude || [ -x "$HOME/.local/bin/claude" ] || { curl -fsSL https://claude.ai/install.sh | bash || die "Claude Code install failed."; }
  ok "Claude Code"
  # shellcheck disable=SC2016
  case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) grep -qF '.local/bin' "$HOME/.zprofile" 2>/dev/null || echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$HOME/.zprofile";; esac
fi

# 11. the double-click launcher (written locally by curl's shell => no Gatekeeper quarantine)
desk="$HOME/Desktop"; [ -d "$desk" ] || desk="$BV_HOME"
cp "$BV_HOME/mac/Start BrettVision.command" "$desk/Start BrettVision.command"
chmod +x "$desk/Start BrettVision.command"; xattr -d com.apple.quarantine "$desk/Start BrettVision.command" 2>/dev/null || true
ok "launcher: $desk/Start BrettVision.command"

# 12. wait for Clause to check in
if [ -z "${BV_SKIP_WAIT:-}" ] && [ -z "${BV_SKIP_TAILSCALE:-}" ]; then
  say "Waiting up to 2 minutes for Clause to connect..."
  for _ in $(seq 1 40); do [ -e "$BV_HOME/data/clause-connected" ] && break; sleep 3; done
fi
say ""
if [ -e "$BV_HOME/data/clause-connected" ]; then
  say "${G}Clause is connected.${N}"
fi
say "${G}DONE.${N} Next: double-click \"Start BrettVision\" on the Desktop."
