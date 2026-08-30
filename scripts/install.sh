#!/usr/bin/env bash
# =============================================================================
# Установка рабочего пространства: драйвер Orbbec Astra + RTAB-Map одометрия.
# Ubuntu 24.04 / ROS 2 Jazzy.
#
# Запуск:  ./scripts/install.sh
# Повторный запуск безопасен (идемпотентен).
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WS_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

ROS_DISTRO_NAME="jazzy"
ORBBEC_BRANCH="${ORBBEC_BRANCH:-v1.5.21}"   # ветка/тег OrbbecSDK_ROS2 (v1.x поддерживает классические Astra)
ORBBEC_REPO="https://github.com/orbbec/OrbbecSDK_ROS2.git"

log()  { echo -e "\033[1;32m[install]\033[0m $*"; }
warn() { echo -e "\033[1;33m[install]\033[0m $*"; }
die()  { echo -e "\033[1;31m[install] ОШИБКА:\033[0m $*" >&2; exit 1; }

# --- 1. Проверка окружения ---------------------------------------------------
[[ -f /opt/ros/${ROS_DISTRO_NAME}/setup.bash ]] || \
    die "ROS 2 ${ROS_DISTRO_NAME} не найден в /opt/ros. Установите Jazzy: https://docs.ros.org/en/jazzy/Installation/Ubuntu-Install-Debians.html"

# Скрипты инициализации ament не рассчитаны на `set -u`: они проверяют
# переменные (AMENT_TRACE_SETUP_FILES и др.) без значений по умолчанию,
# и sourcing падает с "unbound variable". Поэтому на время source
# отключаем nounset (рекомендация colcon/ROS 2 для workspaces).
set +u
source "/opt/ros/${ROS_DISTRO_NAME}/setup.bash"
set -u
log "ROS_DISTRO=${ROS_DISTRO_NAME}"

# --- 2. Системные пакеты -----------------------------------------------------
log "Установка apt-пакетов (rtabmap, драйвер-зависимости, инструменты сборки)..."
sudo apt-get update
sudo apt-get install -y \
    git python3-colcon-common-extensions python3-rosdep \
    libgflags-dev nlohmann-json3-dev libdw-dev \
    ros-${ROS_DISTRO_NAME}-rtabmap-ros \
    ros-${ROS_DISTRO_NAME}-image-transport \
    ros-${ROS_DISTRO_NAME}-image-transport-plugins \
    ros-${ROS_DISTRO_NAME}-compressed-image-transport \
    ros-${ROS_DISTRO_NAME}-image-publisher \
    ros-${ROS_DISTRO_NAME}-camera-info-manager \
    ros-${ROS_DISTRO_NAME}-diagnostic-updater \
    ros-${ROS_DISTRO_NAME}-diagnostic-msgs \
    ros-${ROS_DISTRO_NAME}-statistics-msgs \
    ros-${ROS_DISTRO_NAME}-backward-ros

# rosdep (инициализация, если ещё не сделана)
if ! rosdep --version >/dev/null 2>&1; then
    warn "rosdep недоступен, пропускаю (основные зависимости уже поставлены через apt)"
elif [ ! -f /etc/ros/rosdep/sources.list.d/20-default.list ]; then
    sudo rosdep init || true
fi
rosdep update --rosdistro=${ROS_DISTRO_NAME} >/dev/null 2>&1 || warn "rosdep update не удался (не критично)"

# --- 3. Клонирование драйвера камеры -----------------------------------------
if [ -d "${WS_DIR}/src/orbbec_camera/.git" ]; then
    log "Драйвер уже склонирован в src/orbbec_camera — пропускаю"
else
    log "Клонирование OrbbecSDK_ROS2 (${ORBBEC_BRANCH}) в src/orbbec_camera..."
    git clone --depth 1 -b "${ORBBEC_BRANCH}" "${ORBBEC_REPO}" "${WS_DIR}/src/orbbec_camera"
fi

# --- 4. Права на USB (udev-правила) ------------------------------------------
RULES_SRC="${WS_DIR}/src/orbbec_camera/orbbec_camera/scripts/99-obsensor-libusb.rules"
if [ -f "${RULES_SRC}" ]; then
    log "Установка udev-правил Orbbec..."
    sudo cp -f "${RULES_SRC}" /etc/udev/rules.d/
    sudo udevadm control --reload-rules && sudo udevadm trigger
else
    warn "Файл правил не найден: ${RULES_SRC}"
fi

# Пользователь должен состоять в группе video
if ! id -nG "$USER" | grep -qw video; then
    log "Добавляю ${USER} в группу video (вступит в силу после перелогина)"
    sudo usermod -aG video "$USER"
fi

# --- 4b. Аудио-интерфейсы Astra не должны захватываться ядром ----------------
# У классических Astra есть микрофонный (Audio) интерфейс. Если ядро привязывает
# к нему snd-usb-audio, libusb получает EBUSY, и OrbbecSDK не видит камеру
# ("Current found device(s): (0)"). Запрещаем драйверу трогать камеры Orbbec.
QUIRKS="$(lsusb 2>/dev/null | sed -n 's/.*2bc5:\([0-9a-fA-F]\{4\}\).*/2bc5:\1:IGNORE/p' | sort -u | paste -sd, -)"
[ -z "${QUIRKS}" ] && QUIRKS="2bc5:0401:IGNORE"   # классическая Astra по умолчанию
AUDIO_CONF="/etc/modprobe.d/orbbec-astra-noaudio.conf"
if grep -q "quirks=" "${AUDIO_CONF}" 2>/dev/null; then
    log "Модуль-исключение для snd-usb-audio уже настроен (${AUDIO_CONF})"
else
    log "Запрещаю snd-usb-audio захватывать аудио-интерфейсы Orbbec (${QUIRKS})"
    echo "options snd-usb-audio quirks=${QUIRKS}" | sudo tee "${AUDIO_CONF}" >/dev/null
    warn "Для применения нужна перезагрузка (или: sudo modprobe -r snd-usb-audio и переподключить камеру)"
fi

# --- 5. Сборка ----------------------------------------------------------------
cd "${WS_DIR}"
log "Сборка рабочего пространства (Release)..."
colcon build --symlink-install --cmake-args -DCMAKE_BUILD_TYPE=Release

cat <<EOF

=============================================================================
 Готово! Дальше:

   source ${WS_DIR}/install/setup.bash
   ./scripts/check_camera.sh                  # проверить, что камера видна
   ros2 launch astra_odometry astra_odometry.launch.py rviz:=true

 Совет: добавьте в ~/.bashrc:
   echo "source ${WS_DIR}/install/setup.bash" >> ~/.bashrc
=============================================================================
EOF
