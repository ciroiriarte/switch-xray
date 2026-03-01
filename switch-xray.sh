#!/bin/bash
#
# Script Name: switch-xray.sh
# Description: Collects and displays switch port information via SNMP, including
#              interface status, speed, MTU, LAG membership, LLDP neighbors, and
#              VLAN configuration. Supports multiple switches, cross-switch LAG
#              detection (ESI-LAG/MCLAG), and multiple output formats including
#              network topology diagrams.
#
#              This is the switch-side counterpart to nic-xray, designed for
#              implementation documentation and troubleshooting snapshots.
#
# Author: Ciro Iriarte <ciro.iriarte+software@gmail.com>
# Created: 2026-03-01
#
# Requirements:
#   - Requires: snmpbulkwalk or snmpwalk, snmpget (net-snmp package)
#   - Optional: graphviz (dot command) for svg/png output
#
# Change Log:
#   - 2026-03-01: v1.0.0 - Initial version
#
# Version: 1.0.0

SCRIPT_VERSION="1.0.0"
SCRIPT_NAME="switch-xray"
SCRIPT_YEAR="2026"

# LOCALE setup, we expect output in English for proper parsing
LC_ALL=C
export LC_ALL

# --- Default Configuration ---
declare -a SWITCH_TARGETS
SNMP_VERSION="2c"
SNMP_COMMUNITY=""
SNMP_USER=""
SNMP_SEC_LEVEL=""
SNMP_AUTH_PROTO=""
SNMP_AUTH_PASS=""
SNMP_PRIV_PROTO=""
SNMP_PRIV_PASS=""
SNMP_TIMEOUT=5
SNMP_RETRIES=1
FORCE_PLATFORM=""
CONFIG_FILE=""

# Display options
SHOW_LLDP_DETAIL=false
SHOW_VLANS=false
SHOW_MODEL=false
FIELD_SEP=""
OUTPUT_FORMAT="table"
USE_COLOR=true
FILTER_STATUS=""
FILTER_PORT=""
GROUP_SWITCH=false
DIAGRAM_STYLE="switch"
DIAGRAM_OUTPUT_FILE=""

# --- SNMP OID Constants ---
OID_SYSNAME=".1.3.6.1.2.1.1.5.0"
OID_SYSDESCR=".1.3.6.1.2.1.1.1.0"
OID_IFNAME=".1.3.6.1.2.1.31.1.1.1.1"
OID_IFDESCR=".1.3.6.1.2.1.2.2.1.2"
OID_IFTYPE=".1.3.6.1.2.1.2.2.1.3"
OID_IFMTU=".1.3.6.1.2.1.2.2.1.4"
OID_IFSPEED=".1.3.6.1.2.1.2.2.1.5"
OID_IFHIGHSPEED=".1.3.6.1.2.1.31.1.1.1.15"
OID_IFADMINSTATUS=".1.3.6.1.2.1.2.2.1.7"
OID_IFOPERSTATUS=".1.3.6.1.2.1.2.2.1.8"
OID_IFALIAS=".1.3.6.1.2.1.31.1.1.1.18"

# LLDP-MIB
OID_LLDP_LOC_PORTID=".1.0.8802.1.1.2.1.3.7.1.3"
OID_LLDP_LOC_PORTID_SUBTYPE=".1.0.8802.1.1.2.1.3.7.1.2"
OID_LLDP_REM_SYSNAME=".1.0.8802.1.1.2.1.4.1.1.9"
OID_LLDP_REM_PORTID=".1.0.8802.1.1.2.1.4.1.1.7"
OID_LLDP_REM_PORTID_SUBTYPE=".1.0.8802.1.1.2.1.4.1.1.6"
OID_LLDP_REM_CHASSISID=".1.0.8802.1.1.2.1.4.1.1.5"
OID_LLDP_REM_SYSDESC=".1.0.8802.1.1.2.1.4.1.1.10"

# Q-BRIDGE-MIB (VLANs)
OID_DOT1Q_PVID=".1.3.6.1.2.1.17.7.1.4.5.1.1"
OID_DOT1Q_VLAN_STATIC_NAME=".1.3.6.1.2.1.17.7.1.4.3.1.1"
OID_DOT1D_BASEPORT_IFINDEX=".1.3.6.1.2.1.17.1.4.1.2"

# IF-MIB ifStackTable (LAG membership)
OID_IFSTACK_STATUS=".1.3.6.1.2.1.31.1.2.1.3"

# Entity MIB (chassis model)
OID_ENT_PHYSICAL_MODEL=".1.3.6.1.2.1.47.1.1.1.1.13"
OID_ENT_PHYSICAL_CLASS=".1.3.6.1.2.1.47.1.1.1.1.5"

# --- Global Data Arrays ---
declare -a DATA_SWITCH_NAME DATA_PORT_NAME DATA_LAG DATA_DESCRIPTION
declare -a DATA_ADMIN DATA_OPER DATA_SPEED DATA_MTU
declare -a DATA_LLDP_NEIGHBOR DATA_REMOTE_PORT DATA_LLDP_DESC
declare -a DATA_PVID DATA_MODEL DATA_IFINDEX
declare -a DATA_ADMIN_COLOR DATA_OPER_COLOR DATA_SPEED_COLOR DATA_LAG_COLOR
ROW_COUNT=0

# Cross-switch LAG tracking
declare -A XLAG_GROUP

# --- Helper Functions ---

strip_ansi() {
    echo -e "$1" | sed -r 's/\x1B\[[0-9;]*[mK]//g'
}

pad_color() {
    local TEXT="$1"
    local WIDTH="$2"
    local STRIPPED
    STRIPPED=$(strip_ansi "$TEXT")
    local PAD=$((WIDTH - ${#STRIPPED}))
    printf "%b%*s" "$TEXT" "$PAD" ""
}

json_escape() {
    local STR="$1"
    STR="${STR//\\/\\\\}"
    STR="${STR//\"/\\\"}"
    printf '%s' "$STR"
}

max_width() {
    local HEADER="$1"
    shift
    local MAX=${#HEADER}
    for VAL in "$@"; do
        (( ${#VAL} > MAX )) && MAX=${#VAL}
    done
    echo "$MAX"
}

# --- Progress Spinner ---
SPINNER_PID=""

spinner_start() {
    local MSG="$1"
    {
        local CHARS='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
        local I=0
        while true; do
            printf '\r  %s %s' "${CHARS:I%10:1}" "$MSG" >&2
            ((I++))
            sleep 0.1
        done
    } &
    SPINNER_PID=$!
    disown "$SPINNER_PID" 2>/dev/null
}

spinner_stop() {
    if [[ -n "$SPINNER_PID" ]]; then
        kill "$SPINNER_PID" 2>/dev/null
        wait "$SPINNER_PID" 2>/dev/null
        SPINNER_PID=""
        printf '\r\033[K' >&2
    fi
}

# Ensure spinner cleanup on exit
trap 'spinner_stop' EXIT

# --- Color Helpers ---
colorize_speed() {
    local RAW="$1"

    if [[ "$USE_COLOR" != true ]]; then
        printf "%s" "$RAW"
        return
    fi

    local NUM="${RAW%%[^0-9]*}"
    local COLOR

    if [[ "$NUM" =~ ^[0-9]+$ ]]; then
        if (( NUM >= 200000 )); then
            COLOR="${BOLD_MAGENTA}"  # 200G+
        elif (( NUM >= 100000 )); then
            COLOR="${BOLD_CYAN}"     # 100G
        elif (( NUM >= 25000 )); then
            COLOR="${BOLD_WHITE}"    # 25G / 40G / 50G
        elif (( NUM >= 10000 )); then
            COLOR="${BOLD_GREEN}"    # 10G
        elif (( NUM >= 1000 )); then
            COLOR="${YELLOW}"        # 1G
        else
            COLOR="${RED}"           # < 1G
        fi
    else
        COLOR="${RED}"               # N/A or unknown
    fi

    printf "%b%s%b" "$COLOR" "$RAW" "$RESET_COLOR"
}

colorize_status() {
    local STATUS="$1"
    local TYPE="$2"  # admin or oper

    if [[ "$USE_COLOR" != true ]]; then
        printf "%s" "$STATUS"
        return
    fi

    if [[ "$STATUS" == "up" ]]; then
        printf "%b%s%b" "$GREEN" "$STATUS" "$RESET_COLOR"
    elif [[ "$STATUS" == "down" && "$TYPE" == "admin" ]]; then
        printf "%b%s%b" "$YELLOW" "$STATUS" "$RESET_COLOR"
    else
        printf "%b%s%b" "$RED" "$STATUS" "$RESET_COLOR"
    fi
}

colorize_lag() {
    local LAG="$1"

    if [[ "$USE_COLOR" != true ]]; then
        printf "%s" "$LAG"
        return
    fi

    if [[ "$LAG" == "-" || "$LAG" == "N/A" ]]; then
        printf "%s" "$LAG"
    elif [[ "$LAG" == *"[ESI]"* || "$LAG" == *"[MCLAG]"* ]]; then
        printf "%b%s%b" "$BOLD_CYAN" "$LAG" "$RESET_COLOR"
    elif [[ "$LAG" == *"members"* ]]; then
        printf "%b%s%b" "$BOLD_WHITE" "$LAG" "$RESET_COLOR"
    else
        printf "%b%s%b" "$BOLD_BLUE" "$LAG" "$RESET_COLOR"
    fi
}

# --- Speed Formatting ---
format_speed() {
    local MBPS="$1"
    if [[ -z "$MBPS" || "$MBPS" == "0" ]]; then
        printf "N/A"
        return
    fi
    if (( MBPS >= 1000 )); then
        local GBPS=$((MBPS / 1000))
        printf "%dG" "$GBPS"
    else
        printf "%dM" "$MBPS"
    fi
}

# --- Config File Loading ---
load_config() {
    local FILE="$1"
    [[ ! -f "$FILE" ]] && return 1

    # Warn if world-readable
    local PERMS
    PERMS=$(stat -c '%a' "$FILE" 2>/dev/null)
    if [[ -n "$PERMS" && "${PERMS: -1}" != "0" ]]; then
        echo "Warning: Config file '$FILE' is world-readable (mode $PERMS). It may contain credentials." >&2
    fi

    local KEY VALUE
    while IFS='=' read -r KEY VALUE || [[ -n "$KEY" ]]; do
        # Skip comments and empty lines
        KEY=$(echo "$KEY" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        [[ -z "$KEY" || "$KEY" == \#* ]] && continue
        VALUE=$(echo "$VALUE" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | sed 's/^"//;s/"$//' | sed "s/^'//;s/'$//")

        case "$KEY" in
            switch)          SWITCH_TARGETS+=("$VALUE") ;;
            snmp_version)    [[ -z "$SNMP_VERSION_CLI" ]] && SNMP_VERSION="$VALUE" ;;
            community)       [[ -z "$SNMP_COMMUNITY_CLI" ]] && SNMP_COMMUNITY="$VALUE" ;;
            snmp_user)       [[ -z "$SNMP_USER_CLI" ]] && SNMP_USER="$VALUE" ;;
            sec_level)       [[ -z "$SNMP_SEC_LEVEL_CLI" ]] && SNMP_SEC_LEVEL="$VALUE" ;;
            auth_proto)      [[ -z "$SNMP_AUTH_PROTO_CLI" ]] && SNMP_AUTH_PROTO="$VALUE" ;;
            auth_pass)       [[ -z "$SNMP_AUTH_PASS_CLI" ]] && SNMP_AUTH_PASS="$VALUE" ;;
            priv_proto)      [[ -z "$SNMP_PRIV_PROTO_CLI" ]] && SNMP_PRIV_PROTO="$VALUE" ;;
            priv_pass)       [[ -z "$SNMP_PRIV_PASS_CLI" ]] && SNMP_PRIV_PASS="$VALUE" ;;
            timeout)         SNMP_TIMEOUT="$VALUE" ;;
            retries)         SNMP_RETRIES="$VALUE" ;;
            platform)        [[ -z "$FORCE_PLATFORM" ]] && FORCE_PLATFORM="$VALUE" ;;
        esac
    done < "$FILE"
    return 0
}

