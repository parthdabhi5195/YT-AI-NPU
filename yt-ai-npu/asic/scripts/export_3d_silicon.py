#!/usr/bin/env python3
"""
YT-AI Custom NPU Physical Silicon Floorplan, Binary GDSII Stream, Annotated SVG,
and Watertight 3D-Printable Silicon Die STL Generator (`export_3d_silicon.py`).

Generates three physical chip models directly from the YT-AI NPU architecture
(`3.20 mm x 3.20 mm = 10.24 mm^2` SkyWater SKY130 130nm MPW Die):
  1. `asic/output/yt_ai_npu_floorplan.gds` : Valid IEEE/Calma Binary GDSII layout
     (open in KLayout / Magic VLSI / Blender gds3xtrude)
  2. `asic/output/yt_ai_npu_die.svg`       : High-res annotated silicon die layout diagram
  3. `asic/output/yt_ai_npu_die_3d.stl`    : Watertight binary 3D STL model for 3D printing
     or 3D rendering your custom YT-AI NPU chip!
"""

from __future__ import annotations
import math
import os
import struct
from dataclasses import dataclass
from pathlib import Path

OUT_DIR = Path(__file__).resolve().parent.parent / "output"

# Die dimensions in microns (3,200 um x 3,200 um = 3.20 mm x 3.20 mm = 10.24 mm^2)
DIE_W_UM = 3200
DIE_H_UM = 3200


@dataclass(frozen=True)
class SiliconBlock:
    name: str
    subtitle: str
    x_um: int
    y_um: int
    w_um: int
    h_um: int
    gds_layer: int
    gds_dtype: int
    color_hex: str
    stroke_hex: str
    z_height_mm: float  # Relief height on 100mm x 100mm 3D-printable die plaque


# Exact physical macro floorplan of `yt_npu_top` on a 3200 x 3200 um SKY130 MPW die
FLOORPLAN_BLOCKS: list[SiliconBlock] = [
    # Left Column: Dual-Bank 32 KB Ping-Pong Weight & KV-Cache OpenRAM Macros (16 x 2KB)
    SiliconBlock("WGT_SRAM_BANK0", "16 KB OpenRAM (8x2KB)", 160, 1920, 760, 980, 69, 20, "#1d4ed8", "#60a5fa", 4.2),
    SiliconBlock("WGT_SRAM_BANK1", "16 KB OpenRAM (8x2KB)", 160,  860, 760, 980, 69, 20, "#1e40af", "#60a5fa", 4.2),
    SiliconBlock("AXI4_DMA_RDWR",  "128b Burst DMA + KV Pack", 160, 260, 760, 520, 70, 20, "#0f766e", "#2dd4bf", 3.2),

    # Center Arena: 16x16 W8A16 Systolic Array (256 PEs) + GEMM Tile Controller
    SiliconBlock("SYSTOLIC_16x16", "256 W8A16 MACs (51.2 GOPS)", 980, 1340, 1240, 1240, 71, 20, "#b45309", "#fbbf24", 5.5),
    SiliconBlock("GEMM_TILE_CTRL", "128b Loader + ACC_SRAM (1KB)", 980, 2620, 1240, 280, 70, 20, "#92400e", "#fcd34d", 3.6),

    # Center-Bottom: 100% LUT-Free Algebraic SFU & Autonomous Sampling Engines
    SiliconBlock("LAYERNORM_SFU",  "Divider-Free LN + NR RSQRT",  980, 780, 600, 480, 70, 20, "#6d28d9", "#c084fc", 3.5),
    SiliconBlock("SOFTMAX_SFU",    "512-Ctx Horner EXP + NR RCP",1620, 780, 600, 480, 70, 20, "#7e22ce", "#d8b4fe", 3.5),
    SiliconBlock("GELU_SFU_VEC",   "Analytic GELU + Vec + Embed", 980, 260, 600, 460, 70, 20, "#4338ca", "#818cf8", 3.3),
    SiliconBlock("TOPK_SAMPLER",   "50,257-Vocab Top-200 + PRNG", 1620, 260, 600, 460, 70, 20, "#be123c", "#fb7185", 4.0),

    # Right Column: 32 KB ACT_SRAM + 8 KB PARAM_SRAM + 16 KB UCODE_SRAM + Sequencer
    SiliconBlock("ACT_SRAM_32KB",  "16,384x16b Q7.8 OpenRAM",    2280, 1660, 760, 1240, 69, 20, "#0369a1", "#38bdf8", 4.2),
    SiliconBlock("PARAM_SRAM_8KB", "LN Gamma/Beta + INT32 Bias", 2280, 1220, 760,  380, 69, 20, "#075985", "#7dd3fc", 4.0),
    SiliconBlock("UCODE_SRAM_16K", "1024x128b Microcode SRAM",   2280,  680, 760,  480, 69, 20, "#1e3a8a", "#93c5fd", 4.0),
    SiliconBlock("CTRL_AUTOGEN",   "Token Seq + Loop + AXI-Lite",2280,  260, 760,  360, 70, 20, "#065f46", "#34d399", 3.4),
]


