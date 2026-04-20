#!/usr/bin/env bash
# Real-time resource dashboard for the llama stack.
# Shows CPU / RAM / GPU / per-container stats, refreshes every 2s.
# Uses only what's always available (nvidia-smi, docker, /proc).
#
# Usage: ./scripts/monitor.sh  (Ctrl-C to exit)
set -euo pipefail

# Force C locale for numeric formatting — printf %f under fr_FR expects `,`
# as decimal separator and rejects the `.` values we pass in.
export LC_ALL=C LC_NUMERIC=C

INTERVAL="${MONITOR_INTERVAL:-2}"

# ──────────────────────────────────────────────────────────────
# Colors & helpers
# ──────────────────────────────────────────────────────────────

c_dim()    { printf '\033[90m%s\033[0m' "$*"; }
c_bold()   { printf '\033[1m%s\033[0m'  "$*"; }
c_green()  { printf '\033[32m%s\033[0m' "$*"; }
c_yellow() { printf '\033[33m%s\033[0m' "$*"; }
c_red()    { printf '\033[31m%s\033[0m' "$*"; }

# color_pct <value>  →  green <50, yellow <85, red >=85
color_pct() {
    local v=$1 fmt="${2:-%5.1f%%}"
    if awk -v v="$v" 'BEGIN{exit !(v<50)}'; then
        c_green  "$(printf "$fmt" "$v")"
    elif awk -v v="$v" 'BEGIN{exit !(v<85)}'; then
        c_yellow "$(printf "$fmt" "$v")"
    else
        c_red    "$(printf "$fmt" "$v")"
    fi
}

# bar <pct 0-100> <width>
bar() {
    local pct=$1 width=${2:-20}
    local filled
    filled=$(awk -v p="$pct" -v w="$width" 'BEGIN{printf "%d", p*w/100}')
    local empty=$((width - filled))
    printf '['
    printf '%*s' "$filled" '' | tr ' ' '█'
    printf '%*s' "$empty"  '' | tr ' ' '░'
    printf ']'
}

# ──────────────────────────────────────────────────────────────
# Data collection
# ──────────────────────────────────────────────────────────────

read_cpu_usage() {
    # %CPU over the refresh interval by diffing /proc/stat.
    # Cheap & portable; first call reports 0.
    local prev=${CPU_PREV:-}
    local cur
    cur=$(awk '/^cpu / {print $2+$3+$4+$5+$6+$7+$8, $5}' /proc/stat)
    if [[ -n "$prev" ]]; then
        awk -v p="$prev" -v c="$cur" 'BEGIN{
            split(p, a); split(c, b)
            total = b[1] - a[1]
            idle  = b[2] - a[2]
            if (total > 0) printf "%.1f", (1 - idle/total) * 100
            else printf "0.0"
        }'
    else
        printf "0.0"
    fi
    CPU_PREV="$cur"
}

render_cpu_mem() {
    c_bold " CPU & MEMORY"; echo
    echo "  ─────────────────────────────────────────────────────"
    local load cpu_pct mem_line mem_used mem_total mem_avail swap_used swap_total
    load=$(cut -d' ' -f1-3 /proc/loadavg)
    cpu_pct=$(read_cpu_usage)
    # /proc/meminfo in kB
    mem_total=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)
    mem_avail=$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)
    swap_total=$(awk '/^SwapTotal:/ {print $2}' /proc/meminfo)
    swap_free=$(awk '/^SwapFree:/  {print $2}' /proc/meminfo)
    mem_used=$((mem_total - mem_avail))
    swap_used=$((swap_total - swap_free))
    local mem_pct swap_pct
    mem_pct=$(awk -v u="$mem_used" -v t="$mem_total" 'BEGIN{printf "%.1f", u*100/t}')
    swap_pct=$(awk -v u="$swap_used" -v t="$swap_total" 'BEGIN{if(t>0)printf "%.1f", u*100/t; else printf "0.0"}')

    printf "  Load      %s\n" "$load"
    printf "  CPU       %s %s\n" "$(bar "$cpu_pct" 24)" "$(color_pct "$cpu_pct")"
    printf "  RAM       %s %s   %s / %s\n" \
        "$(bar "$mem_pct" 24)" \
        "$(color_pct "$mem_pct")" \
        "$(printf '%.1fG' "$(awk -v v="$mem_used" 'BEGIN{print v/1024/1024}')")" \
        "$(printf '%.1fG' "$(awk -v v="$mem_total" 'BEGIN{print v/1024/1024}')")"
    if (( swap_total > 0 )); then
        printf "  SWAP      %s %s   %s / %s\n" \
            "$(bar "$swap_pct" 24)" \
            "$(color_pct "$swap_pct")" \
            "$(printf '%.1fG' "$(awk -v v="$swap_used" 'BEGIN{print v/1024/1024}')")" \
            "$(printf '%.1fG' "$(awk -v v="$swap_total" 'BEGIN{print v/1024/1024}')")"
    fi
    echo
}

