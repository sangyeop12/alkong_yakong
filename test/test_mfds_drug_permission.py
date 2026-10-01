import app.services.mfds_drug_permission.db as permission_db

from app.services.mfds_drug_permission.db import (
    count_stats,
    product_to_medicine,
    search_permission_names,
    xml_doc_to_text,
    xml_doc_section_to_text,
)


def test_permission_count_and_search_with_isolated_synthetic_database(tmp_path, monkeypatch):
    monkeypatch.setattr(permission_db, "DB_PATH", str(tmp_path / "permission-test.db"))
    permission_db.initialize_permission_db()
    conn = permission_db.get_permission_connection()
    try:
        permission_db.upsert_list_item(
            conn,
            {"ITEM_SEQ": "SYNTHETIC-001", "ITEM_NAME": "프리마란정 합성 테스트"},
        )
        conn.commit()
    finally:
        conn.close()

    assert permission_db.count_stats()["total"] == 1
    assert "프리마란정 합성 테스트" in permission_db.search_permission_names(
        "프리마란", limit=5
    )


def test_xml_cdata_to_text():
    raw = """
    <DOC title="효능효과" type="EE">
      <SECTION title="">
        <ARTICLE title="">
          <PARAGRAPH><![CDATA[두드러기, 고초열, 알레르기 비염]]></PARAGRAPH>
        </ARTICLE>
      </SECTION>
    </DOC>
    """
    assert xml_doc_to_text(raw) == "두드러기, 고초열, 알레르기 비염"


def test_permission_documents_map_to_official_context_fields():
    row = {
        "item_seq": "1",
        "item_name": "공식약정",
        "ee_doc_data": '<DOC><SECTION><PARAGRAPH><![CDATA[공식 효능]]></PARAGRAPH></SECTION></DOC>',
        "ud_doc_data": '<DOC><SECTION><PARAGRAPH><![CDATA[공식 복용법]]></PARAGRAPH></SECTION></DOC>',
        "nb_doc_data": '<DOC><SECTION title="주의사항"><ARTICLE title="이상반응"><PARAGRAPH><![CDATA[공식 이상반응]]></PARAGRAPH></ARTICLE></SECTION></DOC>',
    }
    medicine = product_to_medicine(row)
    assert medicine["efficacy"] == "공식 효능"
    assert medicine["usage"] == "공식 복용법"
    assert "공식 이상반응" in medicine["cautions"]
    assert medicine["side_effects"] == "공식 이상반응"


def test_side_effects_require_an_explicit_official_section_title():
    raw = '<DOC><SECTION title="주의사항"><PARAGRAPH><![CDATA[일반 주의 원문]]></PARAGRAPH></SECTION></DOC>'
    assert xml_doc_section_to_text(raw, ("이상반응", "부작용")) == ""
def test_xml_article_title_to_text():
    raw = """
    <DOC title="효능효과" type="EE">
      <SECTION title="">
        <ARTICLE title="1. 수술 후, 신경증에서의 불안, 긴장, 초조" />
        <ARTICLE title="2. 두드러기, 피부질환에 수반하는 가려움(습진, 피부염, 피부가려움증)" />
      </SECTION>
    </DOC>
    """
    text = xml_doc_to_text(raw)
    assert "불안, 긴장, 초조" in text
    assert "두드러기" in text
    assert "효능효과" not in text


def test_xml_title_and_cdata_keep_official_wording():
    raw = """
    <DOC title="효능효과" type="EE">
      <SECTION title="">
        <ARTICLE title="">
          <PARAGRAPH><![CDATA[&nbsp;]]></PARAGRAPH>
        </ARTICLE>
        <ARTICLE title="다음 질환의 진통 및 해열시 단기치료:">
          <PARAGRAPH><![CDATA[- 두통, 치통]]></PARAGRAPH>
        </ARTICLE>
      </SECTION>
    </DOC>
    """
    text = xml_doc_to_text(raw)
    assert "다음 질환의 진통 및 해열시 단기치료:" in text
    assert "두통, 치통" in text
    assert "&nbsp;" not in text


def test_xml_strips_html_tags():
    raw = '<ARTICLE title="위&lt;sup&gt;.&lt;/sup&gt;십이지장궤양" />'
    text = xml_doc_to_text(raw)
    assert "위" in text
    assert "십이지장궤양" in text
    assert "<sup>" not in text
    assert "&lt;" not in text


def test_permission_db_has_full_list():
    stats = count_stats()
    assert stats["total"] >= 40000


def test_permission_db_finds_primalan():
    names = search_permission_names("프리마란", limit=5)
    assert any("프리마란" in name for name in names)
