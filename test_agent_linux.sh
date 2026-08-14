#!/bin/bash
# ====================================================================
# SIEM TEST AGENT FOR LINUX (Kali Linux)
# Untuk Pengujian Dashboard - TIDAK mengubah file apapun
# PT BPR Bank Daerah Gianyar (Perseroda)
# ====================================================================

SERVER_URL="http://localhost:5000/api"
HOSTNAME=$(hostname)
AGENT_VERSION="2.1-linux-test"
OS_INFO=$(uname -o 2>/dev/null || echo "GNU/Linux") 
IP_ADDR=$(hostname -I 2>/dev/null | awk '{print $1}')
if [ -z "$IP_ADDR" ]; then IP_ADDR="127.0.0.1"; fi
USERNAME=$(whoami)

# Warna terminal
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
WHITE='\033[1;37m'
NC='\033[0m'

log() {
    local color=$1
    shift
    echo -e "${color}[$(date '+%Y-%m-%d %H:%M:%S')] $*${NC}" >&2
}

# ─── 1. REGISTER AGENT ──────────────────────────────
register_agent() {
    log $CYAN "Registering agent to server..."
    RESULT=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$SERVER_URL/agent/register" \
        -H "Content-Type: application/json" \
        -d "{\"hostname\":\"$HOSTNAME\",\"os\":\"$OS_INFO\",\"ip\":\"$IP_ADDR\",\"agent_version\":\"$AGENT_VERSION\"}" \
        --connect-timeout 3 2>/dev/null)
    
    if [ "$RESULT" = "200" ]; then
        log $GREEN "✓ Agent registered successfully (hostname: $HOSTNAME)"
        return 0
    else
        log $RED "✗ Failed to register (HTTP $RESULT)"
        return 1
    fi
}

# ─── 2. HEARTBEAT ────────────────────────────────────
send_heartbeat() {
    RESULT=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$SERVER_URL/agent/heartbeat" \
        -H "Content-Type: application/json" \
        -d "{\"hostname\":\"$HOSTNAME\",\"ip\":\"$IP_ADDR\"}" \
        --connect-timeout 2 2>/dev/null)
    
    if [ "$RESULT" = "200" ]; then
        log $GREEN "♥ Heartbeat sent"
    else
        log $YELLOW "♥ Heartbeat failed (HTTP $RESULT)"
    fi
}

# ─── 3. SIMULATE LOGIN EVENT ────────────────────────
send_login_event() {
    local action=$1
    if [ -z "$action" ]; then action="login"; fi
    
    RESULT=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$SERVER_URL/agent/login-event" \
        -H "Content-Type: application/json" \
        -d "{\"hostname\":\"$HOSTNAME\",\"username\":\"$USERNAME\",\"action\":\"$action\",\"ip\":\"$IP_ADDR\"}" \
        --connect-timeout 3 2>/dev/null)
    
    if [ "$RESULT" = "200" ]; then
        log $CYAN "→ Login event sent: $USERNAME ($action)"
    fi
}

