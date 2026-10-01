"""SQLite map: official phrases → easy labels, and everyday chat related links."""

from __future__ import annotations

import sqlite3
from pathlib import Path

from app.core.config import EASY_CATEGORY_MAP_DB_PATH

DB_PATH = EASY_CATEGORY_MAP_DB_PATH

# (공식 표현, 쉬운 말, name|efficacy, 메모)
SEED_ROWS: tuple[tuple[str, str, str, str], ...] = (
    ("암로디핀", "혈압약", "name", "제품명/성분"),
    ("메트포르민", "당뇨약", "name", "제품명/성분"),
    ("아스피린", "피가 굳지 않게 하는 약", "name", "제품명/성분"),
    ("아스트릭스", "피가 굳지 않게 하는 약", "name", "아스피린 계열"),
    ("타이레놀", "해열제", "name", "제품명"),
    ("아세트아미노펜", "해열제", "name", "성분명"),
    ("부루펜", "해열제", "name", "제품명"),
    ("이부프로펜", "해열제", "name", "성분명"),
    ("게보린", "두통약", "name", "제품명"),
    ("메퀴타진", "가려움 약", "name", "성분명"),
    ("프리마란", "가려움 약", "name", "제품명"),
    ("스멕타", "설사약", "name", "지사제"),
    ("정로환", "설사약", "name", "지사제"),
    ("로페라", "설사약", "name", "지사제"),
    ("듀파락", "변비약", "name", "변비약"),
    ("마그밀", "변비약", "name", "변비약"),
    ("세프디니르", "감염약", "name", "항생제 성분"),
    ("옴니세프", "감염약", "name", "항생제 제품명"),
    ("클래리트로마이신", "감염약", "name", "항생제 성분"),
    ("레보플록사신", "감염약", "name", "항생제 성분"),
    ("목시플록사신", "감염약", "name", "항생제 성분"),
    ("에리트로마이신", "감염약", "name", "항생제 성분"),
    ("펜타미딘", "특정 감염 치료약", "name", "항원충제 성분"),
    ("반데타닙", "갑상선암 치료약", "name", "항암제 성분"),
    ("감기의 제증상", "감기약", "efficacy", "큰 묶음"),
    ("감기로 인한 발열", "해열제", "efficacy", ""),
    ("콧물", "감기약", "efficacy", ""),
    ("재채기", "감기약", "efficacy", ""),
    ("코막힘", "감기약", "efficacy", ""),
    ("인후통", "목아픔 약", "efficacy", ""),
    ("기침", "감기약", "efficacy", ""),
    ("오한", "감기약", "efficacy", ""),
    ("해열", "해열제", "efficacy", ""),
    ("발열", "해열제", "efficacy", ""),
    ("진통", "진통제", "efficacy", ""),
    ("동통", "진통제", "efficacy", ""),
    ("두통", "두통약", "efficacy", ""),
    ("치통", "이앓이 약", "efficacy", ""),
    ("근육통", "진통제", "efficacy", ""),
    ("생리통", "진통제", "efficacy", ""),
    ("관절통", "진통제", "efficacy", ""),
    ("설사", "설사약", "efficacy", ""),
    ("묽은변", "설사약", "efficacy", ""),
    ("변비", "변비약", "efficacy", ""),
    ("복통", "배아픔 약", "efficacy", ""),
    ("고혈압", "혈압약", "efficacy", ""),
    ("혈압을 낮", "혈압약", "efficacy", ""),
    ("혈압강하", "혈압약", "efficacy", ""),
    ("당뇨병", "당뇨약", "efficacy", ""),
    ("당뇨", "당뇨약", "efficacy", ""),
    ("혈당강하", "당뇨약", "efficacy", ""),
    ("항혈소판", "피가 굳지 않게 하는 약", "efficacy", ""),
    ("혈전 생성", "피가 굳지 않게 하는 약", "efficacy", ""),
    ("알레르기 비염", "알레르기 약", "efficacy", ""),
    ("두드러기", "가려움 약", "efficacy", ""),
    ("가려움", "가려움 약", "efficacy", ""),
    ("알레르기", "알레르기 약", "efficacy", ""),
    ("결막염", "눈약", "efficacy", ""),
    ("역류성식도염", "속쓰림 약", "efficacy", ""),
    ("십이지장궤양", "속쓰림 약", "efficacy", ""),
    ("위궤양", "속쓰림 약", "efficacy", ""),
    ("위염", "속쓰림 약", "efficacy", ""),
    ("속쓰림", "속쓰림 약", "efficacy", ""),
    ("소화불량", "소화제", "efficacy", ""),
    ("구역", "메스꺼움 약", "efficacy", ""),
    ("구토", "토하는 약", "efficacy", ""),
    ("어지러", "어지럼 약", "efficacy", ""),
    ("불면", "잠 오는 약", "efficacy", ""),
    ("불안장애의 치료", "불안약", "efficacy", "자낙스 오탐 방지"),
    ("불안증상", "불안약", "efficacy", ""),
    ("공황장애", "불안약", "efficacy", ""),
    ("주요우울장애", "우울약", "efficacy", ""),
    ("주요 우울", "우울약", "efficacy", ""),
    ("우울증", "우울약", "efficacy", ""),
    ("정신분열", "조현병약", "efficacy", ""),
    ("조현병", "조현병약", "efficacy", ""),
    ("정신병적", "조현병약", "efficacy", ""),
    ("뇌전증", "뇌전증약", "efficacy", ""),
    ("간질", "뇌전증약", "efficacy", ""),
    ("부정맥", "심장 박동 약", "efficacy", ""),
    ("부정빈맥", "심장 박동 약", "efficacy", ""),
    ("심방세동", "심장 박동 약", "efficacy", ""),
    ("울혈성심부전", "심장 박동 약", "efficacy", ""),
    ("고콜레스테롤혈증", "피 기름 약", "efficacy", ""),
    ("고지혈증", "피 기름 약", "efficacy", ""),
    ("고콜레스테롤", "피 기름 약", "efficacy", ""),
    ("심근경색", "피가 굳지 않게 하는 약", "efficacy", ""),
    ("허혈뇌졸중", "피가 굳지 않게 하는 약", "efficacy", ""),
    ("뇌졸중", "피가 굳지 않게 하는 약", "efficacy", ""),
    ("기능성소화불량", "소화제", "efficacy", ""),
    ("위식도역류", "속쓰림 약", "efficacy", ""),
    ("위점막", "속쓰림 약", "efficacy", ""),
    ("급성위염", "속쓰림 약", "efficacy", "진통 오탐보다 김"),
    ("헬리코박터", "속쓰림 약", "efficacy", ""),
    ("아토피피부염", "가려움 약", "efficacy", "알레르기 오탐보다 김"),
    ("가려움발진", "가려움 약", "efficacy", ""),
    ("접촉성알레르기피부염", "가려움 약", "efficacy", ""),
    ("피부염", "가려움 약", "efficacy", ""),
    ("습진", "가려움 약", "efficacy", ""),
    ("건선", "가려움 약", "efficacy", ""),
    ("화농", "상처약", "efficacy", ""),
    ("상처", "상처약", "efficacy", ""),
    ("전립샘비대", "소변약", "efficacy", ""),
    ("전립선비대", "소변약", "efficacy", ""),
    ("배뇨장애", "소변약", "efficacy", ""),
    ("인플루엔자", "독감약", "efficacy", ""),
    ("B형 간염", "간염약", "efficacy", ""),
    ("만성 B형", "간염약", "efficacy", ""),
    ("기억력저하", "기억약", "efficacy", ""),
    ("알츠하이머", "치매약", "efficacy", ""),
    ("치매", "치매약", "efficacy", ""),
    ("비타민 B1", "비타민약", "efficacy", ""),
    ("비타민 B2", "비타민약", "efficacy", ""),
    ("비타민 C의 보급", "비타민약", "efficacy", ""),
    ("육체피로", "비타민약", "efficacy", ""),
    ("골관절염", "진통제", "efficacy", ""),
    ("류마티양", "진통제", "efficacy", ""),
    ("폐렴", "감염약", "efficacy", ""),
    ("기관지염", "감염약", "efficacy", ""),
    ("중이염", "감염약", "efficacy", ""),
    ("신우신염", "감염약", "efficacy", ""),
    ("방광염", "감염약", "efficacy", ""),
    ("기관지천식", "숨 쉬기 약", "efficacy", ""),
    ("호흡곤란", "숨 쉬기 약", "efficacy", ""),
    ("천식", "숨 쉬기 약", "efficacy", ""),
    ("고뇨산", "통풍약", "efficacy", ""),
    ("통풍", "통풍약", "efficacy", ""),
    ("간기능", "간 약", "efficacy", ""),
    ("간질환", "간 약", "efficacy", ""),
    ("말라리아", "말라리아약", "efficacy", ""),
    ("체중감량", "체중약", "efficacy", ""),
    ("티눈", "티눈약", "efficacy", ""),
    ("사마귀", "티눈약", "efficacy", ""),
    ("굳은살", "티눈약", "efficacy", ""),
    ("아미오다론", "심장 박동 약", "name", ""),
    ("코다론", "심장 박동 약", "name", ""),
    ("게루삼", "속쓰림 약", "name", ""),
    ("소타롤", "심장 박동 약", "name", ""),
    ("알프라졸람", "불안약", "name", ""),
    ("자낙스", "불안약", "name", ""),
    ("부스피론", "불안약", "name", ""),
    ("로라제팜", "불안약", "name", ""),
    ("할로페리돌", "조현병약", "name", ""),
    ("미르타자핀", "우울약", "name", ""),
    ("플루옥세틴", "우울약", "name", ""),
    ("에스시탈로프람", "우울약", "name", ""),
    ("아미트리프틸린", "우울약", "name", ""),
    ("클로나제팜", "뇌전증약", "name", ""),
    ("페니토인", "뇌전증약", "name", ""),
    ("클로피도그렐", "피가 굳지 않게 하는 약", "name", ""),
    ("플라빅스", "피가 굳지 않게 하는 약", "name", ""),
    ("아토르바스타틴", "피 기름 약", "name", ""),
    ("로수바스타틴", "피 기름 약", "name", ""),
    ("리피토", "피 기름 약", "name", ""),
    ("크레스토", "피 기름 약", "name", ""),
    ("프레드니카르베이트", "가려움 약", "name", ""),
    ("탐스로신", "소변약", "name", ""),
    ("하루날", "소변약", "name", ""),
    ("피나스테리드", "소변약", "name", ""),
    ("프로스카", "소변약", "name", ""),
    ("오셀타미비르", "독감약", "name", ""),
    ("타미플루", "독감약", "name", ""),
    ("엔테카비르", "간염약", "name", ""),
    ("바라크루드", "간염약", "name", ""),
    ("콜린알포세레이트", "기억약", "name", ""),
    ("글리아티린", "기억약", "name", ""),
    ("리바스티그민", "치매약", "name", ""),
    ("엑셀론", "치매약", "name", ""),
    ("삐콤", "비타민약", "name", ""),
    ("아로나민", "비타민약", "name", ""),
    ("임팩타민", "비타민약", "name", ""),
    ("후시딘", "상처약", "name", ""),
    ("마데카솔", "상처약", "name", ""),
    ("퓨시드산", "상처약", "name", ""),
)

