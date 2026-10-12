"""Local checks of the verifier; these do not substitute for live AWS tests."""
import base64
import contextlib
import io
import json
from pathlib import Path
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

import poc


class VerifierTests(unittest.TestCase):
    def run_verifier(self, missing_status=False, denied_invocation=False, allowed=True, verified=True, wrong_decision=False):
        cfg = {'aws_region': 'ap-northeast-1', 'google_client_id': 'test-client', 'api_endpoint': 'https://example.invalid',
               'api_log_group': 'gateway', 'lambda_log_group': 'lambda', 'secondary_lambda_log_group': 'secondary-lambda'}
        payload = {'iss': 'https://accounts.google.com', 'aud': 'test-client',
                   'exp': int(time.time()) + 3600, 'iat': int(time.time()) - 5,
                   'sub': 'test-sub', 'email': 'allowed@example.invalid' if allowed else 'other@example.invalid', 'email_verified': verified}
        token = 'fixture.' + base64.urlsafe_b64encode(json.dumps(payload).encode()).decode().rstrip('=') + '.signature'
        responses = []
        for endpoint in ('private', 'secondary'):
            body = {'message': 'Hello from the first Lambda!' if endpoint == 'private' else 'Hello from the second Lambda!', 'request_id': endpoint + '_valid'}
            responses.extend([(401, {}, endpoint + '_no_header'), (403, {}, endpoint + '_random'),
                              (403, {}, endpoint + '_broken'),
                              (200 if allowed and verified else 403,
                               body if allowed and verified else {'message': 'Forbidden'}, endpoint + '_valid')])
        gateway = {rid: {'status': str(status), 'integrationStatus': '200' if status == 200 else '-'}
                   for status, _, rid in responses}
        invoked = {rid: {'authorized': status == 200} for status, _, rid in responses if status != 401}
        primary_business = {rid: {} for status, _, rid in responses if status == 200 and rid.startswith('private_')}
        secondary_invoked = {rid: {} for status, _, rid in responses if status == 200 and rid.startswith('secondary_')}
        if wrong_decision:
            invoked['private_random']['authorized'] = True
        if missing_status:
            del gateway['private_random']['integrationStatus']
        if denied_invocation:
            secondary_invoked['private_broken'] = {}
        with tempfile.TemporaryDirectory() as tmp:
            report = Path(tmp) / 'verification.json'
            with patch.dict(poc.os.environ, {'TF_VAR_allowed_email': 'allowed@example.invalid'}), \
                 patch.object(poc, 'call', side_effect=responses), \
                 patch.object(poc, 'log_records', side_effect=[gateway, invoked, primary_business, secondary_invoked]), \
                 patch.object(poc, 'REPORT_PATH', report), contextlib.redirect_stdout(io.StringIO()):
                poc.test(cfg, token)
                result = json.loads(report.read_text())
                self.assertTrue(result['authentication_boundary_verified'])
                self.assertEqual(len(result['cases']), 8)
                self.assertNotIn(token, report.read_text())

    def test_authorizer_and_business_logs_do_not_overwrite_each_other(self):
        records = [{'requestId': 'same-id', 'kind': 'authorization', 'authorized': True},
                   {'requestId': 'same-id', 'kind': 'business'}]
        payload = {'events': [{'message': json.dumps(record)} for record in records]}
        with patch.object(poc, 'aws', return_value=payload):
            authorizer = poc.log_records({}, 'group', 0, kind='authorization')
            business = poc.log_records({}, 'group', 0, kind='business')
        self.assertIs(authorizer['same-id']['authorized'], True)
        self.assertEqual(business['same-id']['kind'], 'business')

    def test_complete_evidence_passes(self):
        self.run_verifier()

    def test_other_email_rejected_by_lambda(self):
        self.run_verifier(allowed=False)

    def test_unverified_email_rejected_by_lambda(self):
        self.run_verifier(verified=False)

    def test_wrong_authorizer_decision_evidence_fails(self):
        with self.assertRaisesRegex(RuntimeError, 'Authorizer decision evidence mismatch'):
            self.run_verifier(wrong_decision=True)

    def test_missing_integration_field_fails(self):
        with self.assertRaisesRegex(RuntimeError, 'Missing integration status evidence'):
            self.run_verifier(missing_status=True)

    def test_denied_lambda_invocation_fails(self):
        with self.assertRaisesRegex(RuntimeError, 'Denied request invoked business Lambda'):
            self.run_verifier(denied_invocation=True)

    def test_wrong_audience_expiry_and_missing_claim_rejected(self):
        valid = {'iss': 'https://accounts.google.com', 'aud': 'test-client',
                 'sub': 'user', 'email': 'user@example.invalid', 'email_verified': True,
                 'iat': int(time.time()) - 10, 'exp': int(time.time()) + 3600}
        invalid = [dict(valid, aud='other-client'), dict(valid, exp=1),
                   dict(valid, iss='accounts.google.com'),
                   {k: v for k, v in valid.items() if k != 'email_verified'}]
        for payload in invalid:
            with self.subTest(payload=payload):
                token = 'header.' + base64.urlsafe_b64encode(json.dumps(payload).encode()).decode().rstrip('=') + '.signature'
                with self.assertRaises(RuntimeError):
                    poc.inspect_token({'google_client_id': 'test-client'}, token)
        with self.assertRaises(RuntimeError):
            poc.inspect_token({'google_client_id': 'test-client'}, 'opaque-access-token')

    def test_failed_rerun_removes_old_report(self):
        with tempfile.TemporaryDirectory() as tmp:
            report = Path(tmp) / 'verification.json'
            report.write_text('{"authentication_boundary_verified": true}')
            with patch.object(poc, 'REPORT_PATH', report), \
                 patch.object(sys, 'argv', ['poc.py', 'test']), \
                 patch.object(poc, 'outputs', side_effect=RuntimeError('No deployment')):
                with self.assertRaisesRegex(RuntimeError, 'No deployment'):
                    poc.main()
            self.assertFalse(report.exists())


if __name__ == '__main__':
    unittest.main()
