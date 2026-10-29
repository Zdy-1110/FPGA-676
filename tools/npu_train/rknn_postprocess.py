"""Numpy-only post-processing for the RKNN YOLOv8 9-tensor export.

The ONNX model produces, for every stride s in (8, 16, 32), three tensors:
    box_s{s}  (1, 4 * reg_max, H, W)  raw DFL logits of Detect.cv2
    cls_s{s}  (1, nc, H, W)           sigmoid of Detect.cv3
    sum_s{s}  (1, 1, H, W)            clamp(cls.sum(1), 0, 1)

All anchors are ordered scale-major (s8, s16, s32) and row-major (i, j)
inside a scale, which matches ultralytics make_anchors()/head concatenation.
"""

import numpy as np

__all__ = ["dfl_decode", "nms"]


def _softmax(x, axis):
    """Numerically stable softmax along one axis."""
    x = x - np.max(x, axis=axis, keepdims=True)
    e = np.exp(x)
    return e / np.sum(e, axis=axis, keepdims=True)


def _as_chw(arr, channels, name):
    """Normalize a (1, C, H, W) or (C, H, W) array to (C, H, W)."""
    a = np.asarray(arr, dtype=np.float32)
    if a.ndim == 4:
        if a.shape[0] != 1:
            raise ValueError("%s: batch size must be 1, got %r" % (name, a.shape))
        a = a[0]
    if a.ndim != 3 or a.shape[0] != channels:
        raise ValueError("%s: expected (%d, H, W), got %r" % (name, channels, a.shape))
    return a


def dfl_decode(outs, strides=(8, 16, 32), reg_max=16):
    """Decode the 9 RKNN outputs into boxes and class scores.

    Args:
        outs: list of 9 numpy arrays (NCHW, batch=1) in the order
            [box_s8, cls_s8, sum_s8, box_s16, cls_s16, sum_s16,
             box_s32, cls_s32, sum_s32].
        strides: anchor strides, one per scale.
        reg_max: DFL bins per side (16).

    Returns:
        boxes_xyxy: (N, 4) float32 in input-image pixels.
        scores:     (N, nc) float32 (already sigmoid).
        N is scale-major then row-major (i, j), like make_anchors().
    """
    strides = tuple(int(s) for s in strides)
    if len(outs) != 3 * len(strides):
        raise ValueError("expected %d tensors, got %d" % (3 * len(strides), len(outs)))

    all_boxes = []
    all_scores = []
    for si, stride in enumerate(strides):
        box_arr = outs[3 * si]
        box_ch = int(box_arr.shape[1] if np.ndim(box_arr) == 4 else box_arr.shape[0])
        cls = _as_chw(outs[3 * si + 1], _infer_nc(outs[3 * si + 1]), "cls_s%d" % stride)
        _, h, w = cls.shape

        if box_ch == 4:
            box = _as_chw(box_arr, 4, "box_s%d" % stride)
            dist = box.reshape(4, -1)
        else:
            box = _as_chw(box_arr, 4 * reg_max, "box_s%d" % stride)
            logits = box.reshape(4, reg_max, h, w)
            prob = _softmax(logits, axis=1)
            bins = np.arange(reg_max, dtype=np.float32).reshape(1, reg_max, 1, 1)
            dist = np.sum(prob * bins, axis=1).reshape(4, -1)  # l, t, r, b

        if box.shape[1:] != cls.shape[1:]:
            raise ValueError(
                "box_s%d %r and cls_s%d %r spatial sizes differ"
                % (stride, box.shape, stride, cls.shape)
            )

        ax = np.arange(w, dtype=np.float32) + 0.5
        ay = np.arange(h, dtype=np.float32) + 0.5
        l, t, r, b = dist[0], dist[1], dist[2], dist[3]
        x1 = (ax[None, :] - l.reshape(h, w)) * stride
        y1 = (ay[:, None] - t.reshape(h, w)) * stride
        x2 = (ax[None, :] + r.reshape(h, w)) * stride
        y2 = (ay[:, None] + b.reshape(h, w)) * stride

        boxes = np.stack([x1, y1, x2, y2], axis=-1).reshape(-1, 4)
        all_boxes.append(boxes.astype(np.float32, copy=False))
        all_scores.append(cls.reshape(cls.shape[0], -1).T.astype(np.float32, copy=False))

    return (
        np.ascontiguousarray(np.concatenate(all_boxes, axis=0), dtype=np.float32),
        np.ascontiguousarray(np.concatenate(all_scores, axis=0), dtype=np.float32),
    )


def _infer_nc(arr):
    """Return channel count of a (1, C, H, W) or (C, H, W) class tensor."""
    a = np.asarray(arr)
    return int(a.shape[1] if a.ndim == 4 else a.shape[0])