# (easy_label, eat|apply|patch|eye, B 문장)
SPOKEN_ROWS: tuple[tuple[str, str, str], ...] = (
    ("혈압약", "eat", "혈압을 낮추는 약이에요"),
    ("당뇨약", "eat", "혈당을 낮추는 약이에요"),
    ("소화제", "eat", "소화가 안 될 때 먹는 약이에요"),
    ("속쓰림 약", "eat", "속쓰림이나 위 불편감을 완화하는 데 쓰이는 약이에요."),
    ("해열제", "eat", "열나고 아플 때 먹는 약이에요"),
    ("진통제", "eat", "열나고 아플 때 먹는 약이에요"),
    ("진통제", "apply", "아픈 곳에 바르는 약이에요"),
    ("진통제", "patch", "아픈 곳에 붙이는 약이에요"),
    ("두통약", "eat", "머리 아플 때 먹는 약이에요"),
    ("이앓이 약", "eat", "이 아플 때 먹는 약이에요"),
    ("감기약", "eat", "감기 기운에 먹는 약이에요"),
    ("목아픔 약", "eat", "목 아플 때 먹는 약이에요"),
    ("가려움 약", "eat", "가려울 때 먹는 약이에요"),
    ("가려움 약", "apply", "가려운 피부에 바르는 약이에요"),
    ("알레르기 약", "eat", "알레르기 때 먹는 약이에요"),
    ("눈약", "eat", "눈에 넣는 약이에요"),
    ("눈약", "eye", "눈에 넣는 약이에요"),
    ("변비약", "eat", "변비에 먹는 약이에요"),
    ("설사약", "eat", "설사할 때 먹는 약이에요"),
    ("배아픔 약", "eat", "배 아플 때 먹는 약이에요"),
    ("메스꺼움 약", "eat", "메스꺼울 때 먹는 약이에요"),
    ("토하는 약", "eat", "토할 때 먹는 약이에요"),
    ("어지럼 약", "eat", "어지러울 때 먹는 약이에요"),
    ("잠 오는 약", "eat", "잠 올 때 먹는 약이에요"),
    ("피가 굳지 않게 하는 약", "eat", "피가 굳지 않게 하는 약이에요"),
    ("피 기름 약", "eat", "피 속 기름을 낮추는 약이에요"),
    ("심장 박동 약", "eat", "심장 박동을 고르게 하는 약이에요"),
    ("우울약", "eat", "기분이 가라앉을 때 먹는 약이에요"),
    ("불안약", "eat", "마음이 불안할 때 먹는 약이에요"),
    ("조현병약", "eat", "마음을 가라앉히는 약이에요"),
    ("뇌전증약", "eat", "경련을 줄이는 약이에요"),
    ("감염약", "eat", "세균을 죽이는 약이에요"),
    ("숨 쉬기 약", "eat", "숨 쉴 때 편한 약이에요"),
    ("통풍약", "eat", "통풍에 먹는 약이에요"),
    ("비타민약", "eat", "기운 없을 때 먹는 약이에요"),
    ("간 약", "eat", "간을 도와주는 약이에요"),
    ("간염약", "eat", "간염에 먹는 약이에요"),
    ("치매약", "eat", "기억을 도와주는 약이에요"),
    ("치매약", "patch", "기억에 붙이는 약이에요"),
    ("기억약", "eat", "기억을 도와주는 약이에요"),
    ("말라리아약", "eat", "말라리아에 먹는 약이에요"),
    ("체중약", "eat", "체중 관리에 먹는 약이에요"),
    ("티눈약", "apply", "티눈에 바르는 약이에요"),
    ("티눈약", "patch", "티눈에 붙이는 약이에요"),
    ("소변약", "eat", "소변이 잘 나오게 하는 약이에요"),
    ("독감약", "eat", "독감에 먹는 약이에요"),
    ("상처약", "apply", "상처에 바르는 약이에요"),
    ("상처약", "eat", "상처에 바르는 약이에요"),
    ("특정 감염 치료약", "eat", "특정 감염을 치료하는 데 쓰이는 약이에요"),
    ("갑상선암 치료약", "eat", "갑상선암을 치료하는 데 쓰이는 약이에요"),
)

