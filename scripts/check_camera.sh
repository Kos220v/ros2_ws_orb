#!/usr/bin/env bash
# =============================================================================
# Диагностика Orbbec Astra без запуска ROS.
# Показывает: видит ли USB камеру, её модель (по VID:PID), скорость шины,
# установлены ли udev-правила и состоит ли пользователь в группе video.
#
# Запуск: ./scripts/check_camera.sh
# =============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WS_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

RULES_CANDIDATES=(
    "${WS_DIR}/src/orbbec_camera/orbbec_camera/scripts/99-obsensor-libusb.rules"
    /etc/udev/rules.d/99-obsensor-libusb.rules
)

ok()   { echo -e "  \033[1;32mOK\033[0m   $*"; }
bad()  { echo -e "  \033[1;31mНЕТ\033[0m $*"; }
info() { echo -e "  \033[1;36m--\033[0m $*"; }

echo "=== 1. USB-устройства Orbbec (vendor 2bc5) ==="
USB_OUT="$(lsusb 2>/dev/null | grep -i '2bc5:' || true)"
if [ -z "${USB_OUT}" ]; then
    bad "Камера не видна в lsusb."
    echo "      - Переподключите USB-кабель / проверьте порт"
    echo "      - В виртуальной машине: пробросьте USB-устройство в ВМ"
    echo "        (VMware: VM -> Removable Devices -> Orbbec Astra -> Connect)"
    echo "      - 'sudo dmesg | tail -20' на предмет ошибок USB"
    exit 1
fi
echo "${USB_OUT}" | sed 's/^/  /'

echo
echo "=== 2. Определение модели ==="
# В правилах два формата строк:
#   UVC:   SUBSYSTEMS=="usb", ATTRS{idVendor}=="2bc5", ATTRS{idProduct}=="0635", ... SYMLINK+="Femto"
#   OpenNI: SUBSYSTEM=="usb", ATTR{idProduct}=="0401", ATTR{idVendor}=="2bc5", ... SYMLINK+="astra"
# Поэтому PID/имя вытаскиваем независимо от порядка атрибутов, учитывая "}".
RULES=""
for candidate in "${RULES_CANDIDATES[@]}"; do
    if [ -f "$candidate" ]; then RULES="$candidate"; break; fi
done
found_model=""
if [ -z "${RULES}" ]; then
    info "Файл udev-правил не найден — запустите scripts/install.sh"
else
    while IFS= read -r line; do
        pid="$(printf '%s' "$line" | sed -n 's/.*idProduct\}=="\([0-9a-fA-F]\{4\}\)".*/\1/p')"
        model="$(printf '%s' "$line" | sed -n 's/.*SYMLINK+="\([^"]*\)".*/\1/p' | head -1)"
        if [ -n "$pid" ] && [ -n "$model" ] && echo "$USB_OUT" | grep -qi "2bc5:${pid}"; then
            ok "Ваша камера: ${model} (VID:PID 2bc5:${pid})"
            found_model="$model"
        fi
    done < "${RULES}"
    if [ -z "${found_model}" ]; then
        info "Модель по PID не определилась — уточните: ros2 run orbbec_camera list_devices_node"
    fi
fi

echo
echo "=== 3. Скорость USB ==="
# lsusb -t не содержит VID:PID, поэтому матчим по номерам шины и устройства.
SPEED_SHOWN=0
while IFS= read -r line; do
    busnum="$(printf '%s' "$line" | sed -n 's/^Bus 0*\([0-9]\{1,3\}\) Device.*/\1/p')"
    devnum="$(printf '%s' "$line" | sed -n 's/^Bus [0-9]\{1,3\} Device 0*\([0-9]\{1,3\}\):.*/\1/p')"
    [ -z "${busnum}" ] || [ -z "${devnum}" ] && continue
    speed="$(lsusb -t 2>/dev/null | awk -v targetbus="${busnum}" -v targetdev="${devnum}" '
        /^\/:/ {
            cur = 0
            if (match($0, /Bus [0-9]+\./)) {
                b = substr($0, RSTART+4, RLENGTH-5)
                gsub(/^0+/, "", b)
                if (b+0 == targetbus+0) cur = 1
            }
            next
        }
        cur && match($0, /Dev [0-9]+,/) {
            d = substr($0, RSTART+4, RLENGTH-5)
            if (d+0 == targetdev+0) { print $NF; exit }
        }
    ' | head -1)"
    if [ -n "${speed}" ]; then
        info "Шина ${busnum}, устройство ${devnum}: ${speed}"
        case "${speed}" in
            5000M|10000M|20000M)
                ok "USB 3.x — запас по полосе есть" ;;
            480M)
                info "USB 2.0 — достаточно для 640x480@30 Гц с цветом MJPG (наши настройки по умолчанию)" ;;
            12M|1500M)
                bad "Слишком медленная шина (${speed}) — потоков не хватит, одометрия работать не будет" ;;
            *) info "Скорость: ${speed}" ;;
        esac
        SPEED_SHOWN=1
    fi
