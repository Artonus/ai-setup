import json
from pathlib import Path
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "tools/lib/merge-tracks.py"


class MergeTracksTest(unittest.TestCase):
    def setUp(self):
        self.sandbox = tempfile.TemporaryDirectory(prefix="merge-tracks-test-")
        self.addCleanup(self.sandbox.cleanup)
        self.dir = Path(self.sandbox.name)

    def merge(self, remote, me):
        a, b = self.dir / "remote.json", self.dir / "me.json"
        a.write_text(json.dumps(remote))
        b.write_text(json.dumps(me))
        return subprocess.run(["python3", str(SCRIPT), "Remote", str(a), "Me", str(b)],
                              check=True, capture_output=True, text=True).stdout.rstrip("\n")

    def test_interleaves_speakers_by_word_time(self):
        remote = {"segments": [{"start": 0.0, "end": 4.0, "text": " Hello there. How are you?", "words": [
            {"start": 0.0, "end": 0.5, "word": " Hello"}, {"start": 0.5, "end": 1.0, "word": " there."},
            {"start": 3.0, "end": 3.5, "word": " How"}, {"start": 3.5, "end": 3.8, "word": " are"},
            {"start": 3.8, "end": 4.0, "word": " you?"}]}]}
        me = {"segments": [{"start": 1.5, "end": 2.5, "text": " Hi, good.", "words": [
            {"start": 1.5, "end": 2.0, "word": " Hi,"}, {"start": 2.0, "end": 2.5, "word": " good."}]},
            {"start": 3605.0, "end": 3606.0, "text": " Bye.", "words": []}]}
        # Turns alternate in time order; segments without words still appear.
        self.assertEqual(self.merge(remote, me), "[00:00] Remote: Hello there.\n"
                                                 "[00:01] Me: Hi, good.\n"
                                                 "[00:03] Remote: How are you?\n"
                                                 "[1:00:05] Me: Bye.")

    def test_handles_an_empty_track(self):
        remote = {"segments": [{"start": 2, "end": 3, "text": " Only them.",
                                "words": [{"start": 2, "end": 3, "word": " Only them."}]}]}
        self.assertEqual(self.merge(remote, {"segments": []}), "[00:02] Remote: Only them.")


if __name__ == "__main__":
    unittest.main()
