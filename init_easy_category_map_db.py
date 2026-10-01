"""Create/refresh easy_category_map.db seed rows."""

from app.services.pharmacist.easy_category_db import (
    DB_PATH,
    initialize_easy_category_map_db,
    list_chat_link_rows,
    list_map_rows,
)


def main() -> None:
    path = initialize_easy_category_map_db(reset_seed=True)
    rows = list_map_rows()
    links = list_chat_link_rows()
    print("db =", path)
    print("category_map rows =", len(rows))
    print("chat_links rows =", len(links))
    for row in rows[:8]:
        print(
            f"  [cat/{row['match_scope']}] {row['official_phrase']} → {row['easy_label']}"
        )
    for row in links[:12]:
        print(
            f"  [chat/{row['link_type']}] {row['trigger']} → {row['link_value']}"
        )


if __name__ == "__main__":
    main()
