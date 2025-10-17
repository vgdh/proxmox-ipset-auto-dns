#!/usr/bin/env bash
# proxmox-ipset-auto-dns
# Automatically updates Proxmox IP sets (ipset) based on DNS names found in comments.
# Author: vgdh
# Requires: pvesh, jq, dig (dnsutils)
set -euo pipefail


# detect --debug flag (only affect printing of executed pvesh commands)
DEBUG=0
for _arg in "$@"; do
    if [[ "$_arg" == "--debug" ]]; then
        DEBUG=1
        break
    fi
done

print_header() {
    local text="$1"
    local width=${2:-$(( ${#text} + 6 ))}   # default width = text length + padding
    if (( width < ${#text} + 4 )); then
        width=$(( ${#text} + 4 ))
    fi

    local border
    border=$(printf '%*s' "$width" '' | tr ' ' '-')

    # compute left/right padding inside the box (2 chars for the side pipes)
    local inner=$(( width - 2 ))
    local pad_left=$(( (inner - ${#text}) / 2 ))
    local pad_right=$(( inner - ${#text} - pad_left ))

    printf '%s\n' "$border"
    printf '|%*s%s%*s|\n' "$pad_left" '' "$text" "$pad_right" ''
    printf '%s\n' "$border"
}

run_pvesh() {
    # build the pvesh command
    local cmd=(pvesh "$@")

    # print the pvesh command (shell-escaped) to stderr only when --debug was passed
    if [[ "${DEBUG:-0}" -eq 1 ]]; then
        printf '+' >&2
        for a in "${cmd[@]}"; do printf ' %q' "$a" >&2; done
        printf '\n' >&2
    fi

    # execute and return stdout only (keep previous behavior of swallowing stderr)
    "${cmd[@]}" --output-format json 2>/dev/null || true
}

safe_get() {
    # $1 = pvesh path
    run_pvesh get "$1"
}

safe_set() {
    # pass through any args
    run_pvesh set "$@"
}

safe_create() {
    # pass through any args (path + flags)
    run_pvesh create "$@"
}

safe_delete() {
    # pass through any args
    run_pvesh delete "$@"
}

update_ipset() {
    local pvesh_path="$1"
    local ipset_name="$2"
    local comment="$3"


    
    # Extract domains from comment (expects comment like "auto_dns_domain1_domain2")
    if [[ "$comment" =~ ^auto_dns_(.*)$ ]]; then
        local domains="${BASH_REMATCH[1]}"

        # display domains comma-separated for readability
        local parsed_display="${domains//_/, }"
        echo "  - Found auto_dns comment. Domains: ${parsed_display:-<none>}"

        # Parse domains: split on underscore only
        local domain_list=()
        if [[ -n "$domains" ]]; then
            IFS='_' read -r -a domain_list <<<"$domains"
            for i in "${!domain_list[@]}"; do
                # trim whitespace just in case
                domain_list[i]="${domain_list[i]#"${domain_list[i]%%[![:space:]]*}"}"
                domain_list[i]="${domain_list[i]%"${domain_list[i]##*[![:space:]]}"}"
            done
        fi



        # Resolve each domain separately, show results per-domain, and map IP -> first-resolving domain
        declare -A ip2domain=()
        local all_ips=()
        for d in "${domain_list[@]}"; do
            echo "  - Resolving domain: $d"
            domain_ips=()
            while IFS= read -r ip; do
                ip="${ip%%[[:space:]]}"   # trim trailing newline/space
                ip="${ip##[[:space:]]}"   # trim leading
                if [[ -n "$ip" ]]; then
                    domain_ips+=("$ip")
                    if [[ -z "${ip2domain[$ip]+x}" ]]; then
                        ip2domain[$ip]="$d"
                        all_ips+=("$ip")
                    fi
                fi
            done < <({ dig +short A "$d" 2>/dev/null; dig +short AAAA "$d" 2>/dev/null; } \
                     | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}|([0-9A-Fa-f:]+:+[0-9A-Fa-f:]*)' \
                     | grep -Ev '^[[:space:]]*$')


            if [[ ${#domain_ips[@]} -gt 0 ]]; then
                echo "  - Resolved for $d: ${domain_ips[*]}"
            else
                echo "  - No IPs resolved for $d"
            fi
        done

        if [[ ${#all_ips[@]} -gt 0 ]]; then
            echo "  - Total unique IPs to add: ${#all_ips[@]}"

            # Get existing IP set data
            local ipset_data
            ipset_data=$(safe_get "$pvesh_path/$ipset_name" || true)

            # Handle empty / non-JSON responses gracefully
            local cidr_list
            if [[ -z "${ipset_data//[$'\t\r\n ']}" ]] || [[ "$ipset_data" == "null" ]] || [[ ! "$ipset_data" =~ ^[\[\{] ]]; then
                cidr_list=""
            else
                if echo "$ipset_data" | jq -e 'type == "array"' >/dev/null 2>&1; then
                    cidr_list=$(jq -r '.[].cidr' <<<"$ipset_data" 2>/dev/null || true)
                else
                    cidr_list=$(jq -r '.cidr' <<<"$ipset_data" 2>/dev/null || true)
                fi
            fi

            # Clear existing IPs
            echo "  - Clearing existing IPs"
            for cidr in $cidr_list; do
                safe_delete "$pvesh_path/$ipset_name/$cidr"
            done

            # Add new IPs with per-domain comment (domain name)
            echo "  - Adding new IPs:"
            for ip in "${all_ips[@]}"; do
                local dom="${ip2domain[$ip]}"
                echo "      Adding IP: $ip (domain: $dom)"
                safe_create "$pvesh_path/$ipset_name" --cidr "$ip" --comment "$dom"
            done
            echo
        else
            echo "  - No IPs resolved for any domains: $domains"
        fi
    fi
}

print_ipsets() {
    local json="$1"; shift
    local origin="$1"; shift
    local pvesh_path
    pvesh_path=$(echo "$origin" | awk -F'/ipset' '{print $1}')

    if [[ -z "$json" || "$json" == "null" ]]; then
        return
    fi

    # determine number of ipset items; arrays -> length, single object -> 1, else 0
    local count
    count=$(echo "$json" | jq -r 'if type=="array" then length elif type=="object" then 1 else 0 end' 2>/dev/null || echo 0)
    if [[ -z "$count" || "$count" -eq 0 ]]; then
        return
    fi

    echo "Found IP sets at $origin:"
    # If array, iterate; if single object, convert to array
    echo "$json" | jq -c 'if type=="array" then .[] else . end' 2>/dev/null | while read -r item; do
        name=$(jq -r '.name // .ipset // .id // empty' <<<"$item")
        comment=$(jq -r '.comment // empty' <<<"$item")
        echo "  IPset name: ${name:-<unnamed>}"
        
        # print all fields for debugging (only when --debug)
        if [[ "${DEBUG:-0}" -eq 1 ]]; then
            jq -r 'to_entries[] | "\(.key): \(.value)"' <<<"$item" 2>/dev/null
            echo
        fi
        update_ipset "$pvesh_path/ipset" "$name" "$comment"
    done
}

print_header "============== Gathering cluster-level IPsets =============="
cluster_ipsets=$(safe_get /cluster/firewall/ipset)
print_ipsets "$cluster_ipsets" "cluster/firewall/ipset"


print_header "============== Gathering NODE-level IPsets =============="
nodes_json=$(safe_get /nodes)
nodes=$(jq -r '.[].node // .[] | select(.)' <<<"$nodes_json" 2>/dev/null || true)
if [[ -z "$nodes" ]]; then
    # fallback: if nodes_json is a single object with "node"
    nodes=$(jq -r '.node // empty' <<<"$nodes_json" 2>/dev/null || true)
fi


for node in $nodes; do
    # node-level ipsets (if supported)
    node_ipsets=$(safe_get /nodes/"$node"/firewall/ipset)
    print_ipsets "$node_ipsets" "nodes/$node/firewall/ipset"

    print_header "============== Node: $node. Gathering VM-level IPsets =============="
    qemus=$(safe_get /nodes/"$node"/qemu)
    vmids=$(jq -r '.[].vmid // .[] | select(.)' <<<"$qemus" 2>/dev/null || true)
    if [[ -n "$vmids" ]]; then
        for vmid in $vmids; do
            vm_ipsets=$(safe_get /nodes/"$node"/qemu/"$vmid"/firewall/ipset)
            print_ipsets "$vm_ipsets" "nodes/$node/qemu/$vmid/firewall/ipset"
        done
    fi

    print_header "============== Node: $node. Gathering LXC-level IPsets =============="
    lxcs=$(safe_get /nodes/"$node"/lxc)
    ctids=$(jq -r '.[].vmid // .[] | select(.)' <<<"$lxcs" 2>/dev/null || true)
    if [[ -n "$ctids" ]]; then
        for ct in $ctids; do
            ct_ipsets=$(safe_get /nodes/"$node"/lxc/"$ct"/firewall/ipset)
            print_ipsets "$ct_ipsets" "nodes/$node/lxc/$ct/firewall/ipset"
        done
    fi

    echo
done

echo "IP set update completed."