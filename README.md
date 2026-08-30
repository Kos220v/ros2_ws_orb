# ROS 2 Jazzy: одометрия с камерой Orbbec Astra

Это рабочее пространство собирает полный пайплайн **визуальной RGB-D одометрии**:

```
                 ┌──────────────────────┐
   Orbbec Astra  │  orbbec_camera       │  /camera/color/image_raw
   (USB 2.0/3.0) │  (OrbbecSDK_ROS2)    │  /camera/depth/image_raw   (выровнена к цвету)
                 │                      │  /camera/*/camera_info + TF
                 └──────────┬───────────┘
                            │
                 ┌──────────▼───────────┐
                 │ rtab_sync/rgbd_sync  │  /camera/rgbd_image
                 │ (синхронизация)      │  (rtabmap_msgs/RGBDImage)
                 └──────────┬───────────┘
                            │
                 ┌──────────▼───────────┐
                 │ rgbd_odometry       │  /odom (nav_msgs/Odometry)
                 │ (RTAB-Map, F2M)     │  TF: odom → camera_link (или base_link)
                 └──────────────────────┘
```

Результат:
- топик **`/odom`** (`nav_msgs/msg/Odometry`) — поза, скорость, ковариация;
- TF-цепочка **`odom → camera_link`** (ручной режим) или **`odom → base_link`** (робот);
- частота до 30 Гц (равна fps камеры), задержка ~1–2 кадра.

---

## 1. Установка

Требования: **Ubuntu 24.04**, **ROS 2 Jazzy** (desktop), камера Astra в USB.

```bash
cd ~/ros2_ws_orb        # этот репозиторий
./scripts/install.sh
```