FALLBACK_SPOKEN = ""

# (일상어 trigger, link_type, link_value, note)
# link_type: search=약검색키, phrase=연관검색어(입력만), faq=질문전송
CHAT_LINK_SEED: tuple[tuple[str, str, str, str], ...] = (
    # ----- 감기 -----
    ("감기", "phrase", "콧물", ""),
    ("감기", "phrase", "기침", ""),
    ("감기", "phrase", "열", ""),
    ("감기", "phrase", "코막힘", ""),
    ("감기", "phrase", "목아픔", ""),
    ("감기", "phrase", "몸살", ""),
    ("감기", "search", "타이레놀콜드", ""),
    ("감기", "search", "타이레놀", ""),
    ("감기", "search", "게보린", ""),
    ("감기", "faq", "이 약 설명", ""),
    ("몸살", "phrase", "감기", ""),
    ("몸살", "phrase", "열", ""),
    ("몸살", "phrase", "근육통", ""),
    ("몸살", "search", "타이레놀", ""),
    ("몸살", "search", "부루펜", ""),
    ("독감", "phrase", "열", ""),
    ("독감", "phrase", "기침", ""),
    ("독감", "phrase", "몸살", ""),
    ("독감", "search", "타이레놀", ""),
    ("콧물", "phrase", "감기", ""),
    ("콧물", "phrase", "코막힘", ""),
    ("콧물", "phrase", "재채기", ""),
    ("콧물", "search", "타이레놀콜드", ""),
    ("기침", "phrase", "감기", ""),
    ("기침", "phrase", "목아픔", ""),
    ("기침", "search", "타이레놀콜드", ""),
    ("코막힘", "phrase", "콧물", ""),
    ("코막힘", "phrase", "감기", ""),
    ("코막힘", "search", "타이레놀콜드", ""),
    ("재채기", "phrase", "콧물", ""),
    ("재채기", "phrase", "알레르기", ""),
    ("목아픔", "phrase", "기침", ""),
    ("목아픔", "phrase", "감기", ""),
    ("인후통", "phrase", "목아픔", ""),
    # ----- 열·통증 -----
    ("열", "phrase", "해열", ""),
    ("열", "phrase", "오한", ""),
    ("열", "phrase", "감기", ""),
    ("열", "search", "타이레놀", ""),
    ("열", "search", "부루펜", ""),
    ("열나", "phrase", "열", ""),
    ("열나", "search", "타이레놀", ""),
    ("해열", "phrase", "열", ""),
    ("해열", "search", "타이레놀", ""),
    ("두통", "phrase", "머리아픔", ""),
    ("두통", "phrase", "진통", ""),
    ("두통", "search", "게보린", ""),
    ("두통", "search", "타이레놀", ""),
    ("머리아", "phrase", "두통", ""),
    ("머리아", "search", "게보린", ""),
    ("골치", "phrase", "두통", ""),
    ("골치", "search", "게보린", ""),
    ("통증", "phrase", "두통", ""),
    ("통증", "phrase", "근육통", ""),
    ("통증", "search", "타이레놀", ""),
    ("통증", "search", "부루펜", ""),
    ("근육통", "phrase", "몸살", ""),
    ("근육통", "search", "부루펜", ""),
    ("생리통", "search", "타이레놀", ""),
    ("생리통", "search", "게보린", ""),
    ("치통", "phrase", "이앓이", ""),
    ("치통", "search", "타이레놀", ""),
    ("이앓이", "phrase", "치통", ""),
    ("관절통", "search", "부루펜", ""),
    ("무릎", "phrase", "관절통", ""),
    ("무릎", "search", "부루펜", ""),
    ("허리", "phrase", "요통", ""),
    ("허리", "search", "부루펜", ""),
    ("요통", "search", "부루펜", ""),
    # ----- 배·설사·변비 -----
    ("설사", "phrase", "배아픔", ""),
    ("설사", "phrase", "물설사", ""),
    ("설사", "phrase", "배탈", ""),
    ("설사", "phrase", "장염", ""),
    ("설사", "search", "스멕타", ""),
    ("설사", "search", "정로환", ""),
    ("설사", "faq", "이 약 설명", ""),
    ("설사", "faq", "같이 먹으면", ""),
    ("물설사", "phrase", "설사", ""),
    ("물설사", "search", "스멕타", ""),
    ("배탈", "phrase", "설사", ""),
    ("배탈", "phrase", "배아픔", ""),
    ("배탈", "phrase", "체함", ""),
    ("배탈", "search", "정로환", ""),
    ("배아", "phrase", "배아픔", ""),
    ("배아픔", "phrase", "설사", ""),
    ("배아픔", "phrase", "체함", ""),
    ("배아픔", "phrase", "속쓰림", ""),
    ("배아픔", "search", "정로환", ""),
    ("복통", "phrase", "배아픔", ""),
    ("장염", "phrase", "설사", ""),
    ("장염", "phrase", "배아픔", ""),
    ("변비", "phrase", "배변", ""),
    ("변비", "phrase", "배아픔", ""),
    ("변비", "search", "듀파락", ""),
    ("변비", "search", "마그밀", ""),
    ("변비", "faq", "이 약 설명", ""),
    ("체함", "phrase", "소화", ""),
    ("체함", "phrase", "배아픔", ""),
    ("체함", "phrase", "메스꺼움", ""),
    ("체한", "phrase", "체함", ""),
    ("소화", "phrase", "체함", ""),
    ("소화", "phrase", "속쓰림", ""),
    ("속쓰림", "phrase", "소화", ""),
    ("속안좋", "phrase", "속쓰림", ""),
    ("속안좋", "phrase", "소화", ""),
    ("메스꺼움", "phrase", "토할것같", ""),
    ("구토", "phrase", "토함", ""),
    ("토함", "phrase", "메스꺼움", ""),
    # ----- 혈압·당뇨 -----
    ("혈압", "phrase", "고혈압", ""),
    ("혈압", "search", "암로디핀", ""),
    ("혈압", "faq", "같이 먹으면", ""),
    ("혈압", "faq", "이 약 설명", ""),
    ("고혈압", "phrase", "혈압", ""),
    ("고혈압", "search", "암로디핀", ""),
    ("당뇨", "phrase", "혈당", ""),
    ("당뇨", "search", "메트포르민", ""),
    ("당뇨", "faq", "같이 먹으면", ""),
    ("당뇨", "faq", "이 약 설명", ""),
    ("혈당", "phrase", "당뇨", ""),
    ("혈당", "search", "메트포르민", ""),
    # ----- 알레르기·피부 -----
    ("알레르기", "phrase", "가려움", ""),
    ("알레르기", "phrase", "두드러기", ""),
    ("알레르기", "phrase", "재채기", ""),
    ("알레르기", "search", "프리마란", ""),
    ("가려움", "phrase", "두드러기", ""),
    ("가려움", "phrase", "알레르기", ""),
    ("가려움", "search", "프리마란", ""),
    ("두드러기", "phrase", "가려움", ""),
    ("두드러기", "search", "프리마란", ""),
    # ----- 복용 습관 -----
    ("같이먹", "faq", "같이 먹으면", ""),
    ("같이", "faq", "같이 먹으면", ""),
    ("겹쳐", "faq", "같이 먹으면", ""),
    ("안먹", "faq", "안 먹었을 때", ""),
    ("깜빡", "faq", "안 먹었을 때", ""),
    ("잊었", "faq", "안 먹었을 때", ""),
    ("어제안", "faq", "안 먹었을 때", ""),
    ("언제먹", "faq", "이 약 설명", ""),
    ("밥전", "faq", "이 약 설명", ""),
    ("식후", "faq", "이 약 설명", ""),
    ("몇알", "faq", "이 약 설명", ""),
    ("두알", "faq", "이 약 설명", ""),
    ("먹어도돼", "faq", "같이 먹으면", ""),
    ("술먹", "faq", "같이 먹으면", ""),
    ("술하고", "faq", "같이 먹으면", ""),
    ("부작용", "faq", "이 약 설명", ""),
    ("어지러", "phrase", "어지러움", ""),
    ("어지러", "faq", "이 약 설명", ""),
    ("졸려", "faq", "이 약 설명", ""),
    ("뭐야", "faq", "이 약 설명", ""),
    ("이거뭐", "faq", "이 약 설명", ""),
    ("효과있", "faq", "이 약 설명", ""),
    # ----- 약 이름 오타·초성 -----
    ("타이", "search", "타이레놀", ""),
    ("타이레", "search", "타이레놀", ""),
    ("타이래", "search", "타이레놀", ""),
    ("ㅌㄹㄴ", "search", "타이레놀", ""),
    ("ㅌㅇㄹㄴ", "search", "타이레놀", ""),
    ("부루", "search", "부루펜", ""),
    ("부르펜", "search", "부루펜", ""),
    ("ㅂㄹㅍ", "search", "부루펜", ""),
    ("게보", "search", "게보린", ""),
    ("게보링", "search", "게보린", ""),
    ("ㄱㅂㄹ", "search", "게보린", ""),
    ("아스피", "search", "아스피린", ""),
    ("ㅇㅅㅍㄹ", "search", "아스피린", ""),
    ("프리마", "search", "프리마란", ""),
    ("ㅍㄹㅁ", "search", "프리마란", ""),
)

