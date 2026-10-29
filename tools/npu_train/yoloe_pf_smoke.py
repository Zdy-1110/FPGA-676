"""YOLOE Prompt-Free (-pf) CPU Smoke Test Script.

Evaluates yoloe-11l-seg-pf and yoloe-26l-seg-pf on 6 evenly spaced sample images.
Filters detections for specific categories: tricycle, traffic cone, barrier/barricade/fence, speed limit / traffic signs.
Saves annotated images with only relevant detections and writes detailed output.
"""

from pathlib import Path
import cv2
from ultralytics import YOLO

# Selected evenly distributed 6 frames
IMAGES = [
    "video_review/label_pool/video_20260929_113539/video_20260929_113539_t0.00.jpg",
    "video_review/label_pool/video_20260929_113539/video_20260929_113539_t15.00.jpg",
    "video_review/label_pool/video_20260929_113539/video_20260929_113539_t30.00.jpg",
    "video_review/label_pool/video_20260929_113539/video_20260929_113539_t45.00.jpg",
    "video_review/label_pool/video_20260929_113539/video_20260929_113539_t60.00.jpg",
    "video_review/label_pool/video_20260929_113539/video_20260929_113539_t75.00.jpg",
]

MODELS = [
    ("yoloe-11l-seg-pf", "models/yoloe/yoloe-11l-seg-pf.pt"),
    ("yoloe-26l-seg-pf", "models/yoloe/yoloe-26l-seg-pf.pt"),
]

# Vocabulary matches:
# 1. 三轮车: 4266: tricycle, 2279: rickshaw
# 2. 锥桶: 4228: traffic cone, 1076: cone
# 3. 水马/施工围挡/隔离栏: 291: barricade, 292: barrier, 1605: fence
# 4. 限速牌/交通标牌: 3807: speed limit sign, 3806: speed limit, 4231: traffic sign, 3405: road sign,
#                     3944: street sign, 3913: stop sign, 4399: warning sign, 2943: parking sign,
#                     3683: sign, 3684: signage
TARGET_CLS_IDS = {
    4266, 2279,
    4228, 1076,
    291, 292, 1605,
    3807, 3806, 4231, 3405, 3944, 3913, 4399, 2943, 3683, 3684
}

def main():
    vis_base = Path("models/yoloe/smoke_vis")

    for model_name, model_path in MODELS:
        print(f"\n=======================================================")
        print(f"=== Model: {model_name} ({model_path}) ===")
        print(f"=======================================================")
        model = YOLO(model_path)
        print(f"Loaded {model_name}. Vocab size: {len(model.names)}")

        model_vis_dir = vis_base / model_name
        model_vis_dir.mkdir(parents=True, exist_ok=True)

        for img_path_str in IMAGES:
            img_path = Path(img_path_str)
            print(f"\n-------------------------------------------------------")
            print(f"Image: {img_path.name}")
            print(f"-------------------------------------------------------")

            # Inference
            results = model.predict(
                source=str(img_path),
                conf=0.15,
                imgsz=1280,
                device="cpu",
                verbose=False
            )
            r = results[0]

            detections = []
            if r.boxes is not None and len(r.boxes) > 0:
                for b in r.boxes:
                    cls_id = int(b.cls[0].item())
                    name = model.names.get(cls_id, str(cls_id))
                    conf = float(b.conf[0].item())
                    xyxy = [round(x, 1) for x in b.xyxy[0].tolist()]
                    detections.append({
                        "cls_id": cls_id,
                        "name": name,
                        "conf": conf,
                        "xyxy": xyxy
                    })

            # Sort by confidence descending
            detections.sort(key=lambda d: d["conf"], reverse=True)

            # a. Relevant target detections
            rel_dets = [d for d in detections if d["cls_id"] in TARGET_CLS_IDS]
            print(f"[A] Target Class Detections (Count: {len(rel_dets)}):")
            if not rel_dets:
                print("  (None)")
            else:
                for d in rel_dets:
                    print(f"  - [{d['cls_id']}] {d['name']}: conf={d['conf']:.4f}, box={d['xyxy']}")

            # b. Top 10 detections overall
            print(f"[B] Top 10 Detections (Any Category):")
            top10 = detections[:10]
            if not top10:
                print("  (None)")
            else:
                for d in top10:
                    is_target = " [TARGET]" if d["cls_id"] in TARGET_CLS_IDS else ""
                    print(f"  - [{d['cls_id']}] {d['name']}: conf={d['conf']:.4f}, box={d['xyxy']}{is_target}")

            # c. Draw only relevant detections
            img = cv2.imread(str(img_path))
            for d in rel_dets:
                x1, y1, x2, y2 = [int(v) for v in d["xyxy"]]
                label = f"{d['name']} {d['conf']:.2f}"
                cv2.rectangle(img, (x1, y1), (x2, y2), (0, 0, 255), 2)
                # Label text
                (tw, th), _ = cv2.getTextSize(label, cv2.FONT_HERSHEY_SIMPLEX, 0.6, 1)
                cv2.rectangle(img, (x1, max(0, y1 - th - 6)), (x1 + tw + 4, max(0, y1)), (0, 0, 255), -1)
                cv2.putText(img, label, (x1 + 2, max(th, y1 - 4)), cv2.FONT_HERSHEY_SIMPLEX, 0.6, (255, 255, 255), 1, cv2.LINE_AA)

            out_img_path = model_vis_dir / img_path.name
            cv2.imwrite(str(out_img_path), img)
            print(f"[C] Saved visualization to: {out_img_path}")

if __name__ == "__main__":
    main()
