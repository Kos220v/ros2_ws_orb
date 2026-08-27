#!/usr/bin/env python3
"""
Одометрия на RGB-D камере Orbbec Astra + RTAB-Map (ROS 2 Jazzy).

Состав пайплайна:
  1. orbbec_camera (OrbbecSDK_ROS2, ветка v1.x) — драйвер камеры,
     публикует /camera/color/image_raw, /camera/depth/image_raw (выровнена
     к цвету при depth_registration:=true), /camera/*/camera_info и TF.
  2. rtabmap_sync/rgbd_sync — синхронизация цвет+глубина в одно
     сообщение rtabmap_msgs/RGBDImage (/camera/rgbd_image).
  3. rtabmap_odom/rgbd_odometry — визуальная одометрия:
     публикует /odom (nav_msgs/Odometry) и TF odom -> frame_id.

Примеры:
  # ручной тест (TF odom -> camera_link), с RViz:
  ros2 launch astra_odometry astra_odometry.launch.py rviz:=true

  # на роботе: TF odom -> base_link + статический TF base_link -> camera_link
  ros2 launch astra_odometry astra_odometry.launch.py \
      base_frame:=base_link camera_mount_x:=0.1 camera_mount_z:=0.25
"""

import os

from ament_index_python.packages import get_package_share_directory

from launch import LaunchDescription
from launch.actions import DeclareLaunchArgument, GroupAction, OpaqueFunction
from launch.conditions import IfCondition
from launch.substitutions import LaunchConfiguration
from launch_ros.actions import ComposableNodeContainer, Node
from launch_ros.descriptions import ComposableNode
from launch_ros.substitutions import FindPackageShare


def _str2bool(value: str) -> bool:
    return str(value).strip().lower() in ("1", "true", "yes", "on")


