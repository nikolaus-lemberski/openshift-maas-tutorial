"""Exercise the actual installer with fake oc/curl; never change a cluster.

Run: python3 -m unittest discover -s chapter-1/tests -v
Requires the installer's local tools (Bash, jq, envsubst).
"""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
FAKE_OC = r'''#!/usr/bin/env python3
import json, os, re, sys
a = sys.argv[1:]
scenario = os.environ['SCENARIO']
with open(os.environ['CALL_LOG'], 'a') as f:
    f.write(json.dumps(a) + '\n')
if a[0] == 'auth': print('yes')
elif a[0] == 'whoami': print('admin')
elif scenario == 'verify-failure' and '--timeout=5s' in a:
    sys.exit(1)
elif a[0] == 'exec' and scenario == 'tenant-discovery-failure':
    sys.exit(1)
elif a[0] == 'logs':
    if scenario == 'logs-failure': sys.exit(1)
    print('limitador operator is not installed, skipping related watches and reconcilers'
          if scenario == 'stale' else 'Starting Controller')
elif a[0] == 'get':
    resource = a[1]
    if resource == 'clusterversion': print('4.20.41')
    elif resource == 'csv': print('3.5.1')
    elif resource == 'subscription':
        if '-A' in a:
            items = [] if scenario == 'fresh' else [{'metadata': {'namespace': 'operators', 'name': 'rhcl'}, 'spec': {'name': 'rhcl-operator'}}]
            print(json.dumps({'items': items}))
        else: print('operator.v3.5.1')
    elif resource == 'storageclass':
        print(json.dumps({'items': [] if scenario == 'no-storage' else [
          {'metadata': {'annotations': {'storageclass.kubernetes.io/is-default-class': 'true'}}}]}))
    elif resource == 'gatewayclass':
        print(json.dumps({'items': [{'metadata': {'name': 'demo-class'}, 'spec': {'controllerName': 'openshift.io/gateway-controller/v1'}}]}))
    elif resource == 'crd' and a[2] == 'kuadrants.kuadrant.io':
        if scenario == 'lookup-failure': sys.exit(1)
        if scenario == 'other-kuadrant': print('crd/kuadrants.kuadrant.io')
    elif resource == 'kuadrant':
        print(json.dumps({'items': [{'metadata': {'namespace': 'other-system', 'name': 'existing'}}]}))
    elif resource == 'nodes':
        print(json.dumps({'items': [{'metadata': {'name': 'gpu-node'}, 'spec': {},
          'status': {'allocatable': {'nvidia.com/gpu': '4'}, 'conditions': [{'type': 'Ready', 'status': 'True'}]}}]}))
    elif resource == 'pods':
        print(json.dumps({'items': [{'spec': {'nodeName': 'gpu-node', 'containers': [{'resources': {'requests': {'nvidia.com/gpu': '4'}}}]},
          'status': {'phase': 'Running'}}] if scenario == 'gpu-busy' else []}))
    elif resource == 'deployment' and '-A' in a:
        print(json.dumps({'items': [{'metadata': {'name': name, 'namespace': 'operators'}} for name in [
          'limitador-operator-controller-manager', 'dns-operator-controller-manager', 'kuadrant-operator-controller-manager']]}))
    elif resource == 'deployment': print('deployment/llama-32-3b-instruct-predictor')
    elif resource == 'configmap':
        config = 'enableUserWorkload: false\nprometheusK8s:\n  retention: 10d\n'
        if '-o' in a and a[a.index('-o') + 1] == 'json':
            print(json.dumps({'data': {'config.yaml': config}}))
        else: print('enableUserWorkload: true')
    elif resource == 'datasciencecluster': print('Managed')
    elif resource == 'authorino': print('true')
    elif resource == 'odhdashboardconfig':
        print(json.dumps({'spec': {'dashboardConfig': {'modelAsService': True, 'genAiStudio': True, 'observabilityDashboard': True}}}))
    elif resource == 'route':
        if scenario != 'missing-route-host': print('inference.example.test')
    elif resource == 'gateway':
        print(json.dumps({'spec': {'listeners': [
          {'name': 'http', 'hostname': 'inference.example.test'},
          {'name': 'https', 'protocol': 'HTTPS', 'hostname': 'inference.example.test'},
          {'name': 'https-router', 'protocol': 'HTTPS', 'port': 443}]}}))
elif a[0] == 'create': print('{}')
elif a[0] == 'apply' and a[-1] == '-':
    manifest = sys.stdin.read()
    with open(os.environ['CALL_LOG'], 'a') as f:
        f.write(json.dumps(['manifest', manifest]) + '\n')
    if 'kind: Gateway\n' in manifest:
        # Model the API's listener uniqueness validation on the actual rendered
        # manifest. Only parse the scalar fields needed for this constraint.
        listeners = re.split(r'(?m)^  - name: ', manifest.split('  listeners:\n')[1])[1:]
        keys = []
        for listener in listeners:
            fields = dict(re.findall(r'(?m)^    (port|protocol|hostname):\s*([^\n]+)', listener))
            keys.append(tuple(fields.get(key, '') for key in ['port', 'protocol', 'hostname']))
        if len(keys) != len(set(keys)):
            print('Combination of port, protocol and hostname must be unique for each listener', file=sys.stderr)
            sys.exit(1)
'''