# --- Environment Variable Loading ---
load_env_vars() {
    [[ -n "$SWITCH_XRAY_SWITCHES" && ${#SWITCH_TARGETS[@]} -eq 0 ]] && {
        IFS=',' read -ra ENV_SWITCHES <<< "$SWITCH_XRAY_SWITCHES"
        for S in "${ENV_SWITCHES[@]}"; do
            S=$(echo "$S" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            [[ -n "$S" ]] && SWITCH_TARGETS+=("$S")
        done
    }
    [[ -n "$SWITCH_XRAY_COMMUNITY" && -z "$SNMP_COMMUNITY" ]] && SNMP_COMMUNITY="$SWITCH_XRAY_COMMUNITY"
    [[ -n "$SWITCH_XRAY_USER" && -z "$SNMP_USER" ]] && SNMP_USER="$SWITCH_XRAY_USER"
    [[ -n "$SWITCH_XRAY_SEC_LEVEL" && -z "$SNMP_SEC_LEVEL" ]] && SNMP_SEC_LEVEL="$SWITCH_XRAY_SEC_LEVEL"
    [[ -n "$SWITCH_XRAY_AUTH_PROTO" && -z "$SNMP_AUTH_PROTO" ]] && SNMP_AUTH_PROTO="$SWITCH_XRAY_AUTH_PROTO"
    [[ -n "$SWITCH_XRAY_AUTH_PASS" && -z "$SNMP_AUTH_PASS" ]] && SNMP_AUTH_PASS="$SWITCH_XRAY_AUTH_PASS"
    [[ -n "$SWITCH_XRAY_PRIV_PROTO" && -z "$SNMP_PRIV_PROTO" ]] && SNMP_PRIV_PROTO="$SWITCH_XRAY_PRIV_PROTO"
    [[ -n "$SWITCH_XRAY_PRIV_PASS" && -z "$SNMP_PRIV_PASS" ]] && SNMP_PRIV_PASS="$SWITCH_XRAY_PRIV_PASS"
    [[ -n "$SWITCH_XRAY_VERSION" && -z "$SNMP_VERSION_CLI" ]] && SNMP_VERSION="$SWITCH_XRAY_VERSION"
}

# --- SNMP Helper Functions ---
build_snmp_args() {
    local HOST="$1"
    local -n _ARGS=$2

    _ARGS=(-Oqn -t "$SNMP_TIMEOUT" -r "$SNMP_RETRIES")

    if [[ "$SNMP_VERSION" == "3" ]]; then
        _ARGS+=(-v3 -u "$SNMP_USER")
        case "$SNMP_SEC_LEVEL" in
            noAuthNoPriv) _ARGS+=(-l noAuthNoPriv) ;;
            authNoPriv)   _ARGS+=(-l authNoPriv -a "$SNMP_AUTH_PROTO" -A "$SNMP_AUTH_PASS") ;;
            authPriv)     _ARGS+=(-l authPriv -a "$SNMP_AUTH_PROTO" -A "$SNMP_AUTH_PASS" -x "$SNMP_PRIV_PROTO" -X "$SNMP_PRIV_PASS") ;;
        esac
    else
        _ARGS+=(-v2c -c "$SNMP_COMMUNITY")
    fi

    _ARGS+=("$HOST")
}

snmp_walk() {
    local HOST="$1"
    local OID="$2"
    local -a ARGS
    build_snmp_args "$HOST" ARGS

    if command -v snmpbulkwalk &>/dev/null; then
        snmpbulkwalk "${ARGS[@]}" "$OID" 2>/dev/null
    else
        snmpwalk "${ARGS[@]}" "$OID" 2>/dev/null
    fi
}

snmp_get() {
    local HOST="$1"
    local OID="$2"
    local -a ARGS
    build_snmp_args "$HOST" ARGS

    snmpget "${ARGS[@]}" "$OID" 2>/dev/null
}

snmp_test_connectivity() {
    local HOST="$1"
    local RESULT
    RESULT=$(snmp_get "$HOST" "$OID_SYSNAME")
    [[ -n "$RESULT" ]]
}

# --- Platform Detection ---
detect_platform() {
    local HOST="$1"
    local SYSDESCR
    SYSDESCR=$(snmp_get "$HOST" "$OID_SYSDESCR")

    if [[ -n "$FORCE_PLATFORM" ]]; then
        echo "$FORCE_PLATFORM"
        return
    fi

    case "$SYSDESCR" in
        *[Jj]uniper*|*[Jj]unos*|*JUNOS*)  echo "junos" ;;
        *[Aa]rista*)                        echo "arista" ;;
        *[Cc]umulus*)                       echo "cumulus" ;;
        *[Cc]isco*|*NX-OS*|*IOS*)          echo "cisco" ;;
        *)                                  echo "generic" ;;
    esac
}

# --- Interface Collection ---
collect_interfaces() {
    local HOST="$1"

    # Associative arrays for this switch's data
    declare -gA IF_NAME IF_DESCR IF_TYPE IF_MTU IF_SPEED IF_ADMIN IF_OPER IF_ALIAS

    local LINE OID_SUFFIX VALUE

    # ifName
    while IFS= read -r LINE; do
        [[ -z "$LINE" ]] && continue
        OID_SUFFIX="${LINE%% *}"
        OID_SUFFIX="${OID_SUFFIX##*.}"
        VALUE="${LINE#* }"
        VALUE="${VALUE#\"}"
        VALUE="${VALUE%\"}"
        IF_NAME[$OID_SUFFIX]="$VALUE"
    done < <(snmp_walk "$HOST" "$OID_IFNAME")

    # ifDescr
    while IFS= read -r LINE; do
        [[ -z "$LINE" ]] && continue
        OID_SUFFIX="${LINE%% *}"
        OID_SUFFIX="${OID_SUFFIX##*.}"
        VALUE="${LINE#* }"
        VALUE="${VALUE#\"}"
        VALUE="${VALUE%\"}"
        IF_DESCR[$OID_SUFFIX]="$VALUE"
    done < <(snmp_walk "$HOST" "$OID_IFDESCR")

    # ifType
    while IFS= read -r LINE; do
        [[ -z "$LINE" ]] && continue
        OID_SUFFIX="${LINE%% *}"
        OID_SUFFIX="${OID_SUFFIX##*.}"
        VALUE="${LINE#* }"
        IF_TYPE[$OID_SUFFIX]="$VALUE"
    done < <(snmp_walk "$HOST" "$OID_IFTYPE")

    # ifMtu
    while IFS= read -r LINE; do
        [[ -z "$LINE" ]] && continue
        OID_SUFFIX="${LINE%% *}"
        OID_SUFFIX="${OID_SUFFIX##*.}"
        VALUE="${LINE#* }"
        IF_MTU[$OID_SUFFIX]="$VALUE"
    done < <(snmp_walk "$HOST" "$OID_IFMTU")

    # ifHighSpeed (Mbps)
    while IFS= read -r LINE; do
        [[ -z "$LINE" ]] && continue
        OID_SUFFIX="${LINE%% *}"
        OID_SUFFIX="${OID_SUFFIX##*.}"
        VALUE="${LINE#* }"
        IF_SPEED[$OID_SUFFIX]="$VALUE"
    done < <(snmp_walk "$HOST" "$OID_IFHIGHSPEED")

    # ifAdminStatus (1=up, 2=down, 3=testing)
    while IFS= read -r LINE; do
        [[ -z "$LINE" ]] && continue
        OID_SUFFIX="${LINE%% *}"
        OID_SUFFIX="${OID_SUFFIX##*.}"
        VALUE="${LINE#* }"
        case "$VALUE" in
            1) IF_ADMIN[$OID_SUFFIX]="up" ;;
            2) IF_ADMIN[$OID_SUFFIX]="down" ;;
            *) IF_ADMIN[$OID_SUFFIX]="testing" ;;
        esac
    done < <(snmp_walk "$HOST" "$OID_IFADMINSTATUS")

    # ifOperStatus (1=up, 2=down, ...)
    while IFS= read -r LINE; do
        [[ -z "$LINE" ]] && continue
        OID_SUFFIX="${LINE%% *}"
        OID_SUFFIX="${OID_SUFFIX##*.}"
        VALUE="${LINE#* }"
        case "$VALUE" in
            1) IF_OPER[$OID_SUFFIX]="up" ;;
            2) IF_OPER[$OID_SUFFIX]="down" ;;
            *) IF_OPER[$OID_SUFFIX]="down" ;;
        esac
    done < <(snmp_walk "$HOST" "$OID_IFOPERSTATUS")

    # ifAlias (description)
    while IFS= read -r LINE; do
        [[ -z "$LINE" ]] && continue
        OID_SUFFIX="${LINE%% *}"
        OID_SUFFIX="${OID_SUFFIX##*.}"
        VALUE="${LINE#* }"
        VALUE="${VALUE#\"}"
        VALUE="${VALUE%\"}"
        IF_ALIAS[$OID_SUFFIX]="$VALUE"
    done < <(snmp_walk "$HOST" "$OID_IFALIAS")
}

# --- Interface Filtering ---
filter_interfaces_junos() {
    local -n _FILTERED=$1

    for IFIDX in "${!IF_NAME[@]}"; do
        local NAME="${IF_NAME[$IFIDX]}"
        local TYPE="${IF_TYPE[$IFIDX]}"

        # Keep only ethernetCsmacd (6) and ieee8023adLag (161)
        [[ "$TYPE" != "6" && "$TYPE" != "161" ]] && continue

        # Keep physical ports and LAG interfaces
        case "$NAME" in
            xe-*|et-*|ge-*|mge-*|ae[0-9]*)
                # Exclude subinterfaces with .32767 (internal)
                [[ "$NAME" == *".32767" ]] && continue
                # Exclude unit subinterfaces (e.g., xe-0/0/0.0)
                [[ "$NAME" == *"."* ]] && continue
                _FILTERED+=("$IFIDX")
                ;;
        esac
    done
}

filter_interfaces_arista() {
    local -n _FILTERED=$1

    for IFIDX in "${!IF_NAME[@]}"; do
        local NAME="${IF_NAME[$IFIDX]}"
        local TYPE="${IF_TYPE[$IFIDX]}"

        [[ "$TYPE" != "6" && "$TYPE" != "161" ]] && continue

        case "$NAME" in
            Ethernet*|Port-Channel*)
                [[ "$NAME" == *"."* ]] && continue
                _FILTERED+=("$IFIDX")
                ;;
        esac
    done
}

filter_interfaces_generic() {
    local -n _FILTERED=$1

    for IFIDX in "${!IF_NAME[@]}"; do
        local TYPE="${IF_TYPE[$IFIDX]}"

        # Keep only ethernetCsmacd (6) and ieee8023adLag (161)
        [[ "$TYPE" != "6" && "$TYPE" != "161" ]] && continue

        local NAME="${IF_NAME[$IFIDX]}"
        # Exclude subinterfaces
        [[ "$NAME" == *"."* ]] && continue

        _FILTERED+=("$IFIDX")
    done
}