SCHEMA_SQL = """
CREATE TABLE IF NOT EXISTS category_map (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    official_phrase TEXT NOT NULL,
    easy_label TEXT NOT NULL,
    match_scope TEXT NOT NULL DEFAULT 'efficacy',
    note TEXT,
    created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
    UNIQUE(official_phrase, match_scope)
);

CREATE TABLE IF NOT EXISTS chat_links (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    trigger TEXT NOT NULL,
    link_type TEXT NOT NULL,
    link_value TEXT NOT NULL,
    note TEXT,
    created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
    UNIQUE(trigger, link_type, link_value)
);

CREATE TABLE IF NOT EXISTS spoken_map (
    easy_label TEXT NOT NULL,
    route TEXT NOT NULL,
    sentence TEXT NOT NULL,
    PRIMARY KEY (easy_label, route)
);

CREATE INDEX IF NOT EXISTS idx_category_map_phrase ON category_map(official_phrase);
CREATE INDEX IF NOT EXISTS idx_category_map_scope ON category_map(match_scope);
CREATE INDEX IF NOT EXISTS idx_chat_links_trigger ON chat_links(trigger);
CREATE INDEX IF NOT EXISTS idx_chat_links_type ON chat_links(link_type);
"""


def get_connection() -> sqlite3.Connection:
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    return conn


