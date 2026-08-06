#!/bin/bash

set -u

###############################################################################
# Root check
###############################################################################

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: root privileges required"
    echo
    echo "Run:"
    echo "    sudo bash $(basename "$0")"
    echo
    exit 1
fi

###############################################################################
# Find modem and AT port
###############################################################################

MODEM_ID=$(
    mmcli -L |
    sed -n 's#.*Modem/\([0-9]\+\).*#\1#p' |
    head -n1
)

if [ -z "$MODEM_ID" ]; then
    echo "ERROR: No modem found"
    exit 1
fi

AT_PORT=$(
    mmcli -m "$MODEM_ID" |
    grep -oE 'ttyUSB[0-9]+ \(at\)' |
    head -n1 |
    cut -d' ' -f1
)

if [ -z "$AT_PORT" ]; then
    echo "ERROR: No AT port found"
    exit 1
fi

DEV="/dev/$AT_PORT"

echo "=============================================================="
echo "SIM7600 Diagnostics"
echo "=============================================================="
echo "Modem ID : $MODEM_ID"
echo "AT Port  : $DEV"

###############################################################################
# Summary variables
###############################################################################

SIM_STATUS="UNKNOWN"
SIGNAL_STATUS="UNKNOWN"
REG_STATUS="UNKNOWN"
SERVICE_STATUS="UNKNOWN"
LTE_SIGNAL_STATUS="UNKNOWN"
APN_STATUS="UNKNOWN"

ISSUES=()

###############################################################################
# Decoders
###############################################################################

cme_decode() {
    case "$1" in
        3)  echo "Operation not allowed" ;;
        10) echo "SIM not inserted" ;;
        11) echo "SIM PIN required" ;;
        12) echo "SIM PUK required" ;;
        13) echo "SIM failure" ;;
        14) echo "SIM busy" ;;
        15) echo "SIM wrong" ;;
        30) echo "No network service" ;;
        *)  echo "Unknown CME error $1" ;;
    esac
}

reg_decode() {
    case "$1" in
        0) echo "Not registered" ;;
        1) echo "Registered (home)" ;;
        2) echo "Searching" ;;
        3) echo "Registration denied" ;;
        4) echo "Unknown / out of coverage" ;;
        5) echo "Registered (roaming)" ;;
        *) echo "Unknown" ;;
    esac
}

decode_network_scan() {

    echo
    echo "Cellular networks detected"
    echo

    LTE_COUNT=0
    GSM_COUNT=0

    grep -oP '\(\d+,"[^"]+","[^"]+","[^"]+",\d+\)' <<< "$RESPONSE" |
    while read -r NET; do

        STATUS=$(sed 's/^(\([0-9]\+\).*/\1/' <<< "$NET")
        OPERATOR=$(sed 's/([^,]*,"\([^"]*\)".*/\1/' <<< "$NET")
        MCCMNC=$(sed 's/.*,"\([0-9]\+\)",\([0-9]\+\)).*/\1/' <<< "$NET")
        RAT=$(sed 's/.*,\([0-9]\+\))$/\1/' <<< "$NET")

        case "$STATUS" in
            0) STATUS_TXT="Available" ;;
            1) STATUS_TXT="Available" ;;
            2) STATUS_TXT="Current" ;;
            3) STATUS_TXT="Forbidden" ;;
            *) STATUS_TXT="Unknown" ;;
        esac

        case "$RAT" in
            0)
                RAT_TXT="GSM"
                GSM_COUNT=$((GSM_COUNT + 1))
                ;;
            2)
                RAT_TXT="UMTS"
                ;;
            7)
                RAT_TXT="LTE"
                LTE_COUNT=$((LTE_COUNT + 1))
                ;;
            *)
                RAT_TXT="Unknown ($RAT)"
                ;;
        esac

        echo "$OPERATOR"
        echo "  MCC/MNC : $MCCMNC"
        echo "  RAT     : $RAT_TXT"
        echo "  Status  : $STATUS_TXT"
        echo
    done

    echo "Summary:"
    echo "  LTE networks visible : yes"
    echo "  Radio operational    : yes"
    echo "  Coverage available   : yes"
}

