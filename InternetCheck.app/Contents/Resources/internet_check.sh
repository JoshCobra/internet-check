#!/usr/bin/env bash
# ==============================================================================
# Script nativo para macOS/Linux para medir la calidad de la conexión a Internet
# Sin necesidad de Python ni dependencias externas (usa curl, ping y awk nativos).
#
# Modos de uso:
#   ./internet_check.sh              -> Salida interactiva con colores en Terminal
#   ./internet_check.sh --gui-stream -> Emite eventos en vivo para InternetCheck.app
# ==============================================================================

set -u

MODE="${1:-terminal}"

# Colores ANSI para la terminal
HEADER="\033[95m"
BLUE="\033[94m"
CYAN="\033[96m"
GREEN="\033[92m"
YELLOW="\033[93m"
RED="\033[91m"
BOLD="\033[1m"
DIM="\033[2m"
END="\033[0m"

USER_AGENT="Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36"

# Archivo temporal para payload de subida (se limpia automáticamente al salir)
TMP_UPLOAD=""
cleanup() {
    if [[ -n "${TMP_UPLOAD}" && -f "${TMP_UPLOAD}" ]]; then
        rm -f "${TMP_UPLOAD}"
    fi
}
trap cleanup EXIT
trap 'printf "\n${YELLOW}Prueba cancelada por el usuario.${END}\n"; exit 0' INT TERM

# ------------------------------------------------------------------------------
# Formatea una métrica con colores según umbrales (usando awk para decimales)
# ------------------------------------------------------------------------------
format_metric() {
    local val="$1"
    local unit="$2"
    local good="$3"
    local warn="$4"
    local lower_is_better="$5"

    if [[ -z "$val" || "$val" == "NA" ]]; then
        printf "${RED}No disponible${END}"
        return
    fi

    awk -v val="$val" -v unit="$unit" -v good="$good" -v warn="$warn" -v lower="$lower_is_better" \
        -v green="$GREEN" -v yellow="$YELLOW" -v red="$RED" -v bold="$BOLD" -v end="$END" '
    BEGIN {
        color = red
        if (lower == 1) {
            if (val <= good) color = green
            else if (val <= warn) color = yellow
        } else {
            if (val >= good) color = green
            else if (val >= warn) color = yellow
        }
        printf "%s%s%.2f %s%s", color, bold, val, unit, end
    }'
}

# ------------------------------------------------------------------------------
# Formatea la intensidad de señal Wi-Fi (RSSI en dBm, ej. -47 dBm)
# ------------------------------------------------------------------------------
format_rssi() {
    local rssi="$1"
    local noise="$2"

    if [[ -z "$rssi" || "$rssi" == "NA" ]]; then
        printf "${YELLOW}No disponible (Ethernet o Wi-Fi apagado)${END}"
        return
    fi

    awk -v rssi="$rssi" -v noise="$noise" \
        -v green="$GREEN" -v yellow="$YELLOW" -v red="$RED" -v bold="$BOLD" -v end="$END" '
    BEGIN {
        r = rssi + 0
        if (r >= -60) {
            color = green
            label = "Excelente"
        } else if (r >= -70) {
            color = yellow
            label = "Buena / Regular"
        } else {
            color = red
            label = "Débil"
        }
        if (noise != "" && noise != "NA") {
            snr = r - (noise + 0)
            printf "%s%s%d dBm (%s)%s  •  Ruido: %d dBm  •  SNR: %d dB", color, bold, r, label, end, noise, snr
        } else {
            printf "%s%s%d dBm (%s)%s", color, bold, r, label, end
        }
    }'
}

