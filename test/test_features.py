import sys
import os
import json
sys.stdout.reconfigure(encoding='utf-8')
sys.path.append(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from app.database import get_connection
from app.services.dur_service import analyze_dur
from app.services.drug_explain_service import get_drug_explanation
from app.models.schemas import DurAnalyzeRequest
import app.services.drug_explain_service as drug_explain_service

def setup_dur_dummy_data():
    conn = get_connection()
    cursor = conn.cursor()
    
    cursor.execute("SELECT medicine_code, product_name, ingredient FROM medicines")
    meds = cursor.fetchall()
    
    med1 = next((m for m in meds if m["product_name"] == "모사피아정"), None)
    med2 = next((m for m in meds if m["product_name"] == "프로맥정"), None)
    
    if med1 and med2:
        # update medicines with ingredients
        cursor.execute("UPDATE medicines SET ingredient = '모사프리드시트르산염' WHERE product_name = '모사피아정'")
        cursor.execute("UPDATE medicines SET ingredient = '폴라프레징크' WHERE product_name = '프로맥정'")
        
        cursor.execute(
            """
            INSERT OR IGNORE INTO dur_taboo (
                ingredient_a, ingredient_b, taboo_type, severity, description,
                source, external_id
            ) VALUES (?, ?, '병용금기', 'HIGH', '두 위장약을 함께 복용 시 위장 장애가 가중될 우려가 있어 병용금기로 지정되었습니다.', '테스트 DUR', 'TEST-001')
            """,
            ("모사프리드시트르산염", "폴라프레징크")
        )
        conn.commit()
    conn.close()

# Mock AI Response to simulate a successful API call
def dummy_generate_easy_explanation(official_info):
    return {
        "easy_summary": "위장 운동을 촉진시켜 속쓰림과 소화불량을 해결해주는 약입니다.",
        "what_it_does": "위장관의 운동을 활발하게 만들어 소화가 잘 되도록 돕습니다.",
        "how_to_take": "보통 하루 3번, 식전에 복용합니다.",
        "cautions": ["이 약을 먹고 어지러울 수 있으니 운전을 피하세요."],
        "possible_side_effects": ["복통", "설사", "어지러움"],
        "storage": "습기가 적은 서늘한 곳에 보관하세요.",
        "ask_doctor_when": ["배가 심하게 아프거나 계속 설사를 하면 의사/약사와 상담하세요."],
        "source_based": True
    }

def test_dur():
    print("=== [1. DUR 병용금기 분석 모듈 연동 확인] ===")
    setup_dur_dummy_data()
    req = DurAnalyzeRequest(user_id="test-user-1")
    try:
        result = analyze_dur(req)
        print("💡 DUR 분석 결과:")
        print(f" - 위험 등급: {result.get('risk_level')}")
        print(f" - 검출된 금기 건수: {result.get('total_matches')}건")
        if result.get('matches'):
            match = result['matches'][0]
            print(f" - 상세 사유: [{match['type']}] {match['ingredient_a']} + {match['ingredient_b']}")
            print(f"   => {match['reason']}")
    except Exception as e:
        print("DUR 분석 실패:", e)

def test_ai_explanation():
    print("\n=== [2. AI 쉬운 의약품 설명 모듈 (e약은요 + Gemini) 연동 확인] ===")
    
    # 젬미니 호출 부분을 모의(Mock)로 대체해서 동작만 확인
    drug_explain_service.generate_card_from_source = dummy_generate_easy_explanation
    
    conn = get_connection()
    med = conn.execute("SELECT medicine_code, product_name FROM medicines LIMIT 1").fetchone()
    conn.close()
    
    if med:
        try:
            result = get_drug_explanation(med["medicine_code"], force_refresh=True)
            print(f"💡 [{med['product_name']}] 약품의 AI 설명 카드:")
            print(f" - 쉬운 요약: {result.get('easy_summary')}")
            print(f" - 효능: {result.get('what_it_does')}")
            print(f" - 주의사항: {result.get('cautions')}")
            print(f" - 의사 상담 시점: {result.get('ask_doctor_when')}")
        except Exception as e:
            print("AI 설명 실패:", e)

if __name__ == "__main__":
    test_dur()
    test_ai_explanation()