# =============================================================================
# 1. Binary GDSII Stream Writer (IEEE / Calma GDSII Format)
# =============================================================================
def _gds_rec(rec_type: int, data_type: int, payload: bytes = b"") -> bytes:
    if len(payload) % 2 == 1:
        payload += b"\x00"
    length = 4 + len(payload)
    return struct.pack(">HBB", length, rec_type, data_type) + payload


def _gds_str(rec_type: int, s: str) -> bytes:
    return _gds_rec(rec_type, 0x06, s.encode("ascii"))


def _gds_real8(val: float) -> bytes:
    """Convert Python float to IBM System/370 base-16 64-bit excess-64 float for GDSII."""
    if val == 0.0:
        return b"\x00" * 8
    sign = 0x80 if val < 0 else 0x00
    v = abs(val)
    exp16 = 64
    while v >= 1.0:
        v /= 16.0
        exp16 += 1
    while v < 1.0 / 16.0:
        v *= 16.0
        exp16 -= 1
    mant = int(round(v * (1 << 56)))
    if mant >= (1 << 56):
        mant >>= 4
        exp16 += 1
    first_byte = sign | (exp16 & 0x7F)
    return struct.pack(">B", first_byte) + mant.to_bytes(7, "big")


def _gds_box(x_nm: int, y_nm: int, w_nm: int, h_nm: int, layer: int, dtype: int) -> bytes:
    pts = [
        (x_nm, y_nm),
        (x_nm + w_nm, y_nm),
        (x_nm + w_nm, y_nm + h_nm),
        (x_nm, y_nm + h_nm),
        (x_nm, y_nm),
    ]
    xy = b"".join(struct.pack(">ii", px, py) for px, py in pts)
    return (
        _gds_rec(0x08, 0x00)  # BOUNDARY
        + _gds_rec(0x0D, 0x02, struct.pack(">h", layer))
        + _gds_rec(0x0E, 0x02, struct.pack(">h", dtype))
        + _gds_rec(0x10, 0x03, xy)
        + _gds_rec(0x11, 0x00)  # ENDEL
    )


