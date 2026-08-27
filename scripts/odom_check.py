#!/usr/bin/env python3
"""Проверка одометрии: подписывается на /odom и печатает частоту, позу и пройденный путь.

Запуск:
    source install/setup.bash
    python3 scripts/odom_check.py              # топик /odom
    python3 scripts/odom_check.py /camera/odom # другой топик
"""

import math
import sys

import rclpy
from rclpy.node import Node
from nav_msgs.msg import Odometry


class OdomCheck(Node):
    def __init__(self, topic: str):
        super().__init__("odom_check")
        self.msg_count = 0
        self.last_print = self.get_clock().now()
        self.last_pos = None
        self.path_len = 0.0
        self.freq = 0.0
        self.latest = None
        self.sub = self.create_subscription(Odometry, topic, self.callback, 30)
        self.timer = self.create_timer(1.0, self.print_status)
        self.get_logger().info(f"Слушаю топик: {topic}")

    def callback(self, msg: Odometry):
        self.msg_count += 1
        p = msg.pose.pose.position
        self.latest = (p.x, p.y, p.z)
        if self.last_pos is not None:
            dx = p.x - self.last_pos[0]
            dy = p.y - self.last_pos[1]
            dz = p.z - self.last_pos[2]
            self.path_len += math.sqrt(dx * dx + dy * dy + dz * dz)
        self.last_pos = (p.x, p.y, p.z)

    def print_status(self):
        now = self.get_clock().now()
        dt = (now - self.last_print).nanoseconds / 1e9
        self.freq = self.msg_count / dt if dt > 0 else 0.0
        self.msg_count = 0
        self.last_print = now
        if self.latest is None:
            print("[odom_check] сообщений нет — одометрия не запущена или топик пустой")
            return
        x, y, z = self.latest
        print(
            f"[odom_check] {self.freq:5.1f} Гц | "
            f"позиция x={x:+7.3f} y={y:+7.3f} z={z:+7.3f} м | "
            f"путь={self.path_len:7.3f} м"
        )


def main():
    rclpy.init()
    topic = sys.argv[1] if len(sys.argv) > 1 else "/odom"
    node = OdomCheck(topic)
    try:
        rclpy.spin(node)
    except KeyboardInterrupt:
        pass
    finally:
        node.destroy_node()
        rclpy.shutdown()


if __name__ == "__main__":
    main()