Скрипт делает всё сам: ставит `ros-jazzy-rtabmap-ros` и зависимости драйвера,
клонирует официальный драйвер [OrbbecSDK_ROS2](https://github.com/orbbec/OrbbecSDK_ROS2)
(тег `v1.5.21`, ветка v1.x — единственная, поддерживающая классические Astra)
в `src/orbbec_camera/`, устанавливает udev-правила и собирает workspace.

> После установки udev-правил **переподключите** камеру (или перезагрузитесь).

### Установка вручную (если не доверяете скрипту)

```bash
source /opt/ros/jazzy/setup.bash

# одометрия RTAB-Map (бинарные пакеты для Jazzy есть в репозитории ROS)
sudo apt install ros-jazzy-rtabmap-ros

# зависимости драйвера
sudo apt install libgflags-dev nlohmann-json3-dev libdw-dev \
  ros-jazzy-image-transport ros-jazzy-image-transport-plugins \
  ros-jazzy-image-publisher ros-jazzy-camera-info-manager \
  ros-jazzy-diagnostic-updater ros-jazzy-diagnostic-msgs \
  ros-jazzy-statistics-msgs ros-jazzy-backward-ros \
  python3-colcon-common-extensions git

# драйвер камеры
cd ~/ros2_ws_orb/src
git clone --depth 1 -b v1.5.21 https://github.com/orbbec/OrbbecSDK_ROS2.git orbbec_camera

# права на USB
cd ~/ros2_ws_orb/src/orbbec_camera/orbbec_camera/scripts
sudo bash install_udev_rules.sh
sudo udevadm control --reload-rules && sudo udevadm trigger

# сборка
cd ~/ros2_ws_orb
colcon build --symlink-install --cmake-args -DCMAKE_BUILD_TYPE=Release
source install/setup.bash
```

---

## 2. Проверка камеры

```bash
./scripts/check_camera.sh
```

Скрипт покажет: видна ли камера в `lsusb` (vendor `2bc5`), **модель** по USB PID,
скорость шины (USB 2.0/3.0), статус udev-правил.

Точное имя/модель после сборки:

```bash
source install/setup.bash
ros2 run orbbec_camera list_devices_node
```

Если модель вам неизвестна — этот шаг её покажет. Все модели серии Astra
(Astra, Astra Pro, Astra Pro Plus, Astra Mini / Mini S (Pro), Astra 2)
поддерживаются драйвером ветки v1.x, ничего дополнительно настраивать не нужно.

---

## 3. Запуск одометрии

### 3.1. Ручной тест (камера в руке / на столе)

```bash
source install/setup.bash
ros2 launch astra_odometry astra_odometry.launch.py rviz:=true
```

Публикуется TF `odom → camera_link`. В RViz видна траектория; двигайте камеру
медленно, плавным поворотом вокруг оси, чтобы сцена была в текстурах и глубина
(0.5–3 м) была в кадре.

### 3.2. На роботе

Камера жёстко закреплена на базе. Указываем рамку базы и где стоит камера:

```bash
ros2 launch astra_odometry astra_odometry.launch.py \
    base_frame:=base_link \
    camera_mount_x:=0.10 camera_mount_z:=0.30 \
    camera_mount_yaw:=0.0
```

Одометрия публикует TF `odom → base_link` (как от колёсной одометрии), а крепление
камеры публикуется статическим TF `base_link → camera_link`. Смещение и поворот
задаются аргументами `camera_mount_x/y/z` (м) и `camera_mount_yaw/pitch/roll` (рад).

Для планарного робота полезно добавить `three_dof:=true` — тогда в решении
остаются только x, y, yaw (Reg/Force3DoF).

### 3.3. Проверка

```bash
# в другом терминале (тоже source install/setup.bash):
ros2 topic hz /odom                  # частота
ros2 topic echo /odom --once         # поза/ковариация
python3 scripts/odom_check.py        # частота + путь + позиция, раз в секунду
ros2 run tf2_ros tf2_echo odom camera_link   # или odom base_link
```

Симптом «всё ок»: `/odom` идёт стабильно ~30 Гц, при неподвижной камере позиция
не уплывает, при движении путь в `odom_check.py` совпадает с реальным (±2–5 %).

---

## 4. Полезные параметры запуска

| Аргумент | По умолчанию | Описание |
|---|---|---|
| `rviz` | `false` | запустить RViz с траекторией и картинкой |
| `base_frame` | `""` | рамка базы робота; задана → TF `odom → base_frame` |
| `camera_frame` | `camera_link` | рамка камеры |
| `camera_mount_x/y/z`, `camera_mount_yaw/pitch/roll` | 0 | крепление камеры (робот) |
| `three_dof` | `false` | планарный режим (x, y, yaw) |
| `depth_width/height/fps` | 640/480/30 | поток глубины |
| `color_width/height/fps` | 640/480/30 | цветовой поток |
| `color_format` | MJPG | ставьте `RGB`, если MJPG камерой не поддержан |
| `depth_registration` | `true` | выравнивание глубины к цвету |
| `align_mode` | `HW` | `HW`/`SW` (если HW не поддержан — `SW`) |
| `odom_reset_countdown` | 1 | автоперезапуск одометрии через N с после потери (0 — выкл) |
| `approx_sync_max_interval` | 0.1 | макс. расхождение пары цвет/глубина, с |
| `serial_number` | `""` | выбрать камеру по серийнику (их несколько) |
| `camera_name` | `camera` | namespace/префикс топиков |
| `connection_delay` | 100 | пауза переподключения, мс (Astra Mini — 500) |
| `params_file` | `config/odometry.yaml` | параметры rgbd_sync/rgbd_odometry |

Тонкая настройка алгоритма — в [`src/astra_odometry/config/odometry.yaml`](src/astra_odometry/config/odometry.yaml)
(число фич, пороги инлайеров, стратегия `Odom/Strategy`, `Reg/Force3DoF` и т.д.).

---

## 5. Как это работает (кратко)

- **Выравнивание глубины.** Для RGB-D одометрии глубина должна быть «в пикселях
  цвета». Драйвер с `depth_registration:=true` выравнивает глубину к цвету
  (аппаратно при `align_mode:=HW`), поэтому `depth/image_raw` приходит уже
  в рамке `camera_color_optical_frame`.
- **Синхронизация.** `rgbd_sync` собирает пары цвет+глубина по времени
  (approx-sync, допуск 0.1 с) в одно сообщение `rtabmap_msgs/RGBDImage` —
  дальше одометрия работает с согласованными кадрами.
- **Одометрия RTAB-Map (F2M).** На каждом кадре детектируются фичи (GFTT),
  сопоставляются с локальной картой точек, движение оценивается PnP+RANSAC.
  Публикуется `/odom` и TF. Глубина в Astra — `16UC1` в миллиметрах, что rtabmap
  понимает «из коробки».

---

## 6. Если что-то не работает

| Симптом | Причина / решение |
|---|---|
| Драйвер: `Failed to open USB device` / `Insufficient permissions` | нет udev-правил или вы не в группе `video`: `scripts/install.sh` и переподключить камеру; проверить `./scripts/check_camera.sh` |
| Камера стартует, топиков нет | Astra Mini и «горячее» подключение: `connection_delay:=500`; проверить `ros2 topic hz /camera/depth/image_raw` |
| Драйвер: ошибка при старте потока (`color profile ... not supported`) | модель не поддерживает выбранные разрешение/fps/формат: `color_format:=RGB color_fps:=15`, либо `color_fps:=10` как в дефолтах производителя |
| Постоянные `Frame drop` в логах, рваная частота | не хватает полосы USB: подключите в USB 3.0 / напрямую без хаба; уменьшите `color_fps:=15` или `depth_fps:=15`; цвет MJPG (по умолчанию) |
| Дроп кадров при нормальном USB, сообщения DDS о потери пакетов | настроить буферы UDP: `echo 'net.core.rmem_max=8388608' \| sudo tee /etc/sysctl.d/60-ros2.conf; echo 'net.core.rmem_default=4194304' \| sudo tee -a /etc/sysctl.d/60-ros2.conf; sudo sysctl --system` |
| Одометрия теряется (`odometry lost`) на столе/стене | сцена без текстур/глубины. Держите в кадре мебель, ковры, предметы 0.5–4 м. Уменьшите пороги: в `odometry.yaml` `Vis/MinInliers: "10"`, `Odom/MinInliers: "10"` |
| TF lookup fails в rgbd_odometry | драйвер не публикует TF: убедитесь `publish_tf:=true`, `tf_publish_rate>0` (в дефолтах 10 Гц); проверьте `ros2 run tf2_tools view_frames` |
| `/odom` есть, но позиция скачет при остановке | уменьшите `GFTT/QualityLevel` до `"0.001"`, увеличьте `GFTT/MinDistance: "15"`, включите `three_dof:=true` для планарного робота |
| Нужен перезапуск после потери | `odom_reset_countdown:=1` (по умолчанию) — одометрия сама перезапустится через 1 с |

---

## 7. Структура репозитория

```
ros2_ws_orb/
├── scripts/
│   ├── install.sh                  # установка зависимостей, драйвера, udev, сборка
│   ├── check_camera.sh             # диагностика камеры без ROS
│   └── odom_check.py               # мониторинг /odom (частота, путь)
├── src/
│   ├── astra_odometry/             # наш пакет: launch, параметры, rviz
│   │   ├── launch/astra_odometry.launch.py
│   │   ├── config/odometry.yaml    # параметры rgbd_sync + rgbd_odometry
│   │   └── rviz/odometry.rviz
│   └── orbbec_camera/              # (клонируется install.sh) драйвер OrbbecSDK_ROS2
└── README.md
```

`build/`, `install/`, `log/` и `src/orbbec_camera/` не коммитятся (см. `.gitignore`).

## 8. Если камера окажется не Astra-серии v1

Драйвер `v1.x` (по умолчанию) покрывает Astra / Astra Pro / Astra Pro Plus /
Astra Mini (S) Pro / Astra 2 и старшие Gemini/Femto. Если `list_devices_node`
покажет модель из нового поколения UVC-линейки (Gemini 330 и т.п.) — драйвер
ставится той же командой с другой веткой:

```bash
ORBBEC_BRANCH=v2-main ./scripts/install.sh
```

(udev-правила и названия топиков идентичны; launch-файл пакета `astra_odometry`
совместим, т.к. обращается к ноде `orbbec_camera` напрямую.)
