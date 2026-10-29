import os
import subprocess

import numpy as np


def iter_frames(video, ffmpeg, step, max_seconds=0, fps=30.0, w=1920, h=1080):
    frame_size = w * h * 3
    cmd = [ffmpeg, "-v", "error", "-i", video, "-f", "rawvideo",
           "-pix_fmt", "bgr24", "-"]
    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    i = 0
    try:
        while True:
            buf = proc.stdout.read(frame_size)
            if not buf or len(buf) < frame_size:
                break
            if i % step == 0:
                t = i / fps
                if max_seconds > 0 and t >= max_seconds:
                    break
                frame = np.frombuffer(buf, dtype=np.uint8).reshape(h, w, 3).copy()
                yield i, t, frame
            i += 1
    finally:
        for closer in (lambda: proc.stdout.close(),):
            try:
                closer()
            except Exception:
                pass
        try:
            proc.terminate()
        except Exception:
            pass
        try:
            proc.wait(timeout=5)
        except Exception:
            try:
                proc.kill()
            except Exception:
                pass
        try:
            proc.stderr.close()
        except Exception:
            pass


def video_id(path):
    base = os.path.splitext(os.path.basename(path))[0]
    return base[-6:]
