#!/usr/bin/env bash
# ============================================================
# run_tests.sh — F5 BIG-IP Next for Kubernetes 2.3
#               Terraform direct-run test suite
#
# Runs init / plan / apply / destroy for four scenarios and
# reports PASS / FAIL per phase.  Each scenario uses an isolated
# .terraform directory and state file; the project source tree
# is never modified.
#
# Scenarios:
#   1  full
#        create_roks_cluster=true   create_roks_transit_gateway=true
#        install_cert_manager=true  deploy_bnk=true
#
#   2  existing-cluster-create-tgw
#        create_roks_cluster=false  create_roks_transit_gateway=true
#        install_cert_manager=true  deploy_bnk=true
#
#   3  existing-cluster-existing-tgw
#        create_roks_cluster=false  create_roks_transit_gateway=false
#        install_cert_manager=true  deploy_bnk=true
#
#   4  existing-cluster-create-tgw-existing-cert-manager
#        create_roks_cluster=false  create_roks_transit_gateway=true
#        install_cert_manager=false deploy_bnk=true
#
# Scenarios 2–4 share a prereqs workspace that provisions the
# ROKS cluster, Transit Gateway, and cert-manager once before
# those tests run and tears them down after all three complete.
#
# Usage:
#   ./run_tests.sh [OPTIONS] [TESTS...]
#
# TESTS (one or more; default: all):
#   1 | full
#   2 | existing-cluster-create-tgw
#   3 | existing-cluster-existing-tgw
#   4 | existing-cluster-create-tgw-existing-cert-manager
#   all
#
# OPTIONS:
#   --no-destroy     Skip all destroy phases (leave resources up)
#   --run-dir DIR    Override test-run output directory
#   --cleanup DIR    Destroy all leftover state in a prior run directory
#                    (use after a crash or SIGKILL that bypassed emergency_cleanup)
#   -h, --help
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# WORK_DIR is the user's writable workspace — where their
# terraform.tfvars lives and where test-runs/ should land. When this
# script is invoked via `bnk infra test`, SCRIPT_DIR is /opt/tf-project
# (in the runner image, read-only) and the cwd is /work (host
# bind-mount). When invoked directly from a checkout, both match.
WORK_DIR="$(pwd)"
BASE_TFVARS="$WORK_DIR/terraform.tfvars"
RUN_TS=$(date -u +%Y%m%d_%H%M%S)
DIVIDER='══════════════════════════════════════════════════════════════'

# ── Arg parsing ─────────────────────────────────────────────
SKIP_DESTROY=false
RUN_DIR=""
CLEANUP_DIR=""
SELECTED_IDS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-destroy)   SKIP_DESTROY=true ;;
        --run-dir)      shift; RUN_DIR="$1" ;;
        --run-dir=*)    RUN_DIR="${1#*=}" ;;
        --cleanup)      shift; CLEANUP_DIR="$1" ;;
        --cleanup=*)    CLEANUP_DIR="${1#*=}" ;;
        -h|--help)      sed -n '2,/^[^#]/{/^#/!q; s/^# \{0,2\}//p}' "$0"; exit 0 ;;
        all)            SELECTED_IDS=(1 2 3 4) ;;
        1|full)                                               SELECTED_IDS+=(1) ;;
        2|existing-cluster-create-tgw)                       SELECTED_IDS+=(2) ;;
        3|existing-cluster-existing-tgw)                     SELECTED_IDS+=(3) ;;
        4|existing-cluster-create-tgw-existing-cert-manager) SELECTED_IDS+=(4) ;;
        *) printf 'Unknown argument: %s\n' "$1" >&2; exit 1 ;;
    esac
    shift