done <<< "${USB_OUT}"
if [ "${SPEED_SHOWN}" -eq 0 ]; then
    info "Не удалось определить скорость из 'lsusb -t' (устройство могло ещё не проинициализироваться)"
fi

# Подсказка для виртуальных машин
VIRT=""
if command -v systemd-detect-virt >/dev/null 2>&1; then
    VIRT="$(systemd-detect-virt -c 2>/dev/null || true)"
fi
if [ -n "${VIRT}" ] && [ "${VIRT}" != "none" ]; then
    info "Обнаружена ВМ (${VIRT}). Для камеры это важно:"
    info "  - камера должна быть проброшена в ВМ (VMware: VM -> Removable Devices -> Orbbec Astra -> Connect);"
    info "  - USB 2.0 (480M) достаточно для настроек по умолчанию; USB 3.x даст запас:"
    info "    в VMware включите контроллер USB 3.1 (VM Settings -> USB Controller) и подключайте к порту 3.0;"
    info "  - не используйте USB-хаб; при фризах изображения уменьшите color_fps/depth_fps до 15."
fi

echo
echo "=== 3a. Захват интерфейсов камеры драйверами ядра ==="
# Если ядро привязало драйвер (например, snd-usb-audio к микрофону Astra) хоть к
# одному интерфейсу, libusb получает EBUSY, и OrbbecSDK не видит камеру
# ("Current found device(s): (0)") даже при корректных правах.
while IFS= read -r line; do
    busnum="$(printf '%s' "$line" | sed -n 's/^Bus 0*\([0-9]\{1,3\}\) Device.*/\1/p')"
    devnum="$(printf '%s' "$line" | sed -n 's/^Bus [0-9]\{1,3\} Device 0*\([0-9]\{1,3\}\):.*/\1/p')"
    [ -z "${busnum}" ] || [ -z "${devnum}" ] && continue
    claims="$(lsusb -t 2>/dev/null | awk -v tb="${busnum}" -v td="${devnum}" '
        /^\/:/ {
            cur = 0
            if (match($0, /Bus [0-9]+\./)) {
                b = substr($0, RSTART+4, RLENGTH-5)
                gsub(/^0+/, "", b)
                if (b+0 == tb+0) cur = 1
            }
            next
        }
        cur && match($0, /Dev [0-9]+,/) {
            d = substr($0, RSTART+4, RLENGTH-5)
            if (d+0 == td+0 && match($0, /Driver=[^,]*/)) {
                drv = substr($0, RSTART+7, RLENGTH-7)
                if (drv != "[none]") print drv
            }
        }' | sort -u | paste -sd' ' -)"
    if [ -n "${claims}" ]; then
        bad "Интерфейсы камеры захвачены драйверами ядра: ${claims}"
        info "OrbbecSDK такую камеру не увидит. Фикс для аудио-интерфейсов Astra:"
        info "  мгновенно:  echo \"2-${busnum}:1.1\" | sudo tee /sys/bus/usb/drivers/snd-usb-audio/unbind  (и :1.2)"
        info "  навсегда:   echo 'options snd-usb-audio quirks=2bc5:0401:IGNORE' | sudo tee /etc/modprobe.d/orbbec-astra-noaudio.conf && перезагрузка"
        info "  (scripts/install.sh делает это автоматически при следующем запуске)"
    else
        ok "Интерфейсы камеры свободны (Driver=[none] у всех)"
    fi
done <<< "${USB_OUT}"