def _launch_setup(context, *args, **kwargs):
    def cfg(name, default=None):
        value = LaunchConfiguration(name).perform(context)
        return default if value == "" and default is not None else value

    # ---------- аргументы ----------
    camera_name = cfg("camera_name", "camera")
    serial_number = LaunchConfiguration("serial_number").perform(context)

    depth_width = int(cfg("depth_width", "640"))
    depth_height = int(cfg("depth_height", "480"))
    depth_fps = int(cfg("depth_fps", "30"))
    color_width = int(cfg("color_width", "640"))
    color_height = int(cfg("color_height", "480"))
    color_fps = int(cfg("color_fps", "30"))

    depth_registration = _str2bool(cfg("depth_registration", "true"))
    align_mode = cfg("align_mode", "HW")
    enable_point_cloud = _str2bool(cfg("enable_point_cloud", "false"))
    enable_colored_point_cloud = _str2bool(cfg("enable_colored_point_cloud", "false"))
    enable_ir = _str2bool(cfg("enable_ir", "false"))
    enable_color_auto_exposure = _str2bool(cfg("enable_color_auto_exposure", "true"))
    connection_delay = int(cfg("connection_delay", "100"))
    log_level = cfg("log_level", "info")
    tf_publish_rate = float(cfg("tf_publish_rate", "10.0"))

    # TF/рамки
    camera_frame = cfg("camera_frame", "camera_link")
    base_frame = cfg("base_frame", "")
    frame_id = base_frame if base_frame else camera_frame
    odom_frame_id = cfg("odom_frame_id", "odom")
    publish_tf = _str2bool(cfg("publish_tf", "true"))

    # крепление камеры на базе (для base_frame), метры/радианы
    mount_x = float(cfg("camera_mount_x", "0.0"))
    mount_y = float(cfg("camera_mount_y", "0.0"))
    mount_z = float(cfg("camera_mount_z", "0.0"))
    mount_yaw = float(cfg("camera_mount_yaw", "0.0"))
    mount_pitch = float(cfg("camera_mount_pitch", "0.0"))
    mount_roll = float(cfg("camera_mount_roll", "0.0"))

    # параметры одометрии
    three_dof = _str2bool(cfg("three_dof", "false"))
    odom_reset_countdown = cfg("odom_reset_countdown", "1")
    approx_sync_max_interval = float(cfg("approx_sync_max_interval", "0.1"))

    rviz = _str2bool(cfg("rviz", "false"))
    pkg_share = get_package_share_directory("astra_odometry")
    odom_params_file = cfg(
        "params_file", os.path.join(pkg_share, "config", "odometry.yaml")
    )

    # ---------- топики драйвера ----------
    ns = "/" + camera_name
    rgb_topic = ns + "/color/image_raw"
    depth_topic = ns + "/depth/image_raw"
    color_info_topic = ns + "/color/camera_info"
    rgbd_image_topic = ns + "/rgbd_image"

    # ---------- 1. Драйвер камеры ----------
    driver_params = {
        "camera_name": camera_name,
        "serial_number": serial_number,
        "connection_delay": connection_delay,
        "enable_color": True,
        "color_width": color_width,
        "color_height": color_height,
        "color_fps": color_fps,
        "color_format": "MJPG",  # экономит полосу USB 2.0; ставьте 'RGB', если MJPG не поддержан
        "enable_color_auto_exposure": enable_color_auto_exposure,
        "enable_depth": True,
        "depth_width": depth_width,
        "depth_height": depth_height,
        "depth_fps": depth_fps,
        "depth_format": "Y11",
        "depth_registration": depth_registration,
        "align_mode": align_mode,
        "enable_ir": enable_ir,
        "enable_point_cloud": enable_point_cloud,
        "enable_colored_point_cloud": enable_colored_point_cloud,
        "publish_tf": True,
        "tf_publish_rate": tf_publish_rate,
        "log_level": log_level,
    }

    camera_container = ComposableNodeContainer(
        name="camera_container",
        namespace=camera_name,
        package="rclcpp_components",
        executable="component_container_mt",
        output="screen",
        composable_node_descriptions=[
            ComposableNode(
                package="orbbec_camera",
                plugin="orbbec_camera::OBCameraNodeDriver",
                name=camera_name,
                namespace=camera_name,
                parameters=[driver_params],
                extra_arguments=[{"use_intra_process_comms": True}],
            )
        ],
    )

    # ---------- 2. rgbd_sync: цвет + глубина -> RGBDImage ----------
    rgbd_sync = Node(
        package="rtabmap_sync",
        executable="rgbd_sync",
        name="rgbd_sync",
        namespace=camera_name,
        output="screen",
        parameters=[
            odom_params_file,
            {
                "approx_sync": True,
                "approx_sync_max_interval": approx_sync_max_interval,
                "topic_queue_size": 30,
                "sync_queue_size": 50,
                "qos": 3,
                "qos_camera_info": 3,
            },
        ],
        remappings=[
            ("rgb/image", rgb_topic),
            ("depth/image", depth_topic),
            ("rgb/camera_info", color_info_topic),
            ("rgbd_image", rgbd_image_topic),
        ],
    )

    # ---------- 3. Визуальная одометрия (RTAB-Map) ----------
    odom_params = {
        "subscribe_rgbd": True,
        "frame_id": frame_id,
        "odom_frame_id": odom_frame_id,
        "publish_tf": publish_tf,
        "wait_for_transform": 0.2,
        "publish_null_when_lost": True,
        "topic_queue_size": 30,
        "sync_queue_size": 50,
        "qos": 3,
        # строковые параметры RTAB-Map (тип в ноде - string!):
        "Reg/Force3DoF": "true" if three_dof else "false",
        "Odom/ResetCountdown": odom_reset_countdown,
    }
    rgbd_odometry = Node(
        package="rtabmap_odom",
        executable="rgbd_odometry",
        name="rgbd_odometry",
        namespace="/",
        output="screen",
        parameters=[odom_params_file, odom_params],
        remappings=[
            ("rgbd_image", rgbd_image_topic),
        ],
    )

    # ---------- 4. Статический TF базы -> камера (режим робота) ----------
    nodes = [camera_container, rgbd_sync, rgbd_odometry]

    if base_frame:
        static_tf = Node(
            package="tf2_ros",
            executable="static_transform_publisher",
            name="base_to_camera_tf",
            namespace=camera_name,
            output="log",
            arguments=[
                "--x", str(mount_x),
                "--y", str(mount_y),
                "--z", str(mount_z),
                "--yaw", str(mount_yaw),
                "--pitch", str(mount_pitch),
                "--roll", str(mount_roll),
                "--frame-id", base_frame,
                "--child-frame-id", camera_frame,
            ],
        )
        nodes.append(static_tf)

    # ---------- 5. RViz ----------
    if rviz:
        rviz_node = Node(
            package="rviz2",
            executable="rviz2",
            name="rviz",
            namespace="/",
            output="log",
            arguments=["-d", os.path.join(pkg_share, "rviz", "odometry.rviz")],
            condition=IfCondition(LaunchConfiguration("rviz")),
        )
        nodes.append(rviz_node)

    return nodes


