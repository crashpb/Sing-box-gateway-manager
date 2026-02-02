#!/bin/bash
CONF_DIR="/opt/sing-box-gateway-manager/conf"
RUN_DIR="/opt/sing-box-gateway-manager/run"

if [ "$EUID" -ne 0 ]; then echo "Root required."; exit 1; fi

# --- UTILS ---
get_uptime() {
    local s=$1
    local ts=$(systemctl show -p ActiveEnterTimestamp "$s" | cut -d= -f2)
    if [ -z "$ts" ] || [ "$ts" == "n/a" ]; then echo "-"; return; fi
    local ss=$(date -d "$ts" +%s 2>/dev/null)
    local ns=$(date +%s)
    local d=$((ns - ss))
    if [ $d -lt 60 ]; then echo "${d}s"; elif [ $d -lt 3600 ]; then echo "$((d/60))m"; else echo "$((d/3600))h"; fi
}

get_traffic_fmt() {
    local i=$1
    if [ ! -d "/sys/class/net/$i" ]; then echo "0/0 KB"; return; fi
    local rx=$(cat /sys/class/net/$i/statistics/rx_bytes 2>/dev/null || echo 0)
    local tx=$(cat /sys/class/net/$i/statistics/tx_bytes 2>/dev/null || echo 0)
    format_bytes() { local b=$1; if [ $b -lt 1048576 ]; then echo "$(awk -v v=$b 'BEGIN {printf "%.0f", v/1024}')K"; else echo "$(awk -v v=$b 'BEGIN {printf "%.1f", v/1048576}')M"; fi; }
    echo "$(format_bytes $rx) / $(format_bytes $tx)"
}

