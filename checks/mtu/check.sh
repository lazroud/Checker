#!/usr/bin/env bash
#
# check.sh — End-to-end MTU validation for network nodes
#
# Detects overlay networks, CGNAT, MSS clamping, and confirms that MTU 1500
# passes end-to-end. Returns exit codes for CI/automation integration.
#
# Source: https://github.com/lazroud/Checker
# License: MIT
#
# Quick run (one-shot):
#   curl -fsSL https://raw.githubusercontent.com/lazroud/Checker/main/checks/mtu/check.sh | sudo bash
#   curl -fsSL https://raw.githubusercontent.com/lazroud/Checker/main/checks/mtu/check.sh | sudo bash -s -- --quiet
#
# Install (persistent):
#   sudo curl -fsSL https://raw.githubusercontent.com/lazroud/Checker/main/checks/mtu/check.sh \
#       -o /usr/local/bin/mtu-check
#   sudo chmod +x /usr/local/bin/mtu-check
#   sudo mtu-check
#
# Modes:
#   --quiet     minimal output (one line, suitable for cron)
#   --json      JSON output (for automation)
#   --no-color  plain text (for logs)
#   --help      show this header
#
# Exit codes:
#   0 — PASS (clean MTU 1500 end-to-end, production-ready)
#   1 — WARN (works but suboptimal)
#   2 — FAIL (overlay / MTU issues, do not use for exit traffic)
#

set -uo pipefail

# ──────────────────────────────────────────────────────────────────────────
# Configuration
# ──────────────────────────────────────────────────────────────────────────

TARGETS=(
    "1.1.1.1"        # Cloudflare
    "8.8.8.8"        # Google
    "9.9.9.9"        # Quad9
)
PAYLOAD_SIZE=1472          # 1472 + 28 (IP+ICMP) = 1500B total
MIN_ACCEPTABLE_MTU=1500
WARN_MTU=1480
PING_COUNT=3
PING_TIMEOUT=3
TRACEPATH_TIMEOUT=15

# ──────────────────────────────────────────────────────────────────────────
# Output mode
# ──────────────────────────────────────────────────────────────────────────

MODE="interactive"      # interactive | quiet | json
USE_COLOR=1

for arg in "$@"; do
    case "$arg" in
        --quiet)    MODE="quiet" ;;
        --json)     MODE="json"; USE_COLOR=0 ;;
        --no-color) USE_COLOR=0 ;;
        --help|-h)
            sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
    esac
done

if [[ "$USE_COLOR" -eq 1 ]] && [[ -t 1 ]] && command -v tput >/dev/null 2>&1; then
    BOLD=$(tput bold); RED=$(tput setaf 1); GREEN=$(tput setaf 2)
    YELLOW=$(tput setaf 3); BLUE=$(tput setaf 4); RESET=$(tput sgr0)
else
    BOLD=""; RED=""; GREEN=""; YELLOW=""; BLUE=""; RESET=""
fi

# ──────────────────────────────────────────────────────────────────────────
# Privilege detection
# ──────────────────────────────────────────────────────────────────────────

SUDO=""
if [[ "$EUID" -ne 0 ]]; then
    if command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
        SUDO="sudo"
    fi
fi

# ──────────────────────────────────────────────────────────────────────────
# Result tracking
# ──────────────────────────────────────────────────────────────────────────

PASS_COUNT=0
WARN_COUNT=0
FAIL_COUNT=0
RESULTS_JSON='[]'
ISSUES=()

# ──────────────────────────────────────────────────────────────────────────
# Output helpers
# ──────────────────────────────────────────────────────────────────────────

is_interactive() { [[ "$MODE" == "interactive" ]]; }

print_header() {
    is_interactive || return 0
    echo
    echo "${BOLD}${BLUE}═══════════════════════════════════════════════════════════════${RESET}"
    echo "${BOLD}${BLUE}  $1${RESET}"
    echo "${BOLD}${BLUE}═══════════════════════════════════════════════════════════════${RESET}"
}

