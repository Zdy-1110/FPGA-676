"""Self-test for rknn_postprocess.py NMS modes (agnostic, class, pr_split)."""

import os
import sys
import numpy as np

_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)

import rknn_postprocess


def legacy_nms(boxes, scores, conf_thres=0.25, iou_thres=0.45, max_det=300, class_aware=True):
    """Reference implementation of pre-modification nms for bitwise comparison."""
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

    if class_aware:
        keep = []
        for c in np.unique(cls):
            idx = np.flatnonzero(cls == c)
            local = rknn_postprocess._greedy_nms(boxes[idx], conf[idx], float(iou_thres))
            keep.extend(idx[local].tolist())
        keep = np.asarray(keep, dtype=np.int64)
    else:
        keep = np.asarray(rknn_postprocess._greedy_nms(boxes, conf, float(iou_thres)), dtype=np.int64)

    order = np.argsort(-conf[keep], kind="stable")[: int(max_det)]
    keep = keep[order]
    return (
        np.ascontiguousarray(boxes[keep], dtype=np.float32),
        np.ascontiguousarray(conf[keep], dtype=np.float32),
        np.ascontiguousarray(cls[keep], dtype=np.int64),
    )


def test_backward_compatibility():
    """Verify that existing arguments and default behavior produce bit-for-bit identical results."""
    rng = np.random.RandomState(42)
    for trial in range(20):
        n = rng.randint(0, 100)
        nc = 9
        boxes = rng.uniform(0, 960, size=(n, 4)).astype(np.float32)
        boxes[:, 2] = boxes[:, 0] + rng.uniform(10, 100, size=n)
        boxes[:, 3] = boxes[:, 1] + rng.uniform(10, 100, size=n)
        scores = rng.uniform(0.0, 1.0, size=(n, nc)).astype(np.float32)

        for c_aware in (True, False):
            # legacy vs updated with default mode=None
            b_leg, s_leg, c_leg = legacy_nms(boxes, scores, conf_thres=0.1, iou_thres=0.5, class_aware=c_aware)
            b_new, s_new, c_new = rknn_postprocess.nms(boxes, scores, conf_thres=0.1, iou_thres=0.5, class_aware=c_aware)

            assert np.array_equal(b_leg, b_new), f"boxes mismatch on trial {trial}, class_aware={c_aware}"
            assert np.array_equal(s_leg, s_new), f"scores mismatch on trial {trial}, class_aware={c_aware}"
            assert np.array_equal(c_leg, c_new), f"cls mismatch on trial {trial}, class_aware={c_aware}"

            # mode string explicit ("class" or "agnostic")
            mode_str = "class" if c_aware else "agnostic"
            b_mod, s_mod, c_mod = rknn_postprocess.nms(boxes, scores, conf_thres=0.1, iou_thres=0.5, mode=mode_str)
            assert np.array_equal(b_leg, b_mod), f"mode={mode_str} mismatch on trial {trial}"
            assert np.array_equal(s_leg, s_mod), f"mode={mode_str} mismatch on trial {trial}"
            assert np.array_equal(c_leg, c_mod), f"mode={mode_str} mismatch on trial {trial}"

    print("[PASS] test_backward_compatibility")


def _make_scores(n, best_cls, best_conf, nc=9):
    scores = np.zeros((n, nc), dtype=np.float32)
    for i in range(n):
        scores[i, best_cls[i]] = best_conf[i]
    return scores


