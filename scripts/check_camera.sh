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
    echo "      - 'dmesg | tail -20' на предмет ошибок USB"
    exit 1
fi
echo "${USB_OUT}" | sed 's/^/  /'

echo
echo "=== 2. Определение модели ==="
RULES=""
for candidate in "${RULES_CANDIDATES[@]}"; do
    [ -f "$candidate" ] && RULES="$candidate" && break
done
if [ -z "${RULES}" ]; then
    info "Файл udev-правил не найден — запустите scripts/install.sh, чтобы определить модель по имени"
else
    while IFS= read -r line; do
        pid="$(echo "$line" | grep -o 'idProduct=="[0-9a-fA-F]*"' | head -1 | sed 's/idProduct=="//;s/"//')"
        model="$(echo "$line" | grep -o 'SYMLINK+="[^"]*"' | head -1 | sed 's/SYMLINK+="//;s/"//')"
        if [ -n "$pid" ] && [ -n "$model" ] && echo "$USB_OUT" | grep -qi "2bc5:${pid}"; then
            ok "Ваша камера: ${model} (VID:PID 2bc5:${pid})"
        fi
    done < "${RULES}"
    info "Если модель не определилась выше — это неизвестный драйверу PID;"
    info "уточните модель: ros2 run orbbec_camera list_devices_node (после сборки)"
fi

echo
echo "=== 3. Скорость USB ==="
BUS_OUT="$(lsusb -t 2>/dev/null | grep -A0 -B0 '2bc5' || true)"
if [ -n "${BUS_OUT}" ]; then
    echo "${BUS_OUT}" | sed 's/^/  /'
    if echo "${BUS_OUT}" | grep -q '5000M'; then
        ok "USB 3.0 (5000M) — запас по полосе есть"
    elif echo "${BUS_OUT}" | grep -q '480M'; then
        info "USB 2.0 (480M) — достаточно для 640x480@30 (цвет MJPG), но не для больших разрешений"
    else
        info "Низкая скорость шины — odometry может страдать от пропусков кадров"
    fi
else
    info "Устройство не найдено в дереве lsusb -t (может требовать права или ещё не проинициализировалось)"
fi

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
fi
DEV_OUT="$(ls -l /dev 2>/dev/null | grep -iE 'astra|orbbec|ob_' || true)"
if [ -n "${DEV_OUT}" ]; then
    echo "${DEV_OUT}" | sed 's/^/  /'
else
    info "Симлинки /dev/astra* не найдены (появятся после установки правил и переподключения камеры)"
fi

echo
echo "=== 5. Свежие события ядра по USB (последние ошибки, если есть) ==="
if command -v dmesg >/dev/null 2>&1 && dmesg 2>/dev/null | tail -200 | grep -iE 'usb|uvc' >/dev/null; then
    dmesg 2>/dev/null | tail -200 | grep -iE 'usb|uvc' | tail -8 | sed 's/^/  /'
else
    info "dmesg недоступен без root или ошибок нет"
fi

echo
echo "Дальше (после scripts/install.sh):"
echo "  source install/setup.bash"
echo "  ros2 run orbbec_camera list_devices_node   # точное имя/модель камеры"
echo "  ros2 launch astra_odometry astra_odometry.launch.py rviz:=true"