# --- LLDP Collection ---
collect_lldp() {
    local HOST="$1"

    declare -gA LLDP_LOC_PORTID LLDP_LOC_PORTID_SUBTYPE
    declare -gA LLDP_REM_SYSNAME LLDP_REM_PORTID LLDP_REM_CHASSISID LLDP_REM_SYSDESC

    local LINE OID_PART VALUE

    # lldpLocPortId: maps localPortNum -> ifIndex (or port name)
    while IFS= read -r LINE; do
        [[ -z "$LINE" ]] && continue
        OID_PART="${LINE%% *}"
        local LOCPORTNUM="${OID_PART##*.}"
        VALUE="${LINE#* }"
        VALUE="${VALUE#\"}"
        VALUE="${VALUE%\"}"
        LLDP_LOC_PORTID[$LOCPORTNUM]="$VALUE"
    done < <(snmp_walk "$HOST" "$OID_LLDP_LOC_PORTID")

    # lldpLocPortIdSubtype
    while IFS= read -r LINE; do
        [[ -z "$LINE" ]] && continue
        OID_PART="${LINE%% *}"
        local LOCPORTNUM="${OID_PART##*.}"
        VALUE="${LINE#* }"
        LLDP_LOC_PORTID_SUBTYPE[$LOCPORTNUM]="$VALUE"
    done < <(snmp_walk "$HOST" "$OID_LLDP_LOC_PORTID_SUBTYPE")

    # lldpRemSysName: index is timeMark.localPortNum.remIndex
    while IFS= read -r LINE; do
        [[ -z "$LINE" ]] && continue
        OID_PART="${LINE%% *}"
        # Extract localPortNum from the triple index
        local TRIPLE="${OID_PART##*$OID_LLDP_REM_SYSNAME.}"
        local LOCPORTNUM
        LOCPORTNUM=$(echo "$TRIPLE" | cut -d. -f2)
        VALUE="${LINE#* }"
        VALUE="${VALUE#\"}"
        VALUE="${VALUE%\"}"
        LLDP_REM_SYSNAME[$LOCPORTNUM]="$VALUE"
    done < <(snmp_walk "$HOST" "$OID_LLDP_REM_SYSNAME")

    # lldpRemPortId
    while IFS= read -r LINE; do
        [[ -z "$LINE" ]] && continue
        OID_PART="${LINE%% *}"
        local TRIPLE="${OID_PART##*$OID_LLDP_REM_PORTID.}"
        local LOCPORTNUM
        LOCPORTNUM=$(echo "$TRIPLE" | cut -d. -f2)
        VALUE="${LINE#* }"
        VALUE="${VALUE#\"}"
        VALUE="${VALUE%\"}"
        LLDP_REM_PORTID[$LOCPORTNUM]="$VALUE"
    done < <(snmp_walk "$HOST" "$OID_LLDP_REM_PORTID")

    # lldpRemChassisId
    while IFS= read -r LINE; do
        [[ -z "$LINE" ]] && continue
        OID_PART="${LINE%% *}"
        local TRIPLE="${OID_PART##*$OID_LLDP_REM_CHASSISID.}"
        local LOCPORTNUM
        LOCPORTNUM=$(echo "$TRIPLE" | cut -d. -f2)
        VALUE="${LINE#* }"
        VALUE="${VALUE#\"}"
        VALUE="${VALUE%\"}"
        LLDP_REM_CHASSISID[$LOCPORTNUM]="$VALUE"
    done < <(snmp_walk "$HOST" "$OID_LLDP_REM_CHASSISID")

    # lldpRemSysDescr
    while IFS= read -r LINE; do
        [[ -z "$LINE" ]] && continue
        OID_PART="${LINE%% *}"
        local TRIPLE="${OID_PART##*$OID_LLDP_REM_SYSDESC.}"
        local LOCPORTNUM
        LOCPORTNUM=$(echo "$TRIPLE" | cut -d. -f2)
        VALUE="${LINE#* }"
        VALUE="${VALUE#\"}"
        VALUE="${VALUE%\"}"
        LLDP_REM_SYSDESC[$LOCPORTNUM]="$VALUE"
    done < <(snmp_walk "$HOST" "$OID_LLDP_REM_SYSDESC")
}

# --- VLAN Collection ---
collect_vlans() {
    local HOST="$1"

    declare -gA BRIDGE_PORT_IFINDEX VLAN_PVID VLAN_NAME

    local LINE OID_PART VALUE

    # dot1dBasePortIfIndex: bridge port number -> ifIndex
    while IFS= read -r LINE; do
        [[ -z "$LINE" ]] && continue
        OID_PART="${LINE%% *}"
        local BPORT="${OID_PART##*.}"
        VALUE="${LINE#* }"
        BRIDGE_PORT_IFINDEX[$BPORT]="$VALUE"
    done < <(snmp_walk "$HOST" "$OID_DOT1D_BASEPORT_IFINDEX")

    # dot1qPvid: bridge port -> PVID
    while IFS= read -r LINE; do
        [[ -z "$LINE" ]] && continue
        OID_PART="${LINE%% *}"
        local BPORT="${OID_PART##*.}"
        VALUE="${LINE#* }"
        VLAN_PVID[$BPORT]="$VALUE"
    done < <(snmp_walk "$HOST" "$OID_DOT1Q_PVID")

    # dot1qVlanStaticName: VLAN ID -> name
    while IFS= read -r LINE; do
        [[ -z "$LINE" ]] && continue
        OID_PART="${LINE%% *}"
        local VID="${OID_PART##*.}"
        VALUE="${LINE#* }"
        VALUE="${VALUE#\"}"
        VALUE="${VALUE%\"}"
        VLAN_NAME[$VID]="$VALUE"
    done < <(snmp_walk "$HOST" "$OID_DOT1Q_VLAN_STATIC_NAME")
}

# --- LAG Collection ---
collect_lag() {
    local HOST="$1"

    declare -gA LAG_MEMBERS LAG_PARENT

    local LINE OID_PART VALUE

    # ifStackTable: higherLayer.lowerLayer -> status
    # status=1 means active relationship
    while IFS= read -r LINE; do
        [[ -z "$LINE" ]] && continue
        OID_PART="${LINE%% *}"
        VALUE="${LINE#* }"

        # Only care about active entries
        [[ "$VALUE" != "1" ]] && continue

        # Extract higher.lower from OID
        local STACK_PART="${OID_PART##*$OID_IFSTACK_STATUS.}"
        local HIGHER="${STACK_PART%%.*}"
        local LOWER="${STACK_PART#*.}"

        # Skip entries with 0 (represents the top/bottom of stack)
        [[ "$HIGHER" == "0" || "$LOWER" == "0" ]] && continue

        # Check if higher layer is a LAG (ifType 161)
        if [[ "${IF_TYPE[$HIGHER]}" == "161" ]]; then
            if [[ -n "${LAG_MEMBERS[$HIGHER]}" ]]; then
                LAG_MEMBERS[$HIGHER]="${LAG_MEMBERS[$HIGHER]},$LOWER"
            else
                LAG_MEMBERS[$HIGHER]="$LOWER"
            fi
            LAG_PARENT[$LOWER]="$HIGHER"
        fi
    done < <(snmp_walk "$HOST" "$OID_IFSTACK_STATUS")
}

# --- System Info Collection ---
collect_sysinfo() {
    local HOST="$1"

    declare -g SYSNAME_VAL MODEL_VAL

    local RESULT
    RESULT=$(snmp_get "$HOST" "$OID_SYSNAME")
    SYSNAME_VAL="${RESULT#* }"
    SYSNAME_VAL="${SYSNAME_VAL#\"}"
    SYSNAME_VAL="${SYSNAME_VAL%\"}"

    # Try to get chassis model from Entity MIB
    MODEL_VAL=""
    local LINE OID_PART VALUE
    # Get entPhysicalClass to find chassis entry (class=3)
    while IFS= read -r LINE; do
        [[ -z "$LINE" ]] && continue
        OID_PART="${LINE%% *}"
        local ENTIDX="${OID_PART##*.}"
        VALUE="${LINE#* }"

        # class 3 = chassis
        if [[ "$VALUE" == "3" ]]; then
            local MODEL_LINE
            MODEL_LINE=$(snmp_get "$HOST" "${OID_ENT_PHYSICAL_MODEL}.${ENTIDX}")
            if [[ -n "$MODEL_LINE" ]]; then
                MODEL_VAL="${MODEL_LINE#* }"
                MODEL_VAL="${MODEL_VAL#\"}"
                MODEL_VAL="${MODEL_VAL%\"}"
                [[ -n "$MODEL_VAL" ]] && break
            fi
        fi
    done < <(snmp_walk "$HOST" "$OID_ENT_PHYSICAL_CLASS")
}

# --- LLDP to ifIndex Mapping ---
# Returns the ifIndex for a given LLDP localPortNum
lldp_locport_to_ifindex() {
    local LOCPORTNUM="$1"
    local SUBTYPE="${LLDP_LOC_PORTID_SUBTYPE[$LOCPORTNUM]}"
    local PORTID="${LLDP_LOC_PORTID[$LOCPORTNUM]}"

    if [[ "$SUBTYPE" == "7" ]]; then
        # Local subtype: value is ifIndex directly
        echo "$PORTID"
    else
        # Try to match by ifName
        for IFIDX in "${!IF_NAME[@]}"; do
            if [[ "${IF_NAME[$IFIDX]}" == "$PORTID" ]]; then
                echo "$IFIDX"
                return
            fi
        done
        # Fallback: localPortNum might equal ifIndex
        echo "$LOCPORTNUM"
    fi
}

