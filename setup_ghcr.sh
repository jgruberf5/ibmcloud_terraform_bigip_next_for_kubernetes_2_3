#!/usr/bin/env bash
# ============================================================
# setup_ghcr.sh — one-time GHCR + repo setup for the release pipeline.
#
# Configures everything the release workflow needs to build, push to
# ghcr.io, and commit a README update without further manual steps:
#
#   1. Verifies `gh` is installed and authenticated.
#   2. Sets the repo's default workflow permissions to "write" so
#      bump-install-url can commit README changes back.
#   3. Once the container package exists (i.e. after the first
#      release builds and pushes it), flips the package to public
#      visibility so anyone can `docker pull` anonymously.
#
# Idempotent — re-run any time. Run once before the first release,
# then again afterwards to flip the package public.
#
# Requires: gh (https://cli.github.com), git, an authenticated gh
# session against the repo's owner.
# ============================================================
set -euo pipefail

IMAGE_NAME="${IMAGE_NAME:-ibmcloud-terraform-bnk-2-3}"

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

confirm() {
    # Default Yes; honour [y/N] semantics if user types n/N. When stdin
    # isn't a tty (e.g. piped input), default through without prompting.
    local prompt=$1
    if [[ ! -t 0 ]]; then return 0; fi
    printf "  %s [Y/n]: " "$prompt"
    local ans; read -r ans
    [[ ! "$ans" =~ ^[Nn] ]]
}

# ── gh CLI ──────────────────────────────────────────────────
section "Checking gh CLI"
if ! command -v gh >/dev/null 2>&1; then
    fail "gh not installed"
    hint "https://cli.github.com/"
    exit 1
fi
ok "gh ($(gh --version | head -1 | awk '{print $3}'))"

if ! gh auth status >/dev/null 2>&1; then
    fail "gh is not authenticated"
    hint "run: gh auth login"
    exit 1
fi
authed_user=$(gh api /user --jq .login)
ok "authenticated as $authed_user"

# Required scopes for what this script does. token may be classic PAT or
# fine-grained — gh maintains either, we only need the access at run time.
required_scopes="repo workflow write:packages"
have_scopes=$(gh auth status 2>&1 | grep -oE "Token scopes: .*" || true)
for s in $required_scopes; do
    if [[ "$have_scopes" != *"'${s}'"* ]] && [[ "$have_scopes" != *"$s"* ]]; then
        warn "token may be missing scope: $s"
        hint "if a later step fails with 403, run: gh auth refresh -s $s"
    fi
done

# ── detect repo ─────────────────────────────────────────────
section "Repository"
if ! gh repo view --json owner,name >/dev/null 2>&1; then
    fail "not in a github-tracked repo"
    hint "cd to your clone of the project, then re-run"
    exit 1
fi
repo_owner=$(gh repo view --json owner --jq .owner.login)
repo_name=$(gh repo view --json name --jq .name)
ok "$repo_owner/$repo_name"

if gh api "/orgs/$repo_owner" >/dev/null 2>&1; then
    owner_type=Organization
else
    owner_type=User
fi
ok "owner type: $owner_type"

# ── workflow permissions ────────────────────────────────────
section "Repo workflow permissions"
perms=$(gh api "/repos/$repo_owner/$repo_name/actions/permissions/workflow" \
        --jq .default_workflow_permissions 2>/dev/null) || perms=""
if [[ "$perms" == "write" ]]; then
    ok "default_workflow_permissions = write"
else
    warn "default_workflow_permissions = ${perms:-unknown}"
    hint "the bump-install-url job needs 'write' to push README updates"
    if confirm "Set to 'write' now?"; then
        gh api -X PUT "/repos/$repo_owner/$repo_name/actions/permissions/workflow" \
            -f default_workflow_permissions=write \
            -F can_approve_pull_request_reviews=false >/dev/null
        ok "set to 'write'"
    fi
fi

# ── package status ──────────────────────────────────────────
section "Container package: ghcr.io/$repo_owner/$IMAGE_NAME"
if [[ "$owner_type" == "Organization" ]]; then
    pkg_path="/orgs/$repo_owner/packages/container/$IMAGE_NAME"
    vis_path="/orgs/$repo_owner/packages/container/$IMAGE_NAME/visibility"
else
    # GHCR's user-package-by-name read endpoint is /users/{user}/...,
    # but the writeable endpoint for the authenticated user is /user/...
    pkg_path="/users/$repo_owner/packages/container/$IMAGE_NAME"
    vis_path="/user/packages/container/$IMAGE_NAME/visibility"
    if [[ "$authed_user" != "$repo_owner" ]]; then
        warn "authenticated as $authed_user but repo owner is $repo_owner"
        hint "user-package visibility can only be set by the package owner"
    fi
fi

if visibility=$(gh api "$pkg_path" --jq .visibility 2>/dev/null); then
    case "$visibility" in
        public)
            ok "package exists, visibility = public"
            ;;
        private|internal)
            warn "package exists, visibility = $visibility"
            hint "anonymous bnk users will need 'docker login ghcr.io' to pull"
            if confirm "Flip to public now?"; then
                gh api -X PATCH "$vis_path" -f visibility=public >/dev/null
                ok "package made public"
            fi
            ;;
        *)
            warn "package exists, visibility = ${visibility:-unknown}"
            ;;
    esac
else
    warn "package does not yet exist on ghcr.io"
    hint "publish a release — release.yml will build and push it"
    hint "then re-run this script to flip visibility to public"
fi

# ── workflow file presence ──────────────────────────────────
section "Release workflow"
if [[ -f .github/workflows/release.yml ]]; then
    ok ".github/workflows/release.yml present"
else
    fail ".github/workflows/release.yml missing — releases won't trigger anything"
    exit 1
fi

# ── done ────────────────────────────────────────────────────
section "Next steps"
echo "  1. If you haven't yet: commit and push these files."
echo "  2. Create a release:"
echo "     gh release create v2.3.0 --title v2.3.0 --notes 'Initial release'"
echo "  3. Watch the workflow:"
echo "     gh run watch"
echo "  4. After the first successful release, re-run ./setup_ghcr.sh to"
echo "     flip the new package to public visibility."
echo
