"""Synthetic in-memory data only; no init_db execution or external lookup."""
import sqlite3
import unittest
from contextlib import ExitStack
from unittest.mock import Mock, patch

from init_db import TABLE_DEFINITIONS
from app.services import medicine_detail_service as detail
from app.services import drug_explain_service as display
from app.services import prescription_service as prescription
from app.services.pharmacist import retrieve
from app.services.medicine_detail_providers import find_reviewed_ingredient_explanations


class DetailIntegrityTest(unittest.TestCase):
    def setUp(self):
        self.db = sqlite3.connect(':memory:')
        self.db.row_factory = sqlite3.Row
        self.addCleanup(self.db.close)
        for table in ('medicines', 'ai_explanation_cards', 'ingredient_explanations',
                      'medicine_detail_profiles', 'medicine_detail_jobs'):
            self.db.execute(TABLE_DEFINITIONS[table])
        self.stack = ExitStack()
        self.addCleanup(self.stack.close)
        self.stack.enter_context(patch('socket.create_connection', side_effect=AssertionError('network forbidden')))
        self.stack.enter_context(patch('app.services.mfds_drug_permission.db.find_permission_product_by_item_seq', return_value=None))
        self.db.execute("INSERT INTO medicines(medicine_code, product_name, ingredient, efficacy, usage, precautions) VALUES ('test-A','합성 제품','합성성분','성인: 증상 가에 사용한다.','0.5 mg','소아 금지')")

    def medicine(self):
        return dict(self.db.execute("SELECT * FROM medicines WHERE medicine_code='test-A'").fetchone())

    def review(self):
        detail.ensure_medicine_detail(self.db, 'test-A')
        self.db.execute("INSERT INTO ai_explanation_cards(medicine_code, summary, review_status, ingredient_explanation, approved_uses) VALUES ('test-A','검토된 설명','REVIEWED','검토된 설명이에요.','[\"성인: 증상 가에 사용한다.\"]')")
        return detail.ensure_medicine_detail(self.db, 'test-A')

    def test_exact_dedup_preserves_numbers_conditions_and_order(self):
        values = ['성인에게 1~2 mg을 사용한다.', '성인에게 12 mg을 사용한다.',
                  '0.5 mg', '5 mg', '10 미만', '10 이하', '10 이상', '10 초과',
                  '사용', '사용하지 않음', '성인', '소아', '사용. 단 예외는 제외', '사용.']
        self.assertEqual(detail._deduplicate_items(values + [' '+values[0]+' ']), values)
        self.assertEqual(detail._without_summary_duplicate(values, values[0]), values[1:])

    def test_source_change_invalidates_review_before_rebuild_and_read(self):
        profile = self.review()
        self.assertEqual(profile['review_status'], 'REVIEWED')
        self.assertEqual(profile['ingredient_explanation'], '검토된 설명이에요.')
        self.assertEqual(self.db.execute('SELECT count(*) FROM ingredient_explanations').fetchone()[0], 0)
        self.db.execute("UPDATE medicines SET usage='5 mg' WHERE medicine_code='test-A'")
        payload = display.reviewed_detail_payload(self.db, self.medicine())
        self.assertEqual(payload['explanation']['status'], 'OUTDATED')
        self.assertEqual(payload['explanation']['ingredient_explanation'], '')
        self.assertEqual(payload['official_usage']['text'], '5 mg')
        result = detail.ensure_medicine_detail(self.db, 'test-A')
        self.assertNotEqual(result['review_status'], 'REVIEWED')
        self.assertEqual(self.db.execute('SELECT review_status FROM ai_explanation_cards').fetchone()[0], 'OUTDATED')
        self.assertNotEqual(detail.ensure_medicine_detail(self.db, 'test-A')['review_status'], 'REVIEWED')

    def test_fingerprint_preserves_all_official_differences(self):
        original = self.medicine()
        for field in ('medicine_code','product_name','ingredient','efficacy','usage','precautions','manufacturer'):
            with self.subTest(field=field):
                self.assertNotEqual(detail.official_source_hash(original), detail.official_source_hash({**original, field: '다른 값'}))

    def test_legacy_unbound_review_not_automatically_promoted(self):
        self.db.execute("INSERT INTO ai_explanation_cards(medicine_code, summary, review_status) VALUES ('test-A','과거 설명','REVIEWED')")
        self.assertEqual(display.reviewed_detail_payload(self.db, self.medicine())['explanation']['status'], 'PENDING')
        self.assertNotEqual(detail.ensure_medicine_detail(self.db,'test-A')['review_status'], 'REVIEWED')

    def test_exact_ingredient_not_alias_or_compound_substitution(self):
        self.db.execute("INSERT INTO ingredient_explanations(normalized_key, ingredient_name, explanation, review_status, source_verified) VALUES ('합성성분','다른 성분','작용을 돕는 성분이에요.','REVIEWED',1)")
        entries = detail.ingredient_entries('합성성분')
        self.assertEqual(find_reviewed_ingredient_explanations(self.db, entries), {})
        self.db.execute("UPDATE ingredient_explanations SET ingredient_name='합성성분'")
        self.assertTrue(find_reviewed_ingredient_explanations(self.db, entries))
        self.assertEqual(find_reviewed_ingredient_explanations(self.db, []), {})
        self.assertEqual(display._ingredient_highlight(self.db, {'ingredient':'합성성분; 다른성분'}, '작용을 돕는 성분이에요.'), '')

    def test_partial_update_preserves_existing_information_and_other_code(self):
        prescription._upsert_official_medicine(self.db, {'medicine': {'medicine_code':'test-A','product_name':'합성 제품'}})
        self.assertEqual(self.medicine()['usage'], '0.5 mg')
        prescription._upsert_official_medicine(self.db, {'medicine': {'medicine_code':'test-B','product_name':'합성 제품','ingredient':'합성성분'}})
        self.assertEqual(self.db.execute('SELECT count(*) FROM medicines').fetchone()[0], 2)
        self.assertEqual(self.medicine()['precautions'], '소아 금지')

    def test_permission_wrong_product_cannot_hydrate(self):
        with patch('app.services.mfds_drug_permission.db.find_permission_product_by_item_seq', return_value={'item_seq':'other'}), patch('app.services.mfds_drug_permission.db.product_to_medicine', return_value={'medicine_code':'other','ingredient':'다른성분'}):
            med = {**self.medicine(), 'ingredient':''}
            self.assertEqual(detail._hydrate_from_local_permission(self.db, med)['ingredient'], '')

    def test_lookup_failure_preserves_official_data(self):
        with patch('app.services.mfds_drug_permission.db.find_permission_product_by_item_seq', side_effect=RuntimeError('synthetic')):
            before = self.medicine()
            self.assertEqual(detail._hydrate_from_local_permission(self.db, before), before)

    def test_local_dur_failure_is_unknown_not_false(self):
        with patch('app.services.dur_service.analyze_dur', side_effect=RuntimeError('synthetic')):
            result = prescription._analyze_registered_medicines_locally('synthetic')
        self.assertIsNone(result['has_risk'])
        self.assertFalse(result['analysis_complete'])

    def test_profile_preparation_rolls_back_with_registration_savepoint(self):
        self.db.commit()
        before = self.medicine()
        with patch.object(prescription, 'ensure_medicine_detail', side_effect=RuntimeError('synthetic')):
            prescription._prepare_detail_without_blocking(self.db, 'test-A')
        self.assertEqual(self.medicine(), before)
        self.assertEqual(self.db.execute('SELECT status FROM medicine_detail_jobs').fetchone()[0], 'FAILED')

    def test_exact_provider_does_not_review_entire_product(self):
        self.db.execute("INSERT INTO ingredient_explanations(normalized_key,ingredient_name,explanation,review_status,source_verified) VALUES ('합성성분','합성성분','작용을 돕는 성분이에요.','REVIEWED',1)")
        result = detail.ensure_medicine_detail(self.db, 'test-A')
        self.assertEqual(result['ingredient_explanation'], '작용을 돕는 성분이에요.')
        self.assertNotEqual(result['review_status'], 'REVIEWED')

    def test_official_document_conditions_are_not_split_or_expanded(self):
        original = '성인에게만 사용한다.\n증상 가, 증상 나; 단, 소아에는 사용하지 않는다. 0.5 mg 이하.'
        result = detail._parse_official_purposes(original)
        self.assertEqual(result['all'], [original])
        self.assertEqual(result['representative'], [original])
        self.assertEqual(detail._parse_official_purposes('치통')['all'], ['치통'])
        self.assertNotIn('생리통', str(detail._parse_official_purposes('치통')))
        self.assertEqual(detail._parse_official_purposes('수치 < 5 또는 > 12')['all'], ['수치 < 5 또는 > 12'])

    def test_registration_keeps_saved_status_for_incomplete_and_refresh_failure(self):
        for raw in (None, {}, {'matches':[]}, {'analysis_complete':True,'matches':None},
                    {'assessment_status':'INCOMPLETE','has_risk':False,'matches':[]}):
            with self.subTest(raw=raw), patch.object(prescription, '_analyze_registered_medicines_locally', return_value=raw), patch('app.services.dur_sync_service.start_background_user_dur_refresh', side_effect=RuntimeError('synthetic')):
                result = prescription._registration_result(prescription_id='synthetic',user_id='synthetic',items=[])
                self.assertTrue(result['registered'])
                self.assertFalse(result['dur_refresh_started'])
                self.assertEqual(result['dur_result']['assessment_status'], 'INCOMPLETE')
                self.assertIsNone(result['dur_result']['has_risk'])

    def test_registration_preserves_complete_zero_and_risk_results(self):
        for matches in ([], [{'type':'병용금기'}]):
            raw = {'analysis_complete':True,'has_risk':bool(matches),
                   'assessment_status':'RISK_FOUND' if matches else 'SAFE','matches':matches}
            with patch.object(prescription, '_analyze_registered_medicines_locally', return_value=raw), patch('app.services.dur_sync_service.start_background_user_dur_refresh', return_value=False):
                result = prescription._registration_result(prescription_id='synthetic',user_id='synthetic',items=[])
                self.assertEqual(result['dur_result'], raw)

    def test_compound_group_requires_every_component_to_be_reviewed_as_group(self):
        entries = [{'key':'a','name':'성분가'}, {'key':'b','name':'성분나'}]
        rows = {'a':{'explanation':'가의 작용이에요.','role_group':'g','group_explanation':'복합 작용이에요.'},
                'b':{'explanation':'나의 작용이에요.','role_group':'','group_explanation':''}}
        result = detail._compose_reviewed_ingredient_explanation(entries, rows)
        self.assertIn('성분가: 가의 작용이에요.', result)
        self.assertIn('성분나: 나의 작용이에요.', result)
        self.assertNotIn('복합 작용', result)

    def test_app_and_registration_upserts_use_same_preparation_policy(self):
        conn = Mock(wraps=self.db)
        conn.close = Mock()
        official = {'medicine':{'medicine_code':'test-A','product_name':'합성 제품','ingredient':'새성분','usage':'5 mg'}}
        with patch('app.database.get_connection', return_value=conn), patch('app.services.pharmacist.easy_category.sync_medicine_guidance'):
            self.assertEqual(retrieve.upsert_official_app_medicine(official), 'test-A')
        app_profile = detail.get_medicine_detail_profile(self.db, 'test-A')
        prescription._upsert_official_medicine(self.db, official)
        registration_profile = detail.get_medicine_detail_profile(self.db, 'test-A')
        for field in ('source_hash', 'ingredient_keys','ingredient_explanation','review_status'):
            self.assertEqual(app_profile[field], registration_profile[field])
        self.assertEqual(self.medicine()['ingredient'], '새성분')
        self.assertEqual(self.medicine()['efficacy'], '성인: 증상 가에 사용한다.')

    def test_background_name_match_does_not_update_another_product(self):
        conn = Mock(wraps=self.db)
        conn.close = Mock()
        before = self.medicine()
        with patch('app.database.get_connection', return_value=conn), patch.object(retrieve, '_retrieve_for_app_medicine', return_value={'medicine':{'medicine_code':'other','efficacy':'다른 제품 효능'}}), patch('app.services.pharmacist.easy_category.backfill_all_medicine_guidance'):
            self.assertEqual(retrieve.refresh_app_medicines_from_permission(),0)
        self.assertEqual(self.medicine(),before)


if __name__ == '__main__':
    unittest.main()
