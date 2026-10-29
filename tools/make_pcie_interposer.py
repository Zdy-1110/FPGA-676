from __future__ import annotations

import json
import math
import shutil
import uuid
import zipfile
from pathlib import Path

ROOT = Path(r"E:\Project\nesai2026")
OUT_DIR = ROOT / "PCIe_INTERPOSER_OK3588C_PANGO100PRO_REV_A_DRAFT_unpacked"
OUT_EPRO = ROOT / "PCIe_INTERPOSER_OK3588C_PANGO100PRO_REV_A_DRAFT.epro"
NOTES = ROOT / "PCIe_INTERPOSER_OK3588C_PANGO100PRO_REV_A_DRAFT.md"

SCH_UUID = "d9f4c2e1a8b34f12b7c9d0e6a1f23540"
PCB_UUID = "a17e8d45b3c24f60a9d1e7c82b054396"
SHEET_IDS = {
    1: ("01_CEM_CONNECTORS", "7d4c2f8a0e6b4c4d9d5b1f0a8e3c6101"),
    2: ("02_PCIE_X4_LANES", "5c7a1e3d9b2f4a6c8d0e1f3b5a7c9202"),
    3: ("03_SIDEBAND_OPTIONS", "9a2d6f1c8b4e4d7a0f3e5b6c1d2a8303"),
    4: ("04_POWER_ISOLATION_NOTES", "3e8b1d5f7a9c4d6e0f2b4c8a1d7e5404"),
}

DEV_P1 = "c1e0000000000001"
DEV_P2 = "c1e0000000000002"
DEV_TP = "c1e0000000000003"
SYM_PCIE = "c1e0000000000011"
SYM_TP = "c1e0000000000012"
FP_EDGE = "c1e0000000000021"
FP_SLOT = "c1e0000000000022"
FP_TP = "c1e0000000000023"


def jdump(value):
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"))


def write_lines(path: Path, records):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(jdump(r) for r in records) + "\n", encoding="utf-8")


def make_symbol(path: Path, symbol_uuid: str, title: str, pin_names: list[str], right_names: list[str] | None = None):
    right_names = right_names or []
    records = [
        ["DOCTYPE", "SYMBOL", "1.1"],
        ["HEAD", {"originX": 0, "originY": 0, "version": "2", "symbolType": 2}],
        ["PART", f"{title}.1", {"BBOX": [-220, 260, 220, -260]}],
        ["LINESTYLE", "st1", None, None, "", None, None],
        ["FONTSTYLE", "st2", None, None, None, 8, 0, 0, 0, 0, 2, 0],
        ["FONTSTYLE", "st3", None, None, None, 7, 0, 0, 0, 0, 2, 0],
        ["FONTSTYLE", "st4", None, None, None, 7, 0, 0, 0, 0, 2, 2],
        ["RECT", "body", -200, -240, 200, 240, 0, 0, 0, "st1", 0],
    ]
    eid = 10
    y0 = 220
    dy = 20
    for idx, name in enumerate(pin_names, start=1):
        y = y0 - (idx - 1) * dy
        pid = f"pL{idx}"
        records.append(["PIN", pid, 1, 1, -220, y, 20, 0, None, 0, 0])
        records.append(["ATTR", f"{pid}n", pid, "NAME", name, 0, 1, -194, y + 4, 0, "st3", 0])
        records.append(["ATTR", f"{pid}#", pid, "NUMBER", str(idx), 0, 1, -196, y - 6, 0, "st4", 0])
        records.append(["ATTR", f"{pid}t", pid, "Pin Type", "BIDIR", 0, 0, None, None, 0, "st3", 0])
        eid += 4
    for idx, name in enumerate(right_names, start=1):
        y = y0 - (idx - 1) * dy
        pid = f"pR{idx}"
        records.append(["PIN", pid, 1, 1, 220, y, 20, 180, None, 0, 0])
        records.append(["ATTR", f"{pid}n", pid, "NAME", name, 0, 1, 194, y + 4, 0, "st3", 0])
        records.append(["ATTR", f"{pid}#", pid, "NUMBER", str(100 + idx), 0, 1, 196, y - 6, 0, "st4", 0])
        records.append(["ATTR", f"{pid}t", pid, "Pin Type", "BIDIR", 0, 0, None, None, 0, "st3", 0])
        eid += 4
    records += [
        ["ATTR", "title", "", "NAME", title, 0, 0, 0, 0, 0, "st2", 0],
        ["ATTR", "desc", "", "Description", "PCIe x4 passive interposer symbol", 0, 0, 0, 0, 0, "st2", 0],
    ]
    write_lines(path, records)


