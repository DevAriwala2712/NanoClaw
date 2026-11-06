import subprocess
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


class ReadmeBadges(unittest.TestCase):
    def test_readme_badges_match_evidence(self):
        r = subprocess.run([sys.executable, str(ROOT / "scripts" / "update_badges.py"), "--check"], cwd=ROOT)
        self.assertEqual(r.returncode, 0, "README badges are stale: run python3 scripts/update_badges.py")


if __name__ == "__main__":
    unittest.main()