class InstallerTest(unittest.TestCase):
    def run_installer(self, scenario='healthy', *args):
        with tempfile.TemporaryDirectory() as directory:
            directory = Path(directory)
            fake_oc = directory / 'oc'
            fake_oc.write_text(FAKE_OC)
            fake_oc.chmod(0o755)
            fake_curl = directory / 'curl'
            fake_curl.write_text('#!/bin/sh\nif [ "$SCENARIO" = gateway-down ]; then printf 503; else printf 401; fi\n')
            fake_curl.chmod(0o755)
            log = directory / 'calls'
            env = dict(os.environ, PATH=f'{directory}:{os.environ["PATH"]}',
                       SCENARIO=scenario, CALL_LOG=str(log))
            result = subprocess.run(['bash', str(ROOT / 'chapter-1/install.sh'), *args],
                                    cwd=directory, env=env, text=True, capture_output=True, timeout=30)
            calls = [json.loads(line) for line in log.read_text().splitlines()] if log.exists() else []
            return result, calls

    def test_install_and_verify_from_another_working_directory(self):
        result, calls = self.run_installer()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('Chapter 1 complete.', result.stdout)
        self.assertFalse(any(c[:2] == ['delete', 'pod'] for c in calls))
        self.assertFalse(any(c[0] == 'scale' or c[:2] == ['patch', 'clusterpolicy'] for c in calls))
        self.assertFalse(any('chapter-1/0-connectivity-link.yml' in c for c in calls))
        patches = [json.loads(c[c.index('-p') + 1]) for c in calls
                   if c[:3] == ['patch', 'configmap', 'cluster-monitoring-config']]
        self.assertEqual(patches[0]['data']['config.yaml'],
                         'enableUserWorkload: true\nprometheusK8s:\n  retention: 10d')
        tenant_patch = next(c for c in calls if c[:2] == ['patch', 'maastenantconfig'])
        metrics = json.loads(tenant_patch[tenant_patch.index('-p') + 1])['spec']['telemetry']['metrics']
        self.assertNotIn('captureUser', metrics)

    def test_fresh_install_applies_operator_before_preflight_and_instance(self):
        result, calls = self.run_installer('fresh')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        operator = next(i for i, c in enumerate(calls) if 'chapter-1/0-connectivity-link.yml' in c)
        dependency = next(i for i, c in enumerate(calls) if 'crd/limitadors.limitador.kuadrant.io' in c)
        instance = next(i for i, c in enumerate(calls) if 'chapter-1/1-kuadrant.yml' in c)
        self.assertLess(operator, dependency)
        self.assertLess(dependency, instance)

    def test_gateway_is_created_with_route_hostname(self):
        result, calls = self.run_installer('fresh')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        gateway = next(i for i, c in enumerate(calls)
                       if c[0] == 'manifest' and 'kind: Gateway\n' in c[1])
        route = next(i for i, c in enumerate(calls)
                     if c[0] == 'manifest' and 'kind: Route\n' in c[1])
        self.assertLess(route, gateway)
        self.assertEqual(calls[gateway][1].count('hostname: inference.example.test'), 2)
        fallback = calls[gateway][1].split('  - name: https-router\n')[1]
        self.assertNotIn('hostname:', fallback)

    def test_missing_route_hostname_stops_before_gateway_creation(self):
        result, calls = self.run_installer('missing-route-host')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('inference Route has no hostname', result.stderr)
        self.assertFalse(any(c[0] == 'manifest' and 'kind: Gateway\n' in c[1] for c in calls))

    def test_stale_discovery_is_refreshed_before_applying_kuadrant(self):
        result, calls = self.run_installer('stale')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        restart = next(i for i, c in enumerate(calls) if c[:2] == ['delete', 'pod'])
        apply = next(i for i, c in enumerate(calls) if 'chapter-1/1-kuadrant.yml' in c)
        self.assertLess(restart, apply)
        self.assertIn('operators', calls[restart])

    def test_failed_prerequisites_make_no_changes(self):
        for scenario in ['gpu-busy', 'no-storage', 'other-kuadrant', 'lookup-failure']:
            with self.subTest(scenario=scenario):
                result, calls = self.run_installer(scenario)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(any(c[0] in ['apply', 'patch', 'create', 'delete', 'scale'] for c in calls))

    def test_check_only_makes_no_changes(self):
        result, calls = self.run_installer('healthy', '--check-only')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse(any(c[0] in ['apply', 'patch', 'create', 'delete', 'scale'] for c in calls))
        self.assertNotIn('Chapter 1 complete.', result.stdout)

    def test_log_read_failure_prevents_instance_creation(self):
        result, calls = self.run_installer('logs-failure')
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(any('chapter-1/1-kuadrant.yml' in c for c in calls))

    def test_failed_verification_never_reports_completion(self):
        result, _ = self.run_installer('verify-failure')
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('Chapter 1 complete.', result.stdout)
        self.assertIn('FAIL', result.stdout)

    def test_unreachable_maas_gateway_never_reports_completion(self):
        result, _ = self.run_installer('gateway-down')
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('Chapter 1 complete.', result.stdout)
        self.assertIn('HTTP 503', result.stdout)

    def test_failed_tenant_discovery_never_reports_completion(self):
        result, _ = self.run_installer('tenant-discovery-failure')
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('Chapter 1 complete.', result.stdout)
        self.assertIn('FAIL', result.stdout)

    def test_gpu_options_are_explicit(self):
        result, calls = self.run_installer('healthy', '--gpu-time-slicing', '--scale-down-demo-model')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue(any('chapter-1/gpu-time-slicing.yml' in c for c in calls))
        self.assertTrue(any(c[:2] == ['patch', 'clusterpolicy'] for c in calls))
        self.assertTrue(any(c[:2] == ['scale', 'deployment'] for c in calls))

    def test_check_only_rejects_mutating_options(self):
        result, calls = self.run_installer('healthy', '--check-only', '--gpu-time-slicing')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(calls, [])


if __name__ == '__main__':
    unittest.main()