print_section() {
    is_interactive || return 0
    echo
    echo "${BOLD}▸ $1${RESET}"
}

record_json() {
    local check="$1" status="$2" message="$3"
    local escaped_msg
    escaped_msg=$(echo "$message" | sed 's/\\/\\\\/g; s/"/\\"/g')
    RESULTS_JSON=$(echo "$RESULTS_JSON" | sed 's/]$//')
    if [[ "$RESULTS_JSON" == "[" ]]; then
        RESULTS_JSON="${RESULTS_JSON}{\"check\":\"${check}\",\"status\":\"${status}\",\"message\":\"${escaped_msg}\"}]"
    else
        RESULTS_JSON="${RESULTS_JSON},{\"check\":\"${check}\",\"status\":\"${status}\",\"message\":\"${escaped_msg}\"}]"
    fi
}

pass() {
    local check="${2:-}"
    is_interactive && echo "  ${GREEN}✓${RESET} $1"
    PASS_COUNT=$((PASS_COUNT + 1))
    [[ -n "$check" ]] && record_json "$check" "pass" "$1"
}

warn() {
    local check="${2:-}"
    is_interactive && echo "  ${YELLOW}⚠${RESET} $1"
    WARN_COUNT=$((WARN_COUNT + 1))
    ISSUES+=("WARN: $1")
    [[ -n "$check" ]] && record_json "$check" "warn" "$1"
}

fail_check() {
    local check="${2:-}"
    is_interactive && echo "  ${RED}✗${RESET} $1"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    ISSUES+=("FAIL: $1")
    [[ -n "$check" ]] && record_json "$check" "fail" "$1"
}

info() {
    is_interactive && echo "    ${BLUE}ℹ${RESET} $1"
}

# ──────────────────────────────────────────────────────────────────────────
# Helpers
# ──────────────────────────────────────────────────────────────────────────

detect_iface() {
    ip route show default 2>/dev/null | awk '/default/ {print $5; exit}'
}

detect_gateway() {
    ip route show default 2>/dev/null | awk '/default/ {print $3; exit}'
}

# RFC 6598 carrier-grade NAT: 100.64.0.0/10
is_cgnat() {
    local ip="$1"
    local first second
    first=$(echo "$ip" | cut -d. -f1)
    second=$(echo "$ip" | cut -d. -f2)
    [[ "$first" == "100" ]] && [[ "$second" -ge 64 ]] && [[ "$second" -le 127 ]]
}

# RFC 1918 private ranges
is_private() {
    local ip="$1"
    local first second
    first=$(echo "$ip" | cut -d. -f1)
    second=$(echo "$ip" | cut -d. -f2)
    [[ "$first" == "10" ]] && return 0
    [[ "$first" == "192" ]] && [[ "$second" == "168" ]] && return 0
    [[ "$first" == "172" ]] && [[ "$second" -ge 16 ]] && [[ "$second" -le 31 ]] && return 0
    return 1
}

# ──────────────────────────────────────────────────────────────────────────
# Checks
# ──────────────────────────────────────────────────────────────────────────

check_interface_mtu() {
    print_section "Interface MTU"
    local iface mtu
    iface=$(detect_iface)
    if [[ -z "$iface" ]]; then
        fail_check "Could not detect default network interface" "iface_mtu"
        return
    fi

    mtu=$(ip -o link show "$iface" 2>/dev/null | grep -oP 'mtu \K\d+' | head -1)
    info "Default interface: $iface (MTU: $mtu)"

    if [[ "$mtu" -ge "$MIN_ACCEPTABLE_MTU" ]]; then
        pass "Interface MTU is $mtu" "iface_mtu"
    elif [[ "$mtu" -ge "$WARN_MTU" ]]; then
        warn "Interface MTU is $mtu (below ideal $MIN_ACCEPTABLE_MTU)" "iface_mtu"
    else
        fail_check "Interface MTU is $mtu (much lower than expected $MIN_ACCEPTABLE_MTU)" "iface_mtu"
    fi
}