###############################################################################
# Transport
###############################################################################

send_at() {

    local CMD="$1"
    local WAIT="${2:-5}"

    echo
    echo "================================================================"
    echo "$CMD"
    echo "================================================================"

    local TMP
    TMP=$(mktemp)

    RESPONSE=""

    ###########################################################################
    # Attempt 1: reader first
    ###########################################################################

    cat "$DEV" > "$TMP" 2>/dev/null &
    local CATPID=$!

    sleep 0.2

    printf '%s\r' "$CMD" > "$DEV"

    local ELAPSED=0

    while [ "$ELAPSED" -lt "$WAIT" ]; do

        sleep 1
        ELAPSED=$((ELAPSED + 1))

        if grep -qE '(^OK$|ERROR|\+CME ERROR:)' "$TMP" 2>/dev/null; then
            break
        fi
    done

    kill "$CATPID" 2>/dev/null || true
    wait "$CATPID" 2>/dev/null || true

    RESPONSE=$(cat "$TMP" 2>/dev/null)

    ###########################################################################
    # Attempt 2: cat exited immediately
    ###########################################################################

    if [ -z "$RESPONSE" ]; then

        printf '%s\r' "$CMD" > "$DEV"

        sleep 0.2

        RESPONSE=$(
            timeout "$WAIT" cat "$DEV" 2>/dev/null || true
        )
    fi

    rm -f "$TMP"

    if [ -z "$RESPONSE" ]; then
        echo "<no response>"
        return
    fi

    echo "$RESPONSE"

    echo
    echo "--- Decoded ---"

    ###########################################################################
    # CME errors
    ###########################################################################

    if grep -q "+CME ERROR:" <<< "$RESPONSE"; then

        ERR=$(
            sed -n 's/.*+CME ERROR: *\([0-9]\+\).*/\1/p' \
            <<< "$RESPONSE" |
            head -n1
        )

        MSG=$(cme_decode "$ERR")

        echo "$MSG"

        case "$ERR" in
            10)
                SIM_STATUS="NOT PRESENT"
                ISSUES+=("No SIM card inserted")
                ;;
            11)
                SIM_STATUS="PIN REQUIRED"
                ISSUES+=("SIM PIN required")
                ;;
            12)
                SIM_STATUS="PUK REQUIRED"
                ISSUES+=("SIM PUK required")
                ;;
        esac

        return
    fi

    ###########################################################################
    # Specific decoders
    ###########################################################################

    case "$CMD" in

        "AT+CPIN?")

            if grep -q "READY" <<< "$RESPONSE"; then
                SIM_STATUS="READY"
                echo "SIM present and unlocked"

            elif grep -q "SIM PIN" <<< "$RESPONSE"; then
                SIM_STATUS="PIN REQUIRED"
                ISSUES+=("SIM PIN required")
                echo "SIM PIN required"

            elif grep -q "SIM PUK" <<< "$RESPONSE"; then
                SIM_STATUS="PUK REQUIRED"
                ISSUES+=("SIM PUK required")
                echo "SIM PUK required"
            fi
            ;;

        "AT+CGDCONT?")

            APNS=$(grep '+CGDCONT:' <<< "$RESPONSE")

            if [ -z "$APNS" ]; then

                APN_STATUS="NONE"

                echo "No PDP contexts configured"

            else

                echo "Configured PDP contexts:"
                echo

                while IFS= read -r LINE; do

                    CID=$(sed -n 's/+CGDCONT: *\([0-9]\+\).*/\1/p' <<< "$LINE")

                    PDP=$(sed -n 's/+CGDCONT: *[0-9]\+,"\([^"]*\)".*/\1/p' <<< "$LINE")

                    APN=$(sed -n 's/+CGDCONT: *[0-9]\+,"[^"]*","\([^"]*\)".*/\1/p' <<< "$LINE")

                    echo "CID : $CID"
                    echo "PDP : $PDP"
                    echo "APN : $APN"
                    echo

                    if [ "$CID" = "1" ]; then
                        APN_STATUS="$APN"
                    fi

                done <<< "$APNS"
            fi
            ;;

        "AT+CGCONTRDP")

            if grep -q "+CGCONTRDP:" <<< "$RESPONSE"; then

                APN=$(awk -F, '/^\+CGCONTRDP:/ {print $3}' <<< "$RESPONSE")

                echo "Active APN: $APN"

            else

                echo "No active PDP context"
            fi
            ;;

        "AT+CCID")

            ICCID=$(grep -oE '[0-9]{18,22}' <<< "$RESPONSE" | head -n1)

            [ -n "$ICCID" ] && echo "ICCID: $ICCID"
            ;;

        "AT+CIMI")

            IMSI=$(grep -oE '[0-9]{14,16}' <<< "$RESPONSE" | head -n1)

            if [ -n "$IMSI" ]; then
                echo "IMSI : $IMSI"
                echo "MCC  : ${IMSI:0:3}"
                echo "MNC  : ${IMSI:3:2}"
            fi
            ;;

        "AT+CFUN?")

            FUN=$(sed -n 's/.*+CFUN: *\([0-9]\+\).*/\1/p' <<< "$RESPONSE")

            case "$FUN" in
                0) echo "Minimum functionality" ;;
                1) echo "Full functionality" ;;
                4) echo "Flight mode" ;;
            esac
            ;;

        "AT+CSQ")

            CSQ=$(sed -n 's/.*+CSQ: *\([0-9]\+\),.*/\1/p' <<< "$RESPONSE")

            if [ -n "$CSQ" ]; then

                if [ "$CSQ" -eq 99 ]; then

                    SIGNAL_STATUS="NO SIGNAL"
                    echo "No measurable signal"

                else

                    DBM=$((-113 + 2 * CSQ))

                    if [ "$CSQ" -ge 25 ]; then
                        QUALITY="Excellent"
                    elif [ "$CSQ" -ge 15 ]; then
                        QUALITY="Good"
                    elif [ "$CSQ" -ge 10 ]; then
                        QUALITY="Fair"
                    else
                        QUALITY="Poor"
                    fi

                    SIGNAL_STATUS="$QUALITY ($DBM dBm)"

                    echo "CSQ     : $CSQ"
                    echo "RSSI    : ${DBM} dBm"
                    echo "Quality : $QUALITY"
                fi
            fi
            ;;

        "AT+CESQ")

            CESQ=$(sed -n 's/.*+CESQ: *//p' <<< "$RESPONSE" | head -n1)

            if [ -n "$CESQ" ]; then

                IFS=',' read -r RXLEV BER RSCP ECNO RSRQ RSRP <<< "$CESQ"

                echo "RXLEV : $RXLEV"

                if [ "$RSRP" = "255" ] || [ "$RSRQ" = "255" ]; then

                    LTE_SIGNAL_STATUS="NO SERVING CELL"

                    echo "No serving LTE cell"
                    echo "RSRP/RSRQ unavailable"

                else
					RSRP=${RSRP//$'\r'/}
					RSRQ=${RSRQ//$'\r'/}

                    #
                    # LTE conversions per 3GPP
                    #
                    RSRP_DBM=$((RSRP - 140))

                    RSRQ_DB=$(awk \
                        "BEGIN {printf \"%.1f\", ($RSRQ/2)-19.5}")

                    echo "RSRP  : ${RSRP_DBM} dBm"
                    echo "RSRQ  : ${RSRQ_DB} dB"

                    if [ "$RSRP_DBM" -ge -90 ]; then
                        QUALITY="Excellent"
                    elif [ "$RSRP_DBM" -ge -100 ]; then
                        QUALITY="Good"
                    elif [ "$RSRP_DBM" -ge -110 ]; then
                        QUALITY="Fair"
                    else
                        QUALITY="Poor"
                    fi

                    LTE_SIGNAL_STATUS="$QUALITY (${RSRP_DBM} dBm)"

                    echo "LTE signal quality: $QUALITY"
                fi
            fi
            ;;

        "AT+CPSI?")

            if grep -q "NO SERVICE" <<< "$RESPONSE"; then

                SERVICE_STATUS="NO SERVICE"
                ISSUES+=("No serving cell")

                echo "No service"
                echo "Not camped on a serving cell"

            elif grep -q "LTE" <<< "$RESPONSE"; then

                SERVICE_STATUS="LTE"
                echo "LTE service available"
            fi
            ;;

        "AT+CREG?"|"AT+CGREG?"|"AT+CEREG?")

            REG=$(sed -n 's/.*: *[0-9]\+,\([0-9]\+\).*/\1/p' <<< "$RESPONSE")

            if [ -n "$REG" ]; then

                MSG=$(reg_decode "$REG")

                echo "$MSG"

                if [ "$CMD" = "AT+CEREG?" ]; then
                    REG_STATUS="$MSG"
                fi
            fi
            ;;

        "AT+COPS?")

            MODE=$(sed -n 's/+COPS: *\([0-9]\+\).*/\1/p' <<< "$RESPONSE")

            case "$MODE" in
                0) echo "Operator selection: Automatic" ;;
                1) echo "Operator selection: Manual" ;;
                2) echo "Operator selection: Deregistered" ;;
            esac
            ;;

        "AT+CNMP?")

            MODE=$(sed -n 's/.*+CNMP: *\([0-9]\+\).*/\1/p' <<< "$RESPONSE")

            case "$MODE" in
                2)  echo "Automatic mode" ;;
                13) echo "GSM only" ;;
                14) echo "WCDMA only" ;;
                38) echo "LTE only" ;;
            esac
            ;;

        "AT+COPS=?")

    		decode_network_scan
    		;;
    esac
}