done
[[ ${#SELECTED_IDS[@]} -eq 0 ]] && SELECTED_IDS=(1 2 3 4)

# De-duplicate preserving order
declare -A _SEEN; DEDUPED=()
for _x in "${SELECTED_IDS[@]}"; do
    [[ -z "${_SEEN[$_x]:-}" ]] && DEDUPED+=("$_x") && _SEEN[$_x]=1
done
SELECTED_IDS=("${DEDUPED[@]}"); unset _SEEN _x DEDUPED

# ── Run directory ────────────────────────────────────────────
[[ -z "$RUN_DIR" ]] && RUN_DIR="$WORK_DIR/test-runs/$RUN_TS"
mkdir -p "$RUN_DIR"
SUMMARY_LOG="$RUN_DIR/summary.log"

# Share provider cache across all scenario inits to avoid re-downloading
export TF_PLUGIN_CACHE_DIR="$SCRIPT_DIR/.terraform-provider-cache"
mkdir -p "$TF_PLUGIN_CACHE_DIR"

# ── Result store ─────────────────────────────────────────────
declare -A RESULTS   # "$id:phase" → PASS | FAIL | SKIP | —

# ── Pending-destroy tracker ───────────────────────────────────
# Each entry is "dir|tfvars_filename" written just before phase_apply and
# removed after a successful phase_destroy.  emergency_cleanup processes
# anything still present on EXIT (covers Ctrl+C, set -e bail-outs, etc.).
PENDING_DESTROY_FILE=$(mktemp)

register_pending_destroy()   { echo "$1|$2" >> "$PENDING_DESTROY_FILE"; }

unregister_pending_destroy() {
    local tmp; tmp=$(mktemp)
    grep -vxF "$1|$2" "$PENDING_DESTROY_FILE" > "$tmp" 2>/dev/null || true
    mv "$tmp" "$PENDING_DESTROY_FILE"
}

emergency_cleanup() {
    [[ "$SKIP_DESTROY" == true ]] && return
    [[ ! -s "$PENDING_DESTROY_FILE" ]] && return
    tslog ""
    tslog "!! Emergency cleanup: destroying remaining active states..."
    while IFS='|' read -r _dir _tfvars; do
        [[ -f "$_dir/terraform.tfstate" ]] || continue
        tslog "   $(basename "$_dir")"
        if phase_destroy "$_dir" "$_tfvars"; then
            tslog "   PASS"
            unregister_pending_destroy "$_dir" "$_tfvars"
        else
            tslog "   FAIL — MANUAL CLEANUP REQUIRED"
            tslog "     terraform -chdir=$SCRIPT_DIR destroy \\"
            tslog "       -var-file=$_dir/$_tfvars -state=$_dir/terraform.tfstate"
        fi
    done < "$PENDING_DESTROY_FILE"
}

# ── Scenario properties ──────────────────────────────────────
scenario_label() {
    case $1 in
        1) echo "full" ;;
        2) echo "existing-cluster-create-tgw" ;;
        3) echo "existing-cluster-existing-tgw" ;;
        4) echo "existing-cluster-create-tgw-existing-cert-manager" ;;
    esac
}

scenario_tfvars_file() {
    case $1 in
        1) echo "terraform_full.tfvars" ;;
        2) echo "terraform_existing_cluster_create_tgw.tfvars" ;;
        3) echo "terraform_existing_cluster_existing_tgw.tfvars" ;;
        4) echo "terraform_existing_cluster_create_tgw_existing_cert_manager.tfvars" ;;
    esac
}

# ── tfvars generator ─────────────────────────────────────────
# gen_tfvars BASE_FILE OUT_FILE KEY=VALUE [KEY=VALUE ...]
# Copies BASE_FILE to OUT_FILE, replacing existing keys in-place
# and appending any keys not found in BASE_FILE.
gen_tfvars() {
    local base="$1" out="$2"; shift 2
    python3 - "$base" "$out" "$@" << 'PY'
import sys, re

base, out = sys.argv[1], sys.argv[2]
overrides = {}
for kv in sys.argv[3:]:
    k, _, v = kv.partition('=')
    overrides[k] = v

def fmt(key, val):
    if val.lower() in ('true', 'false') or re.fullmatch(r'-?\d+', val):
        return f'{key} = {val}\n'
    return f'{key} = "{val}"\n'

with open(base) as f:
    lines = f.readlines()

output = []
seen = set()
for line in lines:
    m = re.match(r'^(\w+)\s*=', line)
    if m and m.group(1) in overrides:
        key = m.group(1)
        output.append(fmt(key, overrides[key]))
        seen.add(key)
    else:
        output.append(line)
for k, v in overrides.items():
    if k not in seen:
        output.append(fmt(k, v))
with open(out, 'w') as f:
    f.writelines(output)
PY
}