def test_pr_split_logic():
    """Verify person/rider, person/car, and same-class suppression behavior."""
    # 1. Person (0) & Rider (1) high overlap
    # Box 0: person, conf 0.90
    # Box 1: rider, conf 0.80
    boxes = np.array([
        [10.0, 10.0, 50.0, 50.0],
        [10.5, 10.5, 50.5, 50.5],
    ], dtype=np.float32)
    scores = _make_scores(2, [0, 1], [0.90, 0.80])

    # agnostic: person suppresses rider -> 1 box (person)
    b_ag, s_ag, c_ag = rknn_postprocess.nms(boxes, scores, iou_thres=0.6, mode="agnostic")
    assert len(b_ag) == 1 and c_ag[0] == 0, f"agnostic expected 1 person, got {c_ag}"

    # class: rider not suppressed -> 2 boxes (person, rider)
    b_cl, s_cl, c_cl = rknn_postprocess.nms(boxes, scores, iou_thres=0.6, mode="class")
    assert len(b_cl) == 2 and set(c_cl.tolist()) == {0, 1}, f"class expected 2 boxes, got {c_cl}"

    # pr_split: person and rider do NOT suppress each other -> 2 boxes (person, rider)
    b_pr, s_pr, c_pr = rknn_postprocess.nms(boxes, scores, iou_thres=0.6, mode="pr_split")
    assert len(b_pr) == 2 and set(c_pr.tolist()) == {0, 1}, f"pr_split expected 2 boxes, got {c_pr}"

    # Reverse score order: rider 0.90, person 0.80
    scores_rev = _make_scores(2, [0, 1], [0.80, 0.90])
    b_pr2, s_pr2, c_pr2 = rknn_postprocess.nms(boxes, scores_rev, iou_thres=0.6, mode="pr_split")
    assert len(b_pr2) == 2 and set(c_pr2.tolist()) == {0, 1}, f"pr_split expected 2 boxes on rev score, got {c_pr2}"

    # 2. Person (0) & Car (2) high overlap
    # Box 0: person, conf 0.90
    # Box 1: car, conf 0.80
    scores_pc = _make_scores(2, [0, 2], [0.90, 0.80])
    # agnostic: 1 box (person)
    b_ag_pc, _, c_ag_pc = rknn_postprocess.nms(boxes, scores_pc, iou_thres=0.6, mode="agnostic")
    assert len(b_ag_pc) == 1 and c_ag_pc[0] == 0
    # class: 2 boxes (person, car)
    b_cl_pc, _, c_cl_pc = rknn_postprocess.nms(boxes, scores_pc, iou_thres=0.6, mode="class")
    assert len(b_cl_pc) == 2 and set(c_cl_pc.tolist()) == {0, 2}
    # pr_split: cross-class suppression applies ({0, 2} != {0, 1}) -> 1 box (person)
    b_pr_pc, _, c_pr_pc = rknn_postprocess.nms(boxes, scores_pc, iou_thres=0.6, mode="pr_split")
    assert len(b_pr_pc) == 1 and c_pr_pc[0] == 0, f"pr_split expected 1 person (suppressed car), got {c_pr_pc}"

    # 3. Same-class high overlap: Person (0) & Person (0)
    scores_pp = _make_scores(2, [0, 0], [0.90, 0.80])
    # agnostic: 1 box
    b_ag_pp, _, c_ag_pp = rknn_postprocess.nms(boxes, scores_pp, iou_thres=0.6, mode="agnostic")
    assert len(b_ag_pp) == 1 and c_ag_pp[0] == 0
    # class: 1 box
    b_cl_pp, _, c_cl_pp = rknn_postprocess.nms(boxes, scores_pp, iou_thres=0.6, mode="class")
    assert len(b_cl_pp) == 1 and c_cl_pp[0] == 0
    # pr_split: same class suppresses ({0, 0} != {0, 1}) -> 1 box
    b_pr_pp, _, c_pr_pp = rknn_postprocess.nms(boxes, scores_pp, iou_thres=0.6, mode="pr_split")
    assert len(b_pr_pp) == 1 and c_pr_pp[0] == 0, f"pr_split expected 1 person, got {c_pr_pp}"

    # 4. Same-class high overlap: Rider (1) & Rider (1)
    scores_rr = _make_scores(2, [1, 1], [0.90, 0.80])
    b_pr_rr, _, c_pr_rr = rknn_postprocess.nms(boxes, scores_rr, iou_thres=0.6, mode="pr_split")
    assert len(b_pr_rr) == 1 and c_pr_rr[0] == 1, f"pr_split expected 1 rider, got {c_pr_rr}"

    # 5. Car (2) & Truck (4) high overlap
    scores_ct = _make_scores(2, [2, 4], [0.90, 0.80])
    b_ag_ct, _, _ = rknn_postprocess.nms(boxes, scores_ct, iou_thres=0.6, mode="agnostic")
    assert len(b_ag_ct) == 1
    b_cl_ct, _, _ = rknn_postprocess.nms(boxes, scores_ct, iou_thres=0.6, mode="class")
    assert len(b_cl_ct) == 2
    b_pr_ct, _, c_pr_ct = rknn_postprocess.nms(boxes, scores_ct, iou_thres=0.6, mode="pr_split")
    assert len(b_pr_ct) == 1 and c_pr_ct[0] == 2, f"pr_split expected 1 car (suppressed truck), got {c_pr_ct}"

    # 6. Low overlap between Person and Car (IoU <= 0.6)
    boxes_sep = np.array([
        [10.0, 10.0, 50.0, 50.0],
        [100.0, 100.0, 150.0, 150.0],
    ], dtype=np.float32)
    b_pr_sep, _, c_pr_sep = rknn_postprocess.nms(boxes_sep, scores_pc, iou_thres=0.6, mode="pr_split")
    assert len(b_pr_sep) == 2, f"pr_split expected 2 separated boxes, got {len(b_pr_sep)}"

    print("[PASS] test_pr_split_logic")


if __name__ == "__main__":
    test_backward_compatibility()
    test_pr_split_logic()
    print("ALL TESTS PASSED SUCCESSFULLY.")
