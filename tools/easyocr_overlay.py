"""EasyOCR로 글자+박스를 읽고 원본 위에 그려 저장한다.

  python tools/easyocr_overlay.py 20260825_164345.jpg
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont, ImageOps

ROOT = Path(__file__).resolve().parents[1]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("image")
    parser.add_argument("--out", default="")
    parser.add_argument("--lang", default="ko,en", help="예: ko,en")
    args = parser.parse_args()

    image_path = Path(args.image)
    if not image_path.is_file():
        image_path = ROOT / args.image
    if not image_path.is_file():
        print("이미지 없음:", args.image)
        return 1

    out_path = Path(args.out) if args.out else image_path.with_name(
        f"{image_path.stem}_easyocr_overlay.jpg"
    )
    if not out_path.is_absolute():
        out_path = ROOT / out_path

    langs = [x.strip() for x in args.lang.split(",") if x.strip()]
    print("EasyOCR 로딩…", langs)
    import easyocr

    reader = easyocr.Reader(langs, gpu=False)
    print("인식 중…", image_path)
    # detail=1 → (bbox, text, conf)
    results = reader.readtext(str(image_path), detail=1, paragraph=False)
    print(f"인식 덩어리: {len(results)}")

    image = ImageOps.exif_transpose(Image.open(image_path).convert("RGB"))
    draw = ImageDraw.Draw(image)
    try:
        font = ImageFont.truetype(r"C:\Windows\Fonts\malgun.ttf", max(16, image.width // 55))
    except Exception:
        font = ImageFont.load_default()

    lines: list[str] = []
    for item in results:
        box, text, conf = item
        text = str(text or "").strip()
        if not text:
            continue
        lines.append(f"{text}  ({conf:.2f})")
        xs = [p[0] for p in box]
        ys = [p[1] for p in box]
        left, top, right, bottom = min(xs), min(ys), max(xs), max(ys)
        draw.rectangle([left, top, right, bottom], outline=(255, 48, 48), width=max(2, image.width // 500))
        label = text if len(text) <= 28 else text[:27] + "…"
        ty = max(0, top - (font.size + 4))
        tb = draw.textbbox((left, ty), label, font=font)
        draw.rectangle(tb, fill=(255, 48, 48))
        draw.text((left, ty), label, fill=(255, 255, 255), font=font)

    out_path.parent.mkdir(parents=True, exist_ok=True)
    image.save(out_path, quality=92)
    print("저장:", out_path.resolve())
    for line in lines[:40]:
        print("-", line)
    if len(lines) > 40:
        print(f"... 외 {len(lines) - 40}개")

    txt_path = out_path.with_suffix(".txt")
    txt_path.write_text("\n".join(lines), encoding="utf-8")
    print("텍스트:", txt_path.resolve())
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
