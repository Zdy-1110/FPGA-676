"""Shared helpers for NPU training data preparation (road-band 960x320)."""

import os
import sys

import cv2
import numpy as np

CLASS_NAMES = [
    "person", "rider", "car", "bus", "truck", "tricycle", "cone", "barrier",
    "speed_limit",
]

SRC_W = 1920
SRC_H = 1080
BAND_Y0 = 360
BAND_Y1 = 1000
OUT_W = 960
OUT_H = 320

COCO_PERSON = 0
COCO_TWO_WHEEL = (1, 3)
COCO_VEHICLE_MAP = {2: 2, 5: 3, 7: 4}
CLS_CAR, CLS_BUS, CLS_TRUCK = 2, 3, 4


def imread_any(path):
    data = np.fromfile(path, dtype=np.uint8)
    if data.size == 0:
        return None
    return cv2.imdecode(data, cv2.IMREAD_COLOR)


def imwrite_any(path, img):
    ext = os.path.splitext(path)[1] or ".jpg"
    ok, buf = cv2.imencode(ext, img)
    if not ok:
        raise IOError("cv2.imencode failed: %s" % path)
    parent = os.path.dirname(os.path.abspath(path))
    if parent and not os.path.isdir(parent):
        os.makedirs(parent, exist_ok=True)
    buf.tofile(path)
    return True


def band_crop_resize(img, y0=BAND_Y0, y1=BAND_Y1, out_w=OUT_W, out_h=OUT_H):
    crop = img[y0:y1, :]
    return cv2.resize(crop, (out_w, out_h), interpolation=cv2.INTER_AREA)


def read_yolo_txt(path, img_w, img_h):
    boxes = []
    if not os.path.isfile(path):
        return boxes
    with open(path, "r", encoding="utf-8") as f:
        for line in f:
            parts = line.split()
            if len(parts) < 5:
                continue
            cls = int(float(parts[0]))
            cx, cy, w, h = (float(v) for v in parts[1:5])
            x1 = (cx - w / 2.0) * img_w
            y1 = (cy - h / 2.0) * img_h
            x2 = (cx + w / 2.0) * img_w
            y2 = (cy + h / 2.0) * img_h
            boxes.append((cls, x1, y1, x2, y2))
    return boxes


def write_yolo_txt(path, boxes, img_w, img_h):
    lines = []
    for cls, x1, y1, x2, y2 in boxes:
        cx = (x1 + x2) / 2.0 / img_w
        cy = (y1 + y2) / 2.0 / img_h
        w = (x2 - x1) / img_w
        h = (y2 - y1) / img_h
        lines.append("%d %.6f %.6f %.6f %.6f" % (int(cls), cx, cy, w, h))
    parent = os.path.dirname(os.path.abspath(path))
    if parent and not os.path.isdir(parent):
        os.makedirs(parent, exist_ok=True)
    text = "\n".join(lines)
    if text:
        text += "\n"
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write(text)
    return len(lines)


def boxes_to_band(boxes, y0=BAND_Y0, y1=BAND_Y1, src_w=SRC_W, out_w=OUT_W,
                  out_h=OUT_H, min_vis=0.3, min_h_out=4.0):
    out = []
    band_h = float(y1 - y0)
    if band_h <= 0 or src_w <= 0:
        return out
    sx = float(out_w) / float(src_w)
    sy = float(out_h) / band_h
    for cls, x1, y1b, x2, y2b in boxes:
        ox1, oy1, ox2, oy2 = float(x1), float(y1b), float(x2), float(y2b)
        area = max(0.0, ox2 - ox1) * max(0.0, oy2 - oy1)
        if area <= 0.0:
            continue
        cx1 = min(max(ox1, 0.0), float(src_w))
        cx2 = min(max(ox2, 0.0), float(src_w))
        cy1 = min(max(oy1, float(y0)), float(y1))
        cy2 = min(max(oy2, float(y0)), float(y1))
        if cx2 <= cx1 or cy2 <= cy1:
            continue
        vis = (cx2 - cx1) * (cy2 - cy1) / area
        if vis < min_vis:
            continue
        bx1 = cx1 * sx
        bx2 = cx2 * sx
        by1 = (cy1 - float(y0)) * sy
        by2 = (cy2 - float(y0)) * sy
        if (by2 - by1) < min_h_out:
            continue
        out.append((int(cls), bx1, by1, bx2, by2))
    return out


