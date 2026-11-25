#!/usr/bin/env bash
# PROXYALL_LIB=nft.sh
# nftables 独立表管理与 UDP 端口跳跃/端口转发冲突检测，供 sb 与中转模块共用。

# 独立表避免改动系统其他防火墙规则。
NFT_TABLE="${NFT_TABLE:-singboxlite}"
NFT_PERSIST_FILE="${NFT_PERSIST_FILE:-/etc/nftables.d/singboxlite.nft}"
export NFT_TABLE NFT_PERSIST_FILE

_find_pf_udp_conflict_in_range() {
    local start="$1" end="$2"
    local pf_meta="${RELAY_AUX_DIR:-$SINGBOX_DIR}/relay_pf.json"
    [ -f "$pf_meta" ] || return 1
    jq -r --argjson start "$start" --argjson end "$end" '
        to_entries[]
        | (.key | tonumber?) as $port
        | select($port != null and $port >= $start and $port <= $end)
        | select(.value.network == "udp" or .value.network == "tcp+udp")
        | [
            .key,
            (.value.name // "端口转发"),
            (.value.network_display // .value.network // "UDP"),
            ((.value.target_addr // "") + ":" + ((.value.target_port // "") | tostring))
          ]
        | @tsv
    ' "$pf_meta" 2>/dev/null | head -n 1
}

_find_udp_hop_conflict_in_range() {
    local start="$1" end="$2" exclude_tag="${3:-}"
    local conflict="" metadata="${MAIN_METADATA_FILE:-$METADATA_FILE}"
    if [ -f "$metadata" ]; then
        conflict=$(jq -r --argjson start "$start" --argjson end "$end" --arg exclude "$exclude_tag" '
            to_entries[]
            | select(.key != $exclude)
            | select(.value.portHopping)
            | (.value.portHopping | capture("^(?<start>[0-9]+)-(?<end>[0-9]+)$")?) as $range
            | select($range != null)
            | ($range.start | tonumber) as $other_start
            | ($range.end | tonumber) as $other_end
            | select($start <= $other_end and $end >= $other_start)
            | [
                .key,
                (.value.name // .key),
                .value.portHopping,
                ("主HY2/" + (.value.portHoppingMode // "unknown"))
              ]
            | @tsv
        ' "$metadata" 2>/dev/null | head -n 1)
        [ -n "$conflict" ] && { echo "$conflict"; return 0; }
    fi

    local relay_links="${RELAY_AUX_DIR:-$SINGBOX_DIR}/relay_links.json"
    if [ -f "$relay_links" ]; then
        conflict=$(jq -r --argjson start "$start" --argjson end "$end" --arg exclude "$exclude_tag" '
            to_entries[]
            | select(.key != $exclude)
            | select(.value.port_hopping)
            | (.value.port_hopping | capture("^(?<start>[0-9]+)-(?<end>[0-9]+)$")?) as $range
            | select($range != null)
            | ($range.start | tonumber) as $other_start
            | ($range.end | tonumber) as $other_end
            | select($start <= $other_end and $end >= $other_start)
            | [
                .key,
                (.value.node_name // .key),
                .value.port_hopping,
                "中转HY2/nftables"
              ]
            | @tsv
        ' "$relay_links" 2>/dev/null | head -n 1)
        [ -n "$conflict" ] && { echo "$conflict"; return 0; }
    fi

    return 1
}

_nft_ensure_base() {
    command -v nft &>/dev/null || return 1
    nft list table inet "$NFT_TABLE" >/dev/null 2>&1 || nft add table inet "$NFT_TABLE" >/dev/null 2>&1 || return 1
    nft list chain inet "$NFT_TABLE" prerouting >/dev/null 2>&1 || nft add chain inet "$NFT_TABLE" prerouting '{ type nat hook prerouting priority -100; policy accept; }' >/dev/null 2>&1 || return 1
    nft list chain inet "$NFT_TABLE" output >/dev/null 2>&1 || nft add chain inet "$NFT_TABLE" output '{ type nat hook output priority -100; policy accept; }' >/dev/null 2>&1 || return 1
    nft list chain inet "$NFT_TABLE" postrouting >/dev/null 2>&1 || nft add chain inet "$NFT_TABLE" postrouting '{ type nat hook postrouting priority 100; policy accept; }' >/dev/null 2>&1 || return 1
    nft list chain inet "$NFT_TABLE" forward >/dev/null 2>&1 || nft add chain inet "$NFT_TABLE" forward '{ type filter hook forward priority 0; policy accept; }' >/dev/null 2>&1 || return 1
}

# 返回非零表示有规则删除失败；没有匹配规则时返回 0。
_nft_delete_rules_by_comment() {
    local comment="$1"
    local entries chain handle rc=0
    command -v nft &>/dev/null || return 0
    entries=$(nft -a list table inet "$NFT_TABLE" 2>/dev/null | awk -v c="comment \"$comment\"" '
        /^[[:space:]]*chain / { chain=$2 }
        index($0, c) && /# handle / { print chain, $NF }
    ')
    [ -z "$entries" ] && return 0
    while read -r chain handle; do
        if [ -n "$chain" ] && [ -n "$handle" ]; then
            nft delete rule inet "$NFT_TABLE" "$chain" handle "$handle" >/dev/null 2>&1 || rc=1
        fi
    done <<< "$entries"
    return "$rc"
}

_nft_port_expr() {
    local start="$1" end="$2"
    if [ "$start" = "$end" ]; then
        echo "$start"
    else
        echo "${start}-${end}"
    fi
}

_nft_apply_redirect_rule() {
    # 节点事务中先保存 nftables 快照，发布失败时由事务恢复。
    if declare -F _node_tx_nft_snapshot >/dev/null; then _node_tx_nft_snapshot || return 1; fi
    local action="$1" start_port="$2" end_port="$3" target_port="$4" comment="$5"
    if [ "$action" = "delete" ]; then
        _nft_delete_rules_by_comment "$comment"
        return 0
    fi
    _nft_ensure_base || return 1
    _nft_delete_rules_by_comment "$comment"
    nft add rule inet "$NFT_TABLE" prerouting udp dport "$(_nft_port_expr "$start_port" "$end_port")" redirect to ":${target_port}" comment "$comment" >/dev/null 2>&1
}

_nft_can_redirect() {
    local test_port="${1:-65530}" target_port="${2:-65531}" comment="singboxlite-test-redirect-$$"
    _nft_apply_redirect_rule add "$test_port" "$test_port" "$target_port" "$comment" || return 1
    _nft_apply_redirect_rule delete "$test_port" "$test_port" "$target_port" "$comment"
    return 0
}

# 先用临时表名校验导出的规则，再原子替换持久化文件。
_save_nftables_rules() {
    command -v nft &>/dev/null || return 0
    mkdir -p /etc/nftables.d
    local persist_tmp validate_tmp validate_table conf_tmp
    persist_tmp=$(mktemp /etc/nftables.d/.singboxlite.nft.XXXXXX) || return 1
    validate_tmp=$(mktemp /tmp/singboxlite-nft-check.XXXXXX) || {
        rm -f "$persist_tmp"
        return 1
    }
    validate_table="${NFT_TABLE}_check_$$"

    if ! nft list table inet "$NFT_TABLE" > "$persist_tmp" 2>/dev/null; then
        rm -f "$persist_tmp" "$validate_tmp"
        return 1
    fi
    # 用临时表名进行语法检查，避免与当前已加载的同名表冲突。
    sed "0,/^table inet ${NFT_TABLE} /s//table inet ${validate_table} /" "$persist_tmp" > "$validate_tmp"
    if ! nft -c -f "$validate_tmp" >/dev/null 2>&1; then
        rm -f "$persist_tmp" "$validate_tmp"
        return 1
    fi
    rm -f "$validate_tmp"
    mv -f "$persist_tmp" "$NFT_PERSIST_FILE" || return 1

    if [ ! -f /etc/nftables.conf ]; then
        conf_tmp=$(mktemp /etc/.nftables.conf.XXXXXX) || return 1
        printf '%s\n%s\n' '#!/usr/sbin/nft -f' 'include "/etc/nftables.d/*.nft"' > "$conf_tmp" \
            && mv -f "$conf_tmp" /etc/nftables.conf || {
                rm -f "$conf_tmp"
                return 1
            }
    elif ! grep -q 'singboxlite\.nft\|/etc/nftables\.d/\*\.nft' /etc/nftables.conf 2>/dev/null; then
        conf_tmp=$(mktemp /etc/.nftables.conf.XXXXXX) || return 1
        if ! cp -a /etc/nftables.conf "$conf_tmp" || \
           ! printf '%s\n' 'include "/etc/nftables.d/singboxlite.nft"' >> "$conf_tmp" || \
           ! mv -f "$conf_tmp" /etc/nftables.conf; then
            rm -f "$conf_tmp"
            return 1
        fi
    fi
    if command -v systemctl &>/dev/null; then
        systemctl enable nftables >/dev/null 2>&1 || true
    fi
    if command -v rc-update &>/dev/null; then
        rc-update add nftables default >/dev/null 2>&1 || true
    fi
}

_remove_nftables_rules() {
    if command -v nft &>/dev/null; then
        nft delete table inet "$NFT_TABLE" >/dev/null 2>&1 || true
    fi
    rm -f "$NFT_PERSIST_FILE"
    if [ -f /etc/nftables.conf ]; then
        sed -i '\|/etc/nftables.d/singboxlite.nft|d' /etc/nftables.conf 2>/dev/null || true
    fi
}
