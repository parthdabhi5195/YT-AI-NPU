#!/usr/bin/env python3
"""
Comprehensive Structural, Syntax & Port-Consistency Linter for YT-AI NPU RTL (`lint_rtl.py`).
Verifies across all SystemVerilog files in `rtl/`:
  1. Balanced `module/endmodule`, `package/endpackage`, `begin/end`, `case/endcase`, parens/braces
  2. `default_nettype none` / `default_nettype wire` discipline on every hardware module
  3. 100% submodule existence & exact `.port_name(...)` matching across the entire RTL hierarchy
  4. 100% bit-exact entry-by-entry match between all 4 hardware ROM LUTs (`yt_*_lut.sv`) and `fixed_ops.py`!
"""

from __future__ import annotations
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent.parent
RTL_DIR = ROOT / "rtl"
sys.path.insert(0, str(ROOT / "python"))

from golden.fixed_ops import EXP_LUT, GELU_LUT, RECIP_LUT, RSQRT_LUT  # noqa: E402


def strip_comments(sv_text: str) -> str:
    text = re.sub(r"//.*", "", sv_text)
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.DOTALL)
    return text


def parse_module_ports(clean_text: str) -> dict[str, set[str]]:
    modules: dict[str, set[str]] = {}
    # Match module header up to `);`
    pattern = re.compile(
        r"\bmodule\s+(\w+)\b(.*?)\)\s*;",
        flags=re.DOTALL,
    )
    for m in pattern.finditer(clean_text):
        mod_name = m.group(1)
        header = m.group(2)
        # If `#(...)` parameter list exists, take the last `(...)` port block
        # Walk parentheses to isolate the port list
        depth = 0
        last_open = -1
        for idx, ch in enumerate(header):
            if ch == "(":
                if depth == 0:
                    last_open = idx
                depth += 1
            elif ch == ")":
                depth -= 1
        port_block = header[last_open + 1 :] if last_open >= 0 else header
        ports: set[str] = set()
        for decl in port_block.split(","):
            decl = decl.strip()
            if not decl:
                continue
            # Strip trailing unpacked array dims if any, e.g. `acc_out [16][16]`
            decl_no_arr = re.sub(r"(\s*\[[^\]]+\])+\s*$", "", decl).strip()
            toks = re.findall(r"\b[A-Za-z_]\w*\b", decl_no_arr)
            if toks:
                ports.add(toks[-1])
        modules[mod_name] = ports
    return modules


def check_rom_luts() -> None:
    expected = {
        "yt_rsqrt_lut.sv": [int(x) & 0xFFFF for x in RSQRT_LUT],
        "yt_exp_lut.sv":   [int(x) & 0xFFFF for x in EXP_LUT],
        "yt_recip_lut.sv": [int(x) & 0xFFFF for x in RECIP_LUT],
        "yt_gelu_lut.sv":  [int(x) & 0xFFFF for x in GELU_LUT],
    }
    for fname, gold_vals in expected.items():
        fpath = RTL_DIR / "ops" / fname
        txt = fpath.read_text(encoding="utf-8")
        entries = re.findall(r"8'd\s*(\d+)\s*:\s*data_out\s*<=\s*16'h([0-9A-Fa-f]{4})", txt)
        assert len(entries) == 256, f"{fname}: expected 256 ROM entries, found {len(entries)}"
        for idx_s, hex_s in entries:
            idx = int(idx_s)
            val = int(hex_s, 16)
            assert val == gold_vals[idx], (
                f"{fname}[{idx}] mismatch: RTL=0x{val:04X} vs Python=0x{gold_vals[idx]:04X}"
            )
    print("[RTL Linter] PASS: All 4 x 256 ROM LUTs (1,024 entries) match Python golden bit-for-bit.")


def main() -> None:
    sv_files = sorted(RTL_DIR.rglob("*.sv"))
    assert len(sv_files) >= 25, f"Expected >=25 SV files, found {len(sv_files)}"

    all_modules: dict[str, set[str]] = {}
    cleaned_by_file: dict[Path, str] = {}

    for f in sv_files:
        raw = f.read_text(encoding="utf-8")
        clean = strip_comments(raw)
        cleaned_by_file[f] = clean

        # Balance checks
        for o_ch, c_ch in [("(", ")"), ("[", "]"), ("{", "}")]:
            assert clean.count(o_ch) == clean.count(c_ch), (
                f"{f.name}: unbalanced {o_ch}{c_ch} ({clean.count(o_ch)} vs {clean.count(c_ch)})"
            )

        for kw_open, kw_close in [
            ("module", "endmodule"),
            ("package", "endpackage"),
            ("function", "endfunction"),
            ("begin", "end"),
            ("case", "endcase"),
        ]:
            n_open = len(re.findall(rf"\b{kw_open}\b", clean))
            n_close = len(re.findall(rf"\b{kw_close}\b", clean))
            assert n_open == n_close, (
                f"{f.name}: unbalanced {kw_open}/{kw_close} ({n_open} vs {n_close})"
            )

        if "pkg" not in f.parts:
            assert "`default_nettype none" in raw, f"{f.name}: missing `default_nettype none"
            assert "`default_nettype wire" in raw, f"{f.name}: missing `default_nettype wire"

        all_modules.update(parse_module_ports(clean))

    print(f"[RTL Linter] Parsed {len(sv_files)} SystemVerilog files ({len(all_modules)} hardware modules).")

    # Verify all submodule instantiations & named port maps
    inst_re = re.compile(
        r"(?<!module\s)\b(yt_\w+)\s+(?:#\s*\([^;]*?\)\s*)?(u_\w+)\s*\(([^;]*?)\)\s*;",
        flags=re.DOTALL,
    )
    total_insts = 0
    for f, clean in cleaned_by_file.items():
        for m in inst_re.finditer(clean):
            sub_mod, inst_name, body = m.group(1), m.group(2), m.group(3)
            assert sub_mod in all_modules, f"{f.name}: instantiates unknown module `{sub_mod}`"
            conn_ports = set(re.findall(r"\.\s*([A-Za-z_]\w*)\s*\(", body))
            expected_ports = all_modules[sub_mod]
            missing = expected_ports - conn_ports
            extra = conn_ports - expected_ports
            assert not missing and not extra, (
                f"{f.name} ({inst_name} : {sub_mod}) port mismatch! "
                f"missing={missing}, extra={extra}"
            )
            total_insts += 1

    print(f"[RTL Linter] PASS: Verified {total_insts} module instantiations with 100% port match.")
    check_rom_luts()
    print("[RTL Linter] ALL CHECKS PASSED SUCCESSFULLY!")


if __name__ == "__main__":
    main()