def _box_width(d):
    return d["x2"] - d["x1"]


def _overlap_width(a, b):
    return max(0.0, min(a["x2"], b["x2"]) - max(a["x1"], b["x1"]))


def _area(d):
    return max(0.0, d["x2"] - d["x1"]) * max(0.0, d["y2"] - d["y1"])


def _inter_area(a, b):
    w = max(0.0, min(a["x2"], b["x2"]) - max(a["x1"], b["x1"]))
    h = max(0.0, min(a["y2"], b["y2"]) - max(a["y1"], b["y1"]))
    return w * h


def _iou(a, b):
    inter = _inter_area(a, b)
    if inter <= 0.0:
        return 0.0
    union = _area(a) + _area(b) - inter
    if union <= 0.0:
        return 0.0
    return inter / union


def _inside_vehicle(person, vehicles):
    p_area = _area(person)
    if p_area <= 0.0:
        return False
    for v in vehicles:
        v_h = v["y2"] - v["y1"]
        if _inter_area(person, v) < 0.8 * p_area:
            continue
        if person["y2"] < v["y2"] - 0.15 * v_h:
            return True
    return False


def coco_to_project(dets, min_h_src=24.0):
    persons = [d for d in dets if d.get("coco_id") == COCO_PERSON]
    two_wheelers = [d for d in dets if d.get("coco_id") in COCO_TWO_WHEEL]
    vehicles = [d for d in dets if d.get("coco_id") in COCO_VEHICLE_MAP]

    assigned = {id(m): [] for m in two_wheelers}
    free_persons = []
    for p in persons:
        pw = _box_width(p)
        pcy = (p["y1"] + p["y2"]) / 2.0
        best = None
        best_ov = -1.0
        for m in two_wheelers:
            ov = _overlap_width(p, m)
            mcy = (m["y1"] + m["y2"]) / 2.0
            if ov >= 0.5 * pw and pcy < mcy and p["y2"] >= m["y1"] and ov > best_ov:
                best = m
                best_ov = ov
        if best is None:
            free_persons.append(p)
        else:
            assigned[id(best)].append(p)

    out = []
    for m in two_wheelers:
        group = assigned[id(m)]
        if not group:
            continue
        x1 = min([m["x1"]] + [p["x1"] for p in group])
        y1 = min([m["y1"]] + [p["y1"] for p in group])
        x2 = max([m["x2"]] + [p["x2"] for p in group])
        y2 = max([m["y2"]] + [p["y2"] for p in group])
        conf = max([m["conf"]] + [p["conf"] for p in group])
        out.append({
            "cls": 1, "conf": conf, "src": "merged",
            "x1": x1, "y1": y1, "x2": x2, "y2": y2,
        })

    for p in free_persons:
        if _inside_vehicle(p, vehicles):
            continue
        out.append({
            "cls": 0, "conf": p["conf"], "src": "coco_person",
            "x1": p["x1"], "y1": p["y1"], "x2": p["x2"], "y2": p["y2"],
        })

    kept_vehicles = []
    for v in sorted(vehicles, key=lambda d: -d["conf"]):
        if any(_iou(v, k) > 0.6 for k in kept_vehicles):
            continue
        kept_vehicles.append(v)
    for v in kept_vehicles:
        out.append({
            "cls": COCO_VEHICLE_MAP[v["coco_id"]],
            "conf": v["conf"],
            "src": "coco_id%d" % int(v["coco_id"]),
            "x1": v["x1"], "y1": v["y1"], "x2": v["x2"], "y2": v["y2"],
        })

    return [d for d in out if (d["y2"] - d["y1"]) >= min_h_src]