def write_gdsii_floorplan(gds_path: Path) -> None:
    timestamps = struct.pack(">12h", 2026, 11, 14, 22, 0, 0, 2026, 11, 14, 22, 0, 0)
    buf = bytearray()
    buf += _gds_rec(0x00, 0x02, struct.pack(">h", 600))  # HEADER v6.0
    buf += _gds_rec(0x01, 0x02, timestamps)              # BGNLIB
    buf += _gds_str(0x02, "YT_AI_NPU_SKY130")            # LIBNAME
    buf += _gds_rec(0x03, 0x05, _gds_real8(1e-3) + _gds_real8(1e-9))  # 1 DB unit = 1 nm

    # Top cell `yt_npu_top`
    buf += _gds_rec(0x05, 0x02, timestamps)              # BGNSTR
    buf += _gds_str(0x06, "yt_npu_top")                  # STRNAME

    # SKY130 prBoundary (235/4)
    buf += _gds_box(0, 0, DIE_W_UM * 1000, DIE_H_UM * 1000, 235, 4)

    # Perimeter I/O Bond Pads (30 per side = 120 pads on met5 72/20)
    for side in range(4):
        for i in range(30):
            pos = (160 + i * 98) * 1000
            if side == 0:   # South
                buf += _gds_box(pos, 30_000, 64_000, 80_000, 72, 20)
            elif side == 1: # North
                buf += _gds_box(pos, (DIE_H_UM - 110) * 1000, 64_000, 80_000, 72, 20)
            elif side == 2: # West
                buf += _gds_box(30_000, pos, 80_000, 64_000, 72, 20)
            else:           # East
                buf += _gds_box((DIE_W_UM - 110) * 1000, pos, 80_000, 64_000, 72, 20)

    # Major functional blocks
    for blk in FLOORPLAN_BLOCKS:
        buf += _gds_box(
            blk.x_um * 1000, blk.y_um * 1000,
            blk.w_um * 1000, blk.h_um * 1000,
            blk.gds_layer, blk.gds_dtype,
        )

    # 16 x 16 = 256 Individual Processing Elements inside SYSTOLIC_16x16 (met2 69/20)
    pe_pitch = 74_000
    pe_size  = 60_000
    base_x   = 1_010_000
    base_y   = 1_370_000
    for r in range(16):
        for c in range(16):
            buf += _gds_box(base_x + c * pe_pitch, base_y + r * pe_pitch, pe_size, pe_size, 68, 20)

    # Metal-4/5 Power Distribution Network (PDN) Straps
    for s in range(18):
        coord = (180 + s * 165) * 1000
        buf += _gds_box(coord, 140_000, 4_000, (DIE_H_UM - 280) * 1000, 71, 20)
        buf += _gds_box(140_000, coord, (DIE_W_UM - 280) * 1000, 4_000, 72, 20)

    buf += _gds_rec(0x07, 0x00)  # ENDSTR
    buf += _gds_rec(0x04, 0x00)  # ENDLIB
    gds_path.write_bytes(bytes(buf))


