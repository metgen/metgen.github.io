#!/bin/bash

# Конфигурация
DASHBOARD_FILE="/etc/update-motd.d/99-dashboard"
FORCE_MODE=false
REQUIRED_PACKAGES=("vnstat" "curl" "jq")

# Цветовые коды
COLOR_RESET="\033[0m"
COLOR_RED="\033[0;31m"
COLOR_GREEN="\033[0;32m"
COLOR_YELLOW="\033[0;33m"
COLOR_BLUE="\033[0;34m"
COLOR_CYAN="\033[0;36m"
COLOR_WHITE="\033[1;37m"

# Функции
show_error() {
    echo -e "${COLOR_RED}❌ Ошибка: $1${COLOR_RESET}" >&2
}

show_warning() {
    echo -e "${COLOR_YELLOW}⚠️ Предупреждение: $1${COLOR_RESET}"
}

show_success() {
    echo -e "${COLOR_GREEN}✅ $1${COLOR_RESET}"
}

show_info() {
    echo -e "${COLOR_CYAN}ℹ️ $1${COLOR_RESET}"
}

check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        show_error "Этот скрипт должен запускаться с правами root"
        show_info "sudo bash -c "$(wget -qO- https://metgen.github.io/scripts/dashboard.sh)" "
        exit 1
    fi
}

check_utf8() {
    if ! locale | grep -qi 'utf-8'; then
        show_warning "Терминал не использует UTF-8. Возможны искажения вывода."
    fi
}

