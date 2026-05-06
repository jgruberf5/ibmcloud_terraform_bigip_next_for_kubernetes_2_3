#!/usr/bin/env bash
# ============================================================
# install.sh — installer for bnk (the IBM Cloud Terraform BIG-IP
# Next for Kubernetes runner).
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/jgruberf5/ibmcloud_terraform_bigip_next_for_kubernetes_2_3/main/install.sh | bash
#
# Overrides via environment:
#   INSTALL_DIR    target dir (default: $HOME/.local/bin)
#   BNK_VERSION    release tag to install (default: latest from GitHub
#                  API, falling back to "main")
#   REPO_OWNER     GitHub owner (default: jgruberf5)
#   REPO_NAME      GitHub repo  (default: ibmcloud_terraform_bigip_next_for_kubernetes_2_3)
#
# Dependency checks happen before any download. Re-run after fixing
# any failures.
# ============================================================
set -euo pipefail

REPO_OWNER="${REPO_OWNER:-jgruberf5}"
REPO_NAME="${REPO_NAME:-ibmcloud_terraform_bigip_next_for_kubernetes_2_3}"
INSTALL_DIR="${INSTALL_DIR:-$HOME/.local/bin}"
BNK_VERSION="${BNK_VERSION:-}"

# ── tty / color ─────────────────────────────────────────────
if [[ -t 1 ]]; then
    OK=$'\e[32m'; FAIL=$'\e[31m'; WARN=$'\e[33m'
    DIM=$'\e[90m'; BOLD=$'\e[1m'; OFF=$'\e[0m'
    SOK="✓"; SFAIL="✗"; SWARN="!"
else
    OK=""; FAIL=""; WARN=""; DIM=""; BOLD=""; OFF=""
    SOK="OK"; SFAIL="FAIL"; SWARN="WARN"
fi
ok()      { printf "  %s%s%s %s\n"  "$OK"   "$SOK"   "$OFF" "$*"; }
fail()    { printf "  %s%s%s %s\n"  "$FAIL" "$SFAIL" "$OFF" "$*"; }
warn()    { printf "  %s%s%s %s\n"  "$WARN" "$SWARN" "$OFF" "$*"; }
hint()    { printf "    %s↳ %s%s\n" "$DIM"  "$*" "$OFF"; }
section() { printf "\n%s%s%s\n"     "$BOLD" "$*" "$OFF"; }

# ── dependency checks ───────────────────────────────────────
section "Checking dependencies"
errors=0
note_error() { errors=$((errors+1)); }

# bash 3.2+
if [[ -z "${BASH_VERSINFO[0]:-}" ]] || (( BASH_VERSINFO[0] < 3 )) \
   || { (( BASH_VERSINFO[0] == 3 )) && (( BASH_VERSINFO[1] < 2 )); }; then
    fail "bash 3.2+ required (found ${BASH_VERSION:-none})"
    note_error
else
    ok "bash ${BASH_VERSION%%(*}"
fi

require() {
    local cmd=$1 hint_text=${2:-}
    if command -v "$cmd" >/dev/null 2>&1; then
        ok "$cmd"
    else
        fail "$cmd not found"
        [[ -n "$hint_text" ]] && hint "$hint_text"
        note_error
    fi
}

require docker  "install Docker Desktop or docker-ce"
require curl    "install curl via your package manager"
require awk
require tr
require date
require chmod
require mkdir
require head

if (( errors > 0 )); then
    fail "$errors dependency check(s) failed — install missing tools and re-run"
    exit 1
fi

# Docker daemon — only check if docker passed the existence test above.
if docker info >/dev/null 2>&1; then
    ok "docker daemon reachable"
else
    fail "docker daemon unreachable"
    hint "start Docker (or 'sudo systemctl start docker'), then re-run"
    exit 1
fi

# ── target dir ──────────────────────────────────────────────
section "Target directory"
mkdir -p "$INSTALL_DIR"
if [[ ! -w "$INSTALL_DIR" ]]; then
    fail "$INSTALL_DIR is not writable"
    hint "set INSTALL_DIR to a writable location, e.g.: INSTALL_DIR=\$HOME/bin"
    exit 1
fi
ok "$INSTALL_DIR ready"

# ── resolve release tag ─────────────────────────────────────
# Pinned via BNK_VERSION env, otherwise ask the GitHub API for the
# latest release, otherwise fall back to main. Plain grep + cut so
# this stays jq-free.
section "Resolving release tag"
if [[ -n "$BNK_VERSION" ]]; then
    RELEASE_TAG="$BNK_VERSION"
    ok "using BNK_VERSION=$RELEASE_TAG"
else
    api="https://api.github.com/repos/${REPO_OWNER}/${REPO_NAME}/releases/latest"
    if RELEASE_TAG=$(curl -fsSL "$api" 2>/dev/null \
            | grep -oE '"tag_name"[[:space:]]*:[[:space:]]*"[^"]+"' \
            | head -1 | cut -d'"' -f4) && [[ -n "$RELEASE_TAG" ]]; then
        ok "latest release: $RELEASE_TAG"
    else
        RELEASE_TAG=main
        warn "no published release found — falling back to '$RELEASE_TAG'"
    fi
fi

# ── download ────────────────────────────────────────────────
section "Downloading bnk (${RELEASE_TAG})"
url="https://raw.githubusercontent.com/${REPO_OWNER}/${REPO_NAME}/${RELEASE_TAG}/bnk"
target="$INSTALL_DIR/bnk"
tmp=$(mktemp 2>/dev/null || mktemp -t bnk-install)
trap 'rm -f "$tmp"' EXIT

if curl -fsSL "$url" -o "$tmp"; then
    ok "fetched $url"
else
    fail "download failed: $url"
    hint "verify tag '$RELEASE_TAG' exists and the repo is public"
    exit 1
fi

# Sanity check — first line must be a bash shebang. Catches the
# common case where a 404 lands as HTML and would otherwise be
# 'installed' as a broken executable.
first_line=$(head -1 "$tmp")
if [[ "$first_line" != "#!/usr/bin/env bash" && "$first_line" != "#!/bin/bash" ]]; then
    fail "downloaded file does not look like bnk"
    hint "first line was: $first_line"
    exit 1
fi
ok "downloaded file looks like a bash script"

mv "$tmp" "$target"
chmod +x "$target"
ok "installed to $target"

# ── PATH check ──────────────────────────────────────────────
section "PATH"
case ":$PATH:" in
    *":$INSTALL_DIR:"*)
        ok "$INSTALL_DIR is on your PATH" ;;
    *)
        warn "$INSTALL_DIR is NOT on your PATH"
        hint "add this to ~/.bashrc or ~/.zshrc, then reload your shell:"
        hint "    export PATH=\"$INSTALL_DIR:\$PATH\""
        ;;
esac

# ── done ────────────────────────────────────────────────────
section "Next steps"
printf "  %sbnk doctor%s    sanity-check the runtime environment\n" "$BOLD" "$OFF"
printf "  %sbnk init%s      create terraform.tfvars in your project dir\n" "$BOLD" "$OFF"
printf "  %sbnk plan%s      plan the deployment\n" "$BOLD" "$OFF"
echo
