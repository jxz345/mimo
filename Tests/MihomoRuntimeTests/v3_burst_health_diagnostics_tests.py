#!/usr/bin/env python3
"""Pure checks for retained burst-health inputs; no VM or fixture access."""
import ast
import copy
from pathlib import Path
from types import SimpleNamespace
import unittest

HERE = Path(__file__).resolve().parent


def functions(path, names, namespace):
    tree = ast.parse(path.read_text())
    tree.body = [node for node in tree.body if isinstance(node, ast.FunctionDef) and node.name in names]
    exec(compile(tree, str(path), 'exec'), namespace)


class HealthDiagnostics(unittest.TestCase):
    def setUp(self):
        self.clock = SimpleNamespace(time=lambda: 978307300.0)
        namespace = {'time': self.clock}
        functions(HERE / 'v3_service_command_test.py', {'healthy'}, namespace)
        namespace['service'] = SimpleNamespace(healthy=namespace['healthy'])
        functions(HERE / 'v3_observation_burst_test.py', {'health_sample'}, namespace)
        self.sample = namespace['health_sample']
        self.state = {'status': {'ready': {}}, 'routing': {
            'configuration': {'mode': 'rule'}, 'phase': 'active', 'heartbeatHealth': 'healthy',
            'heartbeatCheckedAt': 99.0, 'infrastructure': {'pf': 'healthy', 'launchd': 'healthy', 'checkedAt': 90.0},
            'services': [{'id': 'mihomo', 'health': 'running', 'checkedAt': 95.0, 'address': 'private-unused'}]}}

    def testHealthyInputsAndPrivateFieldExclusion(self):
        result = self.sample(self.state, 1)
        self.assertTrue(result['healthy'])
        self.assertEqual(result['failed_components'], [])
        self.assertEqual(result['infrastructure_age_end_seconds'], 10)
        self.assertNotIn('address', result['services'][0])

    def testExactThirtyFiveSecondThresholdUnchanged(self):
        self.state['routing']['infrastructure']['checkedAt'] = 65.0
        result = self.sample(self.state, 1)
        self.assertFalse(result['healthy'])
        self.assertEqual(result['failed_components'], ['infrastructure_age'])

    def testDeferredInspectionAgeIsDistinguishedFromFailedPf(self):
        self.state['routing']['infrastructure']['checkedAt'] = 64.0
        result = self.sample(self.state, 1)
        self.assertFalse(result['healthy'])
        self.assertEqual(result['infrastructure']['pf'], 'healthy')
        self.assertEqual(result['failed_components'], ['infrastructure_age'])

    def testHeartbeatFailureIsRetained(self):
        self.state['routing']['heartbeatHealth'] = 'stale'
        result = self.sample(self.state, 1)
        self.assertFalse(result['healthy'])
        self.assertEqual(result['failed_components'], ['heartbeat'])

    def testPfFailureIsRetained(self):
        self.state['routing']['infrastructure']['pf'] = 'failed'
        result = self.sample(self.state, 1)
        self.assertFalse(result['healthy'])
        self.assertEqual(result['failed_components'], ['pf'])

    def testLaunchdFailureIsRetained(self):
        self.state['routing']['infrastructure']['launchd'] = 'unknown'
        result = self.sample(self.state, 1)
        self.assertFalse(result['healthy'])
        self.assertEqual(result['failed_components'], ['launchd'])

    def testSamplingBoundaryRetainsBothClockBounds(self):
        self.state['routing']['infrastructure']['checkedAt'] = 65.0
        values = iter([978307299.999, 978307300.0, 978307300.001])
        self.clock.time = lambda: next(values)
        result = self.sample(self.state, 1)
        self.assertFalse(result['healthy'])
        self.assertLess(result['infrastructure_age_start_seconds'], 35)
        self.assertGreater(result['infrastructure_age_end_seconds'], 35)


if __name__ == '__main__':
    unittest.main()
