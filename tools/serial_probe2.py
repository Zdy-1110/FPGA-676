#!/usr/bin/env python3
"""加强版串口探测：拉DTR/RTS、发Ctrl+C和回车、长监听。"""
import sys
import time
import serial

PORTS = ["COM3", "COM4", "COM7", "COM8", "COM9", "COM10"]
BAUDS = [1500000, 115200]


def probe(port: str, baud: int) -> None:
    try:
        ser = serial.Serial(port=port, baudrate=baud, timeout=0.3)
    except Exception as e:
        print(f"{port}@{baud}: 打开失败: {e}")
        return
    try:
        ser.dtr = True
        ser.rts = True
        ser.reset_input_buffer()
        # Ctrl+C 唤醒可能卡住的 shell，再回车取提示符
        ser.write(b"\x03\r\n")
        ser.flush()
        end = time.time() + 3.0
        data = b""
        while time.time() < end:
            chunk = ser.read(4096)
            if chunk:
                data += chunk
                end = max(end, time.time() + 1.0)  # 有数据就多等一会
        if not data:
            print(f"{port}@{baud}: (无响应)")
            return
        text = data.decode("utf-8", errors="replace")
        printable = "".join(ch if ch.isprintable() or ch in "\r\n" else "·" for ch in text)
        tail = "\n".join(
            f"  | {l}" for l in printable.replace("\r", "").split("\n")[-20:] if l.strip()
        )
        print(f"{port}@{baud}: 收到 {len(data)} 字节\n{tail}")
        garbled = sum(1 for ch in printable if ch == "·")
        if garbled > len(printable) * 0.3:
            print("  [大量乱码 -> 波特率可能不对]")
    finally:
        ser.close()


if __name__ == "__main__":
    only = sys.argv[1:] or PORTS
    for baud in BAUDS:
        for p in only:
            probe(p, baud)