def initialize_easy_category_map_db(*, reset_seed: bool = False) -> Path:
    path = Path(DB_PATH)
    path.parent.mkdir(parents=True, exist_ok=True)
    conn = get_connection()
    try:
        conn.executescript(SCHEMA_SQL)
        if reset_seed:
            conn.execute("DELETE FROM category_map")
            conn.execute("DELETE FROM chat_links")
            conn.execute("DELETE FROM spoken_map")
        conn.executemany(
            """
            INSERT INTO spoken_map (easy_label, route, sentence)
            VALUES (?, ?, ?)
            ON CONFLICT(easy_label, route) DO UPDATE SET
                sentence = excluded.sentence
            """,
            SPOKEN_ROWS,
        )
        spoken_keys = {(label, route) for label, route, _s in SPOKEN_ROWS}
        stale_spoken = [
            (row["easy_label"], row["route"])
            for row in conn.execute("SELECT easy_label, route FROM spoken_map")
            if (row["easy_label"], row["route"]) not in spoken_keys
        ]
        if stale_spoken:
            conn.executemany(
                "DELETE FROM spoken_map WHERE easy_label = ? AND route = ?",
                stale_spoken,
            )
        conn.executemany(
            """
            INSERT INTO category_map (
                official_phrase, easy_label, match_scope, note
            ) VALUES (?, ?, ?, ?)
            ON CONFLICT(official_phrase, match_scope) DO UPDATE SET
                easy_label = excluded.easy_label,
                note = excluded.note
            """,
            SEED_ROWS,
        )
        seed_keys = {(phrase, scope) for phrase, _label, scope, _note in SEED_ROWS}
        stale_ids = [
            row["id"]
            for row in conn.execute(
                "SELECT id, official_phrase, match_scope FROM category_map"
            ).fetchall()
            if (row["official_phrase"], row["match_scope"]) not in seed_keys
        ]
        if stale_ids:
            conn.executemany(
                "DELETE FROM category_map WHERE id = ?",
                [(row_id,) for row_id in stale_ids],
            )
        conn.execute(
            """
            DELETE FROM chat_links
            WHERE trigger = '속쓰림' AND link_type = 'phrase' AND link_value = '위'
            """
        )
        link_n = conn.execute("SELECT COUNT(*) AS n FROM chat_links").fetchone()["n"]
        if link_n == 0 or reset_seed:
            conn.executemany(
                """
                INSERT OR REPLACE INTO chat_links (
                    trigger, link_type, link_value, note
                ) VALUES (?, ?, ?, ?)
                """,
                CHAT_LINK_SEED,
            )
        conn.commit()
    finally:
        conn.close()
    return path


