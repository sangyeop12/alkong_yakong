import os
import sqlite3
import tempfile
import unittest
from unittest.mock import patch

import init_db


class DatasetSchemaInitTest(unittest.TestCase):
    def test_existing_initializer_creates_dataset_tables_in_temporary_db(self):
        handle, path = tempfile.mkstemp(suffix=".db")
        os.close(handle)
        try:
            with patch.object(init_db, "DB_PATH", path):
                init_db.initialize_database()
            conn = sqlite3.connect(path)
            tables = {row[0] for row in conn.execute("SELECT name FROM sqlite_master WHERE type='table'")}
            conn.close()
            self.assertIn("biosignal_test_sessions", tables)
            self.assertIn("biosignal_test_samples", tables)
        finally:
            os.remove(path)


if __name__ == "__main__":
    unittest.main()
