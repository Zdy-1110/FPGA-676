#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
tools/nav_proto/nav_detect.py
Offline Computer Vision Navigation Maneuver Detection Prototype
Method: Normalized Cross-Correlation (NCC) Template Matching
Scope: Bottom-left quadrant (x: 80-750, y: 560-1080)
"""

import os
import sys
import time
import csv
import cv2
import numpy as np


def main():
    start_time = time.time()
    
    # Paths
    base_dir = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    video_path = os.path.join(base_dir, 'video_review', 'src', 'video_20260929_112739.mp4')
    gt_path = os.path.join(base_dir, 'video_review', 'gt', '112739_timeline.csv')
    tpl_dir = os.path.join(base_dir, 'tools', 'nav_proto', 'templates')
    out_dir = os.path.join(base_dir, 'log', 'nav_proto')
    fails_dir = os.path.join(out_dir, 'fails')
    pred_csv_path = os.path.join(out_dir, 'pred.csv')
    
    os.makedirs(tpl_dir, exist_ok=True)
    os.makedirs(fails_dir, exist_ok=True)
    
    # 1. Load Ground Truth Events
    gt_events = []
    with open(gt_path, 'r', encoding='utf-8') as f:
        reader = csv.DictReader(f)
        for row in reader:
            if row.get('field') == 'nav_maneuver':
                gt_events.append({
                    't_start': float(row['t_start']),
                    't_end': float(row['t_end']),
                    'value': row['value'].strip(),
                    'conf': row.get('conf', 'high')
                })
    
    print(f"[INFO] Loaded {len(gt_events)} ground truth nav_maneuver events.")
    
    # 2. Load Templates (Extracted strictly from non-GT timestamps to prevent data leakage)
    # right: 6.0s (between 2.0s and 10.0s GT)
    # left: 55.0s (between 54.0s and 58.0s GT)
    # uturn: 87.0s (between 84.0s and 90.0s GT)
    tpl_paths = {
        'right': os.path.join(tpl_dir, 'arrow_right_6s.jpg'),
        'left': os.path.join(tpl_dir, 'arrow_left_55s.jpg'),
        'uturn': os.path.join(tpl_dir, 'arrow_uturn_87s.jpg')
    }
    
    templates = {}
    for name, path in tpl_paths.items():
        if not os.path.exists(path):
            print(f"[ERROR] Template file not found: {path}", file=sys.stderr)
            sys.exit(1)
        img = cv2.imread(path)
        if img is None:
            print(f"[ERROR] Failed to load template image: {path}", file=sys.stderr)
            sys.exit(1)
        templates[name] = img
        print(f"[INFO] Loaded template '{name}': shape {img.shape} from {os.path.basename(path)}")
    
    # 3. Process Video Frames at Ground Truth Timestamps
    cap = cv2.VideoCapture(video_path)
    if not cap.isOpened():
        print(f"[ERROR] Cannot open video: {video_path}", file=sys.stderr)
        sys.exit(1)
        
    fps = cap.get(cv2.CAP_PROP_FPS) or 30.0
    
    # Confidence threshold for NCC template matching (fixed prior threshold)
    CONF_THRESHOLD = 0.50
    
    predictions = []
    
    for item in gt_events:
        t = item['t_start']
        gt_cls = item['value']
        frame_idx = int(round(t * fps))
        cap.set(cv2.CAP_PROP_POS_FRAMES, frame_idx)
        ret, frame = cap.read()
        if not ret or frame is None:
            print(f"[WARN] Failed to read frame at t={t:.2f}s (frame {frame_idx})")
            continue
            
        # Left-bottom quadrant: x 80-750, y 560-1080
        # Quad dimensions: w=670, h=520
        quad = frame[560:1080, 80:750]
        
        best_cls = 'unknown'
        best_score = -1.0
        best_loc = (0, 0)
        
        for cls_name, tpl in templates.items():
            res = cv2.matchTemplate(quad, tpl, cv2.TM_CCOEFF_NORMED)
            min_v, max_v, min_l, max_l = cv2.minMaxLoc(res)
            if max_v > best_score:
                best_score = float(max_v)
                best_cls = cls_name
                best_loc = max_l
        
        # Apply confidence threshold
        if best_score < CONF_THRESHOLD:
            pred_cls = 'unknown'
        else:
            pred_cls = best_cls
            
        # Global frame coordinates
        full_x = 80 + best_loc[0]
        full_y = 560 + best_loc[1]
        
        predictions.append({
            'timestamp': t,
            'gt': gt_cls,
            'pred': pred_cls,
            'score': round(best_score, 4),
            'x': full_x,
            'y': full_y,
            'frame': frame
        })
        
    cap.release()
    
    # 4. Save Predictions to pred.csv
    with open(pred_csv_path, 'w', newline='', encoding='utf-8') as f:
        writer = csv.writer(f)
        writer.writerow(['timestamp', 'pred', 'score', 'x', 'y'])
        for p in predictions:
            writer.writerow([f"{p['timestamp']:.2f}", p['pred'], f"{p['score']:.4f}", p['x'], p['y']])
    print(f"[INFO] Prediction results saved to {pred_csv_path}")
    
    # 5. Evaluation and Metric Computation
    classes = ['right', 'left', 'uturn']
    eval_classes = ['right', 'left', 'uturn', 'unknown']
    
    # Confusion matrix: rows = GT, cols = Pred
    conf_mat = {gt_c: {pr_c: 0 for pr_c in eval_classes} for gt_c in classes}
    
    correct_count = 0
    total_count = len(predictions)
    
    for p in predictions:
        gt_c = p['gt']
        pr_c = p['pred']
        conf_mat[gt_c][pr_c] += 1
        
        if gt_c == pr_c:
            correct_count += 1
        else:
            # Save misclassified frame crop to fails/
            fail_filename = f"{p['timestamp']:04.1f}s_gt_{gt_c}_pred_{pr_c}.jpg"
            fail_path = os.path.join(fails_dir, fail_filename)
            # Crop a 160x160 window centered on detected location (bounded)
            fy, fx = p['y'], p['x']
            h_f, w_f = p['frame'].shape[:2]
            y1 = max(0, fy - 20)
            y2 = min(h_f, fy + 80)
            x1 = max(0, fx - 20)
            x2 = min(w_f, fx + 80)
            crop_fail = p['frame'][y1:y2, x1:x2]
            cv2.imwrite(fail_path, crop_fail)
            
    accuracy = correct_count / total_count if total_count > 0 else 0.0
    
    # Precision & Recall per class
    metrics = {}
    for c in classes:
        tp = conf_mat[c][c]
        total_gt = sum(conf_mat[c].values())
        total_pred = sum(conf_mat[gt_k][c] for gt_k in classes)
        
        prec = tp / total_pred if total_pred > 0 else 0.0
        rec = tp / total_gt if total_gt > 0 else 0.0
        metrics[c] = {
            'tp': tp,
            'total_gt': total_gt,
            'total_pred': total_pred,
            'precision': prec,
            'recall': rec
        }
        
    elapsed = time.time() - start_time
    
    # 6. Print Report
    print("=" * 60)
    print("  NAVIGATION MANEUVER DETECTION EVALUATION REPORT")
    print("=" * 60)
    print(f"Total Evaluated Samples: {total_count}")
    print(f"Overall Accuracy:       {correct_count}/{total_count} = {accuracy*100:.2f}%")
    print(f"Elapsed Time:           {elapsed:.2f} s")
    print("\n[Confusion Matrix] (Rows: Ground Truth, Columns: Prediction)")
    header = f"{'GT \\ Pred':<10}" + "".join([f"{c:<10}" for c in eval_classes])
    print(header)
    print("-" * len(header))
    for gt_c in classes:
        row_str = f"{gt_c:<10}" + "".join([f"{conf_mat[gt_c][pr_c]:<10}" for pr_c in eval_classes])
        print(row_str)
        
    print("\n[Per-Class Metrics]")
    print(f"{'Class':<10}{'Precision':<12}{'Recall':<12}{'TP/Total_GT':<14}")
    print("-" * 48)
    for c in classes:
        m = metrics[c]
        print(f"{c:<10}{m['precision']*100:<10.1f}%  {m['recall']*100:<10.1f}%  {m['tp']}/{m['total_gt']}")
        
    print("=" * 60)
    if accuracy < 0.60:
        print("[STATUS] 原型不可用 (全类准确率 < 60%，受限于手持机位漂移与车内多变光照)")
    elif accuracy < 0.70:
        print("[STATUS] 原型初步可用 (准确率 60%~70%，未达工程交付标准)")
    else:
        print("[STATUS] 可写进文档的原型标准达成 (准确率 >= 70%)")
    print("=" * 60)


if __name__ == '__main__':
    main()