def lookup_easy_label(
    *,
    name_text: str = "",
    efficacy_text: str = "",
) -> str | None:
    initialize_easy_category_map_db()
    name_blob = (name_text or "").casefold()
    efficacy_blob = (efficacy_text or "").casefold()
    conn = get_connection()
    try:
        rows = conn.execute(
            """
            SELECT official_phrase, easy_label, match_scope
            FROM category_map
            ORDER BY LENGTH(official_phrase) DESC, id ASC
            """
        ).fetchall()
    finally:
        conn.close()

    name_best: tuple[int, str] | None = None
    efficacy_best: tuple[int, str] | None = None

    for row in rows:
        phrase = str(row["official_phrase"] or "").casefold()
        label = str(row["easy_label"] or "").strip()
        if not phrase or not label:
            continue
        scope = row["match_scope"]
        if scope == "name" and phrase in name_blob:
            plen = len(phrase)
            if name_best is None or plen > name_best[0]:
                name_best = (plen, label)
        elif scope == "efficacy" and phrase in efficacy_blob:
            plen = len(phrase)
            if efficacy_best is None or plen > efficacy_best[0]:
                efficacy_best = (plen, label)

    # 제품명·성분은 효능 문장 속 부수적인 병명보다 강한 근거다.
    # 예: 아스피린 효능에 '고콜레스테롤'이 함께 있어도 혈전 예방약 분류를 유지한다.
    if name_best:
        return name_best[1]
    if efficacy_best:
        return efficacy_best[1]
    return None