# ─── 4. SIMULATE USER ACTIVITY ──────────────────────
send_user_activity() {
    # Detect actual foreground window on Linux using xdotool
    local proc_name="unknown"
    local window_title="Unknown Window"
    
    if command -v xdotool &>/dev/null; then
        local wid=$(xdotool getactivewindow 2>/dev/null)
        if [ -n "$wid" ]; then
            window_title=$(xdotool getactivewindow getwindowname 2>/dev/null || echo "Desktop")
            local pid=$(xdotool getactivewindow getwindowpid 2>/dev/null)
            if [ -n "$pid" ]; then
                proc_name=$(ps -p $pid -o comm= 2>/dev/null || echo "unknown")
            fi
        fi
    else
        # Fallback: simulate with random apps
        local apps=("firefox" "terminal" "code" "chromium" "libreoffice" "thunar" "mousepad")
        local titles=("Mozilla Firefox - Google" "Terminal - bash" "Visual Studio Code" "Chromium - Dashboard" "LibreOffice Writer" "File Manager" "Text Editor")
        local idx=$((RANDOM % ${#apps[@]}))
        proc_name="${apps[$idx]}"
        window_title="${titles[$idx]}"
    fi
    
    # Escape special chars for JSON
    window_title=$(echo "$window_title" | sed 's/"/\\"/g' | head -c 200)
    
    RESULT=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$SERVER_URL/agent/user-activity" \
        -H "Content-Type: application/json" \
        -d "{\"hostname\":\"$HOSTNAME\",\"username\":\"$USERNAME\",\"process_name\":\"$proc_name\",\"window_title\":\"$window_title\",\"duration\":15}" \
        --connect-timeout 3 2>/dev/null)
    
    if [ "$RESULT" = "200" ]; then
        log $WHITE "📺 Activity: $proc_name - $window_title"
    fi
}

# ─── 5. SIMULATE USB EVENT ──────────────────────────
send_usb_event() {
    local serial=$1
    local name=$2
    local action=$3
    
    RESULT=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$SERVER_URL/agent/usb-event" \
        -H "Content-Type: application/json" \
        -d "{\"hostname\":\"$HOSTNAME\",\"serial_number\":\"$serial\",\"device_name\":\"$name\",\"action\":\"$action\"}" \
        --connect-timeout 3 2>/dev/null)
    
    if [ "$RESULT" = "200" ]; then
        if [ "$action" = "blocked" ]; then
            log $RED "🔒 USB BLOCKED: $serial ($name)"
        else
            log $GREEN "🔓 USB Connected: $serial ($name)"
        fi
    fi
}

# ─── 6. CHECK USB POLICY ────────────────────────────
check_usb_policy() {
    local response=$(curl -s "$SERVER_URL/allowed_usbs" --connect-timeout 3 2>/dev/null)
    
    if [ -n "$response" ]; then
        local default_policy=$(echo "$response" | python3 -c "import sys,json; print(json.load(sys.stdin).get('default_policy','block'), end='')" 2>/dev/null)
        local allowed=$(echo "$response" | python3 -c "import sys,json; print(','.join(json.load(sys.stdin).get('allowed_serials',[])), end='')" 2>/dev/null)
        local blocked=$(echo "$response" | python3 -c "import sys,json; print(','.join(json.load(sys.stdin).get('blocked_serials',[])), end='')" 2>/dev/null)
        
        log $MAGENTA "📋 Policy: default=$default_policy | allowed=[$allowed] | blocked=[$blocked]"
        echo "$default_policy|$allowed|$blocked"
    else
        log $YELLOW "📋 Cannot fetch policy"
        echo "block||"
    fi
}

# Global associative array to track USB states so we don't spam the server
declare -A USB_STATES

simulate_usb_sync() {
    local policy_data=$(check_usb_policy)
    local default_policy=$(echo "$policy_data" | cut -d'|' -f1)
    local allowed_list=$(echo "$policy_data" | cut -d'|' -f2)
    local blocked_list=$(echo "$policy_data" | cut -d'|' -f3)
    
    # Detect real USB block devices on Linux
    local has_usb=false
    for dev in /sys/block/sd*; do
        [ -d "$dev" ] || continue
        
        local devname=$(basename "$dev")
        local udev_info=$(udevadm info --query=property --name="/dev/$devname" 2>/dev/null)
        
        # Cek apakah device ini terhubung via USB (Flashdisk / HDD Eksternal)
        if echo "$udev_info" | grep -q "ID_BUS=usb"; then
            has_usb=true
            local serial=$(echo "$udev_info" | grep "ID_SERIAL_SHORT=" | cut -d= -f2)
            local model=$(echo "$udev_info" | grep "ID_MODEL=" | cut -d= -f2)
            
            if [ -z "$serial" ]; then serial="UNKNOWN_$(echo $devname | tr '[:lower:]' '[:upper:]')"; fi
            if [ -z "$model" ]; then model="USB Storage ($devname)"; fi
            serial=$(echo "$serial" | tr -cd 'A-Za-z0-9' | tr '[:lower:]' '[:upper:]')
            
            log $CYAN "  Found USB: /dev/$devname | Serial: $serial | Model: $model"
            
            # Check policy
            local current_state=""
            if echo ",$allowed_list," | grep -qi ",$serial,"; then
                log $GREEN "  → $serial is WHITELISTED (allowed)"
                current_state="connected"
            elif echo ",$blocked_list," | grep -qi ",$serial,"; then
                log $RED "  → $serial is BLACKLISTED (blocked)"
                current_state="blocked"
            else
                if [ "$default_policy" = "allow" ]; then
                    log $GREEN "  → $serial follows default policy: ALLOW"
                    current_state="connected"
                else
                    log $RED "  → $serial follows default policy: BLOCK"
                    current_state="blocked"
                fi
            fi
            
            # --- PHYSICAL ENFORCEMENT PADA LINUX ---
            if [ "$current_state" = "blocked" ]; then
                # Paksa Unmount semua partisi flashdisk agar hilang dari File Manager
                for part in /dev/${devname}*; do
                    if mount | grep -q "$part"; then
                        umount -l "$part" 2>/dev/null
                    fi
                done
                # Keluarkan/Eject perangkat (seperti Safely Remove Hardware)
                eject /dev/$devname 2>/dev/null
            fi
            # ---------------------------------------

            # Hanya kirim event ke server jika state berubah (menghindari spam event berulang)
            if [ "${USB_STATES[$serial]}" != "$current_state" ]; then
                send_usb_event "$serial" "$model" "$current_state"
                USB_STATES[$serial]=$current_state
            fi
        fi
    done
    
    if [ "$has_usb" = false ]; then
        log $YELLOW "  Tidak ada USB Flashdisk / Eksternal HDD terdeteksi di sistem"
    fi
}

# ====================================================================
# INTERACTIVE MENU
# ====================================================================
show_menu() {
    echo ""
    echo -e "${WHITE}╔══════════════════════════════════════════════╗${NC}"
    echo -e "${WHITE}║  ${RED}SIEM Test Agent - Kali Linux${WHITE}                ║${NC}"
    echo -e "${WHITE}║  ${CYAN}PT BPR Bank Daerah Gianyar${WHITE}                 ║${NC}"
    echo -e "${WHITE}╠══════════════════════════════════════════════╣${NC}"
    echo -e "${WHITE}║  ${GREEN}1${WHITE}. Jalankan Auto Mode (Loop terus)         ║${NC}"
    echo -e "${WHITE}║  ${GREEN}2${WHITE}. Register Agent (Manual)                 ║${NC}"
    echo -e "${WHITE}║  ${GREEN}3${WHITE}. Kirim Heartbeat (Manual)                ║${NC}"
    echo -e "${WHITE}║  ${GREEN}4${WHITE}. Simulasi Login Event                    ║${NC}"
    echo -e "${WHITE}║  ${GREEN}5${WHITE}. Simulasi User Activity                  ║${NC}"
    echo -e "${WHITE}║  ${GREEN}6${WHITE}. Simulasi USB Dicolokkan (Custom SN)     ║${NC}"
    echo -e "${WHITE}║  ${GREEN}7${WHITE}. Cek & Sinkronisasi Kebijakan USB        ║${NC}"
    echo -e "${WHITE}║  ${GREEN}8${WHITE}. Simulasi USB Diblokir (Custom SN)       ║${NC}"
    echo -e "${WHITE}║  ${GREEN}0${WHITE}. Keluar                                  ║${NC}"
    echo -e "${WHITE}╚══════════════════════════════════════════════╝${NC}"
    echo -ne "${YELLOW}Pilih menu [0-8]: ${NC}"
}

auto_mode() {
    log $CYAN "═══ AUTO MODE STARTED (Ctrl+C untuk berhenti) ═══"
    register_agent
    send_login_event "login"
    
    local counter=0
    while true; do
        send_heartbeat
        simulate_usb_sync
        send_user_activity
        
        # Send simulated login event once every 5 minutes
        if [ $((counter % 20)) -eq 0 ] && [ $counter -gt 0 ]; then
            send_login_event "login"
        fi
        
        counter=$((counter + 1))
        sleep 15
    done
}

# ====================================================================
# MAIN
# ====================================================================
clear
echo -e "${RED}"
echo "  ____  ___ _____ __  __   _____         _   "
echo " / ___|/ _ \\_   _|  \\/  | |_   _|__  ___| |_ "
echo " \\___ \\  __/ | | | |\\/| |   | |/ _ \\/ __| __|"
echo "  ___) \\___| |_| |_|  |_|   |_|\\___/\\___|\\__|"
echo -e "${NC}"
echo -e "${WHITE}  Server: $SERVER_URL${NC}"
echo -e "${WHITE}  Host:   $HOSTNAME | IP: $IP_ADDR | User: $USERNAME${NC}"
echo ""

while true; do
    show_menu
    read -r choice
    
    case $choice in
        1)
            auto_mode
            ;;
        2)
            register_agent
            ;;
        3)
            send_heartbeat
            ;;
        4)
            echo -ne "${YELLOW}Tipe event (login/logout) [login]: ${NC}"
            read -r evt
            if [ -z "$evt" ]; then evt="login"; fi
            send_login_event "$evt"
            ;;
        5)
            send_user_activity
            ;;
        6)
            echo -ne "${YELLOW}Serial Number USB: ${NC}"
            read -r sn
            echo -ne "${YELLOW}Nama Device [USB Flash Drive]: ${NC}"
            read -r devname
            if [ -z "$devname" ]; then devname="USB Flash Drive"; fi
            sn=$(echo "$sn" | tr -cd 'A-Za-z0-9' | tr '[:lower:]' '[:upper:]')
            send_usb_event "$sn" "$devname" "connected"
            ;;
        7)
            simulate_usb_sync
            ;;
        8)
            echo -ne "${YELLOW}Serial Number USB yang diblokir: ${NC}"
            read -r sn
            echo -ne "${YELLOW}Nama Device [USB Flash Drive]: ${NC}"
            read -r devname
            if [ -z "$devname" ]; then devname="USB Flash Drive"; fi
            sn=$(echo "$sn" | tr -cd 'A-Za-z0-9' | tr '[:lower:]' '[:upper:]')
            send_usb_event "$sn" "$devname" "blocked"
            ;;
        0)
            log $CYAN "Agent dihentikan. Sampai jumpa!"
            exit 0
            ;;
        *)
            log $RED "Pilihan tidak valid"
            ;;
    esac
done
