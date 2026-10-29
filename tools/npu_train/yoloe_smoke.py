"""YOLOE CPU smoke test script."""
import sys
from ultralytics import YOLO

CLASSES = [
    "tricycle",
    "traffic cone",
    "water-filled barrier",
    "construction barrier",
    "speed limit sign"
]

IMAGES = [
    "video_review/label_pool/video_20260929_113539/video_20260929_113539_t0.00.jpg",
    "video_review/label_pool/video_20260929_113539/video_20260929_113539_t0.50.jpg",
    "video_review/label_pool/video_20260929_113539/video_20260929_113539_t1.00.jpg"
]

def main():
    model_path = "models/yoloe/yoloe-11l-seg.pt"
    print(f"Loading {model_path}...")
    model = YOLO(model_path)

    print(f"Setting classes: {CLASSES}...")
    model.set_classes(CLASSES)

    print("Running inference...")
    for img_path in IMAGES:
        print(f"\n--- Image: {img_path} ---")
        results = model.predict(source=img_path, conf=0.25, imgsz=1280, device="cpu", verbose=False)
        for r in results:
            boxes = r.boxes
            if boxes is None or len(boxes) == 0:
                print("  No detections.")
                continue
            for b in boxes:
                cls_id = int(b.cls[0].item())
                cls_name = model.names.get(cls_id, str(cls_id))
                conf = float(b.conf[0].item())
                xyxy = b.xyxy[0].tolist()
                print(f"  Class: {cls_name}, Conf: {conf:.4f}, Box: {xyxy}")

if __name__ == "__main__":
    main()