def lookup_easy_matches(
    *,
    name_text: str = "",
    efficacy_text: str = "",
) -> list[dict[str, str]]:
    """Return matched map rows with the exact evidence phrase.

    Name/ingredient matches are returned first because they are less ambiguous than
    disease words embedded in a long official efficacy paragraph.
    """
    initialize_easy_category_map_db()
    blobs = {
        "name": (name_text or "").casefold(),
        "efficacy": (efficacy_text or "").casefold(),
    }
    conn = get_connection()
    try:
        rows = conn.execute(
            """
            SELECT official_phrase, easy_label, match_scope
            FROM category_map
            ORDER BY CASE match_scope WHEN 'name' THEN 0 ELSE 1 END,
                     LENGTH(official_phrase) DESC, id ASC
            """
        ).fetchall()
    finally:
        conn.close()

    matches: list[dict[str, str]] = []
    seen: set[tuple[str, str]] = set()
    for row in rows:
        scope = str(row["match_scope"] or "")
        phrase = str(row["official_phrase"] or "").strip()
        label = str(row["easy_label"] or "").strip()
        if scope not in blobs or not phrase or not label:
            continue
        if phrase.casefold() not in blobs[scope]:
            continue
        key = (scope, label)
        if key in seen:
            continue
        seen.add(key)
        matches.append(
            {
                "match_scope": scope,
                "official_phrase": phrase,
                "easy_label": label,
            }
        )
    return matches