def _selftest():
    boxes = [(0, 100.0, 400.0, 200.0, 500.0)]
    r = boxes_to_band(boxes, BAND_Y0, BAND_Y1, SRC_W, OUT_W, OUT_H)
    assert len(r) == 1, r
    cls, x1, y1, x2, y2 = r[0]
    assert cls == 0
    assert abs(x1 - 50.0) < 1e-6 and abs(x2 - 100.0) < 1e-6, r
    assert abs(y1 - 20.0) < 1e-6 and abs(y2 - 70.0) < 1e-6, r

    r = boxes_to_band([(1, 100.0, 200.0, 200.0, 520.0)], BAND_Y0, BAND_Y1,
                      SRC_W, OUT_W, OUT_H)
    assert len(r) == 1, r
    assert abs(r[0][2] - 0.0) < 1e-6 and abs(r[0][4] - 80.0) < 1e-6, r

    r = boxes_to_band([(2, 100.0, 200.0, 200.0, 400.0)], BAND_Y0, BAND_Y1,
                      SRC_W, OUT_W, OUT_H)
    assert r == [], r

    r = boxes_to_band([(3, 100.0, 500.0, 200.0, 506.0)], BAND_Y0, BAND_Y1,
                      SRC_W, OUT_W, OUT_H)
    assert r == [], r

    import tempfile
    tmpdir = tempfile.mkdtemp(dir=tempfile.gettempdir(), prefix="npu_common_")
    txt = os.path.join(tmpdir, "roundtrip.txt")
    src_boxes = [(0, 123.456, 400.0, 300.5, 700.25),
                 (8, 1000.0, 360.0, 1200.0, 999.0)]
    write_yolo_txt(txt, src_boxes, SRC_W, SRC_H)
    back = read_yolo_txt(txt, SRC_W, SRC_H)
    assert len(back) == len(src_boxes), back
    for a, b in zip(src_boxes, back):
        assert a[0] == b[0], (a, b)
        for va, vb in zip(a[1:], b[1:]):
            assert abs(va - vb) < 1e-3, (a, b)
    empty_txt = os.path.join(tmpdir, "empty.txt")
    write_yolo_txt(empty_txt, [], SRC_W, SRC_H)
    assert read_yolo_txt(empty_txt, SRC_W, SRC_H) == []
    assert os.path.getsize(empty_txt) == 0

    person = {"coco_id": 0, "conf": 0.9, "x1": 100.0, "y1": 300.0,
              "x2": 160.0, "y2": 500.0}
    moto = {"coco_id": 3, "conf": 0.8, "x1": 90.0, "y1": 420.0,
            "x2": 180.0, "y2": 700.0}
    res = coco_to_project([person, moto])
    assert len(res) == 1, res
    assert res[0]["cls"] == 1 and res[0]["src"] == "merged", res
    assert res[0]["x1"] == 90.0 and res[0]["y1"] == 300.0, res
    assert res[0]["x2"] == 180.0 and res[0]["y2"] == 700.0, res
    assert abs(res[0]["conf"] - 0.9) < 1e-9, res

    res = coco_to_project([{"coco_id": 1, "conf": 0.7, "x1": 500.0,
                            "y1": 500.0, "x2": 600.0, "y2": 700.0}])
    assert res == [], res

    car = {"coco_id": 2, "conf": 0.9, "x1": 800.0, "y1": 400.0,
           "x2": 1100.0, "y2": 800.0}
    passenger = {"coco_id": 0, "conf": 0.6, "x1": 900.0, "y1": 450.0,
                 "x2": 1000.0, "y2": 650.0}
    res = coco_to_project([car, passenger])
    assert len(res) == 1 and res[0]["cls"] == 2, res

    car_low = {"coco_id": 2, "conf": 0.4, "x1": 802.0, "y1": 402.0,
               "x2": 1098.0, "y2": 798.0}
    res = coco_to_project([car, car_low])
    assert len(res) == 1, res
    assert abs(res[0]["conf"] - 0.9) < 1e-9, res

    print("SELFTEST OK")


if __name__ == "__main__":
    if "--selftest" in sys.argv:
        _selftest()
        sys.exit(0)
    print("usage: python npu_common.py --selftest")