render_gpu() {
    c_bold " GPU"; echo
    echo "  ─────────────────────────────────────────────────────"
    if ! command -v nvidia-smi >/dev/null; then
        c_dim "  (nvidia-smi not available)"; echo; echo; return
    fi
    local line; line=$(nvidia-smi \
        --query-gpu=name,utilization.gpu,memory.used,memory.total,temperature.gpu,power.draw,power.max_limit \
        --format=csv,noheader,nounits | head -1)
    IFS=, read -r name util mem_used mem_total temp pwr pwr_max <<<"$line"
    name=$(echo "$name" | xargs)
    util=$(echo "$util" | xargs)
    mem_used=$(echo "$mem_used" | xargs)
    mem_total=$(echo "$mem_total" | xargs)
    temp=$(echo "$temp" | xargs)
    pwr=$(echo "$pwr" | xargs)
    pwr_max=$(echo "$pwr_max" | xargs)

    local vram_pct; vram_pct=$(awk -v u="$mem_used" -v t="$mem_total" 'BEGIN{printf "%.1f", u*100/t}')
    local pwr_pct;  pwr_pct=$(awk  -v u="$pwr" -v t="$pwr_max"    'BEGIN{printf "%.1f", u*100/t}')

    printf "  %s\n" "$(c_dim "$name")"
    printf "  GPU       %s %s\n" "$(bar "$util" 24)"     "$(color_pct "$util")"
    printf "  VRAM      %s %s   %s / %s MiB\n" \
        "$(bar "$vram_pct" 24)" "$(color_pct "$vram_pct")" "$mem_used" "$mem_total"
    printf "  Power     %s %s   %sW / %sW\n" \
        "$(bar "$pwr_pct" 24)"  "$(color_pct "$pwr_pct")"  "$pwr" "$pwr_max"
    printf "  Temp      %s°C\n" "$temp"
    echo
}

render_containers() {
    c_bold " DOCKER CONTAINERS"; echo
    echo "  ─────────────────────────────────────────────────────"
    # --no-stream = one snapshot; faster & deterministic for our loop.
    local stats
    stats=$(docker stats --no-stream --format '{{.Name}}|{{.CPUPerc}}|{{.MemUsage}}|{{.MemPerc}}' 2>/dev/null) || {
        c_dim "  (docker not reachable)"; echo; echo; return
    }
    if [[ -z "$stats" ]]; then
        c_dim "  (no running containers)"; echo; echo; return
    fi
    printf "  %-22s %8s   %-22s %s\n" "NAME" "CPU" "MEM" "MEM%"
    while IFS='|' read -r name cpu mem mem_pct; do
        local pct_num; pct_num="${mem_pct%\%}"
        printf "  %-22s %8s   %-22s %s\n" \
            "$name" "$cpu" "$mem" "$(color_pct "$pct_num")"
    done <<<"$stats"
    echo
}

# ──────────────────────────────────────────────────────────────
# Main loop
# ──────────────────────────────────────────────────────────────

cleanup() { printf '\033[?25h'; echo; exit 0; }
trap cleanup INT TERM EXIT

# Hide cursor
printf '\033[?25l'

# Prime CPU_PREV on the first iteration so the second is meaningful.
CPU_PREV=""

while :; do
    # Move cursor to top-left, clear screen.
    printf '\033[2J\033[H'
    c_bold "llama stack · monitor"; c_dim "  (Ctrl-C to exit, refresh ${INTERVAL}s)"; echo
    echo

    render_cpu_mem
    render_gpu
    render_containers

    sleep "$INTERVAL"
done