# ------------------------------------------------------------------------------
# 0. Información de Red (SSID, Señal/Ruido dBm, Canal, IP Local e IP Pública)
# ------------------------------------------------------------------------------
gather_network_info() {
    NET_DEFAULT_IF=""
    NET_WIFI_IF="en0"
    NET_LOCAL_IP=""
    NET_PUBLIC_IP=""
    NET_SSID=""
    NET_RSSI="NA"
    NET_NOISE="NA"
    NET_SNR="NA"
    NET_RSSI_LABEL="N/A"
    NET_CHANNEL=""
    NET_PHY_MODE=""
    NET_TX_RATE=""

    # Detectar interfaz activa por defecto (ej. en0)
    NET_DEFAULT_IF=$(route -n get default 2>/dev/null | awk '/interface:/{print $2; exit}' || true)
    [[ -z "$NET_DEFAULT_IF" ]] && NET_DEFAULT_IF="en0"

    # Detectar cuál interfaz corresponde a Wi-Fi en macOS
    if command -v networksetup >/dev/null 2>&1; then
        local detected_wifi
        detected_wifi=$(networksetup -listallhardwareports 2>/dev/null | awk '/Wi-Fi|AirPort/{getline; if ($1 == "Device:") print $2; exit}' || true)
        [[ -n "$detected_wifi" ]] && NET_WIFI_IF="$detected_wifi"
    fi

    # Obtener IP Local
    if command -v ipconfig >/dev/null 2>&1; then
        NET_LOCAL_IP=$(ipconfig getifaddr "$NET_DEFAULT_IF" 2>/dev/null || ipconfig getifaddr "$NET_WIFI_IF" 2>/dev/null || true)
    fi
    if [[ -z "$NET_LOCAL_IP" ]]; then
        NET_LOCAL_IP=$(ifconfig "$NET_DEFAULT_IF" 2>/dev/null | awk '/inet /{print $2; exit}' || true)
    fi
    [[ -z "$NET_LOCAL_IP" ]] && NET_LOCAL_IP="No detectada"

    # Obtener IP Pública (vía Cloudflare trace, muy rápido)
    NET_PUBLIC_IP=$(curl -s --max-time 3 "https://1.1.1.1/cdn-cgi/trace" 2>/dev/null | awk -F= '/^ip=/{print $2; exit}' || true)
    [[ -z "$NET_PUBLIC_IP" ]] && NET_PUBLIC_IP="No disponible"

    # Obtener datos de Wi-Fi (SSID, Signal/Noise dBm, Canal, PHY Mode) en macOS
    if command -v system_profiler >/dev/null 2>&1; then
        local airport_info
        airport_info=$(system_profiler SPAirPortDataType 2>/dev/null || true)

        if [[ -n "$airport_info" ]]; then
            eval "$(echo "$airport_info" | awk '
            /Current Network Information:/ { in_curr = 1; next }
            /Other Local Wi-Fi Networks:/ { in_curr = 0 }
            in_curr {
                if (ssid == "" && $0 ~ /^[[:space:]]+[^:]+:[[:space:]]*$/ && $1 !~ /^(Network|PHY|Channel|Country|Security|Signal|Transmit|MCS)/) {
                    line = $0
                    sub(/^[[:space:]]+/, "", line)
                    sub(/:[[:space:]]*$/, "", line)
                    ssid = line
                }
                if ($0 ~ /Signal \/ Noise:/) {
                    for (i = 1; i <= NF; i++) {
                        if ($i ~ /^-[0-9]+$/) {
                            if (rssi == "") rssi = $i
                            else if (noise == "") noise = $i
                        }
                    }
                }
                if ($0 ~ /Channel:/ && channel == "") {
                    line = $0
                    sub(/^[[:space:]]*Channel:[[:space:]]*/, "", line)
                    channel = line
                }
                if ($0 ~ /PHY Mode:/ && phy == "") {
                    line = $0
                    sub(/^[[:space:]]*PHY Mode:[[:space:]]*/, "", line)
                    phy = line
                }
                if ($0 ~ /Transmit Rate:/ && tx == "") {
                    line = $0
                    sub(/^[[:space:]]*Transmit Rate:[[:space:]]*/, "", line)
                    tx = line
                }
            }
            END {
                gsub(/"/, "\\\"", ssid)
                printf "NET_SSID=\"%s\"; NET_RSSI=\"%s\"; NET_NOISE=\"%s\"; NET_CHANNEL=\"%s\"; NET_PHY_MODE=\"%s\"; NET_TX_RATE=\"%s\"\n",
                    ssid, (rssi != "" ? rssi : "NA"), (noise != "" ? noise : "NA"), channel, phy, tx
            }')"
        fi
    fi

    # Fallback para SSID cuando macOS oculta como "<redacted>"
    if [[ -z "$NET_SSID" || "$NET_SSID" == "<redacted>" ]]; then
        if command -v networksetup >/dev/null 2>&1; then
            local pref_ssid
            pref_ssid=$(networksetup -listpreferredwirelessnetworks "$NET_WIFI_IF" 2>/dev/null | sed -n '2p' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' || true)
            if [[ -n "$pref_ssid" ]]; then
                NET_SSID="${pref_ssid}"
            fi
        fi
    fi
    [[ -z "$NET_SSID" ]] && NET_SSID="Ethernet / No Wi-Fi"

    if [[ "$NET_RSSI" != "NA" ]]; then
        if (( NET_RSSI >= -60 )); then
            NET_RSSI_LABEL="Excelente"
        elif (( NET_RSSI >= -70 )); then
            NET_RSSI_LABEL="Buena"
        else
            NET_RSSI_LABEL="Débil"
        fi
        if [[ "$NET_NOISE" != "NA" ]]; then
            NET_SNR=$(( NET_RSSI - NET_NOISE ))
        fi
    fi
}

# ------------------------------------------------------------------------------
# 1. Resolución DNS
# ------------------------------------------------------------------------------
check_dns() {
    local domains=("cloudflare.com" "google.com" "github.com")
    local times=""
    local t

    for domain in "${domains[@]}"; do
        t=$(curl -s -o /dev/null -w "%{time_namelookup}" --connect-timeout 3 "https://${domain}" 2>/dev/null || true)
        if [[ -n "$t" ]] && awk -v t="$t" 'BEGIN { exit !(t > 0) }'; then
            times="${times} ${t}"
        fi
    done

    if [[ -z "$times" ]]; then
        echo "NA"
        return
    fi

    awk -v list="$times" '
    BEGIN {
        n = split(list, arr, " ")
        sum = 0
        for (i = 1; i <= n; i++) sum += arr[i] * 1000.0
        if (n > 0) printf "%.2f", sum / n
        else print "NA"
    }'
}

# ------------------------------------------------------------------------------
# 2. Latencia (Ping), Jitter y Pérdida de paquetes
# ------------------------------------------------------------------------------
check_ping() {
    local host="${1:-1.1.1.1}"
    local count="${2:-10}"
    local output

    output=$(ping -c "$count" -i 0.2 "$host" 2>/dev/null || true)

    if [[ -n "$output" ]] && echo "$output" | grep -q "time="; then
        echo "$output" | awk '
        /time=/ {
            for (i = 1; i <= NF; i++) {
                if ($i ~ /^time=/) {
                    sub(/^time=/, "", $i)
                    val = $i + 0
                    n++
                    rtts[n] = val
                    sum += val
                    if (n == 1 || val < min) min = val
                    if (n == 1 || val > max) max = val
                }
            }
        }
        /packet loss/ {
            for (i = 1; i <= NF; i++) {
                if ($i ~ /%$/) {
                    sub(/%$/, "", $i)
                    loss = $i + 0
                }
            }
        }
        END {
            if (loss == "") loss = 100.0
            if (n == 0) {
                printf "NA NA NA NA %.2f\n", loss
                exit
            }
            avg = sum / n
            if (n > 1) {
                sq_sum = 0
                for (i = 1; i <= n; i++) {
                    diff = rtts[i] - avg
                    sq_sum += diff * diff
                }
                jitter = sqrt(sq_sum / (n - 1))
            } else {
                jitter = 0.0
            }
            printf "%.2f %.2f %.2f %.2f %.2f\n", avg, min, max, jitter, loss
        }'
    else
        check_tcp_latency "$host" 5
    fi
}

check_tcp_latency() {
    local host="${1:-1.1.1.1}"
    local count="${2:-5}"
    local times=""
    local failed=0
    local i t

    for ((i = 1; i <= count; i++)); do
        t=$(curl -s -o /dev/null -w "%{time_connect}" --connect-timeout 3 "https://${host}" 2>/dev/null || true)
        if [[ -n "$t" ]] && awk -v t="$t" 'BEGIN { exit !(t > 0) }'; then
            times="${times} ${t}"
        else
            failed=$((failed + 1))
        fi
        sleep 0.1
    done

    awk -v list="$times" -v failed="$failed" -v total="$count" '
    BEGIN {
        loss = (failed / total) * 100.0
        n = split(list, arr, " ")
        if (n == 0) {
            printf "NA NA NA NA %.2f\n", loss
            exit
        }
        sum = 0
        for (i = 1; i <= n; i++) {
            val = arr[i] * 1000.0
            rtts[i] = val
            sum += val
            if (i == 1 || val < min) min = val
            if (i == 1 || val > max) max = val
        }
        avg = sum / n
        if (n > 1) {
            sq_sum = 0
            for (i = 1; i <= n; i++) {
                diff = rtts[i] - avg
                sq_sum += diff * diff
            }
            jitter = sqrt(sq_sum / (n - 1))
        } else {
            jitter = 0.0
        }
        printf "%.2f %.2f %.2f %.2f %.2f\n", avg, min, max, jitter, loss
    }'
}

# ------------------------------------------------------------------------------
# 3. Velocidad de Descarga (Download) vía Cloudflare Speedtest
# ------------------------------------------------------------------------------
check_download_speed() {
    local num_bytes="${1:-25000000}"
    local url="https://speed.cloudflare.com/__down?bytes=${num_bytes}"
    local result

    [[ "$MODE" == "terminal" ]] && printf "\r  -> Descargando muestra (~25 MB máx 8s)..." >&2
    result=$(curl -s -L --max-time 8 -A "$USER_AGENT" -o /dev/null -w "%{speed_download} %{size_download}" "$url" 2>/dev/null || true)
    [[ "$MODE" == "terminal" ]] && printf "\r%55s\r" " " >&2

    awk -v res="$result" '
    BEGIN {
        n = split(res, parts, " ")
        speed = parts[1] + 0
        size = parts[2] + 0
        if (n < 2 || size <= 0 || speed <= 0) {
            print "NA"
        } else {
            printf "%.2f", (speed * 8.0) / 1000000.0
        }
    }'
}

# ------------------------------------------------------------------------------
# 4. Velocidad de Subida (Upload) vía Cloudflare Speedtest
# ------------------------------------------------------------------------------
check_upload_speed() {
    local num_mb="${1:-10}"
    local url="https://speed.cloudflare.com/__up"
    local result

    TMP_UPLOAD=$(mktemp -t internet_check_up.XXXXXX)
    dd if=/dev/zero of="$TMP_UPLOAD" bs=1000000 count="$num_mb" 2>/dev/null

    [[ "$MODE" == "terminal" ]] && printf "\r  -> Subiendo %s MB..." "$num_mb" >&2
    result=$(curl -s -L --max-time 20 -A "$USER_AGENT" \
        -H "Content-Type: application/octet-stream" \
        --data-binary "@${TMP_UPLOAD}" \
        -o /dev/null -w "%{speed_upload} %{size_upload}" "$url" 2>/dev/null || true)
    [[ "$MODE" == "terminal" ]] && printf "\r%55s\r" " " >&2

    rm -f "$TMP_UPLOAD"
    TMP_UPLOAD=""

    awk -v res="$result" '
    BEGIN {
        n = split(res, parts, " ")
        speed = parts[1] + 0
        size = parts[2] + 0
        if (n < 2 || size <= 0 || speed <= 0) {
            print "NA"
        } else {
            printf "%.2f", (speed * 8.0) / 1000000.0
        }
    }'
}

# ------------------------------------------------------------------------------
# 5. Calcula calificación y estados por actividad
# ------------------------------------------------------------------------------
compute_summary() {
    local avg_ping="$1"
    local jitter="$2"
    local loss="$3"
    local dl="$4"
    local ul="$5"

    awk -v avg_ping="$avg_ping" -v jitter="$jitter" -v loss="$loss" -v dl="$dl" -v ul="$ul" '
    BEGIN {
        if (avg_ping == "NA" && dl == "NA") {
            printf "0|SIN CONEXIÓN|Sin conexión|Sin conexión|Sin conexión|Sin conexión\n"
            exit
        }

        score = 100
        if (avg_ping != "NA") {
            p = avg_ping + 0
            if (p > 150) score -= 35
            else if (p > 80) score -= 20
            else if (p > 40) score -= 8
        } else {
            p = 999.0
        }

        j = (jitter != "NA") ? jitter + 0 : 0.0
        if (j > 30) score -= 20
        else if (j > 10) score -= 10

        l = (loss != "NA") ? loss + 0 : 0.0
        if (l > 5) score -= 40
        else if (l > 1) score -= 20
        else if (l > 0) score -= 10

        if (dl != "NA") {
            d = dl + 0
            if (d < 5) score -= 40
            else if (d < 20) score -= 20
            else if (d < 50) score -= 10
        } else {
            d = 0.0
        }

        if (ul != "NA") {
            u = ul + 0
            if (u < 2) score -= 20
            else if (u < 10) score -= 10
        } else {
            u = 0.0
        }

        if (score < 0) score = 0
        if (score > 100) score = 100

        if (score >= 85) rating = "EXCELENTE"
        else if (score >= 65) rating = "BUENA"
        else if (score >= 40) rating = "REGULAR"
        else rating = "DEFICIENTE"

        nav = (d >= 3) ? "Óptimo" : "Lento"
        if (d >= 25 && l <= 1) stream = "Óptimo"
        else if (d >= 8) stream = "Posible HD (1080p)"
        else stream = "Limitado"

        if (d >= 10 && u >= 5 && p < 100 && j < 20) video = "Óptimo"
        else video = "Inestable / Media"

        if (p < 45 && j < 10 && l == 0) game = "Óptimo"
        else if (p < 90 && l < 1) game = "Jugable"
        else game = "Con Lag"

        printf "%d|%s|%s|%s|%s|%s\n", score, rating, nav, stream, video, game
    }'
}

# ------------------------------------------------------------------------------
# Modo Stream para la GUI nativa de macOS (InternetCheck.app)
# ------------------------------------------------------------------------------
run_gui_stream() {
    echo "STEP|0|Analizando red Wi-Fi, intensidad de señal (dBm) y direcciones IP..."
    gather_network_info
    echo "WIFI|${NET_SSID}|${NET_RSSI}|${NET_NOISE}|${NET_SNR}|${NET_RSSI_LABEL}|${NET_PHY_MODE}|${NET_CHANNEL}|${NET_TX_RATE}|${NET_DEFAULT_IF}|${NET_LOCAL_IP}|${NET_PUBLIC_IP}"

    echo "STEP|1|Midiendo tiempo de respuesta DNS..."
    dns_ms=$(check_dns)
    echo "DNS|${dns_ms}"

    echo "STEP|2|Midiendo latencia (Ping), Jitter y pérdida de paquetes..."
    read -r ping_avg ping_min ping_max ping_jitter ping_loss <<< "$(check_ping "1.1.1.1" 10)"
    echo "PING|${ping_avg}|${ping_min}|${ping_max}|${ping_jitter}|${ping_loss}"

    echo "STEP|3|Midiendo velocidad de descarga (Download)..."
    download_mbps=$(check_download_speed 25000000)
    echo "DOWNLOAD|${download_mbps}"

    echo "STEP|4|Midiendo velocidad de subida (Upload)..."
    upload_mbps=$(check_upload_speed 10)
    echo "UPLOAD|${upload_mbps}"

    IFS='|' read -r score rating nav stream video game <<< "$(compute_summary "$ping_avg" "$ping_jitter" "$ping_loss" "$download_mbps" "$upload_mbps")"
    echo "SUMMARY|${score}|${rating}|${nav}|${stream}|${video}|${game}"
}

# ------------------------------------------------------------------------------
# Modo Terminal interactivo
# ------------------------------------------------------------------------------
run_terminal() {
    printf "\n${BOLD}${HEADER}===================================================${END}\n"
    printf "${BOLD}${HEADER}     DIAGNÓSTICO DE CALIDAD DE INTERNET (MACOS)    ${END}\n"
    printf "${BOLD}${HEADER}===================================================${END}\n\n"

    # 0. Información de Red y Wi-Fi
    printf "${BOLD}[0/4] Información de la conexión local y Wi-Fi...${END}\n"
    gather_network_info
    printf "  Red Wi-Fi (SSID)    : ${CYAN}${BOLD}%s${END}\n" "$NET_SSID"
    printf "  Señal Wi-Fi (dBm)   : %b\n" "$(format_rssi "$NET_RSSI" "$NET_NOISE")"
    if [[ -n "$NET_CHANNEL" || -n "$NET_PHY_MODE" ]]; then
        local extra_wifi="${NET_PHY_MODE}${NET_CHANNEL:+  •  Canal: $NET_CHANNEL}${NET_TX_RATE:+  •  Tx: ${NET_TX_RATE} Mbps}"
        printf "  Detalles Radio Wi-Fi: %s\n" "${extra_wifi#  •  }"
    fi
    printf "  IP Local (%s)      : ${BOLD}%s${END}\n" "$NET_DEFAULT_IF" "$NET_LOCAL_IP"
    printf "  IP Pública          : ${BOLD}%s${END}\n\n" "$NET_PUBLIC_IP"

    # 1. Prueba DNS
    printf "${BOLD}[1/4] Midiendo resolución DNS...${END}\n"
    dns_ms=$(check_dns)
    printf "  Tiempo promedio DNS : %b\n\n" "$(format_metric "$dns_ms" "ms" 35 90 1)"

    # 2. Prueba de Ping y Estabilidad
    printf "${BOLD}[2/4] Midiendo latencia, jitter y pérdida de paquetes (1.1.1.1)...${END}\n"
    read -r ping_avg ping_min ping_max ping_jitter ping_loss <<< "$(check_ping "1.1.1.1" 10)"
    printf "  Latencia promedio   : %b\n" "$(format_metric "$ping_avg" "ms" 40 90 1)"
    if [[ "$ping_min" != "NA" && "$ping_max" != "NA" ]]; then
        printf "  Mínima / Máxima     : %s ms / %s ms\n" "$ping_min" "$ping_max"
    fi
    printf "  Jitter (Variación)  : %b\n" "$(format_metric "$ping_jitter" "ms" 8 20 1)"
    printf "  Pérdida de paquetes : %b\n\n" "$(format_metric "$ping_loss" "%" 0.0 1.0 1)"

    # 3. Prueba de Descarga
    printf "${BOLD}[3/4] Midiendo velocidad de descarga (Download)...${END}\n"
    download_mbps=$(check_download_speed 25000000)
    printf "  Velocidad Descarga  : %b\n\n" "$(format_metric "$download_mbps" "Mbps" 50 15 0)"

    # 4. Prueba de Subida
    printf "${BOLD}[4/4] Midiendo velocidad de subida (Upload)...${END}\n"
    upload_mbps=$(check_upload_speed 10)
    printf "  Velocidad Subida    : %b\n\n" "$(format_metric "$upload_mbps" "Mbps" 20 5 0)"

    # 5. Resumen y Calificación
    IFS='|' read -r score rating nav stream video game <<< "$(compute_summary "$ping_avg" "$ping_jitter" "$ping_loss" "$download_mbps" "$upload_mbps")"

    local color="$RED"
    if (( score >= 85 )); then color="$GREEN"
    elif (( score >= 65 )); then color="$CYAN"
    elif (( score >= 40 )); then color="$YELLOW"
    fi

    printf "${BOLD}---------------------------------------------------${END}\n"
    printf "${BOLD}CALIFICACIÓN GENERAL: %b%s (%d/100)${END}\n" "$color" "$rating" "$score"
    printf "${BOLD}---------------------------------------------------${END}\n\n"

    printf "${BOLD}Rendimiento esperado por actividad:${END}\n"
    for item in "Navegación y Redes Sociales|$nav" "Streaming 4K (Netflix/YouTube)|$stream" "Videollamadas (Zoom/Meet)|$video" "Gaming Online Competitivo|$game"; do
        act="${item%%|*}"
        st="${item##*|}"
        icon="❌"
        [[ "$st" == *"Óptimo"* ]] && icon="✅"
        [[ "$st" == *"Posible"* || "$st" == *"Jugable"* ]] && icon="⚠️"
        printf "  %s %-32s: ${BOLD}%s${END}\n" "$icon" "$act" "$st"
    done
    printf "\n"

    if [[ "$0" == *.command ]]; then
        read -r -p "Presiona [Enter] para cerrar esta ventana..."
    fi
}

if [[ "$MODE" == "--gui-stream" ]]; then
    run_gui_stream
else
    run_terminal
fi
