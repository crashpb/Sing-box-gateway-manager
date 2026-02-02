#!/bin/bash
# ==============================================================================
# Sing-Box Gateway Manager - Core Logic
# Handles routing, firewall rules, process management, and dynamic VIP allocation.
# ==============================================================================

BASE_DIR="/opt/sing-box-gateway-manager"
INSTANCE_NAME=$1
ACTION=${2:-start}
CONFIG_FILE="${BASE_DIR}/conf/${INSTANCE_NAME}.conf"
ID_FILE="${BASE_DIR}/run/${INSTANCE_NAME}.id"
VIP_FILE="${BASE_DIR}/run/${INSTANCE_NAME}.vip"
JSON_CONFIG="${BASE_DIR}/run/${INSTANCE_NAME}.json"
BINARY="${BASE_DIR}/bin/sing-box"
BINARY_ICMP="${BASE_DIR}/bin/icmp_responder"
LOG_ICMP="${BASE_DIR}/run/${INSTANCE_NAME}.icmp.log"
PID_ICMP="${BASE_DIR}/run/${INSTANCE_NAME}.icmp.pid"

# Firewall Rule Identifier
SBG_COMMENT="sbg:${INSTANCE_NAME}"

# Dynamic VIP Pool
VIP_PREFIX="10.200.0"
VIP_START=10
VIP_END=250

clean_firewall() {
    # 1. Clean Gateway Input Drops
    if [ ! -z "$GATEWAY_IP" ]; then
        while iptables -D INPUT -d "$GATEWAY_IP" -p icmp --icmp-type 8 -m comment --comment "$SBG_COMMENT" -j DROP 2>/dev/null; do :; done
        while iptables -t raw -D PREROUTING -d "$GATEWAY_IP" -p icmp --icmp-type 8 -m comment --comment "$SBG_COMMENT" -j DROP 2>/dev/null; do :; done
    fi
    
    # 2. Clean VIP Output Drops
    local target_vip="$ICMP_RES_IP"
    if [ -f "$VIP_FILE" ]; then target_vip=$(cat "$VIP_FILE"); fi
    
    if [ ! -z "$target_vip" ]; then
        while iptables -D INPUT -d "$target_vip" -p icmp --icmp-type 8 -m comment --comment "$SBG_COMMENT" -j DROP 2>/dev/null; do :; done
        while iptables -D OUTPUT -s "$target_vip" -p icmp --icmp-type 0 -m mark ! --mark 100 -m comment --comment "$SBG_COMMENT" -j DROP 2>/dev/null; do :; done
    fi
    
    # 3. Clean MSS Clamping Rules
    while iptables -t mangle -D FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss ${MSS_VAL:-1300} -m comment --comment "$SBG_COMMENT" 2>/dev/null; do :; done
    while iptables -t mangle -D PREROUTING -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss ${MSS_VAL:-1300} -m comment --comment "$SBG_COMMENT" 2>/dev/null; do :; done
}

cleanup() {
    if [ -f "$PID_ICMP" ]; then 
        kill -9 $(cat "$PID_ICMP") 2>/dev/null
        rm "$PID_ICMP"
    fi
    pkill -9 -f "icmp_responder -c $CONFIG_FILE"
}
trap cleanup EXIT

find_free_id() { 
    for i in {10..200}; do 
        if ! ip link show "sbx$i" > /dev/null 2>&1 && [ ! -f "${BASE_DIR}/run/ids/$i" ]; then echo "$i"; return 0; fi; 
    done
    echo "NO_FREE_ID"; return 1; 
}

find_free_vip() {
    # Scan config files to exclude statically assigned IPs
    local reserved_ips=$(grep -r "ICMP_RES_IP=" ${BASE_DIR}/conf/ | cut -d= -f2 | tr -d ' "')

    for i in $(seq $VIP_START $VIP_END); do
        local candidate="${VIP_PREFIX}.${i}"
        
        # Check active routing table
        if ip route show table local | grep -q "$candidate"; then continue; fi
        
        # Check static reservations
        if echo "$reserved_ips" | grep -q "$candidate"; then continue; fi
        
        echo "$candidate"
        return 0
    done
    echo "NO_FREE_VIP"; return 1; 
}