def layer_records():
    return [
        ["DOCTYPE", "PCB", "1.8"],
        ["HEAD", {"editorVersion": "3.2.149.88089769", "importFlag": 0}],
        ["CANVAS", 0, 0, "mm", 0.393701, 0.393701, 0.393701, 0.393701, 0.2, 0.2, 2, 0, 5],
        ["LAYER", 1, "TOP", "Top Layer", 3, "#ff0000", 1, "#7f0000", 0.5],
        ["LAYER", 2, "BOTTOM", "Bottom Layer", 3, "#0000ff", 1, "#00007f", 0.5],
        ["LAYER", 3, "TOP_SILK", "Top Silkscreen Layer", 3, "#ffcc00", 1, "#7f6600", 0.5],
        ["LAYER", 4, "BOT_SILK", "Bottom Silkscreen Layer", 3, "#66cc33", 1, "#336619", 0.5],
        ["LAYER", 5, "TOP_SOLDER_MASK", "Top Solder Mask Layer", 3, "#800080", 1, "#400040", 0.5],
        ["LAYER", 6, "BOT_SOLDER_MASK", "Bottom Solder Mask Layer", 3, "#aa00ff", 1, "#55007f", 0.5],
        ["LAYER", 7, "TOP_PASTE_MASK", "Top Paste Mask Layer", 3, "#808080", 1, "#404040", 0.5],
        ["LAYER", 8, "BOT_PASTE_MASK", "Bottom Paste Mask Layer", 3, "#800000", 1, "#400000", 0.5],
        ["LAYER", 9, "TOP_ASSEMBLY", "Top Assembly Layer", 3, "#33cc99", 1, "#19664c", 0.5],
        ["LAYER", 10, "BOT_ASSEMBLY", "Bottom Assembly Layer", 3, "#5555ff", 1, "#2a2a7f", 0.5],
        ["LAYER", 11, "OUTLINE", "Board Outline Layer", 3, "#ff00ff", 1, "#7f007f", 0.5],
        ["LAYER", 12, "MULTI", "Multi-Layer", 3, "#c0c0c0", 1, "#606060", 0.5],
        ["LAYER", 13, "DOCUMENT", "Document Layer", 3, "#ffffff", 1, "#7f7f7f", 0.5],
        ["LAYER", 14, "MECHANICAL", "Mechanical Layer", 3, "#f022f0", 1, "#781178", 0.5],
        ["LAYER", 15, "PLANE", "Inner1_GND", 0, "#999966", 1, "#4c4c33", 0.5],
        ["LAYER", 16, "SIGNAL", "Inner2_ROUTE", 0, "#008000", 1, "#004000", 0.5],
        ["LAYER", 47, "HOLE", "Hole Layer", 3, "#222222", 1, "#111111", 0.5],
        ["LAYER", 48, "COMPONENT_SHAPE", "Component Shape Layer", 3, "#00cccc", 1, "#006666", 0.5],
        ["LAYER", 49, "COMPONENT_MARKING", "Component Marking Layer", 3, "#66ffcc", 1, "#337f66", 0.5],
        ["LAYER", 50, "PIN_SOLDERING", "Pin Soldering Layer", 3, "#cc9999", 1, "#664c4c", 0.5],
        ["LAYER", 51, "PIN_FLOATING", "Pin Floating Layer", 3, "#ff99ff", 1, "#7f4c7f", 0.5],
        ["LAYER", 56, "DRILL_DRAWING", "Drill Drawing Layer", 3, "#008080", 1, "#004040", 0.5],
    ]


