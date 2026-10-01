# -*- coding: utf-8 -*-
import json
from app.core.config import MFDS_DRUG_PERMISSION_API_KEY, E_DRUG_API_KEY
from app.services.mfds_drug_permission.client import fetch_permission_list_page
from app.services.external_api_service import search_drug_info_by_name

out = {
    "MFDS_DRUG_PERMISSION_API_KEY_present": bool(MFDS_DRUG_PERMISSION_API_KEY),
    "E_DRUG_API_KEY_present": bool(E_DRUG_API_KEY),
    "permission": [],
    "e_drug": [],
}

perm_names = ["프리마란정", "프레벨액0.25%", "프레벨액", "프리마라정", "프레베넥액"]

for name in perm_names:
    try:
        data = fetch_permission_list_page(page_no=1, num_of_rows=5, item_name=name, timeout=15)
        header = (data.get("header") or {})
        body = (data.get("body") or {})
        items = body.get("items") or []
        if isinstance(items, dict):
            items = [items]
        brief = [{"ITEM_NAME": it.get("ITEM_NAME"), "ITEM_SEQ": it.get("ITEM_SEQ")} for it in items[:2]]
        out["permission"].append({
            "query": name,
            "ok": True,
            "resultCode": header.get("resultCode"),
            "resultMsg": header.get("resultMsg"),
            "totalCount": body.get("totalCount"),
            "first": brief,
        })
    except Exception as e:
        out["permission"].append({"query": name, "ok": False, "error_type": type(e).__name__, "error": str(e)[:300]})

for name in perm_names:
    try:
        data = search_drug_info_by_name(name, page_no=1, num_of_rows=10)
        items = data.get("items") or []
        names = []
        for it in items[:3]:
            names.append(it.get("itemName") or it.get("ITEM_NAME") or it.get("item_name"))
        out["e_drug"].append({
            "query": name,
            "ok": True,
            "count": data.get("count"),
            "match_type": data.get("match_type"),
            "first_names": names,
        })
    except Exception as e:
        out["e_drug"].append({"query": name, "ok": False, "error_type": type(e).__name__, "error": str(e)[:300]})

with open("_tmp_api_check_out.json", "w", encoding="utf-8") as f:
    json.dump(out, f, ensure_ascii=False, indent=2)
print("wrote _tmp_api_check_out.json")
