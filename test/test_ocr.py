import sys
from pathlib import Path
import json

# 현재 폴더 경로를 파이썬 경로에 추가하여 app 모듈을 불러올 수 있게 설정
sys.path.append(str(Path(__file__).resolve().parent.parent))

from app.services.ocr.parser import parse_prescription_text

# 1. 첨부해주신 처방전 이미지를 모방한 가상의 원시 OCR 텍스트
# (구글 ML Kit나 Tesseract가 읽었다고 가정하는 지저분한 텍스트 덩어리)
SAMPLE_OCR_TEXT = """
교부번호 2026041700033
병원정보 중앙성모의원(김재민)
처방일자 2026-04-17

약품사진     약품명            복약안내 (투약량 / 횟수 / 일수)   주의사항
모사피아정     [위장관운동조절제]
흰색 장방형 필름코팅정 기능성소화불량 증상을 완화하는 위장운동 조절제입니다. 1정씩 2회 5일분 실온(1~30℃)보관

프로맥정      [위점막보호, 소화성궤양 치료제]
흰색 원형 정제 위점막세포 보호작용과 손상된 점막조직의 재생 작용으로 위궤양, 위염 증상을 치료합니다. 1정씩 2회 5일분 실온(1~30℃)보관

니자액스캡슐150mg               1캡슐씩 2회 5일분
"""

def main():
    print("==================================================")
    print("📥 [입력된 원본 OCR 텍스트]")
    print("==================================================")
    print(SAMPLE_OCR_TEXT.strip())
    print()
    
    print("==================================================")
    print("🤖 [Gemini AI 추출 진행 중...]")
    print("==================================================")
    
    # AI 서비스 호출
    parsed_data = parse_prescription_text(SAMPLE_OCR_TEXT)
    
    if parsed_data is None:
        print("❌ 오류: GEMINI_API_KEY가 설정되지 않았습니다.")
        print(".env 파일에 GEMINI_API_KEY를 입력해주세요!")
        return

    print("✅ [AI 필터링 성공! 구조화된 JSON 결과]")
    print("==================================================")
    # 한글이 깨지지 않도록 json.dumps 사용
    print(json.dumps(parsed_data, indent=4, ensure_ascii=False))
    
    print("\n🔍 백엔드 DB 저장 예상 시나리오:")
    for item in parsed_data.get("items", []):
        print(f" -> '{item['drug_name']}' 검색 후 DB 매핑, 하루 {item['frequency_per_day']}번 x {item['duration_days']}일분 투약 스케줄 생성")

if __name__ == "__main__":
    main()
