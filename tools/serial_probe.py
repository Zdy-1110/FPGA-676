#!/usr/bin/env python3
"""探测哪个 COM 口是 RK 板调试串口：发送回车，打印收到的原始数据。"""
import sys
import time
import serial

CANDIDATE_PORTS = ["COM3", "COM4", "COM7", "COM8", "COM9", "COM10"]
BAUDS = [1500000, 115200]


def probe(port: str, baud: int) -> None:
    print(f"=== {port} @ {baud} ===")
    try:
        ser = serial.Serial(port=port, baudrate=baud, timeout=0.3)
    except Exception as e:
        print(f"  打开失败: {e}")
        return
    try:
        ser.reset_input_buffer()
        ser.write(b"\r\n\r\n")
        ser.flush()
        end = time.time() + 2.5
        data = b""
        while time.time() < end:
            chunk = ser.read(4096)
            if chunk:
                data += chunk
        if not data:
            print("  (无响应)")
            return
        text = data.decode("utf-8", errors="replace")
        printable = "".join(ch if ch.isprintable() or ch in "\r\n" else "·" for ch in text)
        print(f"  收到 {len(data)} 字节:")
        for line in printable.replace("\r", "").split("\n")[-15:]:
            if line.strip():
                print(f"  | {line}")
        if "·" in printable.replace("\n", ""):
            print("  [含乱码 -> 波特率可能不对]")
    finally:
        ser.close()


if __name__ == "__main__":
    ports = sys.argv[1:] or CANDIDATE_PORTS
    for baud in BAUDS:
        for p in ports:
            probe(p, baud)