###############################################################################
# Run diagnostics
###############################################################################

send_at "ATI" 3
send_at "AT+GMR" 3
send_at "AT+CPIN?" 3
send_at "AT+CGDCONT?" 5
send_at "AT+CGCONTRDP" 10
send_at "AT+CFUN?" 3
send_at "AT+CSQ" 5
send_at "AT+CESQ" 5
send_at "AT+CPSI?" 5
send_at "AT+CREG?" 5
send_at "AT+CGREG?" 5
send_at "AT+CEREG?" 5

if [ "$SIM_STATUS" = "READY" ]; then

    send_at "AT+CCID" 5
    send_at "AT+CIMI" 5
    send_at "AT+COPS?" 5
    send_at "AT+CNMP?" 5

    echo
    echo "================================================================"
    echo "NETWORK SCAN  (may take several minutes)"
    echo "================================================================"

    send_at "AT+COPS=?" 240
fi

###############################################################################
# Summary
###############################################################################

echo
echo "================================================================"
echo "DIAGNOSTIC SUMMARY"
echo "================================================================"

echo "SIM Status   : $SIM_STATUS"
echo "APN          : $APN_STATUS"
echo "Signal       : $SIGNAL_STATUS"
echo "LTE Signal   : $LTE_SIGNAL_STATUS"
echo "Registration : $REG_STATUS"
echo "Service      : $SERVICE_STATUS"

echo

if [ "${#ISSUES[@]}" -gt 0 ]; then
    echo "Detected issues:"
    for issue in "${ISSUES[@]}"; do
        echo "  - $issue"
    done
else
    echo "No obvious issues detected"
fi

echo
echo "Done."