# ── Single-value tfvars reader ───────────────────────────────
# get_tfvar KEY FILE  →  prints the value (unquoted), or empty on miss
get_tfvar() {
    python3 - "$2" "$1" << 'PY'
import re, sys
with open(sys.argv[1]) as f:
    for line in f:
        m = re.match(r'^' + re.escape(sys.argv[2]) + r'\s*=\s*"?([^"#\n]+)"?', line)
        if m:
            print(m.group(1).strip().strip('"'))
            break
PY
}

# ── Scenario directory ───────────────────────────────────────
make_scenario_dir() {
    mkdir -p "$1"
}

# ── Logging ──────────────────────────────────────────────────
ts()    { date -u +%H:%M:%S; }
tlog()  { printf '%s\n'       "$*"          | tee -a "$SUMMARY_LOG"; }
tslog() { printf '[%s]  %s\n' "$(ts)" "$*"  | tee -a "$SUMMARY_LOG"; }

# ── Terraform runner ─────────────────────────────────────────
# tf_run SCENARIO_DIR TERRAFORM_ARGS...
# Runs terraform from the project root with the scenario's isolated
# .terraform directory.  Use absolute paths for -var-file / -state.
tf_run() {
    local dir="$1"; shift
    TF_DATA_DIR="$dir/.terraform" \
    terraform -chdir="$SCRIPT_DIR" "$@"
}

# ── Phase runners ─────────────────────────────────────────────

phase_init() {
    local dir="$1"
    local log="$dir/phase-init.log"
    tf_run "$dir" init \
        -input=false -no-color \
        >> "$log" 2>&1
}

phase_plan() {
    local dir="$1"
    local tfvars="$dir/$2"
    local log="$dir/phase-plan.log"
    tf_run "$dir" plan \
        -input=false -no-color \
        -var-file="$tfvars" \
        -state="$dir/terraform.tfstate" \
        >> "$log" 2>&1
}

phase_apply() {
    local dir="$1"
    local tfvars="$dir/$2"
    local log="$dir/phase-apply.log"
    tf_run "$dir" apply \
        -auto-approve -input=false -no-color \
        -var-file="$tfvars" \
        -state="$dir/terraform.tfstate" \
        >> "$log" 2>&1
}

phase_destroy() {
    local dir="$1"
    local tfvars="$dir/$2"
    local log="$dir/phase-destroy.log"
    tf_run "$dir" destroy \
        -auto-approve -input=false -no-color \
        -var-file="$tfvars" \
        -state="$dir/terraform.tfstate" \
        >> "$log" 2>&1
}