# =============================================================================
# 2. High-Resolution Annotated Die Layout SVG Writer
# =============================================================================
def write_die_svg(svg_path: Path) -> None:
    scale = 0.28  # 3200 um -> 896 px + header/margins
    pad_top = 86
    pad_side = 32
    w_px = int(DIE_W_UM * scale) + 2 * pad_side
    h_px = int(DIE_H_UM * scale) + pad_top + pad_side

    def sy(y_um: float, h_um: float = 0.0) -> float:
        return pad_top + (DIE_H_UM - y_um - h_um) * scale

    def sx(x_um: float) -> float:
        return pad_side + x_um * scale

    lines = [
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{w_px}" height="{h_px}" viewBox="0 0 {w_px} {h_px}">',
        '<rect width="100%" height="100%" fill="#090d16"/>',
        f'<text x="{w_px/2:.1f}" y="34" text-anchor="middle" fill="#f8fafc" font-family="monospace" font-size="20" font-weight="bold">YT-AI CUSTOM NPU DIE FLOORPLAN — SKYWATER SKY130 (3.20 mm x 3.20 mm = 10.24 mm²)</text>',
        f'<text x="{w_px/2:.1f}" y="58" text-anchor="middle" fill="#94a3b8" font-family="monospace" font-size="12">51.2M-Param Autonomous SLM Engine | 16x16 W8A16 Systolic Array (256 MACs) | 91 KB On-Chip OpenRAM | 128b AXI4</text>',
        # Silicon Substrate & Core Ring
        f'<rect x="{sx(0):.1f}" y="{sy(0, DIE_H_UM):.1f}" width="{DIE_W_UM*scale:.1f}" height="{DIE_H_UM*scale:.1f}" fill="#111827" stroke="#475569" stroke-width="2.5"/>',
        f'<rect x="{sx(130):.1f}" y="{sy(130, DIE_H_UM-260):.1f}" width="{(DIE_W_UM-260)*scale:.1f}" height="{(DIE_H_UM-260)*scale:.1f}" fill="#0b1120" stroke="#334155" stroke-dasharray="5,4"/>',
    ]

    # Bond pads
    for i in range(30):
        pos = 160 + i * 98
        lines.append(f'<rect x="{sx(pos):.1f}" y="{sy(30, 80):.1f}" width="{64*scale:.1f}" height="{80*scale:.1f}" fill="#eab308" opacity="0.85"/>')
        lines.append(f'<rect x="{sx(pos):.1f}" y="{sy(DIE_H_UM-110, 80):.1f}" width="{64*scale:.1f}" height="{80*scale:.1f}" fill="#eab308" opacity="0.85"/>')
        lines.append(f'<rect x="{sx(30):.1f}" y="{sy(pos, 64):.1f}" width="{80*scale:.1f}" height="{64*scale:.1f}" fill="#eab308" opacity="0.85"/>')
        lines.append(f'<rect x="{sx(DIE_W_UM-110):.1f}" y="{sy(pos, 64):.1f}" width="{80*scale:.1f}" height="{64*scale:.1f}" fill="#eab308" opacity="0.85"/>')

    # Blocks
    for blk in FLOORPLAN_BLOCKS:
        bx, by = sx(blk.x_um), sy(blk.y_um, blk.h_um)
        bw, bh = blk.w_um * scale, blk.h_um * scale
        lines.append(
            f'<rect x="{bx:.1f}" y="{by:.1f}" width="{bw:.1f}" height="{bh:.1f}" rx="4" '
            f'fill="{blk.color_hex}" fill-opacity="0.72" stroke="{blk.stroke_hex}" stroke-width="1.8"/>'
        )

        # Draw 16x16 PE grid inside Systolic Array
        if blk.name == "SYSTOLIC_16x16":
            for r in range(16):
                for c in range(16):
                    px = sx(1010 + c * 74)
                    py = sy(1370 + r * 74, 56)
                    lines.append(
                        f'<rect x="{px:.1f}" y="{py:.1f}" width="{56*scale:.1f}" height="{56*scale:.1f}" '
                        f'fill="#fef3c7" fill-opacity="0.18" stroke="#f59e0b" stroke-width="0.6"/>'
                    )

        cx, cy = bx + bw / 2.0, by + bh / 2.0
        lines.append(
            f'<text x="{cx:.1f}" y="{cy - 5:.1f}" text-anchor="middle" fill="#ffffff" '
            f'font-family="monospace" font-size="11.5" font-weight="bold">{blk.name}</text>'
        )
        lines.append(
            f'<text x="{cx:.1f}" y="{cy + 12:.1f}" text-anchor="middle" fill="#e2e8f0" '
            f'font-family="monospace" font-size="9.5">{blk.subtitle}</text>'
        )

    # Edge bus labels
    lines.append(f'<text x="{w_px/2:.1f}" y="{sy(DIE_H_UM-24):.1f}" text-anchor="middle" fill="#fde047" font-family="monospace" font-size="10">NORTH: CLK / RST_N / IRQ + 32b AXI4-LITE HOST CONTROL</text>')
    lines.append(f'<text x="{w_px/2:.1f}" y="{sy(8):.1f}" text-anchor="middle" fill="#fde047" font-family="monospace" font-size="10">SOUTH: 128-BIT AXI4 EXTERNAL DDR4/LPDDR4 READ CHANNEL (1.6 GB/s)</text>')
    lines.append("</svg>")
    svg_path.write_text("\n".join(lines), encoding="utf-8")


# =============================================================================
# 3. Binary 3D-Printable STL Relief Model Writer (`100 mm x 100 mm` Desk Plaque!)
# =============================================================================
def _box_triangles(
    x0: float, y0: float, z0: float,
    x1: float, y1: float, z1: float,
) -> list[tuple[tuple[float, float, float], tuple[float, float, float], tuple[float, float, float], tuple[float, float, float]]]:
    """Returns 12 outward-oriented (normal, v1, v2, v3) triangles for a closed 3D box."""
    p000, p100, p110, p010 = (x0, y0, z0), (x1, y0, z0), (x1, y1, z0), (x0, y1, z0)
    p001, p101, p111, p011 = (x0, y0, z1), (x1, y0, z1), (x1, y1, z1), (x0, y1, z1)
    return [
        # Bottom (-Z)
        ((0, 0, -1), p000, p110, p100), ((0, 0, -1), p000, p010, p110),
        # Top (+Z)
        ((0, 0,  1), p001, p101, p111), ((0, 0,  1), p001, p111, p011),
        # South (-Y)
        ((0, -1, 0), p000, p100, p101), ((0, -1, 0), p000, p101, p001),
        # North (+Y)
        ((0,  1, 0), p010, p111, p110), ((0,  1, 0), p010, p011, p111),
        # West (-X)
        ((-1, 0, 0), p000, p001, p011), ((-1, 0, 0), p000, p011, p010),
        # East (+X)
        (( 1, 0, 0), p100, p110, p111), (( 1, 0, 0), p100, p111, p101),
    ]