check_gateway() {
    print_section "Gateway analysis"
    local gw
    gw=$(detect_gateway)
    if [[ -z "$gw" ]]; then
        fail_check "Could not detect default gateway" "gateway"
        return
    fi

    info "Default gateway: $gw"

    if is_cgnat "$gw"; then
        fail_check "Gateway in CGNAT (100.64.0.0/10) — overlay/NAT tunnel highly likely" "gateway"
        info "Typical signature of providers with internal SDN. MTU 1500 unlikely achievable."
    elif is_private "$gw"; then
        warn "Gateway in RFC1918 — provider uses internal routing (overlay possible)" "gateway"
        info "Not always bad — DF ping below will confirm."
    else
        pass "Gateway is in public range (clean L3 routing)" "gateway"
    fi
}

check_tunnel_interfaces() {
    print_section "Hidden tunnel interfaces"
    local tunnels
    tunnels=$(ip -d link show 2>/dev/null \
        | grep -iE 'tun|vxlan|geneve|gre|ipip|sit|wireguard' \
        | grep -v 'docker\|veth\|bridge_slave' || true)

    if [[ -z "$tunnels" ]]; then
        pass "No tunnel interfaces detected" "tunnels"
    else
        warn "Tunnel interface(s) detected (review if expected):" "tunnels"
        is_interactive && echo "$tunnels" | sed 's/^/      /'
    fi
}

check_mss_clamping() {
    print_section "TCP MSS clamping rules"
    local has_clamp=0

    if command -v iptables >/dev/null 2>&1; then
        local ipt_out
        ipt_out=$($SUDO iptables -t mangle -L -n 2>/dev/null | grep -iE 'mss|tcpmss|clamp' || true)
        if [[ -n "$ipt_out" ]]; then
            warn "iptables mangle has MSS rules (could reduce effective MTU)" "mss_clamp"
            is_interactive && echo "$ipt_out" | sed 's/^/      /'
            has_clamp=1
        fi
    fi

    if command -v nft >/dev/null 2>&1; then
        local nft_out
        nft_out=$($SUDO nft list ruleset 2>/dev/null | grep -iE 'tcp option maxseg' || true)
        if [[ -n "$nft_out" ]]; then
            warn "nftables has MSS clamping rules" "mss_clamp"
            is_interactive && echo "$nft_out" | sed 's/^/      /'
            has_clamp=1
        fi
    fi

    if [[ -z "$SUDO" ]] && [[ "$EUID" -ne 0 ]]; then
        info "(Limited check — no root/sudo. Run as root for complete firewall inspection.)"
    fi

    [[ "$has_clamp" -eq 0 ]] && pass "No MSS clamping rules found" "mss_clamp"
}

check_cached_pmtu() {
    print_section "Kernel PMTU cache"
    for target in "${TARGETS[@]}"; do
        local cached_mtu
        cached_mtu=$(ip route get "$target" 2>/dev/null | grep -oP 'mtu \K\d+' || true)

        if [[ -z "$cached_mtu" ]]; then
            pass "$target: no cached PMTU (kernel uses interface MTU)" "pmtu_cache"
        elif [[ "$cached_mtu" -ge "$MIN_ACCEPTABLE_MTU" ]]; then
            pass "$target: cached PMTU $cached_mtu" "pmtu_cache"
        else
            fail_check "$target: cached PMTU $cached_mtu (below $MIN_ACCEPTABLE_MTU)" "pmtu_cache"
        fi
    done
}