# --- Data Correlation ---
correlate_data() {
    local SWITCH_NAME="$1"
    local PLATFORM="$2"
    local -a FILTERED_IFINDEXES
    shift 2

    # Get filtered interface list from caller
    FILTERED_IFINDEXES=("$@")

    # Build reverse bridge port map: ifIndex -> bridge port number
    declare -A IFINDEX_TO_BPORT
    for BPORT in "${!BRIDGE_PORT_IFINDEX[@]}"; do
        local BPIF="${BRIDGE_PORT_IFINDEX[$BPORT]}"
        IFINDEX_TO_BPORT[$BPIF]="$BPORT"
    done

    # Build LLDP map: ifIndex -> LLDP data
    declare -A LLDP_BY_IFINDEX_SYSNAME LLDP_BY_IFINDEX_PORTID LLDP_BY_IFINDEX_CHASSISID LLDP_BY_IFINDEX_SYSDESC
    for LOCPORTNUM in "${!LLDP_REM_SYSNAME[@]}"; do
        local MAPPED_IFIDX
        MAPPED_IFIDX=$(lldp_locport_to_ifindex "$LOCPORTNUM")
        LLDP_BY_IFINDEX_SYSNAME[$MAPPED_IFIDX]="${LLDP_REM_SYSNAME[$LOCPORTNUM]}"
        LLDP_BY_IFINDEX_PORTID[$MAPPED_IFIDX]="${LLDP_REM_PORTID[$LOCPORTNUM]}"
        LLDP_BY_IFINDEX_CHASSISID[$MAPPED_IFIDX]="${LLDP_REM_CHASSISID[$LOCPORTNUM]}"
        LLDP_BY_IFINDEX_SYSDESC[$MAPPED_IFIDX]="${LLDP_REM_SYSDESC[$LOCPORTNUM]}"
    done

    for IFIDX in "${FILTERED_IFINDEXES[@]}"; do
        local PORT_NAME="${IF_NAME[$IFIDX]}"
        local ADMIN="${IF_ADMIN[$IFIDX]:-down}"
        local OPER="${IF_OPER[$IFIDX]:-down}"
        local SPEED_VAL="${IF_SPEED[$IFIDX]:-0}"
        local MTU_VAL="${IF_MTU[$IFIDX]:-0}"
        local ALIAS="${IF_ALIAS[$IFIDX]}"
        local IFTYPE="${IF_TYPE[$IFIDX]}"

        # Apply status filter
        if [[ -n "$FILTER_STATUS" ]]; then
            case "$FILTER_STATUS" in
                up)         [[ "$OPER" != "up" ]] && continue ;;
                down)       [[ "$OPER" != "down" || "$ADMIN" == "down" ]] && continue ;;
                admin-down) [[ "$ADMIN" != "down" ]] && continue ;;
            esac
        fi

        # Apply port name filter
        if [[ -n "$FILTER_PORT" ]]; then
            # shellcheck disable=SC2254
            case "$PORT_NAME" in
                $FILTER_PORT) ;;
                *) continue ;;
            esac
        fi

        # Format speed
        local SPEED_FMT
        SPEED_FMT=$(format_speed "$SPEED_VAL")

        # LAG info
        local LAG_INFO="-"
        if [[ "$IFTYPE" == "161" ]]; then
            # This is a LAG interface, show member count
            local MEMBER_LIST="${LAG_MEMBERS[$IFIDX]}"
            if [[ -n "$MEMBER_LIST" ]]; then
                local MEMBER_COUNT
                IFS=',' read -ra MEMBER_ARR <<< "$MEMBER_LIST"
                MEMBER_COUNT=${#MEMBER_ARR[@]}
                LAG_INFO="${MEMBER_COUNT} members"
            else
                LAG_INFO="0 members"
            fi
        elif [[ -n "${LAG_PARENT[$IFIDX]}" ]]; then
            # This is a LAG member, show parent ae name
            local PARENT_IFIDX="${LAG_PARENT[$IFIDX]}"
            LAG_INFO="${IF_NAME[$PARENT_IFIDX]}"
        fi

        # LLDP info
        local LLDP_SYSNAME="${LLDP_BY_IFINDEX_SYSNAME[$IFIDX]}"
        local LLDP_PORTID="${LLDP_BY_IFINDEX_PORTID[$IFIDX]}"
        local LLDP_CHASSID="${LLDP_BY_IFINDEX_CHASSISID[$IFIDX]}"
        local LLDP_SYSDESC="${LLDP_BY_IFINDEX_SYSDESC[$IFIDX]}"

        [[ -z "$LLDP_SYSNAME" ]] && LLDP_SYSNAME="-"
        [[ -z "$LLDP_PORTID" ]] && LLDP_PORTID="-"
        [[ -z "$LLDP_SYSDESC" ]] && LLDP_SYSDESC="-"
        [[ -z "$ALIAS" ]] && ALIAS="-"

        # VLAN info
        local PVID_INFO="-"
        if [[ "$SHOW_VLANS" == true ]]; then
            local BPORT="${IFINDEX_TO_BPORT[$IFIDX]}"
            if [[ -n "$BPORT" && -n "${VLAN_PVID[$BPORT]}" ]]; then
                local VID="${VLAN_PVID[$BPORT]}"
                local VNAME="${VLAN_NAME[$VID]}"
                if [[ -n "$VNAME" ]]; then
                    PVID_INFO="${VID} (${VNAME})"
                else
                    PVID_INFO="$VID"
                fi
            fi
        fi

        # Store row data
        DATA_SWITCH_NAME[$ROW_COUNT]="$SWITCH_NAME"
        DATA_PORT_NAME[$ROW_COUNT]="$PORT_NAME"
        DATA_LAG[$ROW_COUNT]="$LAG_INFO"
        DATA_DESCRIPTION[$ROW_COUNT]="$ALIAS"
        DATA_ADMIN[$ROW_COUNT]="$ADMIN"
        DATA_OPER[$ROW_COUNT]="$OPER"
        DATA_SPEED[$ROW_COUNT]="$SPEED_FMT"
        DATA_MTU[$ROW_COUNT]="$MTU_VAL"
        DATA_LLDP_NEIGHBOR[$ROW_COUNT]="$LLDP_SYSNAME"
        DATA_REMOTE_PORT[$ROW_COUNT]="$LLDP_PORTID"
        DATA_LLDP_DESC[$ROW_COUNT]="$LLDP_SYSDESC"
        DATA_PVID[$ROW_COUNT]="$PVID_INFO"
        DATA_MODEL[$ROW_COUNT]="${MODEL_VAL:--}"
        DATA_IFINDEX[$ROW_COUNT]="$IFIDX"

        # Store color variants
        DATA_ADMIN_COLOR[$ROW_COUNT]=$(colorize_status "$ADMIN" "admin")
        DATA_OPER_COLOR[$ROW_COUNT]=$(colorize_status "$OPER" "oper")
        DATA_SPEED_COLOR[$ROW_COUNT]=$(colorize_speed "$SPEED_VAL")
        DATA_LAG_COLOR[$ROW_COUNT]=$(colorize_lag "$LAG_INFO")

        # Track chassis ID for cross-switch LAG detection
        if [[ -n "$LLDP_CHASSID" && "$LLDP_CHASSID" != "-" ]]; then
            # Store as switch:ifindex for later correlation
            local XLAG_KEY="${LLDP_CHASSID}"
            if [[ -n "${XLAG_GROUP[$XLAG_KEY]}" ]]; then
                XLAG_GROUP[$XLAG_KEY]="${XLAG_GROUP[$XLAG_KEY]},${SWITCH_NAME}:${IFIDX}"
            else
                XLAG_GROUP[$XLAG_KEY]="${SWITCH_NAME}:${IFIDX}"
            fi
        fi

        ((ROW_COUNT++))
    done
}