get_proto_details() {
    local u=$1
    local p=$(echo "$u" | awk -F:// '{print $1}' | tr '[:lower:]' '[:upper:]')
    local s=""
    if [[ "$p" == "VMESS" ]]; then s="JSON";
    elif [[ "$p" == "SOCKS5" || "$p" == "HTTP" ]]; then
        local t=${u#*://}; if [[ "$t" == *"@"* ]]; then t="${t#*@}"; fi
        s="${t}"
    else
        local t=${u#*://}; s="${t%@*}"; s=$(echo "$u" | grep -oE "://[^?]+" | cut -c 4- | cut -d@ -f2)
    fi
    echo "$p|$s"
}

get_latency() {
    local name=$1
    local log="$RUN_DIR/$name.icmp.log"
    if [ ! -f "$log" ]; then echo "-"; return; fi
    local lat=$(grep -oE "Latency(:| Updated:) [0-9]+ms" "$log" | tail -n 1 | grep -oE "[0-9]+ms")
    echo "${lat:-0ms}"
}

# --- COMMANDS ---

print_status() {
    echo "==================================================================================================================================================="
    printf "%-12s | %-16s | %-8s | %-14s | %-14s | %-8s | %-8s | %-20s | %-6s | %-14s\n" \
           "NAME" "STATUS" "IFACE" "GW IP" "ICMP_RES" "LATENCY" "PROTO" "SERVER" "UPTIME" "TRAFFIC"
    echo "==================================================================================================================================================="

    shopt -s nullglob
    for conf in "$CONF_DIR"/*.conf; do
        name=$(basename "$conf" .conf)
        unset PHY_IF GATEWAY_IP ICMP_RES_IP PROXY_URL
        source "$conf"

        local svc="sbg@$name"
        local id_file="$RUN_DIR/$name.id"
        local vip_file="$RUN_DIR/$name.vip"
        local tr="-"
        local lat="-"
        local up="-"
        local st_color=""
        local st_text=""

        # Determine Display VIP (Runtime > Config)
        local vip_disp="${ICMP_RES_IP:-N/A}"

        if systemctl is-active --quiet "$svc"; then
            st_text="ACTIVE"
            st_color="\e[32m"
            up=$(get_uptime "$svc")
            lat=$(get_latency "$name")
            if [ -f "$id_file" ]; then
                local id=$(cat "$id_file")
                local tun="sbx$id"
                tr=$(get_traffic_fmt "$tun")
            fi
            # If runtime VIP exists, overwrite config value
            if [ -f "$vip_file" ]; then
                vip_disp=$(cat "$vip_file")
            fi
        else
            st_text="STOPPED"
            st_color="\e[31m"
        fi

        IFS='|' read -r pr sr <<< "$(get_proto_details "$PROXY_URL")"
        local gw_disp="${GATEWAY_IP:-N/A}"
        local srv_disp="${sr:0:20}"

        printf "%-12s | ${st_color}%-16s\e[0m | %-8s | %-14s | %-14s | %-8s | %-8s | %-20s | %-6s | %-14s\n" \
               "$name" "$st_text" "$PHY_IF" "$gw_disp" "$vip_disp" "$lat" "$pr" "$srv_disp" "$up" "$tr"
    done
    echo "==================================================================================================================================================="
}

print_detail_status() {
    local name=$1
    local conf="$CONF_DIR/$name.conf"

    if [ ! -f "$conf" ]; then echo "Error: Configuration '$name' not found."; exit 1; fi

    unset PHY_IF GATEWAY_IP ICMP_RES_IP PROXY_URL
    source "$conf"

    local svc="sbg@$name"
    local id_file="$RUN_DIR/$name.id"
    local vip_file="$RUN_DIR/$name.vip"
    local pid_icmp="$RUN_DIR/$name.icmp.pid"
    local log_icmp="$RUN_DIR/$name.icmp.log"

    # Determine Real VIP
    local vip_final="${ICMP_RES_IP:- (Dynamic)}"
    if [ -f "$vip_file" ]; then
        vip_final="$(cat "$vip_file") (Active)"
    fi

    echo ""
    echo ">>> STATUS DETAIL: $name"
    echo "============================================================"

    # 1. Service Health
    if systemctl is-active --quiet "$svc"; then
        echo -e "Status       : \e[32mACTIVE\e[0m"
        echo "Uptime       : $(get_uptime "$svc")"
        echo "Main PID     : $(systemctl show -p MainPID "$svc" | cut -d= -f2)"

        if [ -f "$pid_icmp" ]; then
            echo "Responder PID: $(cat "$pid_icmp")"
        else
            echo "Responder PID: (Not Running)"
        fi
    else
        echo -e "Status       : \e[31mSTOPPED\e[0m"
    fi

    # 2. Network Config
    echo "------------------------------------------------------------"
    echo "Physical Iface : $PHY_IF"
    echo "Gateway IP     : ${GATEWAY_IP:- (None)}"
    echo "ICMP Resp IP   : $vip_final"
    if [ -f "$id_file" ]; then
        local id=$(cat "$id_file")
        echo "Tunnel Iface   : sbx$id"
        echo "Traffic        : $(get_traffic_fmt "sbx$id")"
    else
        echo "Tunnel Iface   : -"
    fi
    echo "Latency        : $(get_latency "$name")"

    # 3. Proxy Config
    echo "------------------------------------------------------------"
    IFS='|' read -r pr sr <<< "$(get_proto_details "$PROXY_URL")"
    echo "Protocol       : $pr"
    echo "Server         : $sr"
    echo "Full URL       : $PROXY_URL"

    # 4. Recent Logs
    echo "------------------------------------------------------------"
    echo "Recent ICMP Logs:"
    if [ -f "$log_icmp" ]; then
        tail -n 5 "$log_icmp" | sed 's/^/  /'
    else
        echo "  (No logs found)"
    fi
    echo "============================================================"
    echo ""
}

start_service() {
    local n=$1
    if [ ! -f "$CONF_DIR/$n.conf" ]; then echo "Error: Config '$n.conf' not found in $CONF_DIR"; exit 1; fi

    echo ">>> Starting sbg@$n..."
    systemctl start "sbg@$n"
    sleep 2

    if systemctl is-active --quiet "sbg@$n"; then
        echo ">>> [SUCCESS]"
        echo ">>> Recent Logs:"
        if [ -f "$RUN_DIR/$n.icmp.log" ]; then
            tail -n 3 "$RUN_DIR/$n.icmp.log" | sed 's/^/    /'
        else
            echo "    (No ICMP logs found)"
        fi
    else
        echo ">>> [FAILED]"
        journalctl -u "sbg@$n" -n 20 --no-pager
    fi
}

stop_service() {
    local n=$1
    if [ ! -f "$CONF_DIR/$n.conf" ]; then echo "Error: Config '$n.conf' not found."; exit 1; fi

    echo ">>> Stopping sbg@$n..."
    systemctl stop "sbg@$n"

    if ! systemctl is-active --quiet "sbg@$n"; then
        echo ">>> [STOPPED]"
    else
        echo ">>> [FAILED TO STOP] (Check system logs)"
        journalctl -u "sbg@$n" -n 10 --no-pager
    fi
}

restart_service() {
    local n=$1
    if [ ! -f "$CONF_DIR/$n.conf" ]; then echo "Error: Config '$n.conf' not found."; exit 1; fi

    echo ">>> Restarting sbg@$n..."
    systemctl restart "sbg@$n"
    sleep 2

    if systemctl is-active --quiet "sbg@$n"; then
        echo ">>> [RESTARTED]"
        echo ">>> Recent Logs:"
        if [ -f "$RUN_DIR/$n.icmp.log" ]; then
            tail -n 3 "$RUN_DIR/$n.icmp.log" | sed 's/^/    /'
        else
            echo "    (No ICMP logs found)"
        fi
    else
        echo ">>> [FAILED]"
        journalctl -u "sbg@$n" -n 20 --no-pager
    fi
}

case "$1" in
    start)
        [ -z "$2" ] && echo "Usage: sbg start <name>" && exit 1
        start_service "$2"
        ;;
    stop)
        [ -z "$2" ] && echo "Usage: sbg stop <name>" && exit 1
        stop_service "$2"
        ;;
    restart)
        [ -z "$2" ] && echo "Usage: sbg restart <name>" && exit 1
        restart_service "$2"
        ;;
    status)
        if [ -z "$2" ]; then
            print_status
        else
            print_detail_status "$2"
        fi
        ;;
    log)
        [ -z "$2" ] && echo "Usage: sbg log <name>" && exit 1
        if [ ! -f "$RUN_DIR/$2.icmp.log" ]; then echo "Error: Log file for '$2' not found."; exit 1; fi
        tail -f "$RUN_DIR/$2.icmp.log"
        ;;
    *)
        echo "Usage: sbg {start|stop|restart|status [name]|log [name]}"
        ;;
esac
