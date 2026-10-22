"""Tests for status.py. Run with: python3 -m unittest discover tests"""
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
import status  # noqa: E402

BLOCKED = """\
aur-audit blocked an AUR package on 2026-10-20 12:00:00 EDT
Stage: manual check (aur-audit check)

==> aur-audit: yyay 12.5.0-1
  [BLOCK] name is one letter away from popular package 'yay'
  -> HAZARDOUS: refusing to install.
     If you have reviewed it and trust it, add this line to /etc/aur-audit/allowlist:
       yyay 12.5.0-1
     Not sure? Have your AI assistant check whether it is actually malicious:
       aur-audit ai yyay

==> aur-audit: good-pkg 1.0-1
  [INFO] 120 votes
  -> passed

==> aur-audit: evil 2-1
  [BLOCK] curl | sh in install script
  -> HAZARDOUS: refusing to install.
     Not sure? Have your AI assistant check whether it is actually malicious:
       aur-audit ai /home/u/.cache/yay/evil;rm
"""

SCAN = """\
aur-audit system scan on 2026-10-20 12:00:00 EDT
SERIOUS = investigate now, CHECK = worth a look, INFO = background.

==> Installed files changed since install
  [SERIOUS] unowned setuid program: /tmp/x
  [CHECK] file contents changed since install: lutris: /usr/bin/lutris
  [CHECK] file contents changed since install: foo: /usr/bin/foo
  [INFO] 15 permission/owner/type differences
"""

REVIEW = "AI review of system by claude\n\nVERDICT: NO SIGNS OF COMPROMISE\n\nNothing found.\n"


class ParseTests(unittest.TestCase):
    def test_blocked_lists_only_hazardous_packages(self):
        pkgs = status.parse_blocked(BLOCKED)
        self.assertEqual([p["name"] for p in pkgs], ["yyay", "evil"])
        self.assertEqual(pkgs[0]["aiTarget"], "yyay")

    def test_unsafe_ai_target_is_dropped(self):
        self.assertEqual(status.parse_blocked(BLOCKED)[1]["aiTarget"], "")

    def test_safe_targets(self):
        self.assertEqual(status.safe_target("/home/u/.cache/yay/pkg"), "/home/u/.cache/yay/pkg")
        for bad in ["$(id)", "a b", "../x", "/a/../b", "~/x", "-rf", "x;y"]:
            self.assertEqual(status.safe_target(bad), "", bad)

    def test_scan_counts(self):
        self.assertEqual(status.parse_scan(SCAN), {"serious": 1, "check": 2})

    def test_verdict(self):
        self.assertEqual(status.parse_verdict(REVIEW), "NO SIGNS OF COMPROMISE")
        self.assertEqual(status.parse_verdict("**VERDICT: PROBABLY SAFE**"), "PROBABLY SAFE")
        self.assertEqual(status.parse_verdict("no verdict here"), "")


class SummaryTests(unittest.TestCase):
    def setUp(self):
        self.home = tempfile.mkdtemp()
        self.addCleanup(lambda: __import__("shutil").rmtree(self.home))
        self.seen = os.path.join(self.home, "seen")
        status.SEEN_FILE = self.seen

    def write(self, name, text, mtime):
        path = os.path.join(self.home, name)
        with open(path, "w") as f:
            f.write(text)
        os.utime(path, (mtime, mtime))

    def test_summary(self):
        self.write("aur-audit-system-scan-2026-10-19_10-00-00.txt", SCAN, 1000)
        self.write("aur-audit-blocked-2026-10-20_10-00-00.txt", BLOCKED, 3000)
        self.write("aur-audit-ai-review-yyay-2026-10-20_11-00-00.txt", REVIEW, 4000)
        self.write("aur-audit-ai-system-data-2026-10-19_10-00-00.txt", "data", 1001)
        self.write("notes.txt", "unrelated", 5000)
        with open(self.seen, "w") as f:
            f.write("2000")

        s = status.summary(self.home)
        self.assertEqual(s["reportCount"], 3)
        self.assertEqual([r["kind"] for r in s["reports"]], ["ai-review", "blocked", "system-scan"])
        self.assertEqual(s["reports"][0]["title"], "AI review of yyay")
        self.assertEqual(s["lastScan"]["serious"], 1)
        self.assertEqual(s["newBlocks"], 1)

        with open(self.seen, "w") as f:
            f.write("3000")
        self.assertEqual(status.summary(self.home)["newBlocks"], 0)


if __name__ == "__main__":
    unittest.main()