def lookup_spoken_sentence(easy_label: str | None, route: str) -> str:
    initialize_easy_category_map_db()
    if not (easy_label or "").strip():
        return FALLBACK_SPOKEN
    conn = get_connection()
    try:
        row = conn.execute(
            """
            SELECT sentence FROM spoken_map
            WHERE easy_label = ? AND route = ?
            """,
            (easy_label, route),
        ).fetchone()
        if row:
            return str(row["sentence"])
        fallback = conn.execute(
            """
            SELECT sentence FROM spoken_map
            WHERE easy_label = ? AND route = 'eat'
            """,
            (easy_label,),
        ).fetchone()
        if fallback:
            return str(fallback["sentence"])
        any_row = conn.execute(
            "SELECT sentence FROM spoken_map WHERE easy_label = ? LIMIT 1",
            (easy_label,),
        ).fetchone()
        if any_row:
            return str(any_row["sentence"])
    finally:
        conn.close()
    return FALLBACK_SPOKEN


def lookup_chat_links(query: str) -> dict[str, list[str]]:
    """일상어 입력에 묶인 search/phrase/faq 목록."""
    initialize_easy_category_map_db()
    needle = "".join(str(query or "").casefold().split())
    result: dict[str, list[str]] = {"search": [], "phrase": [], "faq": []}
    if not needle:
        return result

    conn = get_connection()
    try:
        rows = conn.execute(
            """
            SELECT trigger, link_type, link_value
            FROM chat_links
            ORDER BY LENGTH(trigger) DESC, id ASC
            """
        ).fetchall()
    finally:
        conn.close()

    # 입력에 들어 있는 trigger만 인정.
    # (설사 → 물설사 trigger로 잘못 잡히지 않게 needle in trigger 는 쓰지 않음)
    matched_triggers: list[str] = []
    best_len = 0
    for row in rows:
        trigger = str(row["trigger"] or "").casefold()
        if not trigger:
            continue
        hit = needle == trigger or trigger in needle
        if not hit and len(trigger) == 1:
            hit = needle.startswith(trigger)
        if not hit:
            continue
        if len(trigger) > best_len:
            best_len = len(trigger)
            matched_triggers = [trigger]
        elif len(trigger) == best_len and trigger not in matched_triggers:
            matched_triggers.append(trigger)

    if not matched_triggers:
        return result

    seen: dict[str, set[str]] = {"search": set(), "phrase": set(), "faq": set()}
    for row in rows:
        trigger = str(row["trigger"] or "").casefold()
        if trigger not in matched_triggers:
            continue
        link_type = str(row["link_type"] or "")
        value = str(row["link_value"] or "").strip()
        if link_type not in seen or not value or value in seen[link_type]:
            continue
        seen[link_type].add(value)
        result[link_type].append(value)
    return result


def list_map_rows(limit: int = 200) -> list[dict]:
    initialize_easy_category_map_db()
    conn = get_connection()
    try:
        rows = conn.execute(
            """
            SELECT official_phrase, easy_label, match_scope, note
            FROM category_map
            ORDER BY match_scope, LENGTH(official_phrase) DESC, id
            LIMIT ?
            """,
            (limit,),
        ).fetchall()
        return [dict(row) for row in rows]
    finally:
        conn.close()


def list_chat_link_rows(limit: int = 300) -> list[dict]:
    initialize_easy_category_map_db()
    conn = get_connection()
    try:
        rows = conn.execute(
            """
            SELECT trigger, link_type, link_value, note
            FROM chat_links
            ORDER BY trigger, link_type, id
            LIMIT ?
            """,
            (limit,),
        ).fetchall()
        return [dict(row) for row in rows]
    finally:
        conn.close()