def make_footprint(path: Path, fp_uuid: str, title: str, kind: str):
    records = [
        ["DOCTYPE", "FOOTPRINT", "1.8"],
        ["HEAD", {"editorVersion": "3.2.149.88089769", "importFlag": 0, "uuid": fp_uuid, "title": title, "source": "custom"}],
        ["CANVAS", 0, 0, "mm", 10, 10, 0.393701, 0.393701, 0.2, 0.2, 0, 0, 5],
    ] + layer_records()[3:]
    eid = 1
    pad_positions = {}
    if kind == "edge":
        for row, layer, x in [("A", 1, 0.8), ("B", 2, 0.8)]:
            for i in range(1, 33):
                y = (i - 16.5) * 0.8
                num = f"{row}{i}"
                pad_id = f"pad_{num}"
                pad_positions[num] = (x, y, layer, pad_id)
                geom = ["RECT", 2.8, 0.55, 0]
                records.append(["PAD", pad_id, 0, "", layer, num, x, y, 0, ["ROUND", 0, 0], geom, [], 0, 0, 0, 1, 0, None, None, None, None, 0])
                eid += 1
        records += [
            ["POLY", "outline", 0, "", 11, 0.2, [0, -14, "L", 4.4, -14, "L", 4.4, 14, "L", 0, 14], 0],
            ["POLY", "edge", 0, "", 14, 0.2, [0, -14.2, "L", 0, 14.2], 0],
            ["ATTR", "fp", 0, "", 3, None, None, "Footprint", title, 0, 0, "default", 0, 6, 0, 0, 3, 0, 0, 0, 0, False],
            ["ATTR", "ref", 0, "", 3, None, None, "Designator", "P?", 0, 0, "default", 0, 6, 0, 0, 3, 0, 0, 0, 0, False],
        ]
    elif kind == "slot":
        for row, layer, x in [("A", 1, 0.8), ("B", 2, 3.4)]:
            for i in range(1, 33):
                y = (i - 16.5) * 0.8
                num = f"{row}{i}"
                pad_id = f"pad_{num}"
                pad_positions[num] = (x, y, layer, pad_id)
                geom = ["RECT", 1.6, 0.55, 0]
                records.append(["PAD", pad_id, 0, "", layer, num, x, y, 0, ["ROUND", 0, 0], geom, [], 0, 0, 0, 1, 0, None, None, None, None, 0])
                eid += 1
        records += [
            ["POLY", "body", 0, "", 48, 0.2, [-1, -14, "L", 5.2, -14, "L", 5.2, 14, "L", -1, 14, -1, -14], 0],
            ["POLY", "slot", 0, "", 14, 0.2, [1.9, -13.5, "L", 1.9, 13.5], 0],
            ["ATTR", "fp", 0, "", 3, None, None, "Footprint", title, 0, 0, "default", 0, 6, 0, 0, 3, 0, 0, 0, 0, False],
            ["ATTR", "ref", 0, "", 3, None, None, "Designator", "P?", 0, 0, "default", 0, 6, 0, 0, 3, 0, 0, 0, 0, False],
        ]
    elif kind == "tp":
        records += [
            ["PAD", "pad_1", 0, "", 1, "1", 0, 0, 0, ["ROUND", 0, 0], ["ELLIPSE", 1.6, 1.6], [], 0, 0, 0, 1, 0, None, None, None, None, 0],
            ["POLY", "tp", 0, "", 3, 0.15, ["CIRCLE", 0, 0, 1.1], 0],
            ["ATTR", "fp", 0, "", 3, None, None, "Footprint", title, 0, 0, "default", 0, 6, 0, 0, 3, 0, 0, 0, 0, False],
            ["ATTR", "ref", 0, "", 3, None, None, "Designator", "TP?", 0, 0, "default", 0, 6, 0, 0, 3, 0, 0, 0, 0, False],
        ]
    write_lines(path, records)
    return pad_positions


def sheet_records(page_no: int, page_name: str, texts: list[str], components=None):
    records = [["DOCTYPE", "SCH", "1.1"], ["HEAD", {"originX": 0, "originY": 0, "version": "2"}]]
    records += [
        ["FONTSTYLE", "st1", None, None, None, 9, 0, 0, 0, 0, 2, 0],
        ["FONTSTYLE", "st2", None, None, None, 15, 0, 0, 0, 0, 1, 1],
        ["FONTSTYLE", "st3", None, None, None, 11, 0, 0, 0, 0, 1, 0],
        ["LINESTYLE", "ls1", None, 0, None, 1, 1],
    ]
    meta = [
        ("@Project Name", "PCIe_INTERPOSER_OK3588C_PANGO100PRO_REV_A_DRAFT"),
        ("@Page Count", "4"),
        ("@Page No", str(page_no)),
        ("@Page Name", page_name),
        ("Version", "REV_A_DRAFT"),
        ("Description", "Passive PCIe x4 interposer; not release-ready until connector and REFCLK evidence close."),
    ]
    for i, (k, v) in enumerate(meta):
        records.append(["ATTR", f"meta{i}", "", k, v, 0, 0, None, None, 0, "st1", 0])
    y = 150
    for idx, text in enumerate(texts, start=1):
        records.append(["TEXT", f"txt{idx}", 100, y, 0, text, "st2" if idx == 1 else "st3"])
        y += 60
    if components:
        for comp in components:
            cid, inst, x, y, dev, sym, fp, ref, name, rot = comp
            records.append(["COMPONENT", cid, inst, x, y, rot, 0, {}, 0])
            records += [
                ["ATTR", cid + "d", cid, "Device", dev, 0, 0, None, None, 0, "st1", 0],
                ["ATTR", cid + "s", cid, "Symbol", sym, 0, 0, None, None, 0, "st1", 0],
                ["ATTR", cid + "f", cid, "Footprint", fp, 0, 0, None, None, 0, "st1", 0],
                ["ATTR", cid + "r", cid, "Designator", ref, 0, 1, x, y + 280, 0, "st2", 0],
                ["ATTR", cid + "n", cid, "Name", name, 0, 1, x, y - 280, 0, "st3", 0],
            ]
    return records


