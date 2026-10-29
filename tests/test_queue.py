import sys
from pathlib import Path
import unittest
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
from queue_watchdog import ready_tasks


class QueueTests(unittest.TestCase):
    def test_dependency_gate(self):
        q = {'tasks': [{'id': 'a', 'status': 'done', 'depends_on': []},
                       {'id': 'b', 'status': 'queued', 'depends_on': ['a']},
                       {'id': 'c', 'status': 'queued', 'depends_on': ['b']}]}
        self.assertEqual(['b'], [x['id'] for x in ready_tasks(q)])