# --- Collect Data for One Switch ---
collect_switch_data() {
    local HOST="$1"

    # Clear per-switch arrays
    unset IF_NAME IF_DESCR IF_TYPE IF_MTU IF_SPEED IF_ADMIN IF_OPER IF_ALIAS
    unset LLDP_LOC_PORTID LLDP_LOC_PORTID_SUBTYPE
    unset LLDP_REM_SYSNAME LLDP_REM_PORTID LLDP_REM_CHASSISID LLDP_REM_SYSDESC
    unset BRIDGE_PORT_IFINDEX VLAN_PVID VLAN_NAME
    unset LAG_MEMBERS LAG_PARENT
    unset SYSNAME_VAL MODEL_VAL

    # Test connectivity
    spinner_start "Testing connectivity to $HOST..."
    if ! snmp_test_connectivity "$HOST"; then
        spinner_stop
        echo "Warning: Cannot reach switch '$HOST' via SNMP. Skipping." >&2
        return 1
    fi
    spinner_stop

    # Detect platform
    spinner_start "Detecting platform for $HOST..."
    local PLATFORM
    PLATFORM=$(detect_platform "$HOST")
    spinner_stop
    echo "  Switch $HOST: platform=$PLATFORM" >&2

    # Collect system info
    spinner_start "Collecting system info from $HOST..."
    collect_sysinfo "$HOST"
    spinner_stop

    local SWITCH_DISPLAY="${SYSNAME_VAL:-$HOST}"

    # Collect interfaces
    spinner_start "Collecting interfaces from $HOST..."
    collect_interfaces "$HOST"
    spinner_stop

    # Collect LAG membership
    spinner_start "Collecting LAG membership from $HOST..."
    collect_lag "$HOST"
    spinner_stop

    # Filter interfaces
    local -a FILTERED_IFINDEXES
    case "$PLATFORM" in
        junos)   filter_interfaces_junos FILTERED_IFINDEXES ;;
        arista)  filter_interfaces_arista FILTERED_IFINDEXES ;;
        *)       filter_interfaces_generic FILTERED_IFINDEXES ;;
    esac

    if [[ ${#FILTERED_IFINDEXES[@]} -eq 0 ]]; then
        echo "  Warning: No matching interfaces found on $HOST." >&2
        return 0
    fi

    # Sort interfaces by name (natural sort)
    local -a SORTED_IFINDEXES
    local -a SORT_PAIRS
    for IFIDX in "${FILTERED_IFINDEXES[@]}"; do
        SORT_PAIRS+=("${IF_NAME[$IFIDX]} $IFIDX")
    done
    IFS=$'\n' SORT_PAIRS=($(sort -V <<< "${SORT_PAIRS[*]}")); unset IFS
    for PAIR in "${SORT_PAIRS[@]}"; do
        SORTED_IFINDEXES+=("${PAIR##* }")
    done

    # Collect LLDP
    spinner_start "Collecting LLDP neighbors from $HOST..."
    collect_lldp "$HOST"
    spinner_stop

    # Collect VLANs if requested
    if [[ "$SHOW_VLANS" == true ]]; then
        spinner_start "Collecting VLAN info from $HOST..."
        collect_vlans "$HOST"
        spinner_stop
    fi

    # Correlate all data
    spinner_start "Correlating data for $HOST..."
    correlate_data "$SWITCH_DISPLAY" "$PLATFORM" "${SORTED_IFINDEXES[@]}"
    spinner_stop

    echo "  Collected ${#SORTED_IFINDEXES[@]} interfaces from $SWITCH_DISPLAY" >&2
    return 0
}

# --- Cross-Switch LAG Detection ---
detect_cross_switch_lag() {
    # After collecting all switches, check XLAG_GROUP for chassis IDs
    # that appear connected to ae interfaces on multiple switches
    for CHASSIS_ID in "${!XLAG_GROUP[@]}"; do
        local ENTRIES="${XLAG_GROUP[$CHASSIS_ID]}"
        IFS=',' read -ra ENTRY_ARR <<< "$ENTRIES"

        # Count unique switches
        declare -A SEEN_SWITCHES
        for ENTRY in "${ENTRY_ARR[@]}"; do
            local SW="${ENTRY%%:*}"
            SEEN_SWITCHES[$SW]=1
        done
        local SW_COUNT=${#SEEN_SWITCHES[@]}
        unset SEEN_SWITCHES

        if [[ $SW_COUNT -gt 1 ]]; then
            # This chassis is connected to multiple switches via LAG members
            # Find the corresponding rows and check if they're LAG members
            for ((i = 0; i < ROW_COUNT; i++)); do
                local ROW_LAG="${DATA_LAG[$i]}"
                [[ "$ROW_LAG" == "-" || "$ROW_LAG" == *"members"* ]] && continue

                # Check if this row's ifindex is in the XLAG group
                local ROW_SW="${DATA_SWITCH_NAME[$i]}"
                local ROW_IFIDX="${DATA_IFINDEX[$i]}"
                for ENTRY in "${ENTRY_ARR[@]}"; do
                    local E_SW="${ENTRY%%:*}"
                    local E_IFIDX="${ENTRY#*:}"
                    if [[ "$ROW_SW" == "$E_SW" && "$ROW_IFIDX" == "$E_IFIDX" ]]; then
                        # Mark this row's LAG as cross-switch
                        DATA_LAG[$i]="${ROW_LAG} [ESI]"
                        DATA_LAG_COLOR[$i]=$(colorize_lag "${DATA_LAG[$i]}")
                        break
                    fi
                done
            done
        fi
    done
}

# --- Argument Parsing ---
show_help() {
    cat <<'HELPEOF'
Usage: switch-xray.sh [OPTIONS] --switch HOST [--switch HOST...]

Collect and display switch port information via SNMP.

Target:
  --switch HOST            Switch to query (repeatable)
  --platform PLATFORM      Force platform: junos|arista|cumulus|cisco|generic

SNMP:
  --snmp-version VER       2c (default) or 3
  -c, --community STR      SNMPv2c community string
  -u, --snmp-user USER     SNMPv3 user
  -l, --sec-level LVL      noAuthNoPriv|authNoPriv|authPriv
  -a, --auth-proto PROTO   MD5|SHA|SHA-256|SHA-384|SHA-512
  -A, --auth-pass PASS     Auth passphrase
  -x, --priv-proto PROTO   DES|AES|AES-256
  -X, --priv-pass PASS     Privacy passphrase
  --config FILE            Config file path
  --timeout SECS           SNMP timeout (default: 5)
  --retries N              SNMP retries (default: 1)

Display:
  --lldp-detail            Show LLDP remote system description
  --vlans                  Show VLAN columns (PVID)
  --all                    All optional columns
  --no-color               Disable colors
  --filter-status TYPE     up|down|admin-down
  --filter-port PATTERN    Glob filter on port name

Format:
  -s, --separator[=SEP]    Column separators (default: |)
  --group-switch           Visual grouping by switch
  --output FORMAT          table|csv|json|dot|svg|png
  --diagram-style STYLE    switch (default) or network
  --diagram-out FILE       Output path for svg/png

General:
  -v, --version            Version info
  -h, --help               Display this help message
HELPEOF
}

# Track which values came from CLI for config merge priority
SNMP_VERSION_CLI=""
SNMP_COMMUNITY_CLI=""
SNMP_USER_CLI=""
SNMP_SEC_LEVEL_CLI=""
SNMP_AUTH_PROTO_CLI=""
SNMP_AUTH_PASS_CLI=""
SNMP_PRIV_PROTO_CLI=""
SNMP_PRIV_PASS_CLI=""

OPTIONS=$(getopt -o hvs::c:u:l:a:A:x:X: \
    --long help,version,switch:,platform:,snmp-version:,community:,snmp-user:,sec-level:,auth-proto:,auth-pass:,priv-proto:,priv-pass:,config:,timeout:,retries:,lldp-detail,vlans,all,no-color,filter-status:,filter-port:,separator::,group-switch,output:,diagram-style:,diagram-out: \
    -n "$0" -- "$@")

if [[ $? -ne 0 ]]; then
    echo "Failed to parse options. Use --help for usage." >&2
    exit 1
fi

eval set -- "$OPTIONS"

while true; do
    case "$1" in
        --switch)
            SWITCH_TARGETS+=("$2")
            shift 2
            ;;
        --platform)
            case "$2" in
                junos|arista|cumulus|cisco|generic)
                    FORCE_PLATFORM="$2"
                    ;;
                *)
                    echo "Invalid platform: $2. Choose from junos, arista, cumulus, cisco, generic." >&2
                    exit 1
                    ;;
            esac
            shift 2
            ;;
        --snmp-version)
            SNMP_VERSION="$2"
            SNMP_VERSION_CLI="$2"
            shift 2
            ;;
        -c|--community)
            SNMP_COMMUNITY="$2"
            SNMP_COMMUNITY_CLI="$2"
            shift 2
            ;;
        -u|--snmp-user)
            SNMP_USER="$2"
            SNMP_USER_CLI="$2"
            shift 2
            ;;
        -l|--sec-level)
            SNMP_SEC_LEVEL="$2"
            SNMP_SEC_LEVEL_CLI="$2"
            shift 2
            ;;
        -a|--auth-proto)
            SNMP_AUTH_PROTO="$2"
            SNMP_AUTH_PROTO_CLI="$2"
            shift 2
            ;;
        -A|--auth-pass)
            SNMP_AUTH_PASS="$2"
            SNMP_AUTH_PASS_CLI="$2"
            shift 2
            ;;
        -x|--priv-proto)
            SNMP_PRIV_PROTO="$2"
            SNMP_PRIV_PROTO_CLI="$2"
            shift 2
            ;;
        -X|--priv-pass)
            SNMP_PRIV_PASS="$2"
            SNMP_PRIV_PASS_CLI="$2"
            shift 2
            ;;
        --config)
            CONFIG_FILE="$2"
            shift 2
            ;;
        --timeout)
            SNMP_TIMEOUT="$2"
            shift 2
            ;;
        --retries)
            SNMP_RETRIES="$2"
            shift 2
            ;;
        --lldp-detail)
            SHOW_LLDP_DETAIL=true
            shift
            ;;
        --vlans)
            SHOW_VLANS=true
            shift
            ;;
        --all)
            SHOW_LLDP_DETAIL=true
            SHOW_VLANS=true
            SHOW_MODEL=true
            shift
            ;;
        --no-color)
            USE_COLOR=false
            shift
            ;;
        --filter-status)
            case "$2" in
                up|down|admin-down)
                    FILTER_STATUS="$2"
                    ;;
                *)
                    echo "Invalid filter-status value: $2. Choose 'up', 'down', or 'admin-down'." >&2
                    exit 1
                    ;;
            esac
            shift 2
            ;;
        --filter-port)
            FILTER_PORT="$2"
            shift 2
            ;;
        -s|--separator)
            if [[ -n "$2" ]]; then
                FIELD_SEP="$2"
                shift 2
            else
                FIELD_SEP="|"
                shift 2
            fi
            ;;
        --group-switch)
            GROUP_SWITCH=true
            shift
            ;;
        --output)
            case "$2" in
                table|csv|json|dot|svg|png)
                    OUTPUT_FORMAT="$2"
                    ;;
                *)
                    echo "Invalid output format: $2. Choose from table, csv, json, dot, svg, or png." >&2
                    exit 1
                    ;;
            esac
            shift 2
            ;;
        --diagram-style)
            case "$2" in
                switch|network)
                    DIAGRAM_STYLE="$2"
                    ;;
                *)
                    echo "Invalid diagram style: $2. Choose 'switch' or 'network'." >&2
                    exit 1
                    ;;
            esac
            shift 2
            ;;
        --diagram-out)
            DIAGRAM_OUTPUT_FILE="$2"
            shift 2
            ;;
        -v|--version)
            echo "$SCRIPT_NAME $SCRIPT_VERSION"
            exit 0
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        --)
            shift
            break
            ;;
        *)
            echo "Unexpected option: $1" >&2
            exit 1
            ;;
    esac
done

# --- Load Config & Env Vars (CLI takes priority) ---
if [[ -n "$CONFIG_FILE" ]]; then
    if [[ ! -f "$CONFIG_FILE" ]]; then
        echo "Config file not found: $CONFIG_FILE" >&2
        exit 1
    fi
    load_config "$CONFIG_FILE"
elif [[ -f "$HOME/.switch-xray.conf" ]]; then
    load_config "$HOME/.switch-xray.conf"
elif [[ -f "/etc/switch-xray.conf" ]]; then
    load_config "/etc/switch-xray.conf"
fi

load_env_vars

# --- Auto-disable colors for non-terminal output ---
[[ ! -t 1 ]] && USE_COLOR=false

# --- Color Setup ---
if [[ "$USE_COLOR" == true ]]; then
    RESET_COLOR="\033[0m"
    GREEN="\033[1;32m"
    RED="\033[1;31m"
    YELLOW="\033[1;33m"
    BOLD_GREEN="\033[1;32m"
    BOLD_CYAN="\033[1;36m"
    BOLD_MAGENTA="\033[1;35m"
    BOLD_WHITE="\033[1;37m"
    BOLD_BLUE="\033[1;34m"
else
    RESET_COLOR=""
    GREEN=""
    RED=""
    YELLOW=""
    BOLD_GREEN=""
    BOLD_CYAN=""
    BOLD_MAGENTA=""
    BOLD_WHITE=""
    BOLD_BLUE=""
fi

# --- Diagram format setup ---
if [[ "$OUTPUT_FORMAT" =~ ^(dot|svg|png)$ ]]; then
    SHOW_LLDP_DETAIL=true
    SHOW_VLANS=true
    SHOW_MODEL=true

    if [[ "$OUTPUT_FORMAT" != "dot" ]] && ! command -v dot &>/dev/null; then
        echo "graphviz is required for --output $OUTPUT_FORMAT but 'dot' command was not found." >&2
        echo "Install graphviz or use --output dot to generate raw DOT source." >&2
        exit 1
    fi
fi

# --- Validation ---
REQUIRED_CMDS=("snmpget")
if command -v snmpbulkwalk &>/dev/null; then
    REQUIRED_CMDS+=("snmpbulkwalk")
elif command -v snmpwalk &>/dev/null; then
    REQUIRED_CMDS=("snmpget" "snmpwalk")
else
    echo "Required command 'snmpbulkwalk' or 'snmpwalk' is not installed or not in PATH." >&2
    echo "Install the net-snmp package." >&2
    exit 1
fi

for CMD in "${REQUIRED_CMDS[@]}"; do
    if ! command -v "$CMD" &>/dev/null; then
        echo "Required command '$CMD' is not installed or not in PATH." >&2
        exit 1
    fi
done