def make_project():
    if OUT_DIR.exists():
        shutil.rmtree(OUT_DIR)
    OUT_DIR.mkdir(parents=True)
    for sub in ["SHEET", "PCB", "SYMBOL", "FOOTPRINT", "INSTANCE", "POUR", "PANEL", "BLOB", "FONT"]:
        (OUT_DIR / sub).mkdir()

    pin_left = ["A11_PERST#", "A12_REFCLK+", "A13_REFCLK-", "A15_PER0+", "A16_PER0-", "A19_PER1+", "A20_PER1-", "A23_PER2+", "A24_PER2-", "A27_PER3+", "A28_PER3-", "A1_PRSNT1#", "B11_WAKE#", "B12_CLKREQ#", "GND", "NC_POWER"]
    pin_right = ["B13_PET0+", "B14_PET0-", "B17_PET1+", "B18_PET1-", "B21_PET2+", "B22_PET2-", "B25_PET3+", "B26_PET3-", "GND", "NC_POWER", "SMBUS_NC", "JTAG_NC", "REFCLK_VERIFY"]
    make_symbol(OUT_DIR / "SYMBOL" / f"{SYM_PCIE}.esym", SYM_PCIE, "PCIe_X4_CEM_INTERCONNECT", pin_left, pin_right)
    make_symbol(OUT_DIR / "SYMBOL" / f"{SYM_TP}.esym", SYM_TP, "TESTPOINT", ["TP"], [])
    make_footprint(OUT_DIR / "FOOTPRINT" / f"{FP_EDGE}.efoo", FP_EDGE, "CUSTOM_PCIE_X4_HOST_EDGE_DRAFT", "edge")
    make_footprint(OUT_DIR / "FOOTPRINT" / f"{FP_SLOT}.efoo", FP_SLOT, "CUSTOM_PCIE_X4_ENDPOINT_SLOT_DRAFT", "slot")
    make_footprint(OUT_DIR / "FOOTPRINT" / f"{FP_TP}.efoo", FP_TP, "TESTPOINT_SMD_1P6", "tp")

    devices = {
        DEV_P1: {
            "uuid": DEV_P1,
            "title": "CUSTOM_PCIE_X4_HOST_EDGE_DRAFT",
            "description": "P1 is the interposer card edge entering the RK host slot; power contacts intentionally NC.",
            "attributes": {"Symbol": SYM_PCIE, "Footprint": FP_EDGE, "Designator": "P1", "Name": "HOST PCIe x4 EDGE", "Manufacturer Part": "TBD CEM x4 edge geometry", "Supplier Part": "", "Datasheet": "", "DNI": "NO"},
            "source": "custom", "version": "20261001", "symbol_type": 2,
        },
        DEV_P2: {
            "uuid": DEV_P2,
            "title": "CUSTOM_PCIE_X4_ENDPOINT_SLOT_DRAFT",
            "description": "P2 is the receiving slot for the Pango 100Pro+ card; exact connector manufacturer/height TBD.",
            "attributes": {"Symbol": SYM_PCIE, "Footprint": FP_SLOT, "Designator": "P2", "Name": "PANGO PCIe x4 SLOT", "Manufacturer Part": "TBD CEM x4 card slot", "Supplier Part": "", "Datasheet": "", "DNI": "NO"},
            "source": "custom", "version": "20261001", "symbol_type": 2,
        },
        DEV_TP: {
            "uuid": DEV_TP,
            "title": "TESTPOINT_SMD_1P6",
            "description": "Test point used for pre-power continuity and REFCLK validation.",
            "attributes": {"Symbol": SYM_TP, "Footprint": FP_TP, "Designator": "TP?", "Name": "TESTPOINT", "Manufacturer Part": "TBD", "Supplier Part": "", "Datasheet": ""},
            "source": "custom", "version": "20261001", "symbol_type": 2,
        },
    }
    symbols = {
        SYM_PCIE: {"uuid": SYM_PCIE, "title": "PCIe_X4_CEM_INTERCONNECT", "display_title": "PCIe_X4_CEM_INTERCONNECT", "docType": 2, "type": 2, "source": "custom", "version": "20261001"},
        SYM_TP: {"uuid": SYM_TP, "title": "TESTPOINT", "display_title": "TESTPOINT", "docType": 2, "type": 2, "source": "custom", "version": "20261001"},
    }
    footprints = {
        FP_EDGE: {"uuid": FP_EDGE, "title": "CUSTOM_PCIE_X4_HOST_EDGE_DRAFT", "display_title": "CUSTOM_PCIE_X4_HOST_EDGE_DRAFT", "docType": 4, "type": 4, "description": "Host-side edge card contact pattern, 32 A + 32 B contacts; geometry needs final CEM/mechanical verification.", "source": "custom", "version": "20261001"},
        FP_SLOT: {"uuid": FP_SLOT, "title": "CUSTOM_PCIE_X4_ENDPOINT_SLOT_DRAFT", "display_title": "CUSTOM_PCIE_X4_ENDPOINT_SLOT_DRAFT", "docType": 4, "type": 4, "description": "Endpoint-side slot contact pattern, connector body/mechanical height TBD.", "source": "custom", "version": "20261001"},
        FP_TP: {"uuid": FP_TP, "title": "TESTPOINT_SMD_1P6", "display_title": "TESTPOINT_SMD_1P6", "docType": 4, "type": 4, "description": "SMD test pad.", "source": "custom", "version": "20261001"},
    }

    project = {
        "schematics": {SCH_UUID: {"name": "PCIe Interposer", "sheets": [{"uuid": sid, "id": no, "name": name, "display_title": name} for no, (name, sid) in SHEET_IDS.items()]}},
        "pcbs": {PCB_UUID: "PCIe Interposer Board"},
        "panels": {}, "symbols": symbols, "footprints": footprints, "devices": devices,
        "boards": {"PCIe Interposer Board": {"schematic": SCH_UUID, "pcb": PCB_UUID}},
        "config": {"title": "PCIe_INTERPOSER_OK3588C_PANGO100PRO_REV_A_DRAFT", "cbbProject": False, "defaultSheet": "", "editorVersion": "3.2.149.88089769"},
    }
    (OUT_DIR / "project.json").write_text(json.dumps(project, ensure_ascii=False, indent=2), encoding="utf-8")

    # Four documentation-first schematic pages.
    pages = {
        1: [
            "PCIe x4 被动中间件 / CEM 连接器页",
            "P1 HOST_EDGE：板边金手指，插入 OK3588-C / RK3568 主机 PCIe 槽",
            "P2 ENDPOINT_SLOT：接收盘古100Pro+标准 PCIe x4 金手指；连接器型号/合高待机械图闭环",
            "P1/P2 高速触点按同一 CEM 接触号一一对应；不在中间件上交换 TX/RX 方向",
            "PCIe 12V、3.3V、3.3Vaux 触点全部 NC_POWER_ISOLATED，不铺铜、不走线",
            "PRSNT/SMBus/JTAG 未最终接通，需按实际连接器和主机检测逻辑复核",
        ],
        2: [
            "PCIe x4 高速网络页",
            "Lane 0: B13/B14 PET0± ↔ A15/A16 PER0±（CEM contact identity preserved）",
            "Lane 1: B17/B18 PET1± ↔ A19/A20 PER1±",
            "Lane 2: B21/B22 PET2± ↔ A23/A24 PER2±",
            "Lane 3: B25/B26 PET3± ↔ A27/A28 PER3±",
            "REFCLK: A12 REFCLK+ ↔ A12；A13 REFCLK- ↔ A13；连续参考地",
            "目标规则：PCIe TX/RX 85Ω差分、REFCLK 100Ω差分；最终数值必须用嘉立创选定叠层计算",
        ],
        3: [
            "侧带信号与验证焊盘页",
            "A11 PERST#：主机端直通端点卡，默认连接",
            "B11 WAKE#：主机侧保留测试点；P2 侧默认开路/DNI，盘古例程未使用",
            "B12 CLKREQ#：主机侧测试点；盘古无 CLKREQ#，不连接至 P2",
            "REFCLK_VERIFY：验证盘古实际 100MHz 输入是否为 F11/E11；F13/E13 仍为资料冲突候选",
            "首次上电前：断电测量两端电源脚无互连、GND 连通、PERST/REFCLK 连续性正确",
        ],
        4: [
            "供电隔离与联调说明页",
            "两块开发板各自使用外部 12V 电源；中间件只提供高速信号、侧带和公共地参考",
            "禁止将 PCIe 12V/3.3V/3.3Vaux 通过中间件并联；禁止只靠主机槽电源带动盘古整板",
            "首联顺序：先给盘古板上电并加载 Endpoint bitstream，再给 RK 主机上电并枚举",
            "OK3588-C 目标：Gen2 x4；RK3568 兼容：仅使用 lane 0/1，预期 Gen2 x2",
            "本工程 REV_A_DRAFT 不可直接下单：连接器机械图、盘古 REFCLK 实测、PRSNT 方案和 JLC 叠层仍需闭环",
        ],
    }
    components1 = [
        ("p1", "PCIe_X4_CEM_INTERCONNECT.1", 420, 520, DEV_P1, SYM_PCIE, FP_EDGE, "P1", "HOST PCIe x4 EDGE", 0),
        ("p2", "PCIe_X4_CEM_INTERCONNECT.2", 980, 520, DEV_P2, SYM_PCIE, FP_SLOT, "P2", "PANGO PCIe x4 SLOT", 180),
    ]
    for no, (name, sid) in SHEET_IDS.items():
        comps = components1 if no == 1 else None
        write_lines(OUT_DIR / "SHEET" / SCH_UUID / f"{no}.esch", sheet_records(no, name, pages[no], comps))

    # PCB nets: contact identity is preserved across P1/P2; power/WAKE/CLKREQ remain isolated.
    nets = [
        "GND", "CEM_A11_PERST_N", "CEM_A12_REFCLK_P", "CEM_A13_REFCLK_N",
        "CEM_A15_PER0_P", "CEM_A16_PER0_N", "CEM_A19_PER1_P", "CEM_A20_PER1_N",
        "CEM_A23_PER2_P", "CEM_A24_PER2_N", "CEM_A27_PER3_P", "CEM_A28_PER3_N",
        "CEM_B13_PET0_P", "CEM_B14_PET0_N", "CEM_B17_PET1_P", "CEM_B18_PET1_N",
        "CEM_B21_PET2_P", "CEM_B22_PET2_N", "CEM_B25_PET3_P", "CEM_B26_PET3_N",
        "HOST_B11_WAKE_N", "HOST_B12_CLKREQ_N", "HOST_A1_PRSNT1_OPTION", "REFCLK_F11_E11_VERIFY",
    ]
    pcb = layer_records()
    pcb += [
        ["LAYER_PHYS", 1, "JLC outer copper 1oz", 1.378, 0, 0, 1],
        ["LAYER_PHYS", 15, "JLC inner GND plane", 0.598, 8.283, 0, 0],
        ["LAYER_PHYS", 16, "JLC inner route", 0.598, 8.283, 0, 0],
        ["LAYER_PHYS", 2, "JLC outer copper 1oz", 1.378, 0, 0, 1],
        ["ACTIVE_LAYER", 1],
        ["PREFERENCE", 0, 15, 0, 0.2, 0.3, 1, 1, "JLC_4L_1.6mm_DRAFT", 1, 0, 0, 1, "PENDING_STACKUP", 0, 3, "OPTIMIZA_OPEN", 2, "OPTIMIZA_STRONG", 1, 1],
        ["SILK_OPTS", 3, "#000000", "#ffffff"],
        ["SILK_OPTS", 4, "#000000", "#ffffff"],
    ]
    for n in nets:
        pcb.append(["NET", n, None, None, 1 if n != "GND" else 0, None, 0, None])
    # board outline and ground reference plane
    pcb += [
        ["POLY", "board_outline", 0, "", 11, 0.2, [0, 0, "L", 130, 0, "L", 130, 70, "L", 0, 70, 0, 0], 0],
        ["FILL", "gnd_plane", 0, "GND", 15, 0.2, 2, [[0.3, 0.3, "L", 129.7, 0.3, "L", 129.7, 69.7, "L", 0.3, 69.7, 0.3, 0.3]], 0],
    ]
    # Components.
    comps = [
        ("c_p1", 1, 0, 35, 0, "P1", FP_EDGE, DEV_P1),
        ("c_p2", 1, 112, 35, 180, "P2", FP_SLOT, DEV_P2),
    ]
    for cid, side, x, y, rot, ref, fp, dev in comps:
        pcb.append(["COMPONENT", cid, 0, side, x, y, rot, {"Unique ID": "gge_" + cid}, 0])
        pcb += [
            ["ATTR", cid + "_fp", 0, cid, 3, None, None, "Footprint", fp, 0, 0, "default", 45, 6, 0, 0, 3, 0, 0, 0, 0, False],
            ["ATTR", cid + "_ref", 0, cid, 3, x, y + 18, "Designator", ref, 0, 1, "default", 45, 6, 0, 0, 3, 0, 0, 0, 0, False],
            ["ATTR", cid + "_dev", 0, cid, 3, None, None, "Device", dev, 0, 0, "default", 45, 6, 0, 0, 3, 0, 0, 0, 0, False],
        ]
    # Test points around the center / right edge.
    tp_defs = [
        ("c_tp1", "TP1", 35, 61, "CEM_A12_REFCLK_P", "REFCLK_P"),
        ("c_tp2", "TP2", 41, 61, "CEM_A13_REFCLK_N", "REFCLK_N"),
        ("c_tp3", "TP3", 47, 61, "CEM_A11_PERST_N", "PERST_N"),
        ("c_tp4", "TP4", 53, 61, "GND", "GND"),
        ("c_tp5", "TP5", 59, 61, "HOST_B11_WAKE_N", "WAKE_DNI"),
        ("c_tp6", "TP6", 65, 61, "HOST_B12_CLKREQ_N", "CLKREQ_NC"),
        ("c_tp7", "TP7", 71, 61, "HOST_A1_PRSNT1_OPTION", "PRSNT_OPTION"),
    ]
    for cid, ref, x, y, net, label in tp_defs:
        pcb.append(["COMPONENT", cid, 0, 1, x, y, 0, {"Unique ID": "gge_" + cid}, 0])
        pcb += [
            ["ATTR", cid + "_fp", 0, cid, 3, None, None, "Footprint", FP_TP, 0, 0, "default", 45, 6, 0, 0, 3, 0, 0, 0, 0, False],
            ["ATTR", cid + "_ref", 0, cid, 3, x, y + 2.4, "Designator", ref, 0, 1, "default", 35, 6, 0, 0, 3, 0, 0, 0, 0, False],
            ["ATTR", cid + "_dev", 0, cid, 3, None, None, "Device", DEV_TP, 0, 0, "default", 45, 6, 0, 0, 3, 0, 0, 0, 0, False],
            ["PAD_NET", cid, "1", net, "pad_1", 0],
            ["STRING", cid + "_label", 0, 3, x, y - 2.4, label, "default", 25, 6, 0, 0, 3, 0, 0, 0, 0, 0],
        ]

    # Contact net assignment. P1/P2 power contacts are intentionally omitted.
    contact_net = {
        "A11": "CEM_A11_PERST_N", "A12": "CEM_A12_REFCLK_P", "A13": "CEM_A13_REFCLK_N",
        "A15": "CEM_A15_PER0_P", "A16": "CEM_A16_PER0_N", "A19": "CEM_A19_PER1_P", "A20": "CEM_A20_PER1_N",
        "A23": "CEM_A23_PER2_P", "A24": "CEM_A24_PER2_N", "A27": "CEM_A27_PER3_P", "A28": "CEM_A28_PER3_N",
        "B13": "CEM_B13_PET0_P", "B14": "CEM_B14_PET0_N", "B17": "CEM_B17_PET1_P", "B18": "CEM_B18_PET1_N",
        "B21": "CEM_B21_PET2_P", "B22": "CEM_B22_PET2_N", "B25": "CEM_B25_PET3_P", "B26": "CEM_B26_PET3_N",
        "A4": "GND", "A14": "GND", "A17": "GND", "A21": "GND", "A29": "GND", "A30": "GND", "A31": "GND", "A32": "GND",
        "B4": "GND", "B7": "GND", "B15": "GND", "B19": "GND", "B20": "GND", "B23": "GND", "B24": "GND", "B27": "GND", "B28": "GND", "B29": "GND", "B30": "GND", "B31": "GND", "B32": "GND",
        "A1": "HOST_A1_PRSNT1_OPTION", "B11": "HOST_B11_WAKE_N", "B12": "HOST_B12_CLKREQ_N",
    }
    # For the endpoint slot, WAKE/CLKREQ/PRSNT are deliberately left blank.
    for row in ["A", "B"]:
        for i in range(1, 33):
            contact = f"{row}{i}"
            net = contact_net.get(contact, "")
            for cid, prefix in [("c_p1", "P1"), ("c_p2", "P2")]:
                actual_net = net
                if cid == "c_p2" and contact in {"A1", "B11", "B12"}:
                    actual_net = ""
                pad_id = f"pad_{contact}"
                pcb.append(["PAD_NET", cid, contact, actual_net, pad_id, 0])

    # Top-layer initial routes for all connected high-speed nets and PERST/REFCLK.
    # P1 is at x=0, P2 is at x=112; footprints use aligned y coordinates.
    route_nets = [n for n in nets if n not in {"GND", "HOST_B11_WAKE_N", "HOST_B12_CLKREQ_N", "HOST_A1_PRSNT1_OPTION", "REFCLK_F11_E11_VERIFY"}]
    # contact rows in the same local coordinate system as footprints
    route_contacts = {
        "CEM_A11_PERST_N": "A11", "CEM_A12_REFCLK_P": "A12", "CEM_A13_REFCLK_N": "A13",
        "CEM_A15_PER0_P": "A15", "CEM_A16_PER0_N": "A16", "CEM_A19_PER1_P": "A19", "CEM_A20_PER1_N": "A20",
        "CEM_A23_PER2_P": "A23", "CEM_A24_PER2_N": "A24", "CEM_A27_PER3_P": "A27", "CEM_A28_PER3_N": "A28",
        "CEM_B13_PET0_P": "B13", "CEM_B14_PET0_N": "B14", "CEM_B17_PET1_P": "B17", "CEM_B18_PET1_N": "B18",
        "CEM_B21_PET2_P": "B21", "CEM_B22_PET2_N": "B22", "CEM_B25_PET3_P": "B25", "CEM_B26_PET3_N": "B26",
    }
    route_id = 1000
    for net in route_nets:
        contact = route_contacts.get(net)
        if not contact:
            continue
        idx = int(contact[1:])
        y = 35 + (idx - 16.5) * 0.8
        start_x = 3.6
        end_x = 112 + (0.8 if contact.startswith("A") else 3.4)
        width = 0.16 if ("PER" in net or "PET" in net) else 0.18
        pcb.append(["LINE", f"route_{route_id}", 0, net, 1, start_x, y, end_x, y, width, 0])
        route_id += 1
    # Ground vias / mounting holes.
    for i, (x, y) in enumerate([(8, 8), (122, 8), (8, 62), (122, 62)], start=1):
        pcb += [
            ["PAD", f"hole_{i}", 0, "", 12, "", x, y, 0, ["ROUND", 3.2, 3.2], ["ELLIPSE", 3.2, 3.2], [], 0, 0, 0, 0, 0, None, None, None, None, 0],
            ["STRING", f"hole_label_{i}", 0, 3, x, y + 3, "M3", "default", 20, 6, 0, 0, 3, 0, 0, 0, 0, 0],
        ]
    # Design notes / silk.
    pcb += [
        ["STRING", "title", 0, 3, 65, 5, "PCIe x4 INTERPOSER REV_A_DRAFT", "default", 60, 6, 0, 0, 3, 0, 0, 0, 0, 0],
        ["STRING", "host", 0, 3, 12, 67, "HOST EDGE / RK3588 x4", "default", 28, 6, 0, 0, 3, 0, 0, 0, 0, 0],
        ["STRING", "pango", 0, 3, 113, 67, "PANGO SLOT / GEN2 x4", "default", 28, 6, 0, 0, 3, 0, 0, 0, 0, 0],
        ["STRING", "iso", 0, 3, 65, 9, "12V / 3V3 / 3V3AUX ISOLATED", "default", 30, 6, 0, 0, 3, 0, 0, 0, 0, 0],
        ["STRING", "clk", 0, 3, 65, 13, "REFCLK F11/E11 VERIFY BEFORE POWER", "default", 27, 6, 0, 0, 3, 0, 0, 0, 0, 0],
        ["STRING", "sideband", 0, 3, 65, 17, "WAKE/CLKREQ DNI; PERST STRAIGHT-THRU", "default", 24, 6, 0, 0, 3, 0, 0, 0, 0, 0],
    ]
    write_lines(OUT_DIR / "PCB" / f"{PCB_UUID}.epcb", pcb)

    # Package epro.
    if OUT_EPRO.exists():
        OUT_EPRO.unlink()
    with zipfile.ZipFile(OUT_EPRO, "w", compression=zipfile.ZIP_DEFLATED) as z:
        for file in sorted(OUT_DIR.rglob("*")):
            if file.is_file():
                z.write(file, file.relative_to(OUT_DIR).as_posix())

    NOTES.write_text(
        """# PCIe_INTERPOSER_OK3588C_PANGO100PRO_REV_A_DRAFT\n\n"
        "这是嘉立创EDA专业版可打开的第一版工程草稿，不是可直接下单的最终PCB。\n\n"
        "## 已实现\n"
        "- P1：主机侧标准PCIe x4卡边触点草图；P2：盘古端PCIe x4插槽触点草图。\n"
        "- x4 lane 0~3、A12/A13 REFCLK、A11 PERST# 的接触号保持直通。\n"
        "- PCIe 12V、3.3V、3.3Vaux没有分配网络，也没有走线/铺铜。\n"
        "- WAKE#、CLKREQ#、PRSNT#为保守的可选/测试点方案；WAKE和CLKREQ默认不连到P2。\n"
        "- 4层PCB草图：L1走线、L2连续GND参考面、L3预留内层、L4返回/低速。\n"
        "- 板上丝印明确写出`REFCLK F11/E11 VERIFY BEFORE POWER`和电源隔离。\n\n"
        "## 未闭环，禁止直接制板\n"
        "1. 盘古底板PCIE_CLKP/N到底接FPGA F11/E11还是F13/E13，必须用底板网表或万用表闭环。\n"
        "2. P2必须替换为已核对的PCIe x4卡槽制造商型号、合高、引脚方向和推荐PCB封装。\n"
        "3. P1金手指需按嘉立创硬金/倒角/阻焊开窗工艺和实际CEM机械尺寸复核。\n"
        "4. PRSNT1#/PRSNT2#、WAKE#、CLKREQ#需要结合实际主机和卡槽电路决定。\n"
        "5. 嘉立创最终4层叠层和阻抗计算未写死；当前85Ω/100Ω只是目标，不是制造参数。\n\n"
        "## 首次联调前\n"
        "- 两板各自使用外部12V；中间件只共地并传高速/必要侧带。\n"
        "- 断电测量P1/P2所有电源触点之间无互连，GND触点连通。\n"
        "- 先给盘古Endpoint上电加载bitstream，再给RK主机上电。\n"
        "- OK3588-C预期Gen2 x4；RK3568兼容场景只使用lane0/1，预期Gen2 x2。\n""",
        encoding="utf-8",
    )
    print(f"created {OUT_EPRO}")
    print(f"created {NOTES}")
    print(f"unpacked {OUT_DIR}")


if __name__ == "__main__":
    make_project()