check_tracepath_pmtu() {
    print_section "Tracepath PMTU discovery"
    if ! command -v tracepath >/dev/null 2>&1; then
        warn "tracepath not installed (apt install iputils-tracepath)" "tracepath"
        return
    fi

    local target="${TARGETS[0]}"
    info "Running tracepath to $target (up to ${TRACEPATH_TIMEOUT}s)..."

    local result pmtu_drops min_pmtu
    result=$(timeout "$TRACEPATH_TIMEOUT" tracepath -n "$target" 2>&1 || true)
    pmtu_drops=$(echo "$result" | grep -oP 'pmtu \K\d+' | sort -un)

    if [[ -z "$pmtu_drops" ]]; then
        pass "No PMTU info from tracepath (unusual but not an error)" "tracepath"
        return
    fi

    min_pmtu=$(echo "$pmtu_drops" | sort -n | head -1)
    if [[ "$min_pmtu" -ge "$MIN_ACCEPTABLE_MTU" ]]; then
        pass "Minimum PMTU along path: $min_pmtu" "tracepath"
    else
        fail_check "Path reduces PMTU to $min_pmtu (overlay/tunneling detected on route)" "tracepath"
        if is_interactive; then
            echo "$result" | grep -iE 'pmtu|asymm' | sed 's/^/      /'
        fi
    fi
}