# ── Single test ──────────────────────────────────────────────
run_test() {
    local id="$1" dir="$2" tfvars="$3"
    local label; label=$(scenario_label "$id")
    local start elapsed mins secs

    RESULTS["$id:plan"]="—"
    RESULTS["$id:apply"]="—"
    RESULTS["$id:destroy"]="—"

    # INIT ────────────────────────────────────────────────────
    tslog "INIT   $label"
    start=$(date +%s)
    if phase_init "$dir"; then
        elapsed=$(( $(date +%s) - start ))
        mins=$(( elapsed/60 )) secs=$(( elapsed%60 ))
        tslog "DONE   $label / INIT  (${mins}m${secs}s)"
    else
        elapsed=$(( $(date +%s) - start ))
        mins=$(( elapsed/60 )) secs=$(( elapsed%60 ))
        RESULTS["$id:plan"]="SKIP"
        RESULTS["$id:apply"]="SKIP"
        RESULTS["$id:destroy"]="SKIP"
        tslog "FAIL   $label / INIT  (${mins}m${secs}s)  →  $dir/phase-init.log"
        return
    fi

    # PLAN ────────────────────────────────────────────────────
    tslog "TEST   $label / PLAN"
    start=$(date +%s)
    if phase_plan "$dir" "$tfvars"; then
        elapsed=$(( $(date +%s) - start ))
        mins=$(( elapsed/60 )) secs=$(( elapsed%60 ))
        RESULTS["$id:plan"]="PASS"
        tslog "PASS   $label / PLAN  (${mins}m${secs}s)"
    else
        elapsed=$(( $(date +%s) - start ))
        mins=$(( elapsed/60 )) secs=$(( elapsed%60 ))
        RESULTS["$id:plan"]="FAIL"
        RESULTS["$id:apply"]="SKIP"
        RESULTS["$id:destroy"]="SKIP"
        tslog "FAIL   $label / PLAN  (${mins}m${secs}s)  →  $dir/phase-plan.log"
        return
    fi

    # APPLY ───────────────────────────────────────────────────
    register_pending_destroy "$dir" "$tfvars"
    tslog "TEST   $label / APPLY"
    start=$(date +%s)
    if phase_apply "$dir" "$tfvars"; then
        elapsed=$(( $(date +%s) - start ))
        mins=$(( elapsed/60 )) secs=$(( elapsed%60 ))
        RESULTS["$id:apply"]="PASS"
        tslog "PASS   $label / APPLY  (${mins}m${secs}s)"
    else
        elapsed=$(( $(date +%s) - start ))
        mins=$(( elapsed/60 )) secs=$(( elapsed%60 ))
        RESULTS["$id:apply"]="FAIL"
        tslog "FAIL   $label / APPLY  (${mins}m${secs}s)  →  $dir/phase-apply.log"
        # Attempt cleanup even after a partial apply
        if [[ "$SKIP_DESTROY" == false ]]; then
            tslog "TEST   $label / DESTROY (cleanup after failed apply)"
            start=$(date +%s)
            if phase_destroy "$dir" "$tfvars"; then
                elapsed=$(( $(date +%s) - start ))
                mins=$(( elapsed/60 )) secs=$(( elapsed%60 ))
                RESULTS["$id:destroy"]="PASS"
                unregister_pending_destroy "$dir" "$tfvars"
                tslog "PASS   $label / DESTROY  (${mins}m${secs}s)"
            else
                elapsed=$(( $(date +%s) - start ))
                mins=$(( elapsed/60 )) secs=$(( elapsed%60 ))
                RESULTS["$id:destroy"]="FAIL"
                tslog "FAIL   $label / DESTROY  (${mins}m${secs}s)  →  $dir/phase-destroy.log"
                tslog "  !! MANUAL CLEANUP MAY BE REQUIRED"
            fi
        else
            RESULTS["$id:destroy"]="SKIP"
        fi
        return
    fi

    # DESTROY ─────────────────────────────────────────────────
    if [[ "$SKIP_DESTROY" == true ]]; then
        RESULTS["$id:destroy"]="SKIP"
        tslog "SKIP   $label / DESTROY  (--no-destroy)"
        return
    fi

    tslog "TEST   $label / DESTROY"
    start=$(date +%s)
    if phase_destroy "$dir" "$tfvars"; then
        elapsed=$(( $(date +%s) - start ))
        mins=$(( elapsed/60 )) secs=$(( elapsed%60 ))
        RESULTS["$id:destroy"]="PASS"
        unregister_pending_destroy "$dir" "$tfvars"
        tslog "PASS   $label / DESTROY  (${mins}m${secs}s)"
    else
        elapsed=$(( $(date +%s) - start ))
        mins=$(( elapsed/60 )) secs=$(( elapsed%60 ))
        RESULTS["$id:destroy"]="FAIL"
        tslog "FAIL   $label / DESTROY  (${mins}m${secs}s)  →  $dir/phase-destroy.log"
        tslog "  !! MANUAL CLEANUP MAY BE REQUIRED"
    fi
}

# ── Shared prerequisites (for scenarios 2 / 3 / 4) ──────────
# Creates ROKS cluster + Transit Gateway + cert-manager once.
# deploy_bnk=false so FLO/CNEInstance/License are skipped.
PREREQS_DIR="$RUN_DIR/prereqs"
PREREQS_TFVARS="terraform_prereqs.tfvars"