def _iou_xyxy(box, boxes):
    """IoU of one box (4,) against many boxes (M, 4)."""
    x1 = np.maximum(box[0], boxes[:, 0])
    y1 = np.maximum(box[1], boxes[:, 1])
    x2 = np.minimum(box[2], boxes[:, 2])
    y2 = np.minimum(box[3], boxes[:, 3])
    iw = np.maximum(x2 - x1, 0.0)
    ih = np.maximum(y2 - y1, 0.0)
    inter = iw * ih
    area_a = max(box[2] - box[0], 0.0) * max(box[3] - box[1], 0.0)
    area_b = np.maximum(boxes[:, 2] - boxes[:, 0], 0.0) * np.maximum(
        boxes[:, 3] - boxes[:, 1], 0.0
    )
    union = area_a + area_b - inter
    return np.where(union > 0.0, inter / np.maximum(union, 1e-12), 0.0)


def _greedy_nms(boxes, scores, iou_thres):
    """Greedy NMS on a single class; returns indices sorted by score."""
    order = np.argsort(-scores, kind="stable")
    keep = []
    while order.size:
        i = int(order[0])
        keep.append(i)
        if order.size == 1:
            break
        ious = _iou_xyxy(boxes[i], boxes[order[1:]])
        order = order[1:][ious <= iou_thres]
    return keep


def nms(
    boxes,
    scores,
    conf_thres=0.25,
    iou_thres=0.45,
    max_det=300,
    class_aware=True,
    mode=None,
):
    """Confidence filtering plus greedy NMS in pure numpy.

    Args:
        boxes: (N, 4) xyxy float array.
        scores: (N, nc) or (N,) class scores.
        conf_thres: anchors whose best class score is below this are dropped.
        iou_thres: IoU above which a lower-scored box is suppressed.
        max_det: maximum number of returned detections.
        class_aware: suppress only inside the same class (used when mode is None).
        mode: NMS mode ("agnostic", "class", or "pr_split"). If None, falls
            back to "class" if class_aware else "agnostic".

    Returns:
        (boxes (K,4), scores (K,), cls (K,) int64), sorted by score desc.
    """
    boxes = np.asarray(boxes, dtype=np.float32).reshape(-1, 4)
    scores = np.asarray(scores, dtype=np.float32)
    if scores.ndim == 1:
        scores = scores.reshape(-1, 1)
    if boxes.shape[0] != scores.shape[0]:
        raise ValueError(
            "boxes/scores length mismatch: %d vs %d" % (boxes.shape[0], scores.shape[0])
        )
    if boxes.shape[0] == 0:
        return (
            np.zeros((0, 4), dtype=np.float32),
            np.zeros((0,), dtype=np.float32),
            np.zeros((0,), dtype=np.int64),
        )

    cls = np.argmax(scores, axis=1).astype(np.int64)
    conf = scores[np.arange(scores.shape[0]), cls]
    valid = conf >= float(conf_thres)
    boxes = boxes[valid]
    conf = conf[valid]
    cls = cls[valid]
    if boxes.shape[0] == 0:
        return (
            np.zeros((0, 4), dtype=np.float32),
            np.zeros((0,), dtype=np.float32),
            np.zeros((0,), dtype=np.int64),
        )

    if mode is None:
        mode = "class" if class_aware else "agnostic"
    elif mode not in ("agnostic", "class", "pr_split"):
        raise ValueError(
            "unknown nms mode: %r (expected 'agnostic', 'class', or 'pr_split')"
            % (mode,)
        )

    if mode == "class":
        keep = []
        for c in np.unique(cls):
            idx = np.flatnonzero(cls == c)
            local = _greedy_nms(boxes[idx], conf[idx], float(iou_thres))
            keep.extend(idx[local].tolist())
        keep = np.asarray(keep, dtype=np.int64)
    elif mode == "agnostic":
        keep = np.asarray(_greedy_nms(boxes, conf, float(iou_thres)), dtype=np.int64)
    elif mode == "pr_split":
        order = np.argsort(-conf, kind="stable")
        keep = []
        while order.size:
            i = int(order[0])
            keep.append(i)
            if order.size == 1:
                break
            cand = order[1:]
            ious = _iou_xyxy(boxes[i], boxes[cand])
            # High-score box i suppresses low-score box j if IoU > iou_thres and {cls_i, cls_j} != {0, 1}
            is_pr_pair = ((cls[i] == 0) & (cls[cand] == 1)) | ((cls[i] == 1) & (cls[cand] == 0))
            suppressed = (ious > float(iou_thres)) & (~is_pr_pair)
            order = cand[~suppressed]
        keep = np.asarray(keep, dtype=np.int64)

    order = np.argsort(-conf[keep], kind="stable")[: int(max_det)]
    keep = keep[order]
    return (
        np.ascontiguousarray(boxes[keep], dtype=np.float32),
        np.ascontiguousarray(conf[keep], dtype=np.float32),
        np.ascontiguousarray(cls[keep], dtype=np.int64),
    )