if [[ ${#SWITCH_TARGETS[@]} -eq 0 ]]; then
    echo "No switch targets specified. Use --switch HOST or set SWITCH_XRAY_SWITCHES." >&2
    echo "Use --help for usage information." >&2
    exit 1
fi

if [[ "$SNMP_VERSION" == "2c" && -z "$SNMP_COMMUNITY" ]]; then
    echo "SNMPv2c requires a community string. Use -c/--community or set SWITCH_XRAY_COMMUNITY." >&2
    exit 1
fi

if [[ "$SNMP_VERSION" == "3" && -z "$SNMP_USER" ]]; then
    echo "SNMPv3 requires a username. Use -u/--snmp-user or set SWITCH_XRAY_USER." >&2
    exit 1
fi

# --- Main Collection Loop ---
SWITCHES_OK=0
SWITCHES_FAIL=0

echo "switch-xray v${SCRIPT_VERSION} - Collecting data from ${#SWITCH_TARGETS[@]} switch(es)..." >&2
echo "" >&2

for TARGET in "${SWITCH_TARGETS[@]}"; do
    if collect_switch_data "$TARGET"; then
        ((SWITCHES_OK++))
    else
        ((SWITCHES_FAIL++))
    fi
    echo "" >&2
done

if [[ $SWITCHES_OK -eq 0 ]]; then
    echo "All switches were unreachable. No data to display." >&2
    exit 1
fi

if [[ $ROW_COUNT -eq 0 ]]; then
    echo "No interfaces found matching the specified criteria." >&2
    exit 0
fi

# --- Cross-Switch LAG Detection ---
if [[ ${#SWITCH_TARGETS[@]} -gt 1 ]]; then
    detect_cross_switch_lag
fi

echo "Total: $ROW_COUNT interfaces from $SWITCHES_OK switch(es)" >&2
if [[ $SWITCHES_FAIL -gt 0 ]]; then
    echo "Warning: $SWITCHES_FAIL switch(es) were unreachable" >&2
fi
echo "" >&2

# --- Determine if Switch column should be shown ---
SHOW_SWITCH_COL=true
SINGLE_SWITCH_HEADER=""
if [[ ${#SWITCH_TARGETS[@]} -eq 1 && $SWITCHES_OK -eq 1 ]]; then
    SHOW_SWITCH_COL=false
    SINGLE_SWITCH_HEADER="${DATA_SWITCH_NAME[0]}"
fi

# --- Build Render Order ---
declare -a RENDER_ORDER

if [[ "$GROUP_SWITCH" == true ]]; then
    # Sort by switch name, then port name
    declare -A SWITCH_INDICES
    for ((i = 0; i < ROW_COUNT; i++)); do
        SW="${DATA_SWITCH_NAME[$i]}"
        SWITCH_INDICES["$SW"]+="$i "
    done

    for SW in $(printf '%s\n' "${!SWITCH_INDICES[@]}" | sort); do
        read -ra INDICES <<< "${SWITCH_INDICES[$SW]}"
        for IDX in "${INDICES[@]}"; do
            RENDER_ORDER+=("$IDX")
        done
    done
    unset SWITCH_INDICES
else
    for ((i = 0; i < ROW_COUNT; i++)); do
        RENDER_ORDER+=("$i")
    done
fi

# --- Compute Dynamic Column Widths ---
COL_W_SWITCH=$(max_width "Switch" "${DATA_SWITCH_NAME[@]}")
COL_W_PORT=$(max_width "Port" "${DATA_PORT_NAME[@]}")
COL_W_LAG=$(max_width "LAG" "${DATA_LAG[@]}")
COL_W_DESC=$(max_width "Description" "${DATA_DESCRIPTION[@]}")
COL_W_ADMIN=$(max_width "Admin" "${DATA_ADMIN[@]}")
COL_W_OPER=$(max_width "Oper" "${DATA_OPER[@]}")
COL_W_SPEED=$(max_width "Speed" "${DATA_SPEED[@]}")
COL_W_MTU=$(max_width "MTU" "${DATA_MTU[@]}")
COL_W_NEIGHBOR=$(max_width "LLDP Neighbor" "${DATA_LLDP_NEIGHBOR[@]}")
COL_W_RPORT=$(max_width "Remote Port" "${DATA_REMOTE_PORT[@]}")
COL_W_LLDPDESC=$(max_width "LLDP Description" "${DATA_LLDP_DESC[@]}")
COL_W_PVID=$(max_width "PVID" "${DATA_PVID[@]}")
COL_W_MODEL=$(max_width "Model" "${DATA_MODEL[@]}")

# --- Column Gap ---
if [[ -n "${FIELD_SEP}" ]]; then
    COL_GAP=" ${FIELD_SEP} "
else
    COL_GAP="   "
fi

# --- DOT Diagram Helpers ---
dot_id() {
    local STR="$1"
    STR="${STR//[^a-zA-Z0-9_]/_}"
    printf '%s' "$STR"
}

dot_escape() {
    local STR="$1"
    STR="${STR//&/&amp;}"
    STR="${STR//</&lt;}"
    STR="${STR//>/&gt;}"
    STR="${STR//\"/&quot;}"
    printf '%s' "$STR"
}

dot_penwidth() {
    local RAW="$1"
    local NUM="${RAW%%[^0-9]*}"
    if [[ "$NUM" =~ ^[0-9]+$ ]]; then
        if (( NUM >= 800 )); then
            echo "6.0"
        elif (( NUM >= 400 )); then
            echo "5.0"
        elif (( NUM >= 100 )); then
            echo "4.0"
        elif (( NUM >= 25 )); then
            echo "3.0"
        elif (( NUM >= 10 )); then
            echo "2.5"
        elif (( NUM >= 1 )); then
            echo "2.0"
        else
            echo "1.5"
        fi
    else
        echo "1.0"
    fi
}

dot_speed_tier() {
    local RAW="$1"
    # RAW is formatted speed like "100G", "10G", "1G", etc.
    printf '%s' "$RAW"
}

# --- Generate DOT: Switch-Centric Style ---
generate_dot_switch() {
    # Catppuccin Mocha theme
    local BG_COLOR="#1e1e2e"
    local FG_COLOR="#cdd6f4"
    local SURFACE_COLOR="#313244"
    local BORDER_COLOR="#585b70"
    local GREEN_COLOR="#a6e3a1"
    local RED_COLOR="#f38ba8"
    local PEACH_COLOR="#fab387"
    local MAUVE_COLOR="#cba6f7"
    local GRAY_COLOR="#6c7086"
    local TEXT_COLOR="#cdd6f4"
    local SUBTEXT_COLOR="#a6adc8"
    local BLUE_COLOR="#89b4fa"

    cat <<DOTHEADER
digraph switch_xray {
    rankdir=LR;
    bgcolor="$BG_COLOR";
    fontname="Helvetica,Arial,sans-serif";
    fontcolor="$FG_COLOR";
    pad="0.5";
    nodesep="0.4";
    ranksep="1.5";
    node [fontname="Helvetica,Arial,sans-serif", fontcolor="$TEXT_COLOR", fontsize=11];
    edge [fontname="Helvetica,Arial,sans-serif", fontcolor="$SUBTEXT_COLOR", fontsize=10];
    label=<<FONT POINT-SIZE="9" COLOR="$GRAY_COLOR">Generated by switch-xray v$SCRIPT_VERSION &mdash; &copy; $SCRIPT_YEAR Ciro Iriarte</FONT>>;
    labeljust=r;
    labelloc=b;

DOTHEADER

    # Collect unique switches and their ports
    declare -A SW_PORT_INDICES  # "switch" -> space-separated row indices

    for ((i = 0; i < ROW_COUNT; i++)); do
        local SW="${DATA_SWITCH_NAME[$i]}"
        SW_PORT_INDICES["$SW"]+="$i "
    done

    # Emit switch clusters
    local CLUSTER_IDX=0
    for SW in $(printf '%s\n' "${!SW_PORT_INDICES[@]}" | sort); do
        local SW_ID
        SW_ID=$(dot_id "sw_${SW}")
        local MODEL="${DATA_MODEL[${SW_PORT_INDICES[$SW]%% *}]}"

        printf '    subgraph cluster_%d {\n' "$CLUSTER_IDX"
        printf '        style=rounded;\n'
        printf '        color="%s";\n' "$BORDER_COLOR"
        printf '        bgcolor="%s";\n' "${BG_COLOR}cc"
        printf '        fontcolor="%s";\n' "$PEACH_COLOR"
        if [[ -n "$MODEL" && "$MODEL" != "-" ]]; then
            printf '        label=<<FONT POINT-SIZE="14"><B>%s</B></FONT><BR/><FONT POINT-SIZE="10" COLOR="%s">%s</FONT>>;\n' \
                "$(dot_escape "$SW")" "$SUBTEXT_COLOR" "$(dot_escape "$MODEL")"
        else
            printf '        label=<<FONT POINT-SIZE="14"><B>%s</B></FONT>>;\n' "$(dot_escape "$SW")"
        fi
        printf '        penwidth=1.5;\n\n'

        # Emit port nodes inside the cluster
        read -ra INDICES <<< "${SW_PORT_INDICES[$SW]}"
        for IDX in "${INDICES[@]}"; do
            local PORT="${DATA_PORT_NAME[$IDX]}"
            local OPER="${DATA_OPER[$IDX]}"
            local ADMIN="${DATA_ADMIN[$IDX]}"
            local SPEED="${DATA_SPEED[$IDX]}"
            local DESC="${DATA_DESCRIPTION[$IDX]}"
            local LAG="${DATA_LAG[$IDX]}"
            local NODE_ID
            NODE_ID=$(dot_id "port_${SW}_${PORT}")

            local NODE_BORDER
            if [[ "$ADMIN" == "down" ]]; then
                NODE_BORDER="$GRAY_COLOR"
            elif [[ "$OPER" == "up" ]]; then
                NODE_BORDER="$GREEN_COLOR"
            else
                NODE_BORDER="$RED_COLOR"
            fi

            # Port label with details
            printf '        %s [shape=plain, label=<\n' "$NODE_ID"
            printf '            <TABLE BORDER="1" CELLBORDER="0" CELLSPACING="2" CELLPADDING="3" '
            printf 'BGCOLOR="%s" COLOR="%s">\n' "$SURFACE_COLOR" "$NODE_BORDER"
            printf '            <TR><TD><FONT COLOR="%s"><B>%s</B></FONT></TD></TR>\n' \
                "$TEXT_COLOR" "$(dot_escape "$PORT")"
            if [[ -n "$DESC" && "$DESC" != "-" ]]; then
                printf '            <TR><TD><FONT POINT-SIZE="9" COLOR="%s">%s</FONT></TD></TR>\n' \
                    "$SUBTEXT_COLOR" "$(dot_escape "$DESC")"
            fi
            printf '            <TR><TD><FONT POINT-SIZE="9" COLOR="%s">%s &bull; MTU:%s</FONT></TD></TR>\n' \
                "$SUBTEXT_COLOR" "$(dot_escape "$SPEED")" "${DATA_MTU[$IDX]}"
            if [[ "$LAG" != "-" ]]; then
                printf '            <TR><TD><FONT POINT-SIZE="9" COLOR="%s">%s</FONT></TD></TR>\n' \
                    "$BLUE_COLOR" "$(dot_escape "$LAG")"
            fi
            printf '            </TABLE>\n'
            printf '        >];\n'
        done

        printf '    }\n\n'
        ((CLUSTER_IDX++))
    done

    # Emit neighbor (LLDP) nodes
    declare -A SEEN_NEIGHBORS
    for ((i = 0; i < ROW_COUNT; i++)); do
        local NEIGHBOR="${DATA_LLDP_NEIGHBOR[$i]}"
        [[ "$NEIGHBOR" == "-" || -z "$NEIGHBOR" ]] && continue
        [[ -n "${SEEN_NEIGHBORS[$NEIGHBOR]+x}" ]] && continue
        SEEN_NEIGHBORS["$NEIGHBOR"]=1

        local N_ID
        N_ID=$(dot_id "neighbor_${NEIGHBOR}")
        local SYSDESC="${DATA_LLDP_DESC[$i]}"

        printf '    %s [shape=plain, label=<\n' "$N_ID"
        printf '        <TABLE BORDER="1" CELLBORDER="0" CELLSPACING="2" CELLPADDING="4" '
        printf 'BGCOLOR="%s" COLOR="%s" STYLE="ROUNDED">\n' "$SURFACE_COLOR" "$MAUVE_COLOR"
        printf '        <TR><TD><FONT POINT-SIZE="12" COLOR="%s"><B>%s</B></FONT></TD></TR>\n' \
            "$MAUVE_COLOR" "$(dot_escape "$NEIGHBOR")"
        if [[ -n "$SYSDESC" && "$SYSDESC" != "-" ]]; then
            # Truncate long descriptions
            local SHORT_DESC="${SYSDESC:0:60}"
            [[ ${#SYSDESC} -gt 60 ]] && SHORT_DESC+="..."
            printf '        <TR><TD><FONT POINT-SIZE="9" COLOR="%s">%s</FONT></TD></TR>\n' \
                "$SUBTEXT_COLOR" "$(dot_escape "$SHORT_DESC")"
        fi
        printf '        </TABLE>\n'
        printf '    >];\n\n'
    done

    # "No LLDP peer" stub
    local HAS_NO_LLDP=false
    for ((i = 0; i < ROW_COUNT; i++)); do
        if [[ "${DATA_LLDP_NEIGHBOR[$i]}" == "-" ]]; then
            HAS_NO_LLDP=true
            break
        fi
    done

    if [[ "$HAS_NO_LLDP" == true ]]; then
        printf '    no_lldp_peer [shape=plain, label=<\n'
        printf '        <TABLE BORDER="1" CELLBORDER="0" CELLSPACING="2" CELLPADDING="4" '
        printf 'BGCOLOR="%s" COLOR="%s" STYLE="ROUNDED">\n' "$SURFACE_COLOR" "$GRAY_COLOR"
        printf '        <TR><TD><FONT COLOR="%s"><I>No LLDP peer</I></FONT></TD></TR>\n' "$GRAY_COLOR"
        printf '        </TABLE>\n'
        printf '    >];\n\n'
    fi

    # Edges: switch ports -> LLDP neighbors
    for ((i = 0; i < ROW_COUNT; i++)); do
        local SW="${DATA_SWITCH_NAME[$i]}"
        local PORT="${DATA_PORT_NAME[$i]}"
        local NEIGHBOR="${DATA_LLDP_NEIGHBOR[$i]}"
        local RPORT="${DATA_REMOTE_PORT[$i]}"
        local SPEED="${DATA_SPEED[$i]}"
        local OPER="${DATA_OPER[$i]}"
        local LAG="${DATA_LAG[$i]}"

        local PORT_ID
        PORT_ID=$(dot_id "port_${SW}_${PORT}")

        local PW
        PW=$(dot_penwidth "$SPEED")

        local EDGE_COLOR
        if [[ "$OPER" == "up" ]]; then
            EDGE_COLOR="$GREEN_COLOR"
        else
            EDGE_COLOR="$RED_COLOR"
        fi

        if [[ "$NEIGHBOR" != "-" && -n "$NEIGHBOR" ]]; then
            local N_ID
            N_ID=$(dot_id "neighbor_${NEIGHBOR}")
            local EDGE_LABEL=""
            if [[ -n "$RPORT" && "$RPORT" != "-" ]]; then
                EDGE_LABEL="$(dot_escape "$RPORT")"
            fi
            [[ -n "$SPEED" && "$SPEED" != "N/A" ]] && {
                [[ -n "$EDGE_LABEL" ]] && EDGE_LABEL+="<BR/>"
                EDGE_LABEL+="$(dot_escape "$SPEED")"
            }

            # ESI/MCLAG edges are dashed
            local EDGE_STYLE=""
            if [[ "$LAG" == *"[ESI]"* || "$LAG" == *"[MCLAG]"* ]]; then
                EDGE_STYLE=', style=dashed'
            fi

            printf '    %s -> %s [label=<%s>, penwidth=%s, color="%s", fontcolor="%s"%s];\n' \
                "$PORT_ID" "$N_ID" "$EDGE_LABEL" "$PW" "$EDGE_COLOR" "$SUBTEXT_COLOR" "$EDGE_STYLE"
        else
            printf '    %s -> no_lldp_peer [style=dashed, color="%s", penwidth=1.0];\n' \
                "$PORT_ID" "$GRAY_COLOR"
        fi
    done

    # Rank constraints
    if [[ ${#SEEN_NEIGHBORS[@]} -gt 0 || "$HAS_NO_LLDP" == true ]]; then
        printf '    { rank=max;'
        for N in $(printf '%s\n' "${!SEEN_NEIGHBORS[@]}" | sort); do
            printf ' %s;' "$(dot_id "neighbor_${N}")"
        done
        [[ "$HAS_NO_LLDP" == true ]] && printf ' no_lldp_peer;'
        printf ' }\n'
    fi

    printf '}\n'
}

# --- Generate DOT: Network-Centric Style ---
generate_dot_network() {
    local BG_COLOR="#1e1e2e"
    local FG_COLOR="#cdd6f4"
    local SURFACE_COLOR="#313244"
    local BORDER_COLOR="#585b70"
    local GREEN_COLOR="#a6e3a1"
    local RED_COLOR="#f38ba8"
    local PEACH_COLOR="#fab387"
    local MAUVE_COLOR="#cba6f7"
    local GRAY_COLOR="#6c7086"
    local TEXT_COLOR="#cdd6f4"
    local SUBTEXT_COLOR="#a6adc8"

    cat <<DOTHEADER
graph switch_xray_network {
    layout=neato;
    overlap=false;
    splines=true;
    bgcolor="$BG_COLOR";
    fontname="Helvetica,Arial,sans-serif";
    fontcolor="$FG_COLOR";
    pad="0.5";
    node [fontname="Helvetica,Arial,sans-serif", fontcolor="$TEXT_COLOR", fontsize=11];
    edge [fontname="Helvetica,Arial,sans-serif", fontcolor="$SUBTEXT_COLOR", fontsize=10];
    label=<<FONT POINT-SIZE="9" COLOR="$GRAY_COLOR">Generated by switch-xray v$SCRIPT_VERSION &mdash; &copy; $SCRIPT_YEAR Ciro Iriarte</FONT>>;
    labeljust=r;
    labelloc=b;

DOTHEADER

    # Emit switch nodes
    declare -A SEEN_SWITCHES
    for ((i = 0; i < ROW_COUNT; i++)); do
        local SW="${DATA_SWITCH_NAME[$i]}"
        [[ -n "${SEEN_SWITCHES[$SW]+x}" ]] && continue
        SEEN_SWITCHES["$SW"]=1

        local SW_ID
        SW_ID=$(dot_id "sw_${SW}")
        local MODEL="${DATA_MODEL[$i]}"

        printf '    %s [shape=plain, label=<\n' "$SW_ID"
        printf '        <TABLE BORDER="1" CELLBORDER="0" CELLSPACING="4" CELLPADDING="6" '
        printf 'BGCOLOR="%s" COLOR="%s" STYLE="ROUNDED">\n' "$SURFACE_COLOR" "$PEACH_COLOR"
        printf '        <TR><TD><FONT POINT-SIZE="14" COLOR="%s"><B>%s</B></FONT></TD></TR>\n' \
            "$PEACH_COLOR" "$(dot_escape "$SW")"
        if [[ -n "$MODEL" && "$MODEL" != "-" ]]; then
            printf '        <TR><TD><FONT POINT-SIZE="10" COLOR="%s">%s</FONT></TD></TR>\n' \
                "$SUBTEXT_COLOR" "$(dot_escape "$MODEL")"
        fi
        printf '        <TR><TD><FONT COLOR="%s">Switch</FONT></TD></TR>\n' "$SUBTEXT_COLOR"
        printf '        </TABLE>\n'
        printf '    >];\n\n'
    done

    # Emit neighbor nodes
    declare -A SEEN_NEIGHBORS
    for ((i = 0; i < ROW_COUNT; i++)); do
        local NEIGHBOR="${DATA_LLDP_NEIGHBOR[$i]}"
        [[ "$NEIGHBOR" == "-" || -z "$NEIGHBOR" ]] && continue
        # Skip if neighbor is also one of our switches
        [[ -n "${SEEN_SWITCHES[$NEIGHBOR]+x}" ]] && continue
        [[ -n "${SEEN_NEIGHBORS[$NEIGHBOR]+x}" ]] && continue
        SEEN_NEIGHBORS["$NEIGHBOR"]=1

        local N_ID
        N_ID=$(dot_id "host_${NEIGHBOR}")

        printf '    %s [shape=plain, label=<\n' "$N_ID"
        printf '        <TABLE BORDER="1" CELLBORDER="0" CELLSPACING="2" CELLPADDING="4" '
        printf 'BGCOLOR="%s" COLOR="%s" STYLE="ROUNDED">\n' "$SURFACE_COLOR" "$MAUVE_COLOR"
        printf '        <TR><TD><FONT POINT-SIZE="12" COLOR="%s"><B>%s</B></FONT></TD></TR>\n' \
            "$MAUVE_COLOR" "$(dot_escape "$NEIGHBOR")"
        printf '        <TR><TD><FONT COLOR="%s">Host</FONT></TD></TR>\n' "$SUBTEXT_COLOR"
        printf '        </TABLE>\n'
        printf '    >];\n\n'
    done

    # Edges
    for ((i = 0; i < ROW_COUNT; i++)); do
        local SW="${DATA_SWITCH_NAME[$i]}"
        local PORT="${DATA_PORT_NAME[$i]}"
        local NEIGHBOR="${DATA_LLDP_NEIGHBOR[$i]}"
        local RPORT="${DATA_REMOTE_PORT[$i]}"
        local SPEED="${DATA_SPEED[$i]}"
        local OPER="${DATA_OPER[$i]}"

        [[ "$NEIGHBOR" == "-" || -z "$NEIGHBOR" ]] && continue

        local SW_ID
        SW_ID=$(dot_id "sw_${SW}")

        local N_ID
        if [[ -n "${SEEN_SWITCHES[$NEIGHBOR]+x}" ]]; then
            N_ID=$(dot_id "sw_${NEIGHBOR}")
        else
            N_ID=$(dot_id "host_${NEIGHBOR}")
        fi

        local PW
        PW=$(dot_penwidth "$SPEED")

        local EDGE_COLOR
        if [[ "$OPER" == "up" ]]; then
            EDGE_COLOR="$GREEN_COLOR"
        else
            EDGE_COLOR="$RED_COLOR"
        fi

        local EDGE_LABEL=""
        [[ -n "$PORT" ]] && EDGE_LABEL="$(dot_escape "$PORT")"
        if [[ -n "$RPORT" && "$RPORT" != "-" ]]; then
            [[ -n "$EDGE_LABEL" ]] && EDGE_LABEL+=" &harr; "
            EDGE_LABEL+="$(dot_escape "$RPORT")"
        fi

        printf '    %s -- %s [label=<%s>, penwidth=%s, color="%s", fontcolor="%s"];\n' \
            "$SW_ID" "$N_ID" "$EDGE_LABEL" "$PW" "$EDGE_COLOR" "$SUBTEXT_COLOR"
    done

    printf '}\n'
}

generate_dot() {
    if [[ "$DIAGRAM_STYLE" == "network" ]]; then
        generate_dot_network
    else
        generate_dot_switch
    fi
}

# --- Output ---
if [[ "$OUTPUT_FORMAT" == "table" ]]; then
    # Print single-switch header
    if [[ "$SHOW_SWITCH_COL" == false && -n "$SINGLE_SWITCH_HEADER" ]]; then
        M="${DATA_MODEL[0]}"
        if [[ -n "$M" && "$M" != "-" && "$SHOW_MODEL" == true ]]; then
            echo "Switch: $SINGLE_SWITCH_HEADER ($M)"
        else
            echo "Switch: $SINGLE_SWITCH_HEADER"
        fi
        echo ""
    fi

    # Header
    if [[ "$SHOW_SWITCH_COL" == true ]]; then
        printf "%-${COL_W_SWITCH}s${COL_GAP}" "Switch"
    fi
    printf "%-${COL_W_PORT}s${COL_GAP}%-${COL_W_LAG}s${COL_GAP}%-${COL_W_DESC}s${COL_GAP}%-${COL_W_ADMIN}s${COL_GAP}%-${COL_W_OPER}s${COL_GAP}%-${COL_W_SPEED}s${COL_GAP}%-${COL_W_MTU}s${COL_GAP}%-${COL_W_NEIGHBOR}s${COL_GAP}%-${COL_W_RPORT}s" \
        "Port" "LAG" "Description" "Admin" "Oper" "Speed" "MTU" "LLDP Neighbor" "Remote Port"
    if [[ "$SHOW_LLDP_DETAIL" == true ]]; then
        printf "${COL_GAP}%-${COL_W_LLDPDESC}s" "LLDP Description"
    fi
    if [[ "$SHOW_VLANS" == true ]]; then
        printf "${COL_GAP}%-${COL_W_PVID}s" "PVID"
    fi
    if [[ "$SHOW_MODEL" == true && "$SHOW_SWITCH_COL" == true ]]; then
        printf "${COL_GAP}%-${COL_W_MODEL}s" "Model"
    fi
    printf "\n"

    # Separator
    COL_GAP_WIDTH=${#COL_GAP}
    SEP_WIDTH=0
    [[ "$SHOW_SWITCH_COL" == true ]] && SEP_WIDTH=$((SEP_WIDTH + COL_W_SWITCH + COL_GAP_WIDTH))
    SEP_WIDTH=$((SEP_WIDTH + COL_W_PORT + COL_GAP_WIDTH + COL_W_LAG + COL_GAP_WIDTH + COL_W_DESC + COL_GAP_WIDTH + COL_W_ADMIN + COL_GAP_WIDTH + COL_W_OPER + COL_GAP_WIDTH + COL_W_SPEED + COL_GAP_WIDTH + COL_W_MTU + COL_GAP_WIDTH + COL_W_NEIGHBOR + COL_GAP_WIDTH + COL_W_RPORT))
    [[ "$SHOW_LLDP_DETAIL" == true ]] && SEP_WIDTH=$((SEP_WIDTH + COL_GAP_WIDTH + COL_W_LLDPDESC))
    [[ "$SHOW_VLANS" == true ]] && SEP_WIDTH=$((SEP_WIDTH + COL_GAP_WIDTH + COL_W_PVID))
    [[ "$SHOW_MODEL" == true && "$SHOW_SWITCH_COL" == true ]] && SEP_WIDTH=$((SEP_WIDTH + COL_GAP_WIDTH + COL_W_MODEL))
    printf '%*s\n' "$SEP_WIDTH" '' | tr ' ' '-'

    # Data rows
    PREV_SWITCH=""
    for i in "${RENDER_ORDER[@]}"; do
        # Group separator
        if [[ "$GROUP_SWITCH" == true && "$SHOW_SWITCH_COL" == true ]]; then
            if [[ -n "$PREV_SWITCH" && "${DATA_SWITCH_NAME[$i]}" != "$PREV_SWITCH" ]]; then
                printf '%*s\n' "$SEP_WIDTH" '' | tr ' ' '-'
            fi
            PREV_SWITCH="${DATA_SWITCH_NAME[$i]}"
        fi

        if [[ "$SHOW_SWITCH_COL" == true ]]; then
            printf "%-${COL_W_SWITCH}s${COL_GAP}" "${DATA_SWITCH_NAME[$i]}"
        fi
        printf "%-${COL_W_PORT}s${COL_GAP}" "${DATA_PORT_NAME[$i]}"
        pad_color "${DATA_LAG_COLOR[$i]}" "$COL_W_LAG"
        printf "${COL_GAP}"
        printf "%-${COL_W_DESC}s${COL_GAP}" "${DATA_DESCRIPTION[$i]}"
        pad_color "${DATA_ADMIN_COLOR[$i]}" "$COL_W_ADMIN"
        printf "${COL_GAP}"
        pad_color "${DATA_OPER_COLOR[$i]}" "$COL_W_OPER"
        printf "${COL_GAP}"
        pad_color "${DATA_SPEED_COLOR[$i]}" "$COL_W_SPEED"
        printf "${COL_GAP}"
        printf "%-${COL_W_MTU}s${COL_GAP}" "${DATA_MTU[$i]}"
        printf "%-${COL_W_NEIGHBOR}s${COL_GAP}" "${DATA_LLDP_NEIGHBOR[$i]}"
        printf "%-${COL_W_RPORT}s" "${DATA_REMOTE_PORT[$i]}"
        if [[ "$SHOW_LLDP_DETAIL" == true ]]; then
            printf "${COL_GAP}%-${COL_W_LLDPDESC}s" "${DATA_LLDP_DESC[$i]}"
        fi
        if [[ "$SHOW_VLANS" == true ]]; then
            printf "${COL_GAP}%-${COL_W_PVID}s" "${DATA_PVID[$i]}"
        fi
        if [[ "$SHOW_MODEL" == true && "$SHOW_SWITCH_COL" == true ]]; then
            printf "${COL_GAP}%-${COL_W_MODEL}s" "${DATA_MODEL[$i]}"
        fi
        printf "\n"
    done

elif [[ "$OUTPUT_FORMAT" == "csv" ]]; then
    FS="${FIELD_SEP:-,}"

    # Header
    [[ "$SHOW_SWITCH_COL" == true ]] && printf "Switch${FS}"
    printf "Port${FS}LAG${FS}Description${FS}Admin${FS}Oper${FS}Speed${FS}MTU${FS}LLDP Neighbor${FS}Remote Port"
    [[ "$SHOW_LLDP_DETAIL" == true ]] && printf "${FS}LLDP Description"
    [[ "$SHOW_VLANS" == true ]] && printf "${FS}PVID"
    [[ "$SHOW_MODEL" == true ]] && printf "${FS}Model"
    printf "\n"

    # Data
    for i in "${RENDER_ORDER[@]}"; do
        [[ "$SHOW_SWITCH_COL" == true ]] && printf "%s${FS}" "${DATA_SWITCH_NAME[$i]}"
        printf "%s${FS}%s${FS}%s${FS}%s${FS}%s${FS}%s${FS}%s${FS}%s${FS}%s" \
            "${DATA_PORT_NAME[$i]}" "${DATA_LAG[$i]}" "${DATA_DESCRIPTION[$i]}" \
            "${DATA_ADMIN[$i]}" "${DATA_OPER[$i]}" "${DATA_SPEED[$i]}" "${DATA_MTU[$i]}" \
            "${DATA_LLDP_NEIGHBOR[$i]}" "${DATA_REMOTE_PORT[$i]}"
        [[ "$SHOW_LLDP_DETAIL" == true ]] && printf "${FS}%s" "${DATA_LLDP_DESC[$i]}"
        [[ "$SHOW_VLANS" == true ]] && printf "${FS}%s" "${DATA_PVID[$i]}"
        [[ "$SHOW_MODEL" == true ]] && printf "${FS}%s" "${DATA_MODEL[$i]}"
        printf "\n"
    done

elif [[ "$OUTPUT_FORMAT" == "json" ]]; then
    MULTI_SWITCH=false
    [[ ${#SWITCH_TARGETS[@]} -gt 1 && $SWITCHES_OK -gt 1 ]] && MULTI_SWITCH=true

    if [[ "$MULTI_SWITCH" == true ]]; then
        printf '{\n'
        # Group rows by switch
        declare -A JSON_SW_INDICES
        for i in "${RENDER_ORDER[@]}"; do
            SW="${DATA_SWITCH_NAME[$i]}"
            JSON_SW_INDICES["$SW"]+="$i "
        done

        SW_COUNT=0
        TOTAL_SWITCHES=${#JSON_SW_INDICES[@]}
        for SW in $(printf '%s\n' "${!JSON_SW_INDICES[@]}" | sort); do
            ((SW_COUNT++))
            printf '  "%s": [\n' "$(json_escape "$SW")"

            read -ra INDICES <<< "${JSON_SW_INDICES[$SW]}"
            LAST_IDX="${INDICES[-1]}"
            for i in "${INDICES[@]}"; do
                printf '    {\n'
                printf '      "port": "%s",\n' "$(json_escape "${DATA_PORT_NAME[$i]}")"
                printf '      "lag": "%s",\n' "$(json_escape "${DATA_LAG[$i]}")"
                printf '      "description": "%s",\n' "$(json_escape "${DATA_DESCRIPTION[$i]}")"
                printf '      "admin_status": "%s",\n' "$(json_escape "${DATA_ADMIN[$i]}")"
                printf '      "oper_status": "%s",\n' "$(json_escape "${DATA_OPER[$i]}")"
                printf '      "speed": "%s",\n' "$(json_escape "${DATA_SPEED[$i]}")"
                printf '      "mtu": %s,\n' "${DATA_MTU[$i]:-0}"
                printf '      "lldp_neighbor": "%s",\n' "$(json_escape "${DATA_LLDP_NEIGHBOR[$i]}")"
                printf '      "remote_port": "%s"' "$(json_escape "${DATA_REMOTE_PORT[$i]}")"
                if [[ "$SHOW_LLDP_DETAIL" == true ]]; then
                    printf ',\n      "lldp_description": "%s"' "$(json_escape "${DATA_LLDP_DESC[$i]}")"
                fi
                if [[ "$SHOW_VLANS" == true ]]; then
                    printf ',\n      "pvid": "%s"' "$(json_escape "${DATA_PVID[$i]}")"
                fi
                if [[ "$SHOW_MODEL" == true ]]; then
                    printf ',\n      "model": "%s"' "$(json_escape "${DATA_MODEL[$i]}")"
                fi
                printf '\n    }'
                [[ "$i" != "$LAST_IDX" ]] && printf ','
                printf '\n'
            done

            printf '  ]'
            [[ $SW_COUNT -lt $TOTAL_SWITCHES ]] && printf ','
            printf '\n'
        done
        printf '}\n'
        unset JSON_SW_INDICES
    else
        printf '[\n'
        LAST_IDX="${RENDER_ORDER[-1]}"
        for i in "${RENDER_ORDER[@]}"; do
            printf '  {\n'
            printf '    "port": "%s",\n' "$(json_escape "${DATA_PORT_NAME[$i]}")"
            printf '    "lag": "%s",\n' "$(json_escape "${DATA_LAG[$i]}")"
            printf '    "description": "%s",\n' "$(json_escape "${DATA_DESCRIPTION[$i]}")"
            printf '    "admin_status": "%s",\n' "$(json_escape "${DATA_ADMIN[$i]}")"
            printf '    "oper_status": "%s",\n' "$(json_escape "${DATA_OPER[$i]}")"
            printf '    "speed": "%s",\n' "$(json_escape "${DATA_SPEED[$i]}")"
            printf '    "mtu": %s,\n' "${DATA_MTU[$i]:-0}"
            printf '    "lldp_neighbor": "%s",\n' "$(json_escape "${DATA_LLDP_NEIGHBOR[$i]}")"
            printf '    "remote_port": "%s"' "$(json_escape "${DATA_REMOTE_PORT[$i]}")"
            if [[ "$SHOW_LLDP_DETAIL" == true ]]; then
                printf ',\n    "lldp_description": "%s"' "$(json_escape "${DATA_LLDP_DESC[$i]}")"
            fi
            if [[ "$SHOW_VLANS" == true ]]; then
                printf ',\n    "pvid": "%s"' "$(json_escape "${DATA_PVID[$i]}")"
            fi
            if [[ "$SHOW_MODEL" == true ]]; then
                printf ',\n    "model": "%s"' "$(json_escape "${DATA_MODEL[$i]}")"
            fi
            printf '\n  }'
            [[ "$i" != "$LAST_IDX" ]] && printf ','
            printf '\n'
        done
        printf ']\n'
    fi

elif [[ "$OUTPUT_FORMAT" == "dot" ]]; then
    generate_dot

elif [[ "$OUTPUT_FORMAT" == "svg" || "$OUTPUT_FORMAT" == "png" ]]; then
    if [[ -z "$DIAGRAM_OUTPUT_FILE" ]]; then
        DIAGRAM_OUTPUT_FILE="/tmp/switch-xray-$(date +%Y%m%d-%H%M%S).${OUTPUT_FORMAT}"
    fi

    if generate_dot | dot -T"$OUTPUT_FORMAT" -o "$DIAGRAM_OUTPUT_FILE" 2>/dev/null; then
        echo "Diagram saved to: $DIAGRAM_OUTPUT_FILE" >&2
    else
        echo "Failed to render diagram. Check that graphviz is working correctly." >&2
        exit 1
    fi
fi