run_prereqs_setup() {
    local cluster_name="$1" vpc_name="$2" cos_name="$3" tgw_name="$4"
    tslog "SETUP  shared prerequisites (cluster + TGW + cert-manager) for scenarios 2/3/4"
    tslog "       cluster=${cluster_name}  tgw=${tgw_name}"
    make_scenario_dir "$PREREQS_DIR"

    gen_tfvars "$BASE_TFVARS" "$PREREQS_DIR/$PREREQS_TFVARS" \
        "openshift_cluster_name=${cluster_name}"                      \
        "roks_cluster_vpc_name=${vpc_name}"                           \
        "roks_cos_instance_name=${cos_name}"                          \
        "roks_transit_gateway_name=${tgw_name}"                       \
        "cneinstance_gslb_datacenter_name=${cluster_name}-dc"         \
        "create_roks_cluster=true"                                    \
        "create_roks_transit_gateway=true"                            \
        "create_roks_registry_cos_instance=true"                      \
        "install_cert_manager=true"                                   \
        "deploy_bnk=false"                                            \
        "testing_create_tgw_jumphost=false"                           \
        "testing_create_cluster_jumphosts=false"

    local start elapsed mins secs

    # init
    tslog "INIT   prereqs"
    start=$(date +%s)
    if tf_run "$PREREQS_DIR" init \
            -input=false -no-color \
            >> "$PREREQS_DIR/phase-setup.log" 2>&1; then
        elapsed=$(( $(date +%s) - start ))
        mins=$(( elapsed/60 )) secs=$(( elapsed%60 ))
        tslog "DONE   prereqs / INIT  (${mins}m${secs}s)"
    else
        elapsed=$(( $(date +%s) - start ))
        mins=$(( elapsed/60 )) secs=$(( elapsed%60 ))
        tslog "FAIL   prereqs / INIT  (${mins}m${secs}s)  →  $PREREQS_DIR/phase-setup.log"
        return 1
    fi

    # apply
    register_pending_destroy "$PREREQS_DIR" "$PREREQS_TFVARS"
    tslog "TEST   prereqs / APPLY"
    start=$(date +%s)
    if tf_run "$PREREQS_DIR" apply \
            -auto-approve -input=false -no-color \
            -var-file="$PREREQS_DIR/$PREREQS_TFVARS" \
            -state="$PREREQS_DIR/terraform.tfstate" \
            >> "$PREREQS_DIR/phase-setup.log" 2>&1; then
        elapsed=$(( $(date +%s) - start ))
        mins=$(( elapsed/60 )) secs=$(( elapsed%60 ))
        tslog "READY  shared prerequisites  (${mins}m${secs}s)"
        return 0
    else
        elapsed=$(( $(date +%s) - start ))
        mins=$(( elapsed/60 )) secs=$(( elapsed%60 ))
        tslog "FAIL   shared prerequisites setup  (${mins}m${secs}s)  →  $PREREQS_DIR/phase-setup.log"
        return 1
    fi
}

run_prereqs_teardown() {
    if [[ "$SKIP_DESTROY" == true ]]; then
        tslog "SKIP   shared prerequisites teardown  (--no-destroy)"
        return
    fi
    tslog "TEARDOWN  shared prerequisites"
    local start elapsed mins secs
    start=$(date +%s)
    if tf_run "$PREREQS_DIR" destroy \
            -auto-approve -input=false -no-color \
            -var-file="$PREREQS_DIR/$PREREQS_TFVARS" \
            -state="$PREREQS_DIR/terraform.tfstate" \
            >> "$PREREQS_DIR/phase-teardown.log" 2>&1; then
        elapsed=$(( $(date +%s) - start ))
        mins=$(( elapsed/60 )) secs=$(( elapsed%60 ))
        unregister_pending_destroy "$PREREQS_DIR" "$PREREQS_TFVARS"
        tslog "PASS   shared prerequisites teardown  (${mins}m${secs}s)"
    else
        elapsed=$(( $(date +%s) - start ))
        mins=$(( elapsed/60 )) secs=$(( elapsed%60 ))
        tslog "FAIL   shared prerequisites teardown  (${mins}m${secs}s)  →  $PREREQS_DIR/phase-teardown.log"
        tslog "  !! MANUAL CLEANUP REQUIRED"
    fi
}

