#!/usr/bin/env bash
# =============================================================================
# Отвязывает драйверы ядра от интерфейсов камер Orbbec (2bc5).
#
# Зачем: у классических Astra есть микрофонный интерфейс, который ядро
# захватывает snd-usb-audio. Пока захвачен хотя бы один интерфейс, libusb
# отвечает EBUSY, и OrbbecSDK не видит камеру ("Current found device(s): (0)")
# даже при правильных правах 0666.
#
# После переподключения камеры драйвер привязывается заново — запускайте
# этот скрипт после каждого reconnect (или поставьте постоянный фикс,
# см. README / install.sh: options snd-usb-audio quirks=2bc5:<PID>:IGNORE).
#
# Запуск: sudo ./scripts/unbind_orbbec.sh
# =============================================================================
set -uo pipefail

found=0

for d in /sys/bus/usb/devices/*:*; do
    [ -e "$d" ] || continue
    # idVendor лежит в каталоге УСТРОЙСТВА, а не интерфейса:
    # разрешаем симлинк интерфейса и берём родителя.
    devdir="$(basename "$(readlink -f "$d/..")")"
    vid="$(cat "/sys/bus/usb/devices/${devdir}/idVendor" 2>/dev/null)" || vid=""
    [ "$vid" = "2bc5" ] || continue

    iface="$(basename "$d")"
    found=1
    if [ -e "$d/driver" ]; then
        drv="$(basename "$(readlink -f "$d/driver")")"
        echo "Отвязываю $iface (драйвер: $drv)..."
        if echo "$iface" | tee "/sys/bus/usb/drivers/$drv/unbind" >/dev/null; then
            echo "  OK"
        else
            echo "  НЕ УДАЛОСЬ (нужен root? запустите через sudo)"
        fi
    else
        echo "$iface: драйвер не привязан — уже свободен"
    fi
done

if [ "$found" -eq 0 ]; then
    echo "Устройства Orbbec (2bc5) в sysfs не найдены."
    echo "Камера не проброшена в систему? Проверьте: lsusb | grep 2bc5"
    exit 1
fi

echo
echo "Готово. Проверка: ros2 run orbbec_camera list_devices_node"