validate_env() {
    if [ ! -d "/sys/class/net/$PHY_IF" ]; then
        echo "FATAL: Interface '$PHY_IF' does not exist."
        exit 1
    fi
}

get_vars() { local id=$1; TUN_DEV="sbx${id}"; TUN_IP="10.100.${id}.1"; TABLE_ID=$((1000 + id)); }

generate_json() {
    local url="$PROXY_URL"
    local scheme=$(echo "$url" | grep -oE "^[a-z0-9]+" | tr '[:upper:]' '[:lower:]')
    local outbound=""
    local uot="false"
    if [[ "$UDP_OVER_TCP" == "true" ]]; then uot="true"; fi

    local mux_json=""
    if [[ "$ENABLE_MUX" == "true" ]]; then
        local concurrency=${MUX_CONCURRENCY:-8}
        mux_json=", \"multiplex\": { \"enabled\": true, \"padding\": true, \"max_connections\": $concurrency }"
    fi

    local dns_fake_ip=""
    if [[ "$ENABLE_FAKEDNS" == "true" ]]; then
        dns_fake_ip=", \"fake_ip\": { \"enabled\": true, \"inet4_range\": \"198.18.0.0/15\", \"inet6_range\": \"fc00::/18\" }"
    fi

    if [[ "$scheme" == "socks5" || "$scheme" == "http" ]]; then
        local t=${url#*://}
        local u=""; local p=""; local s=""; local po=""
        if [[ "$t" == *"@"* ]]; then
            local up="${t%@*}"; local hp="${t#*@}"; u="${up%:*}"; p="${up#*:}"
            s="${hp%:*}"; po="${hp#*:}"
        else s="${t%:*}"; po="${t#*:}"; fi
        local ty="socks"; [[ "$scheme" == "http" ]] && ty="http"
        
        if [[ ! -z "$u" ]]; then
            outbound="{ \"type\": \"$ty\", \"tag\": \"proxy-out\", \"server\": \"$s\", \"server_port\": $po, \"username\": \"$u\", \"password\": \"$p\", \"udp_over_tcp\": $uot $mux_json }"
        else
            outbound="{ \"type\": \"$ty\", \"tag\": \"proxy-out\", \"server\": \"$s\", \"server_port\": $po, \"udp_over_tcp\": $uot $mux_json }"
        fi
    elif [[ "$scheme" =~ ^(vless|vmess|trojan|ss)$ ]]; then
         local t=${url#*://}; local s="${t%%:*}"; local po="443" 
         outbound="{ \"type\": \"$scheme\", \"tag\": \"proxy-out\", \"server\": \"$s\", \"server_port\": $po, \"udp_over_tcp\": $uot $mux_json }"
    fi
    [ -z "$outbound" ] && outbound="{ \"type\": \"socks\", \"tag\": \"proxy-out\" }"

    cat <<EOF_JSON > "$JSON_CONFIG"
{
  "log": { "level": "warn", "timestamp": true },
  "dns": {
    "servers": [ { "tag": "remote_dns", "type": "tcp", "server": "8.8.8.8", "detour": "proxy-out" } ],
    "rules": [],
    "final": "remote_dns"
    $dns_fake_ip
  },
  "inbounds": [ { "type": "tun", "tag": "tun-in", "interface_name": "$TUN_DEV", "address": [ "$TUN_IP/30" ], "mtu": 1500, "auto_route": false, "strict_route": false, "stack": "system", "sniff": true } ],
  "outbounds": [ $outbound, { "type": "direct", "tag": "direct" } ],
  "route": { 
      "rules": [ 
          { "protocol": "dns", "action": "hijack-dns" },
          { "protocol": "quic", "action": "reject" },
          { "port": 443, "network": "udp", "action": "reject" },
          { "inbound": "tun-in", "outbound": "proxy-out" } 
      ],
      "default_domain_resolver": "remote_dns", "auto_detect_interface": true
  }
}
EOF_JSON
}

if [ "$ACTION" == "start" ]; then
    source "$CONFIG_FILE"
    validate_env
    cleanup
    clean_firewall

    # --- Orphan Rule Cleanup ---
    # Automatically removes stale Catch-All rules if their parent process is dead.
    if [ -z "$CLIENT_IP" ]; then
        STALE_TABLES=$(ip rule show | grep "iif $PHY_IF" | grep "from all" | grep "lookup" | awk '{print $NF}')
        for tbl in $STALE_TABLES; do
            if [[ "$tbl" == "main" || "$tbl" == "default" || "$tbl" == "local" ]]; then continue; fi
            sid=$((tbl - 1000))
            if [ ! -f "${BASE_DIR}/run/ids/$sid" ]; then
                # No lockfile = Stale rule
                while ip rule del from all iif $PHY_IF lookup $tbl 2>/dev/null; do :; done
            fi
        done
    fi

    # --- VIP Allocation ---
    ACTUAL_VIP=""
    if [ ! -z "$ICMP_RES_IP" ]; then
        if ip route show table local | grep -q "$ICMP_RES_IP"; then
            # Warning only; assume we are overtaking or restarting.
            : 
        fi
        ACTUAL_VIP="$ICMP_RES_IP"
    else
        ACTUAL_VIP=$(find_free_vip)
        if [ "$ACTUAL_VIP" == "NO_FREE_VIP" ]; then
            echo "FATAL: No free IPs available in pool $VIP_PREFIX.x"
            exit 1
        fi
    fi
    echo "$ACTUAL_VIP" > "$VIP_FILE"

    # --- Process Cleanup & ID Assignment ---
    ps -ef | grep "sing-box.*$JSON_CONFIG" | grep -v grep | awk '{print $2}' | xargs -r kill -9
    mkdir -p "${BASE_DIR}/run/ids"
    if [ -f "$ID_FILE" ]; then OLD_ID=$(cat "$ID_FILE"); rm "${BASE_DIR}/run/ids/$OLD_ID" 2>/dev/null; rm "$ID_FILE"; fi

    MY_ID=$(find_free_id)
    if [ "$MY_ID" == "NO_FREE_ID" ]; then echo "Error: No free IDs."; exit 1; fi
    touch "${BASE_DIR}/run/ids/$MY_ID"
    echo "$MY_ID" > "$ID_FILE"
    get_vars "$MY_ID"
    
    generate_json
    
    CHECK_OUT=$("$BINARY" check -c "$JSON_CONFIG" 2>&1)
    if [ $? -ne 0 ]; then echo "FATAL: JSON Invalid"; echo "$CHECK_OUT"; rm "${BASE_DIR}/run/ids/$MY_ID"; exit 1; fi

    # --- Network Setup ---
    ip link delete $TUN_DEV 2>/dev/null || true
    ip tuntap add dev $TUN_DEV mode tun
    ip link set $TUN_DEV mtu 1500
    ip link set $TUN_DEV up
    sleep 0.5

    sysctl -w net.ipv4.ip_forward=1 > /dev/null
    sysctl -w net.ipv4.conf.all.rp_filter=0 > /dev/null
    if [ ! -z "$PHY_IF" ]; then sysctl -w net.ipv4.conf.$PHY_IF.rp_filter=0 > /dev/null; fi
    
    if [ ! -z "$GATEWAY_IP" ]; then ip addr replace $GATEWAY_IP/32 dev $PHY_IF; fi
    ip route replace default dev $TUN_DEV table $TABLE_ID
    ip addr add $TUN_IP/32 dev $TUN_DEV
    
    if [ ! -z "$ACTUAL_VIP" ]; then ip route replace local $ACTUAL_VIP dev lo; fi

    if [ ! -z "$GATEWAY_IP" ]; then ip rule add to $GATEWAY_IP lookup main pref 90 2>/dev/null || true; fi
    if [ ! -z "$ACTUAL_VIP" ]; then ip rule add to $ACTUAL_VIP lookup main pref 91 2>/dev/null || true; fi

    if [ ! -z "$CLIENT_IP" ]; then
        ip rule add from $CLIENT_IP iif $PHY_IF lookup $TABLE_ID pref 100 2>/dev/null || true
    else
        ip rule add from 10.0.0.0/8 iif $PHY_IF lookup $TABLE_ID pref 100 2>/dev/null || true
        ip rule add from 192.168.0.0/16 iif $PHY_IF lookup $TABLE_ID pref 100 2>/dev/null || true
        ip rule add from 172.16.0.0/12 iif $PHY_IF lookup $TABLE_ID pref 100 2>/dev/null || true
    fi
    
    ip rule add from $TUN_IP lookup $TABLE_ID pref 101 2>/dev/null || true
    
    iptables -t nat -A POSTROUTING -o $TUN_DEV -j MASQUERADE
    
    # --- Firewall & MSS Clamping ---
    MSS=${MSS_VAL:-1300}
    iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss $MSS -m comment --comment "$SBG_COMMENT"
    iptables -t mangle -A PREROUTING -i $PHY_IF -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss $MSS -m comment --comment "$SBG_COMMENT"

    if [ ! -z "$ACTUAL_VIP" ]; then
        iptables -I OUTPUT -s $ACTUAL_VIP -p icmp --icmp-type 0 -m mark ! --mark 100 -m comment --comment "$SBG_COMMENT" -j DROP
    elif [ ! -z "$GATEWAY_IP" ]; then
        iptables -I INPUT -d $GATEWAY_IP -p icmp --icmp-type 8 -m comment --comment "$SBG_COMMENT" -j DROP
    fi

    if [ -f "$BINARY_ICMP" ]; then
         "$BINARY_ICMP" -c "$CONFIG_FILE" -i "$PHY_IF" -e "$TUN_DEV" -g "$TUN_IP" -v "$ACTUAL_VIP" -l "$LOG_ICMP" &
         echo $! > "$PID_ICMP"
    fi
    
    exec "$BINARY" run -c "$JSON_CONFIG"

elif [ "$ACTION" == "stop" ]; then
    if [ ! -f "$ID_FILE" ]; then cleanup; exit 0; fi
    MY_ID=$(cat "$ID_FILE"); get_vars "$MY_ID"; source "$CONFIG_FILE"
    
    ACTUAL_VIP=""
    if [ -f "$VIP_FILE" ]; then ACTUAL_VIP=$(cat "$VIP_FILE"); fi
    
    cleanup
    clean_firewall
    
    iptables -t nat -D POSTROUTING -o $TUN_DEV -j MASQUERADE 2>/dev/null
    
    if [ ! -z "$ACTUAL_VIP" ]; then ip route del local $ACTUAL_VIP dev lo 2>/dev/null; fi
    if [ ! -z "$GATEWAY_IP" ]; then ip rule del to $GATEWAY_IP lookup main 2>/dev/null; fi
    if [ ! -z "$ACTUAL_VIP" ]; then ip rule del to $ACTUAL_VIP lookup main 2>/dev/null; fi

    if [ ! -z "$CLIENT_IP" ]; then
        ip rule del from $CLIENT_IP iif $PHY_IF lookup $TABLE_ID 2>/dev/null
    else
        ip rule del from 10.0.0.0/8 iif $PHY_IF lookup $TABLE_ID 2>/dev/null
        ip rule del from 192.168.0.0/16 iif $PHY_IF lookup $TABLE_ID 2>/dev/null
        ip rule del from 172.16.0.0/12 iif $PHY_IF lookup $TABLE_ID 2>/dev/null
    fi
    
    ip rule del from $TUN_IP lookup $TABLE_ID 2>/dev/null
    ip route flush table $TABLE_ID 2>/dev/null
    ip link delete $TUN_DEV 2>/dev/null
    if [ ! -z "$GATEWAY_IP" ]; then ip addr del $GATEWAY_IP/32 dev $PHY_IF 2>/dev/null; fi
    
    rm "$ID_FILE" "$JSON_CONFIG" "$VIP_FILE" "${BASE_DIR}/run/ids/$MY_ID" 2>/dev/null
fi