install_packages() {
    local missing_pkgs=()
    for pkg in "${REQUIRED_PACKAGES[@]}"; do
        if ! command -v "$pkg" &>/dev/null; then
            missing_pkgs+=("$pkg")
        fi
    done

    if [ ${#missing_pkgs[@]} -gt 0 ]; then
        show_info "Установка недостающих пакетов: ${missing_pkgs[*]}..."
        if apt-get update && apt-get install -y "${missing_pkgs[@]}"; then
            show_success "Пакеты успешно установлены"
        else
            show_error "Не удалось установить пакеты"
            exit 1
        fi
    fi
}

generate_dashboard() {
    cat > "$1" << 'EOF'
#!/bin/bash

# Цвета
bold=$(tput bold)
normal=$(tput sgr0)
blue=$(tput setaf 4)
green=$(tput setaf 2)
red=$(tput setaf 1)
yellow=$(tput setaf 3)
cyan=$(tput setaf 6)
white=$(tput setaf 7)

# Иконки статусов
ok="${green}●${normal}"
fail="${red}●${normal}"
warn="${yellow}●${normal}"
separator="${blue}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${normal}"

# Очистка экрана
echo "${normal}"

# Заголовок
echo "$separator"
echo "${bold}${cyan}🚀 СИСТЕМНЫЙ ДАШБОРД ${white}$(date +'%Y-%m-%d %H:%M:%S')${normal}"
echo "$separator"

# Системная информация
uptime_str=$(uptime -p | sed 's/up //')
loadavg=$(cut -d ' ' -f1-3 /proc/loadavg)
cpu_cores=$(nproc)
cpu_usage=$(top -bn1 | grep "Cpu(s)" | awk '{printf "%.1f%%", 100 - $8}')
mem_data=$(free -m | awk '/Mem:/ {printf "%.0f%% (%dMB/%dMB)", $3/$2*100, $3, $2}')
swap_data=$(free -m | awk '/Swap:/ {if ($2!=0) printf "%.0f%% (%dMB/%dMB)", $3/$2*100, $3, $2; else print "N/A"}')

# Дисковая информация
disk_used=$(df -h / | awk 'NR==2 {print $5}' | tr -d '%')
disk_line=$(df -h / | awk 'NR==2 {print $5 " (" $3 " / " $2 ")"}')
if [ "$disk_used" -ge 95 ]; then
    disk_status="${red}${disk_line}${normal} ${red}[КРИТИЧНО: Освободите место!]${normal}"
elif [ "$disk_used" -ge 85 ]; then
    disk_status="${yellow}${disk_line}${normal} ${yellow}[Внимание: Высокая загрузка]${normal}"
else
    disk_status="${green}${disk_line}${normal}"
fi

# Сетевая информация
traffic=$(vnstat --oneline 2>/dev/null | awk -F\; '{print $10 " ↓ / " $11 " ↑"}') || traffic="N/A"
ip_local=$(hostname -I | awk '{print $1}')
ip_public=$(curl -4 -s ifconfig.me || echo "N/A")
ip6=$(ip -6 addr show scope global | grep inet6 | awk '{print $2}' | cut -d/ -f1 | head -n1)
[ -z "$ip6" ] && ip6="N/A"

# Безопасность
if systemctl is-active crowdsec &>/dev/null; then
    bouncers=$(crowdsec-cli bouncers list 2>/dev/null | grep -v NAME | awk '{print $1 ": " $2}' | paste -sd ', ' -)
    [ -z "$bouncers" ] && crowdsec_status="$warn active, no bouncers" || crowdsec_status="$ok $bouncers"
else
    crowdsec_status="$fail not running"
fi

# Docker
if command -v docker &>/dev/null; then
    docker_total=$(docker ps -a -q | wc -l)
    docker_running=$(docker ps -q | wc -l)
    docker_stopped=$((docker_total - docker_running))
    docker_msg="$ok ${docker_running} running / ${docker_stopped} stopped"
    bad_containers=$(docker ps -a --filter "status=exited" --filter "status=restarting" --format '{{.Names}} ({{.Status}})' | head -2)
    if [ -n "$bad_containers" ]; then
        docker_msg="$fail Issues: $docker_running running / $docker_stopped stopped
       ${red}⛔ $bad_containers${normal}"
    fi
else
    docker_msg="$warn not installed"
fi

# SSH
ssh_users=$(who | wc -l)
ssh_ips=$(who | awk '{print $5}' | tr -d '()' | sort | uniq | paste -sd ', ' -)

# Файрволл
if command -v fail2ban-client &>/dev/null; then
    jail_count=$(fail2ban-client status | grep -c "Jail list:")
    fail2ban_status="$ok active (${jail_count} jails)"
else
    fail2ban_status="$warn not installed"
fi

if command -v ufw &>/dev/null; then
    ufw_status=$(ufw status | grep -i "Status" | awk '{print $2}')
    if [[ "$ufw_status" == "active" ]]; then
        rules_count=$(ufw status numbered | grep -c '^\[[0-9]\]')
        ufw_status="$ok enabled (${rules_count} rules)"
    else
        ufw_status="$warn disabled"
    fi
else
    ufw_status="$warn not installed"
fi

# Обновления
updates=$(apt list --upgradable 2>/dev/null | grep -v "Listing" | wc -l)
if [ "$updates" -gt 50 ]; then
    update_msg="${red}$updates packages${normal} can be updated"
elif [ "$updates" -gt 20 ]; then
    update_msg="${yellow}$updates packages${normal} can be updated"
else
    update_msg="${green}$updates packages${normal} can be updated"
fi

# Температура (если доступно)
temp=$(cat /sys/class/thermal/thermal_zone*/temp 2>/dev/null | awk '{print $1/1000}' | sort -nr | head -1)
[ -n "$temp" ] && temp_status="🌡️  ${temp}°C" || temp_status=""

# Вывод информации
printf "${bold}${cyan}🏠 Хост:          ${normal} %s\n" "$(hostname -f)"
printf "${bold}${cyan}⏱️  Аптайм:        ${normal} %s\n" "$uptime_str"
printf "${bold}${cyan}🧮 Нагрузка:      ${normal} %s (1/5/15 мин)\n" "$loadavg"
printf "${bold}${cyan}⚙️  CPU:           ${normal} %s использование, ${cpu_cores} ядер\n" "$cpu_usage"
printf "${bold}${cyan}💾 RAM:           ${normal} %s\n" "$mem_data"
printf "${bold}${cyan}🔀 SWAP:          ${normal} %s\n" "$swap_data"
printf "${bold}${cyan}💽 Диск:          ${normal} %b\n" "$disk_status"
printf "${bold}${cyan}📶 Трафик:        ${normal} %s\n" "$traffic"
printf "${bold}${cyan}🔐 CrowdSec:      ${normal} %b\n" "$crowdsec_status"
printf "${bold}${cyan}🐳 Docker:        ${normal} %b\n" "$docker_msg"
printf "${bold}${cyan}🛡️  Fail2Ban:     ${normal} %s\n" "$fail2ban_status"
printf "${bold}${cyan}🧱 UFW:           ${normal} %s\n" "$ufw_status"
printf "${bold}${cyan}👥 SSH:           ${normal} %s пользователей\n" "$ssh_users"
printf "${bold}${cyan}🌐 IP:            ${normal} Локальный: ${ip_local} | Публичный: ${ip_public}\n"
printf "${bold}${cyan}🔗 IPv6:          ${normal} %s\n" "$ip6"
printf "${bold}${cyan}🔄 Обновления:    ${normal} %b\n" "$update_msg"
[ -n "$temp_status" ] && printf "${bold}${cyan}${temp_status}\n"
echo "$separator"

# Краткое резюме
echo "${bold}${white}✔️  СИСТЕМНОЕ РЕЗЮМЕ:${normal}"
[ "$updates" -eq 0 ] && echo "$ok Пакеты обновлены" || echo "$warn Доступны обновления ($updates)"
[ "$disk_used" -ge 85 ] && echo "$fail Высокая загрузка диска" || echo "$ok Диск в норме"
[ "$(echo "$cpu_usage" | cut -d% -f1)" -gt 90 ] && echo "$warn Высокая загрузка CPU" || echo "$ok CPU в норме"
[[ "$docker_msg" == *"Issues:"* ]] && echo "$fail Проблемы с Docker" || echo "$ok Docker в норме"
[[ "$crowdsec_status" =~ "$fail" ]] && echo "$fail CrowdSec не работает" || echo "$ok CrowdSec активен"
[[ "$ufw_status" =~ "disabled" ]] && echo "$warn UFW отключен" || echo "$ok UFW активен"
echo ""
EOF
}

# Главная функция
main() {
    check_root
    check_utf8
    
    # Обработка аргументов
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --force)
                FORCE_MODE=true
                shift
                ;;
            *)
                show_error "Неизвестный аргумент: $1"
                exit 1
                ;;
        esac
    done

    install_packages

    # Создание временного файла
    TMP_FILE=$(mktemp)
    generate_dashboard "$TMP_FILE"

    # Предпросмотр
    clear
    echo -e "${COLOR_BLUE}====================================================${COLOR_RESET}"
    echo -e "${COLOR_BLUE}📋 Предпросмотр MOTD:${COLOR_RESET}"
    echo -e "${COLOR_BLUE}====================================================${COLOR_RESET}"
    bash "$TMP_FILE"
    echo -e "${COLOR_BLUE}====================================================${COLOR_RESET}"

    # Установка
    if [ "$FORCE_MODE" = true ]; then
        echo -e "${COLOR_CYAN}⚙️ Автоматическая установка без подтверждения (--force)${COLOR_RESET}"
        mv "$TMP_FILE" "$DASHBOARD_FILE"
        chmod 755 "$DASHBOARD_FILE"
        # Отключаем другие MOTD скрипты
        find /etc/update-motd.d/ -type f -not -name "99-dashboard" -exec chmod -x {} \;
        show_success "MOTD дашборд успешно установлен в $DASHBOARD_FILE"
    else
        read -p '❓ Установить этот MOTD-дашборд? [y/N]: ' confirm
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            mv "$TMP_FILE" "$DASHBOARD_FILE"
            chmod 755 "$DASHBOARD_FILE"
            find /etc/update-motd.d/ -type f -not -name "99-dashboard" -exec chmod -x {} \;
            show_success "MOTD дашборд успешно установлен в $DASHBOARD_FILE"
        else
            echo -e "${COLOR_YELLOW}❌ Установка отменена.${COLOR_RESET}"
            rm -f "$TMP_FILE"
        fi
    fi
}

main "$@"