check_dont_fragment_ping() {
    print_section "Don't-fragment ping (CRITICAL CHECK)"
    info "Sending ${PAYLOAD_SIZE}B payload (1500B total) with DF flag set."
    info "Overlay-based providers drop oversized frames here — sysctl tweaks can't help."
    is_interactive && echo

    local total=${#TARGETS[@]} successful=0

    for target in "${TARGETS[@]}"; do
        local result loss exit_code
        result=$(ping -M do -s "$PAYLOAD_SIZE" -c "$PING_COUNT" -W "$PING_TIMEOUT" "$target" 2>&1)
        exit_code=$?

        if [[ "$exit_code" -eq 0 ]]; then
            loss=$(echo "$result" | grep -oP '\d+(?=% packet loss)' || echo "100")
            if [[ "$loss" -lt 50 ]]; then
                pass "$target: 1500B passes with DF (loss: ${loss}%)" "df_ping"
                successful=$((successful + 1))
            else
                fail_check "$target: high loss (${loss}%) on 1500B DF packets" "df_ping"
            fi
        else
            if echo "$result" | grep -qiE 'frag needed|message too long|mtu='; then
                local suggested_mtu
                suggested_mtu=$(echo "$result" | grep -oP 'mtu=\K\d+' | head -1 || echo "?")
                fail_check "$target: ICMP frag needed (suggested MTU: ${suggested_mtu})" "df_ping"
            else
                fail_check "$target: 1500B DF cannot reach destination" "df_ping"
            fi
        fi
    done

    is_interactive && echo
    if [[ "$successful" -eq "$total" ]]; then
        pass "All ${total} targets accept 1500B DF — clean MTU 1500 end-to-end" "df_ping_summary"
    elif [[ "$successful" -gt 0 ]]; then
        warn "Partial: ${successful}/${total} targets accept full-size packets" "df_ping_summary"
    else
        fail_check "Zero targets accept 1500B DF — overlay/MTU restriction confirmed" "df_ping_summary"
    fi
}

check_active_tcp_mss() {
    print_section "Active TCP connections MSS sample"
    if ! command -v ss >/dev/null 2>&1; then
        warn "ss not available (install iproute2)" "tcp_mss"
        return
    fi

    # Filter out loopback (MSS 65483) and unrealistic values
    local mss_values max_mss min_mss
    mss_values=$(ss -tin state established 2>/dev/null \
        | grep -oP 'mss:\K\d+' \
        | awk '$1 < 2000 && $1 > 500' \
        | sort -un)

    if [[ -z "$mss_values" ]]; then
        info "No active TCP connections to sample (normal on fresh nodes)"
        pass "TCP MSS check skipped (no active connections)" "tcp_mss"
        return
    fi

    max_mss=$(echo "$mss_values" | sort -n | tail -1)
    min_mss=$(echo "$mss_values" | sort -n | head -1)

    info "Active TCP MSS range: $min_mss .. $max_mss"

    # MTU 1500 with TCP timestamps → MSS 1448; without timestamps → 1460
    if [[ "$max_mss" -ge 1448 ]]; then
        pass "Max MSS $max_mss is consistent with MTU 1500" "tcp_mss"
    elif [[ "$max_mss" -ge 1400 ]]; then
        warn "Max MSS $max_mss suggests MTU ~$((max_mss + 52))" "tcp_mss"
    else
        fail_check "All MSS values below 1400 — overlay strongly indicated" "tcp_mss"
    fi
}

# ──────────────────────────────────────────────────────────────────────────
# Summary
# ──────────────────────────────────────────────────────────────────────────

print_summary() {
    local exit_code=0
    local verdict=""

    if [[ "$FAIL_COUNT" -gt 0 ]]; then
        exit_code=2
        verdict="FAIL"
    elif [[ "$WARN_COUNT" -gt 0 ]]; then
        exit_code=1
        verdict="WARN"
    else
        exit_code=0
        verdict="PASS"
    fi

    if [[ "$MODE" == "json" ]]; then
        local hostname public_ip
        hostname=$(hostname -f 2>/dev/null || hostname)
        public_ip=$(ip -4 addr show "$(detect_iface)" 2>/dev/null \
            | grep -oP 'inet \K[0-9.]+' | head -1)
        printf '{"hostname":"%s","public_ip":"%s","timestamp":"%s","verdict":"%s","passed":%d,"warnings":%d,"failures":%d,"results":%s}\n' \
            "$hostname" \
            "${public_ip:-unknown}" \
            "$(date -u +%FT%TZ)" \
            "$verdict" \
            "$PASS_COUNT" \
            "$WARN_COUNT" \
            "$FAIL_COUNT" \
            "$RESULTS_JSON"
        return $exit_code
    fi

    if [[ "$MODE" == "quiet" ]]; then
        echo "[${verdict}] pass=${PASS_COUNT} warn=${WARN_COUNT} fail=${FAIL_COUNT}"
        return $exit_code
    fi

    print_header "SUMMARY"
    echo
    echo "  Passed:   ${GREEN}${PASS_COUNT}${RESET}"
    echo "  Warnings: ${YELLOW}${WARN_COUNT}${RESET}"
    echo "  Failures: ${RED}${FAIL_COUNT}${RESET}"
    echo

    case "$verdict" in
        FAIL)
            echo "${BOLD}${RED}VERDICT: FAIL${RESET} — node has MTU/overlay issues."
            echo
            echo "Critical issues:"
            for issue in "${ISSUES[@]}"; do
                [[ "$issue" == FAIL:* ]] && echo "  • ${issue#FAIL: }"
            done
            echo
            echo "Do not use this node for outbound exit traffic."
            echo "Migrate to a provider with clean L3 routing (no CGNAT, no overlay)."
            ;;
        WARN)
            echo "${BOLD}${YELLOW}VERDICT: WARN${RESET} — works but suboptimal."
            echo
            echo "Warnings:"
            for issue in "${ISSUES[@]}"; do
                [[ "$issue" == WARN:* ]] && echo "  • ${issue#WARN: }"
            done
            ;;
        PASS)
            echo "${BOLD}${GREEN}VERDICT: PASS${RESET} — clean MTU 1500 end-to-end."
            echo "Node is suitable for production exit traffic."
            ;;
    esac

    return $exit_code
}

# ──────────────────────────────────────────────────────────────────────────
# Main
# ──────────────────────────────────────────────────────────────────────────

main() {
    local hostname public_ip
    hostname=$(hostname -f 2>/dev/null || hostname)
    public_ip=$(ip -4 addr show "$(detect_iface)" 2>/dev/null \
        | grep -oP 'inet \K[0-9.]+' | head -1)

    print_header "FLOWXE MTU validation — ${hostname}"
    info "Public IP: ${public_ip:-unknown}"
    info "Date: $(date '+%Y-%m-%d %H:%M:%S %Z')"
    info "Targets: ${TARGETS[*]}"
    [[ -z "$SUDO" ]] && [[ "$EUID" -ne 0 ]] && info "Running without root — firewall checks limited."

    check_interface_mtu
    check_gateway
    check_tunnel_interfaces
    check_mss_clamping
    check_cached_pmtu
    check_tracepath_pmtu
    check_dont_fragment_ping
    check_active_tcp_mss

    print_summary
}

main
exit $?