echo
echo "=== 4. udev-правила и права доступа ==="
if [ -f /etc/udev/rules.d/99-obsensor-libusb.rules ]; then
    ok "/etc/udev/rules.d/99-obsensor-libusb.rules установлен"
else
    bad "udev-правила не установлены — выполните scripts/install.sh"
fi
if id -nG "${SUDO_USER:-$USER}" 2>/dev/null | grep -qw video; then
    ok "Пользователь состоит в группе video"
else
    bad "Пользователь НЕ в группе video: sudo usermod -aG video \$USER && перелогин"
    info "Не блокирует работу: наши правила дают MODE 0666 (доступ всем), но группу лучше добавить"
fi
DEV_OUT="$(ls -l /dev 2>/dev/null | grep -iE 'astra|orbbec|ob_' || true)"
if [ -n "${DEV_OUT}" ]; then
    echo "${DEV_OUT}" | sed 's/^/  /'
else
    info "Симлинки /dev/astra* не найдены (появятся после установки правил и переподключения камеры)"
fi

# Права на сами USB-узлы (правила применяются в момент подключения)
while IFS= read -r line; do
    busnum="$(printf '%s' "$line" | sed -n 's/^Bus 0*\([0-9]\{1,3\}\) Device.*/\1/p')"
    devnum="$(printf '%s' "$line" | sed -n 's/^Bus [0-9]\{1,3\} Device 0*\([0-9]\{1,3\}\):.*/\1/p')"
    [ -z "${busnum}" ] || [ -z "${devnum}" ] && continue
    node="$(printf '/dev/bus/usb/%03d/%03d' "${busnum}" "${devnum}")"
    if [ -c "${node}" ]; then
        p="$(stat -c '%A' "${node}")"
        if [[ "${p}" == crw-rw-rw-* ]]; then
            ok "Права ${node}: ${p} — доступ открыт"
        else
            bad "Права ${node}: ${p} — нет записи для всех."
            info "Правила применяются при ПОДКЛЮЧЕНИИ камеры: переподключите её (в ВМ — через меню VMware)"
        fi
    else
        info "Узел ${node} не найден (устройство могло появиться до монтирования /dev/bus/usb)"
    fi
done <<< "${USB_OUT}"

echo
echo "=== 5. Кто может держать камеру (процессы и блокировки) ==="
# OrbbecSDK v1.10 прячет устройства, открытые другим процессом:
# если драйвер завис/остался от прошлого запуска, list_devices покажет (0).
PROC_OUT="$(ps -eo pid,cmd 2>/dev/null | grep -E 'ob_camera|orbbec|component_container|list_devices' | grep -v grep || true)"
if [ -n "${PROC_OUT}" ]; then
    bad "Обнаружены процессы, которые могут держать камеру:"
    echo "${PROC_OUT}" | sed 's/^/  /'
    info "Завершите их: pkill -f component_container; pkill -f ob_camera"
else
    ok "Посторонних процессов драйвера нет"
fi
LOCK_OUT="$(ls -la /dev/shm 2>/dev/null | grep -iE 'orbbec|ob_|astra' || true)"
if [ -n "${LOCK_OUT}" ]; then
    info "Файлы блокировок в /dev/shm:"
    echo "${LOCK_OUT}" | sed 's/^/  /'
    info "Если процессов драйвера нет (выше пусто), а файлы остались — зависшие: rm -f /dev/shm/orbbec_device_lock*"
else
    ok "Зависших блокировок /dev/shm нет"
fi

echo
echo "=== 6. Свежие события ядра по USB (последние ошибки, если есть) ==="
if command -v dmesg >/dev/null 2>&1 && dmesg 2>/dev/null | tail -200 | grep -iE 'usb|uvc' >/dev/null; then
    dmesg 2>/dev/null | tail -200 | grep -iE 'usb|uvc' | tail -8 | sed 's/^/  /'
else
    info "dmesg недоступен без root или ошибок нет (попробуйте: sudo dmesg | tail -30)"
fi

echo
echo "Дальше (после scripts/install.sh):"
echo "  source install/setup.bash"
echo "  ros2 run orbbec_camera list_devices_node   # точное имя/модель камеры"
echo "  ros2 launch astra_odometry astra_odometry.launch.py rviz:=true"