# ── Summary ──────────────────────────────────────────────────
print_summary() {
    local total=0 passed=0
    tlog ""
    tlog "$DIVIDER"
    tlog "SUMMARY"
    tlog "$DIVIDER"
    tlog "$(printf '  %-50s  %-6s  %-6s  %-7s' 'SCENARIO' 'PLAN' 'APPLY' 'DESTROY')"
    tlog "$(printf '  %-50s  %-6s  %-6s  %-7s' \
        '────────────────────────────────────────────────────' '──────' '──────' '───────')"

    for id in 1 2 3 4; do
        local is_selected=false
        for s in "${SELECTED_IDS[@]}"; do [[ $s == "$id" ]] && is_selected=true && break; done
        [[ $is_selected == false ]] && continue

        local label plan apply destroy
        label=$(scenario_label "$id")
        plan="${RESULTS[$id:plan]:-—}"
        apply="${RESULTS[$id:apply]:-—}"
        destroy="${RESULTS[$id:destroy]:-—}"
        tlog "$(printf '  %-50s  %-6s  %-6s  %-7s' "$label" "$plan" "$apply" "$destroy")"

        (( total++ )) || true
        if [[ "$plan" == "PASS" && "$apply" == "PASS" \
              && ( "$destroy" == "PASS" || "$destroy" == "SKIP" ) ]]; then
            (( passed++ )) || true
        fi
    done

    tlog "$DIVIDER"
    tlog ""
    tlog "Result: $passed / $total scenarios fully passed"
    tlog "Logs:   $RUN_DIR"
    tlog ""
}

