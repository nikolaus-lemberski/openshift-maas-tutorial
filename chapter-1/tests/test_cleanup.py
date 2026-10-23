"""Exercise cleanup.sh with fake oc; never change a cluster.

Run: python3 -m unittest discover -s chapter-1/tests -v
"""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
FAKE_OC = r'''#!/usr/bin/env python3
import json, os, sys
a = sys.argv[1:]
with open(os.environ['CALL_LOG'], 'a') as f:
    f.write(json.dumps(a) + '\n')
if a[0] == 'auth': print('yes')
elif a[0] == 'whoami': print('admin')
elif a[0] == 'get' and a[1] == 'subscription':
    items = [
      {'metadata': {'namespace': 'kuadrant-system', 'name': 'rhcl-operator'}, 'spec': {'name': 'rhcl-operator'}},
      {'metadata': {'namespace': 'openshift-operators', 'name': 'authorino-operator'}, 'spec': {'name': 'authorino-operator'}},
      {'metadata': {'namespace': 'redhat-ods-operator', 'name': 'rhods-operator'}, 'spec': {'name': 'rhods-operator'}},
    ]
    if '-A' in a:
        print(json.dumps({'items': items}))
    elif a[1:3] == ['subscription', 'opentelemetry-product']:
        print('subscription.operators.coreos.com/opentelemetry-product')
    elif a[1:3] == ['subscription', 'cluster-observability-operator']:
        print('subscription.operators.coreos.com/cluster-observability-operator')
    else:
        sys.exit(0)
elif a[:3] == ['get', 'configmap', 'cluster-monitoring-config']:
    print('enableUserWorkload: true')
elif a[:3] == ['get', 'configmap', 'time-slicing-config']:
    sys.exit(0)
elif a[:3] == ['get', 'deployment', 'llama-32-3b-instruct-predictor']:
    print('0')
elif a[0] in ('delete', 'patch', 'scale', 'wait'):
    sys.exit(0)
'''


PROTECTED = (
    ['delete', 'gateway', 'data-science-gateway'],
    ['delete', 'gateway', 'openshift-ai-inference'],
    ['delete', 'route', 'data-science-gateway'],
    ['delete', 'route', 'rhods-dashboard'],
    ['delete', 'subscription', 'rhods-operator'],
    ['delete', 'subscription', 'gpu-operator-certified'],
    ['delete', 'subscription', 'authorino-operator'],
    ['delete', 'namespace', 'redhat-ods-applications'],
    ['delete', 'namespace', 'redhat-ods-monitoring'],
    ['delete', 'namespace', 'nvidia-gpu-operator'],
    ['delete', 'namespace', 'openshift-operators'],
    ['delete', 'namespace', 'ai-tenants'],
    ['delete', 'namespace', 'redhat-ai-gateway-infra'],
)