def generate_launch_description():
    return LaunchDescription(
        [
            DeclareLaunchArgument("camera_name", default_value="camera",
                description="Имя/namespace камеры (влияет на топики /camera/... и имя ноды)"),
            DeclareLaunchArgument("serial_number", default_value="",
                description="Серийный номер камеры (если их несколько)"),
            DeclareLaunchArgument("depth_width", default_value="640"),
            DeclareLaunchArgument("depth_height", default_value="480"),
            DeclareLaunchArgument("depth_fps", default_value="30"),
            DeclareLaunchArgument("color_width", default_value="640"),
            DeclareLaunchArgument("color_height", default_value="480"),
            DeclareLaunchArgument("color_fps", default_value="30"),
            DeclareLaunchArgument("depth_registration", default_value="true",
                description="Выравнивание глубины к цвету (нужно для одометрии по умолчанию)"),
            DeclareLaunchArgument("align_mode", default_value="HW",
                description="Режим D2C-выравнивания: HW или SW"),
            DeclareLaunchArgument("enable_point_cloud", default_value="false"),
            DeclareLaunchArgument("enable_colored_point_cloud", default_value="false"),
            DeclareLaunchArgument("enable_ir", default_value="false"),
            DeclareLaunchArgument("enable_color_auto_exposure", default_value="true"),
            DeclareLaunchArgument("connection_delay", default_value="100",
                description="Задержка переподключения, мс (Astra Mini: 500)"),
            DeclareLaunchArgument("log_level", default_value="info",
                description="Уровень логов OrbbecSDK: none/info/warning/error/debug"),
            DeclareLaunchArgument("tf_publish_rate", default_value="10.0"),
            DeclareLaunchArgument("camera_frame", default_value="camera_link",
                description="Рамка камеры (ребёнок base_frame)"),
            DeclareLaunchArgument("base_frame", default_value="",
                description="Рамка основания робота; если задана, одометрия публикует odom->base_frame"),
            DeclareLaunchArgument("odom_frame_id", default_value="odom"),
            DeclareLaunchArgument("publish_tf", default_value="true"),
            DeclareLaunchArgument("camera_mount_x", default_value="0.0",
                description="Смещение камеры в base_frame, м"),
            DeclareLaunchArgument("camera_mount_y", default_value="0.0"),
            DeclareLaunchArgument("camera_mount_z", default_value="0.0"),
            DeclareLaunchArgument("camera_mount_yaw", default_value="0.0",
                description="Поворот камеры в base_frame, рад"),
            DeclareLaunchArgument("camera_mount_pitch", default_value="0.0"),
            DeclareLaunchArgument("camera_mount_roll", default_value="0.0"),
            DeclareLaunchArgument("three_dof", default_value="false",
                description="Рег/Force3DoF: только планарное движение (робот на полу)"),
            DeclareLaunchArgument("odom_reset_countdown", default_value="1",
                description="Odom/ResetCountdown: автоперезапуск через N c после потери трека (0 = выкл)"),
            DeclareLaunchArgument("approx_sync_max_interval", default_value="0.1",
                description="Макс. расхождение цвет/глубина в rgbd_sync, с"),
            DeclareLaunchArgument("params_file", default_value="",
                description="YAML с параметрами rgbd_sync/rgbd_odometry"),
            DeclareLaunchArgument("rviz", default_value="false",
                description="Запустить RViz с визуализацией одометрии"),
            OpaqueFunction(function=_launch_setup),
        ]
    )
