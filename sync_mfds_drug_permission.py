"""Download MFDS drug permission API into mfds_drug_permission.db."""

from __future__ import annotations

import argparse

from app.services.mfds_drug_permission.db import DB_PATH, count_stats, initialize_permission_db
from app.services.mfds_drug_permission.sync import (
    seed_permission_sample,
    sync_permission_details,
    sync_permission_list,
)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--mode",
        choices=("list", "detail", "all", "sample"),
        default="all",
        help="list=목록만, detail=미동기화 상세만, all=목록 후 상세",
    )
    parser.add_argument("--page-size", type=int, default=500)
    parser.add_argument(
        "--max-detail",
        type=int,
        default=None,
        help="상세 동기화 최대 건수 (개발계정 일일 한도 고려)",
    )
    args = parser.parse_args()

    path = initialize_permission_db()
    print("db =", path)
    print("path env default =", DB_PATH)

    if args.mode == "sample":
        result = seed_permission_sample(
            target=100,
            batch_size=4,
            sleep_seconds=2.5,
            progress=print,
        )
        print("sample result:", result)
        print("final stats:", count_stats())
        return

    if args.mode in {"list", "all"}:
        result = sync_permission_list(
            page_size=args.page_size,
            progress=print,
        )
        print("list result:", result)

    if args.mode in {"detail", "all"}:
        result = sync_permission_details(
            max_items=args.max_detail,
            progress=print,
        )
        print("detail result:", result)

    print("final stats:", count_stats())


if __name__ == "__main__":
    main()