class CleanupTest(unittest.TestCase):
    def run_cleanup(self, *args):
        with tempfile.TemporaryDirectory() as directory:
            directory = Path(directory)
            fake_oc = directory / 'oc'
            fake_oc.write_text(FAKE_OC)
            fake_oc.chmod(0o755)
            log = directory / 'calls'
            env = dict(os.environ, PATH=f'{directory}:{os.environ["PATH"]}', CALL_LOG=str(log))
            result = subprocess.run(
                ['bash', str(ROOT / 'cleanup.sh'), *args],
                cwd=directory, env=env, text=True, capture_output=True, timeout=30)
            calls = [json.loads(line) for line in log.read_text().splitlines()] if log.exists() else []
            return result, calls

    def mutating(self, calls):
        return [c for c in calls if c and c[0] in ('delete', 'patch', 'scale')]

    def has_args(self, calls, *parts):
        return any(all(part in c for part in parts) for c in calls)

    def test_dry_run_makes_no_changes(self):
        result, calls = self.run_cleanup('--dry-run', '--yes')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.mutating(calls), [])
        self.assertIn('dry-run:', result.stdout)
        self.assertIn('maas-default-gateway', result.stdout)
        self.assertNotIn('Tutorial cleanup complete.', result.stdout)

    def test_does_not_delete_platform_components(self):
        result, calls = self.run_cleanup('--yes')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        mutating = self.mutating(calls)
        for forbidden in PROTECTED:
            self.assertFalse(
                any(c[0] == 'delete' and all(part in c for part in forbidden[1:]) for c in mutating),
                f'cleanup deleted protected resource {forbidden}: {mutating}')
        self.assertFalse(any('openshift-operators' in c for c in mutating))

    def test_deletes_tutorial_resources_and_restores_llama(self):
        result, calls = self.run_cleanup('--yes')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        mutating = self.mutating(calls)
        self.assertTrue(self.has_args(mutating, 'delete', 'gateway', 'maas-default-gateway'))
        self.assertTrue(self.has_args(mutating, 'delete', 'route', 'openshift-ai-inference'))
        self.assertTrue(self.has_args(mutating, 'delete', 'group', 'department-a'))
        self.assertTrue(self.has_args(mutating, 'delete', 'namespace', 'ai-models'))
        self.assertTrue(self.has_args(mutating, 'chapter-1/5-maas-db.yml'))
        self.assertTrue(self.has_args(mutating, 'chapter-1/0-connectivity-link.yml'))
        self.assertTrue(self.has_args(mutating, 'patch', 'datasciencecluster', 'default-dsc'))
        dsc_patch = next(c for c in mutating if c[0] == 'patch' and 'datasciencecluster' in c)
        payload = ' '.join(dsc_patch)
        self.assertIn('modelsAsAService', payload)
        self.assertNotIn('"managementState": "Removed"', payload.split('modelsAsAService')[0])
        self.assertTrue(self.has_args(mutating, 'delete', 'config.maas.opendatahub.io', 'default'))
        self.assertTrue(self.has_args(mutating, 'delete', 'namespace', 'models-as-a-service'))
        self.assertFalse(self.has_args(mutating, '--wait=false'))
        self.assertFalse(
            any(c[0] == 'wait' and any('config.maas.opendatahub.io' in x for x in c) for c in calls),
            'oc wait --for=delete on Config hangs: operator recreates it while MaaS is Managed')
        self.assertTrue(self.has_args(mutating, 'delete', 'persesdashboard'))
        self.assertTrue(self.has_args(mutating, 'storage-data-science-perses-0'))
        config_deletes = [i for i, c in enumerate(mutating) if 'config.maas.opendatahub.io' in c]
        dsc_i = next(i for i, c in enumerate(mutating) if c[0] == 'patch' and 'datasciencecluster' in c)
        self.assertGreaterEqual(len(config_deletes), 2, mutating)
        self.assertLess(config_deletes[0], dsc_i)
        self.assertGreater(config_deletes[-1], dsc_i)
        pvc_i = next(i for i, c in enumerate(mutating) if 'storage-data-science-perses-0' in c)
        coo_i = next(i for i, c in enumerate(mutating) if 'chapter-1/coo-subscription.yml' in c)
        perses_i = max(i for i, c in enumerate(mutating) if 'persesdashboard' in c)
        self.assertLess(pvc_i, coo_i)
        self.assertLess(coo_i, perses_i)
        self.assertTrue(self.has_args(mutating, 'scale', 'llama-32-3b-instruct-predictor'))
        self.assertIn('Tutorial cleanup complete.', result.stdout)

    def test_keep_operators_skips_rhcl_and_observability_uninstall(self):
        result, calls = self.run_cleanup('--yes', '--keep-operators', '--keep-demo-model')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        mutating = self.mutating(calls)
        self.assertFalse(any('0-connectivity-link.yml' in c for c in mutating))
        self.assertFalse(any('opentelemetry-subscription.yml' in c for c in mutating))
        self.assertFalse(any('coo-subscription.yml' in c for c in mutating))
        self.assertFalse(any(c[0] == 'scale' for c in mutating))
        self.assertTrue(self.has_args(mutating, 'delete', 'kuadrant', 'kuadrant'))


if __name__ == '__main__':
    unittest.main()