# ── Cleanup mode ─────────────────────────────────────────────
# Scans a prior run directory for non-empty state files and destroys each.
# Runs terraform init first when the .terraform directory is absent (e.g. after
# the working directory was wiped or the run was interrupted before init finished).
run_cleanup() {
    local target_dir="$1"
    [[ -d "$target_dir" ]] || { tslog "FATAL: cleanup dir not found: $target_dir"; exit 1; }
    target_dir="$(cd "$target_dir" && pwd)"

    tlog "$DIVIDER"
    tlog "  Cleanup: $target_dir"
    tlog "$DIVIDER"
    tlog ""

    local found=0 destroyed=0 failed=0

    while IFS= read -r statefile; do
        local dir; dir=$(dirname "$statefile")

        # Skip state files with no resources
        local resource_count
        resource_count=$(python3 - "$statefile" << 'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    print(len(d.get("resources", [])))
except Exception:
    print(0)
PY
)
        [[ "$resource_count" -gt 0 ]] || continue

        # Require a .tfvars file alongside the state
        local tfvars_path tfvars_file
        tfvars_path=$(ls "$dir"/*.tfvars 2>/dev/null | head -1) || true
        if [[ -z "$tfvars_path" ]]; then
            tslog "  SKIP  $(basename "$dir") — no .tfvars file (state has $resource_count resources)"
            tslog "        manual: TF_DATA_DIR=$dir/.terraform terraform -chdir=$SCRIPT_DIR destroy \\"
            tslog "                  -state=$statefile"
            continue
        fi
        tfvars_file=$(basename "$tfvars_path")
        (( found++ )) || true

        # Init if providers aren't cached locally for this scenario
        if [[ ! -d "$dir/.terraform" ]]; then
            tslog "  INIT  $(basename "$dir")"
            if ! phase_init "$dir" ; then
                tslog "  FAIL  $(basename "$dir") / INIT — skipping destroy"
                tslog "        check $dir/phase-init.log"
                (( failed++ )) || true
                continue
            fi
        fi

        tslog "  DESTROY  $(basename "$dir")  ($resource_count resources)"
        if phase_destroy "$dir" "$tfvars_file"; then
            (( destroyed++ )) || true
            tslog "  PASS  $(basename "$dir")"
        else
            (( failed++ )) || true
            tslog "  FAIL  $(basename "$dir") — MANUAL CLEANUP REQUIRED"
            tslog "        check $dir/phase-destroy.log"
            tslog "        manual: TF_DATA_DIR=$dir/.terraform terraform -chdir=$SCRIPT_DIR destroy \\"
            tslog "                  -var-file=$dir/$tfvars_file -state=$statefile"
        fi
    done < <(find "$target_dir" -name "terraform.tfstate" -not -empty | sort)

    tlog ""
    if [[ $found -eq 0 ]]; then
        tlog "  No active state files found in $target_dir"
    else
        tlog "  Result: $destroyed destroyed, $failed failed  (found $found)"
    fi
    tlog ""
    [[ $failed -eq 0 ]]
}

# ── Main ─────────────────────────────────────────────────────
main() {
    # Run emergency_cleanup on any exit — normal, set -e bail-out, or signal.
    # INT/TERM convert to exit 130/143 so the EXIT trap fires once.
    trap 'emergency_cleanup; rm -f "$PENDING_DESTROY_FILE"' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM

    tlog "$DIVIDER"
    tlog "  F5 BIG-IP Next for Kubernetes 2.3 — Terraform Test Suite"
    tlog "  Run timestamp : $RUN_TS"
    tlog "  Run directory : $RUN_DIR"
    tlog "  Tests         : ${SELECTED_IDS[*]}"
    tlog "  Skip destroy  : $SKIP_DESTROY"
    tlog "$DIVIDER"
    tlog ""

    [[ -f "$BASE_TFVARS" ]] || { tslog "FATAL: $BASE_TFVARS not found"; exit 1; }

    # ── Derive unique resource names from base tfvars ─────────
    # Each run appends a short time-based suffix so concurrent or
    # back-to-back test runs never collide in IBM Cloud.
    local hhmm="${RUN_TS:9:4}"   # e.g. "0652" from 20260504_065205
    local base_cluster base_vpc base_cos base_tgw base_dc
    base_cluster=$(get_tfvar "openshift_cluster_name"         "$BASE_TFVARS")
    base_vpc=$(get_tfvar     "roks_cluster_vpc_name"          "$BASE_TFVARS")
    base_cos=$(get_tfvar     "roks_cos_instance_name"         "$BASE_TFVARS")
    base_tgw=$(get_tfvar     "roks_transit_gateway_name"      "$BASE_TFVARS")
    base_dc=$(get_tfvar      "cneinstance_gslb_datacenter_name" "$BASE_TFVARS")

    # Prereqs names — shared by scenarios 2, 3, 4
    local p_cluster="${base_cluster}-s${hhmm}"
    local p_vpc="${base_vpc}-s${hhmm}"
    local p_cos="${base_cos}-s${hhmm}"
    local p_tgw="${base_tgw}-s${hhmm}"

    tlog "  Resource suffix : -tN-${hhmm}  (prereqs: -s${hhmm})"
    tlog ""

    # Pre-initialize results so the summary shows — for any unrun test
    for id in "${SELECTED_IDS[@]}"; do
        RESULTS["$id:plan"]="—"; RESULTS["$id:apply"]="—"; RESULTS["$id:destroy"]="—"
    done

    # ── Scenario 1 (full) — independent of all other scenarios ─
    local id dir tfvars
    for id in "${SELECTED_IDS[@]}"; do
        [[ "$id" == "1" ]] || continue
        tlog ""; tlog "──── Scenario 1: full ────"
        dir="$RUN_DIR/scenario-1-full"
        tfvars=$(scenario_tfvars_file 1)
        make_scenario_dir "$dir"
        gen_tfvars "$BASE_TFVARS" "$dir/$tfvars" \
            "openshift_cluster_name=${base_cluster}-t1-${hhmm}"       \
            "roks_cluster_vpc_name=${base_vpc}-t1-${hhmm}"            \
            "roks_cos_instance_name=${base_cos}-t1-${hhmm}"           \
            "roks_transit_gateway_name=${base_tgw}-t1-${hhmm}"        \
            "cneinstance_gslb_datacenter_name=${base_dc}-t1-${hhmm}"  \
            "create_roks_cluster=true"                                 \
            "create_roks_transit_gateway=true"                         \
            "create_roks_registry_cos_instance=true"                   \
            "install_cert_manager=true"                                \
            "deploy_bnk=true"                                          \
            "testing_create_tgw_jumphost=false"                        \
            "testing_create_cluster_jumphosts=false"
        run_test 1 "$dir" "$tfvars"
    done

    # ── Scenarios 2, 3, 4 — require shared prereqs ────────────
    local needs_prereqs=false
    for id in "${SELECTED_IDS[@]}"; do
        [[ "$id" != "1" ]] && needs_prereqs=true && break
    done

    if [[ "$needs_prereqs" == true ]]; then
        tlog ""; tlog "──── Shared prerequisites ────"
        local prereqs_ok=true
        if ! run_prereqs_setup "$p_cluster" "$p_vpc" "$p_cos" "$p_tgw"; then
            prereqs_ok=false
            run_prereqs_teardown
            for id in "${SELECTED_IDS[@]}"; do
                [[ "$id" == "1" ]] && continue
                RESULTS["$id:plan"]="SKIP"
                RESULTS["$id:apply"]="SKIP"
                RESULTS["$id:destroy"]="SKIP"
            done
        fi

        if [[ "$prereqs_ok" == true ]]; then
            for id in "${SELECTED_IDS[@]}"; do
                [[ "$id" == "1" ]] && continue
                local label; label=$(scenario_label "$id")
                tlog ""; tlog "──── Scenario $id: $label ────"
                dir="$RUN_DIR/scenario-$id-$label"
                tfvars=$(scenario_tfvars_file "$id")
                make_scenario_dir "$dir"

                case $id in
                    2)
                        # Existing cluster, new TGW, new cert-manager, new BNK
                        gen_tfvars "$BASE_TFVARS" "$dir/$tfvars"              \
                            "openshift_cluster_name=${p_cluster}"             \
                            "roks_cluster_id_or_name=${p_cluster}"            \
                            "roks_cluster_vpc_name=${base_vpc}-t2-${hhmm}"    \
                            "roks_cos_instance_name=${base_cos}-t2-${hhmm}"   \
                            "roks_transit_gateway_name=${base_tgw}-t2-${hhmm}" \
                            "cneinstance_gslb_datacenter_name=${base_dc}-t2-${hhmm}" \
                            "create_roks_cluster=false"                       \
                            "create_roks_transit_gateway=true"                \
                            "create_roks_registry_cos_instance=false"         \
                            "install_cert_manager=true"                       \
                            "deploy_bnk=true"                                 \
                            "testing_create_tgw_jumphost=false"               \
                            "testing_create_cluster_jumphosts=false"
                        ;;
                    3)
                        # Existing cluster, existing TGW (from prereqs), new cert-manager, new BNK
                        gen_tfvars "$BASE_TFVARS" "$dir/$tfvars"              \
                            "openshift_cluster_name=${p_cluster}"             \
                            "roks_cluster_id_or_name=${p_cluster}"            \
                            "roks_cluster_vpc_name=${base_vpc}-t3-${hhmm}"    \
                            "roks_cos_instance_name=${base_cos}-t3-${hhmm}"   \
                            "roks_transit_gateway_name=${p_tgw}"              \
                            "cneinstance_gslb_datacenter_name=${base_dc}-t3-${hhmm}" \
                            "create_roks_cluster=false"                       \
                            "create_roks_transit_gateway=false"               \
                            "create_roks_registry_cos_instance=false"         \
                            "install_cert_manager=true"                       \
                            "deploy_bnk=true"                                 \
                            "testing_create_tgw_jumphost=false"               \
                            "testing_create_cluster_jumphosts=false"
                        ;;
                    4)
                        # Existing cluster, new TGW, existing cert-manager (from prereqs), new BNK
                        gen_tfvars "$BASE_TFVARS" "$dir/$tfvars"              \
                            "openshift_cluster_name=${p_cluster}"             \
                            "roks_cluster_id_or_name=${p_cluster}"            \
                            "roks_cluster_vpc_name=${base_vpc}-t4-${hhmm}"    \
                            "roks_cos_instance_name=${base_cos}-t4-${hhmm}"   \
                            "roks_transit_gateway_name=${base_tgw}-t4-${hhmm}" \
                            "cneinstance_gslb_datacenter_name=${base_dc}-t4-${hhmm}" \
                            "create_roks_cluster=false"                       \
                            "create_roks_transit_gateway=true"                \
                            "create_roks_registry_cos_instance=false"         \
                            "install_cert_manager=false"                      \
                            "deploy_bnk=true"                                 \
                            "testing_create_tgw_jumphost=false"               \
                            "testing_create_cluster_jumphosts=false"
                        ;;
                esac

                run_test "$id" "$dir" "$tfvars"
            done

            run_prereqs_teardown
        fi
    fi

    print_summary
}

if [[ -n "$CLEANUP_DIR" ]]; then
    run_cleanup "$CLEANUP_DIR"
else
    main
fi