def write_3d_silicon_stl(stl_path: Path) -> None:
    """Writes a 100 mm x 100 mm physical 3D relief model of `yt_npu_top` in binary STL."""
    mm_per_um = 100.0 / float(DIE_W_UM)  # 3200 um -> 100.0 mm physical model!
    base_z = 2.0  # 2.0 mm solid silicon wafer base
    tris = []

    # 1. Silicon wafer substrate base (100 x 100 x 2.0 mm)
    tris.extend(_box_triangles(0.0, 0.0, 0.0, 100.0, 100.0, base_z))

    # 2. Perimeter seal ring & 120 I/O bond pads
    for i in range(30):
        p = (160 + i * 98) * mm_per_um
        w64, w80 = 64 * mm_per_um, 80 * mm_per_um
        d30, d110 = 30 * mm_per_um, (DIE_H_UM - 110) * mm_per_um
        tris.extend(_box_triangles(p, d30, base_z, p + w64, d30 + w80, base_z + 1.2))
        tris.extend(_box_triangles(p, d110, base_z, p + w64, d110 + w80, base_z + 1.2))
        tris.extend(_box_triangles(d30, p, base_z, d30 + w80, p + w64, base_z + 1.2))
        tris.extend(_box_triangles(d110, p, base_z, d110 + w80, p + w64, base_z + 1.2))

    # 3. Functional silicon macro blocks
    for blk in FLOORPLAN_BLOCKS:
        x0 = blk.x_um * mm_per_um
        y0 = blk.y_um * mm_per_um
        x1 = (blk.x_um + blk.w_um) * mm_per_um
        y1 = (blk.y_um + blk.h_um) * mm_per_um
        if blk.name == "SYSTOLIC_16x16":
            # Systolic pedestal + 256 individual sculpted PE towers!
            tris.extend(_box_triangles(x0, y0, base_z, x1, y1, base_z + 1.6))
            for r in range(16):
                for c in range(16):
                    px0 = (1010 + c * 74) * mm_per_um
                    py0 = (1370 + r * 74) * mm_per_um
                    px1 = px0 + 54 * mm_per_um
                    py1 = py0 + 54 * mm_per_um
                    tris.extend(_box_triangles(px0, py0, base_z + 1.6, px1, py1, base_z + 3.8))
        elif "SRAM" in blk.name:
            # Sub-bank ridges showing individual OpenRAM 2KB macros
            tris.extend(_box_triangles(x0, y0, base_z, x1, y1, base_z + 1.8))
            n_sub = 4
            sub_h = (y1 - y0 - 1.0) / n_sub
            for s in range(n_sub):
                sy0 = y0 + 0.5 + s * sub_h
                sy1 = sy0 + sub_h * 0.82
                tris.extend(_box_triangles(x0 + 0.6, sy0, base_z + 1.8, x1 - 0.6, sy1, base_z + blk.z_height_mm - 1.0))
        else:
            tris.extend(_box_triangles(x0, y0, base_z, x1, y1, base_z + blk.z_height_mm - 1.0))

    header = b"YT-AI 51.2M Custom Silicon NPU (SkyWater SKY130 3.2x3.2mm Die)".ljust(80, b" ")
    with open(stl_path, "wb") as f:
        f.write(header)
        f.write(struct.pack("<I", len(tris)))
        for nrm, v1, v2, v3 in tris:
            f.write(struct.pack("<12fH", *nrm, *v1, *v2, *v3, 0))


def main() -> None:
    os.makedirs(OUT_DIR, exist_ok=True)
    gds_path = OUT_DIR / "yt_ai_npu_floorplan.gds"
    svg_path = OUT_DIR / "yt_ai_npu_die.svg"
    stl_path = OUT_DIR / "yt_ai_npu_die_3d.stl"

    write_gdsii_floorplan(gds_path)
    write_die_svg(svg_path)
    write_3d_silicon_stl(stl_path)

    print(f"[Silicon Export] Binary GDSII Stream : {gds_path} ({gds_path.stat().st_size:,} bytes)")
    print(f"[Silicon Export] Annotated Die SVG   : {svg_path} ({svg_path.stat().st_size:,} bytes)")
    print(f"[Silicon Export] 3D Printable STL    : {stl_path} ({stl_path.stat().st_size:,} bytes)")


if __name__ == "__main__":
    main()
