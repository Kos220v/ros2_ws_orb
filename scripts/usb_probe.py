#!/usr/bin/env python3
"""Зонд доступа к камере Orbbec на уровне libusb — как это делает OrbbecSDK.

Отличает три причины «found device(s): (0)»:
  1. нет прав на запись в usbfs (udev-правила не применились к этому подключению);
  2. устройство занято другим процессом/драйвером внутри гостя;
  3. проблема перечисления libusb/udev (устройство видно в lsusb, но не в libusb).

Запуск:
    sudo apt install python3-usb   # один раз
    python3 scripts/usb_probe.py
"""

import errno
import sys

VID = 0x2BC5  # Orbbec


def main() -> int:
    try:
        import usb.core
        import usb.util
    except ImportError:
        print("Нет модуля pyusb. Установите: sudo apt install python3-usb")
        return 2

    # 1. Перечисление: libusb видит устройство вообще?
    devices = list(usb.core.find(find_all=True, idVendor=VID))
    if not devices:
        print("libusb: устройства Orbbec (2bc5) НЕ найдены, хотя lsusb их видит.")
        print("  -> проблема перечисления libusb/udev (характерно для ВМ).")
        print("     Попробуйте: sudo udevadm control --reload-rules && sudo udevadm trigger")
        print("     и переподключите камеру (в ВМ — через меню VMware).")
        return 1

    for dev in devices:
        pid = dev.idProduct
        print(f"libusb: найдено устройство {dev.bus:03d}/{dev.address:03d} "
              f"(2bc5:{pid:04x})")

        # 2. Чтение дескрипторов (read-only доступ)
        try:
            cfg = dev.get_active_configuration()
            print(f"  чтение дескрипторов: OK (конфигурация {cfg.bConfigurationValue}, "
                  f"интерфейсов: {cfg.bNumInterfaces})")
        except usb.core.USBError as e:
            print(f"  чтение дескрипторов: НЕ УДАЛОСЬ: {e!r}")

        # 3. Открытие на запись — тот же доступ, что нужен SDK для потоков
        try:
            dev.set_configuration()
            print("  открытие на запись (set_configuration): OK")
            print("  => на уровне libusb всё доступно; если SDK всё равно не видит")
            print("     камеру — ищите процессы-держатели и локи /dev/shm/orbbec_device_lock*")
        except usb.core.USBError as e:
            code = e.errno
            if code == errno.EACCES:
                print("  открытие на запись: ОТКАЗАНО В ДОСТУПЕ")
                print("  -> udev-правила не применились к ЭТОМУ подключению.")
                print("     Переподключите камеру (в ВМ — через меню VMware) или:")
                print("     sudo udevadm control --reload-rules && sudo udevadm trigger")
            elif code == errno.EBUSY:
                print("  открытие на запись: УСТРОЙСТВО ЗАНЯТО")
                print("  -> камеру держит другой процесс/драйвер внутри гостя:")
                print("     pkill -f component_container; pkill -f ob_camera")
                print("     и проверьте: ps -ef | grep -E 'ob_camera|orbbec' | grep -v grep")
            else:
                print(f"  открытие на запись: ОШИБКА usbfs: {e!r}")
                print("  -> характерно для сбоев проброса USB в ВМ; переподключите")
                print("     камеру через меню VMware или смените порт/контроллер.")
        finally:
            usb.util.dispose_resources(dev)

    return 0


if __name__ == "__main__":
    sys.exit(main())
