"""원본 처방전 사진 위에 OCR 인식 글자(대략 위치)를 그려 저장한다.

사용:
  python tools/make_ocr_overlay.py 20260825_164345.jpg
  python tools/make_ocr_overlay.py 20260620_165936.jpg --out ocr_overlay.png
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from app.core.config import GEMINI_API_KEY, GEMINI_MODEL
from app.services.matching.name_matcher import line_matches_drug_name
from app.services.ocr.engine import _prepare_image
from app.services.ocr.pipeline import run_ocr_pipeline
from app.services.pharmacist.retrieve import retrieve_official
from app.services.prescription_service import _user_readiness


BOX_SCHEMA = {
    "type": "object",
    "properties": {
        "lines": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {
                    "text": {"type": "string"},
                    "ymin": {"type": "integer"},
                    "xmin": {"type": "integer"},
                    "ymax": {"type": "integer"},
                    "xmax": {"type": "integer"},
                },
                "required": ["text", "ymin", "xmin", "ymax", "xmax"],
                "additionalProperties": False,
            },
        }
    },
    "required": ["lines"],
    "additionalProperties": False,
}


def detect_text_boxes(image_bytes: bytes) -> list[dict]:
    if not GEMINI_API_KEY:
        raise RuntimeError("GEMINI_API_KEY가 없습니다.")

    from google import genai
    from google.genai import types

    prepared, mime = _prepare_image(image_bytes)
    part = types.Part.from_bytes(data=prepared, mime_type=mime)
    prompt = (
        "이 사진은 한국 처방전/복약안내문입니다. "
        "보이는 글자 줄마다 텍스트와 위치 박스를 JSON으로 반환하세요. "
        "좌표는 이미지 기준 0~1000 정규화 정수 "
        "(ymin, xmin, ymax, xmax) 입니다. "
        "약품명·용량·횟수·일수·병원·날짜 줄을 우선하세요. "
        "추측하지 말고 보이는 글자만 넣으세요."
    )
    with genai.Client(api_key=GEMINI_API_KEY) as client:
        response = client.models.generate_content(
            model=GEMINI_MODEL,
            contents=[part, prompt],
            config={
                "temperature": 0.0,
                "response_mime_type": "application/json",
                "response_json_schema": BOX_SCHEMA,
            },
        )
    parsed = getattr(response, "parsed", None)
    if parsed is None:
        text = str(getattr(response, "text", None) or "")
        parsed = json.loads(text) if text else {}
    lines = parsed.get("lines") if isinstance(parsed, dict) else None
    if not isinstance(lines, list):
        return []
    return [line for line in lines if isinstance(line, dict) and line.get("text")]


def _pct_for_line(text: str, drugs: list[dict]) -> int | None:
    needle = str(text or "").strip()
    if len(needle) < 2:
        return None
    best: tuple[int, int] | None = None
    for drug in drugs:
        names = [drug.get("ocr_name"), drug.get("drug_name")]
        for name in names:
            label = str(name or "").strip()
            if not label or not line_matches_drug_name(needle, label):
                continue
            overlap = min(len(needle), len(label))
            if best is None or overlap > best[0]:
                best = (overlap, int(drug["pct"]))
    return best[1] if best else None


def score_ocr_image(image_bytes: bytes) -> dict:
    """파이프라인으로 약 이름·성분 인식률을 계산한다."""
    result = run_ocr_pipeline(image_bytes)
    seed: list[dict] = []
    drugs: list[dict] = []
    if result.ok and isinstance(result.structured, dict):
        for raw in result.structured.get("items") or []:
            if not isinstance(raw, dict):
                continue
            ocr_name = str(raw.get("drug_name") or "").strip()
            if not ocr_name:
                continue
            official = retrieve_official(ocr_name)
            med = (official or {}).get("medicine") or {}
            official_name = str(med.get("product_name") or med.get("medicine_name") or "").strip()
            matched = bool(official_name)
            item = {
                "drug_name": official_name or ocr_name,
                "product_name": official_name or ocr_name,
                "ocr_name": ocr_name,
                "ingredient": med.get("ingredient") or "",
                "uncertain": not matched,
                "match_status": "MATCHED" if matched else "UNMATCHED",
            }
            seed.append(item)
            drugs.append({**item, "pct": _user_readiness([item])["pct"]})
    readiness = _user_readiness(seed)
    return {
        "ok": result.ok,
        "error": result.error,
        "trace": result.trace,
        "structured": result.structured,
        "readiness": readiness,
        "drugs": drugs,
        "raw_text": result.raw_text,
    }


def _pct_for_line(text: str, drugs: list[dict]) -> int | None:
    needle = _norm(text)
    if len(needle) < 2:
        return None
    best: tuple[int, int] | None = None
    for drug in drugs:
        names = [drug.get("ocr_name"), drug.get("drug_name")]
        for name in names:
            key = _norm(name or "")
            if len(key) < 2:
                continue
            if key in needle or needle in key:
                overlap = min(len(key), len(needle))
                if best is None or overlap > best[0]:
                    best = (overlap, int(drug["pct"]))
    return best[1] if best else None


def _font(size: int) -> ImageFont.ImageFont:
    for path in (
        r"C:\Windows\Fonts\malgun.ttf",
        r"C:\Windows\Fonts\malgunbd.ttf",
        r"C:\Windows\Fonts\NanumGothic.ttf",
    ):
        if Path(path).exists():
            return ImageFont.truetype(path, size=size)
    return ImageFont.load_default()


def draw_overlay(
    image_path: Path,
    lines: list[dict],
    out_path: Path,
    *,
    overall_pct: int | None = None,
    drugs: list[dict] | None = None,
) -> Path:
    image = Image.open(image_path).convert("RGB")
    try:
        from PIL import ImageOps

        image = ImageOps.exif_transpose(image)
    except Exception:
        pass
    width, height = image.size
    draw = ImageDraw.Draw(image)
    font = _font(max(13, width // 70))
    banner_font = _font(max(22, width // 28))
    drugs = drugs or []

    if overall_pct is not None:
        banner = f"공식 약 확인 {overall_pct}%"
        pad = max(8, width // 80)
        tb = draw.textbbox((pad, pad), banner, font=banner_font)
        draw.rectangle(
            [tb[0] - 8, tb[1] - 6, tb[2] + 8, tb[3] + 6],
            fill=(220, 38, 38),
        )
        draw.text((pad, pad), banner, fill=(255, 255, 255), font=banner_font)

    for line in lines:
        text = str(line.get("text") or "").strip()
        if not text:
            continue
        try:
            ymin = int(line["ymin"])
            xmin = int(line["xmin"])
            ymax = int(line["ymax"])
            xmax = int(line["xmax"])
        except (KeyError, TypeError, ValueError):
            continue
        left = max(0, int(xmin / 1000 * width))
        top = max(0, int(ymin / 1000 * height))
        right = min(width - 1, int(xmax / 1000 * width))
        bottom = min(height - 1, int(ymax / 1000 * height))
        if right <= left or bottom <= top:
            continue
        draw.rectangle(
            [left, top, right, bottom],
            outline=(255, 64, 64),
            width=max(2, width // 400),
        )
        short = text if len(text) <= 28 else text[:27] + "…"
        pct = _pct_for_line(text, drugs)
        label = f"{short}  {pct}%" if pct is not None else short
        box_h = max(1, bottom - top)
        inner_font = _font(max(11, min(font.size, box_h // 2)))
        tx, ty = left + 3, top + 2
        bbox = draw.textbbox((tx, ty), label, font=inner_font)
        if bbox[2] > right - 2:
            overflow = bbox[2] - (right - 2)
            tx = max(left + 2, tx - overflow)
            bbox = draw.textbbox((tx, ty), label, font=inner_font)
        fill_right = min(right - 1, max(bbox[2] + 4, left + 8))
        fill_bottom = min(bottom - 1, bbox[3] + 2)
        draw.rectangle([left + 1, top + 1, fill_right, fill_bottom], fill=(255, 64, 64))
        draw.text((tx, ty), label, fill=(255, 255, 255), font=inner_font)

    out_path.parent.mkdir(parents=True, exist_ok=True)
    image.save(out_path, quality=92)
    return out_path


def main() -> int:
    parser = argparse.ArgumentParser(description="OCR 인식 글자 오버레이 이미지 생성")
    parser.add_argument("image", help="원본 이미지 경로")
    parser.add_argument(
        "--out",
        default="",
        help="저장 경로 (기본: <원본이름>_ocr_overlay.jpg)",
    )
    args = parser.parse_args()

    image_path = Path(args.image)
    if not image_path.is_file():
        image_path = ROOT / args.image
    if not image_path.is_file():
        print(f"이미지 없음: {args.image}")
        return 1

    out_path = Path(args.out) if args.out else image_path.with_name(
        f"{image_path.stem}_ocr_overlay.jpg"
    )
    if not out_path.is_absolute():
        out_path = ROOT / out_path

    image_bytes = image_path.read_bytes()
    print("OCR 파이프라인(이름·성분 인식률)…", image_path)
    scored = score_ocr_image(image_bytes)
    overall = int((scored.get("readiness") or {}).get("pct") or 0)
    drugs = scored.get("drugs") or []
    print(f"OCR 인식률: {overall}%  ({(scored.get('readiness') or {}).get('summary')})")
    for drug in drugs:
        print(f"  - {drug.get('drug_name')}  {drug.get('pct')}%  [{drug.get('match_status')}]")

    print("OCR 박스 인식 중…")
    lines = detect_text_boxes(image_bytes)
    print(f"인식 줄 수: {len(lines)}")
    saved = draw_overlay(
        image_path,
        lines,
        out_path,
        overall_pct=overall,
        drugs=drugs,
    )
    print("저장:", saved.resolve())
    for line in lines[:20]:
        pct = _pct_for_line(str(line.get("text") or ""), drugs)
        suffix = f"  {pct}%" if pct is not None else ""
        print("-", line.get("text"), suffix)
    if len(lines) > 20:
        print(f"... 외 {len(lines) - 20}줄")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
