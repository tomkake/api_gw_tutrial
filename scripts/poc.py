#!/usr/bin/env python3
"""PoC helpers: credentials and tokens stay in memory, never in Terraform."""
import base64
import datetime
import getpass
from http.server import BaseHTTPRequestHandler, HTTPServer
import json
import os
from pathlib import Path
import subprocess
import sys
import time
import urllib.error
import urllib.request

ROOT = Path(__file__).resolve().parent.parent
os.chdir(ROOT)
os.environ['AWS_PAGER'] = ''
os.environ['AWS_CLI_AUTO_PROMPT'] = 'off'
REPORT_PATH = ROOT / '.build' / 'verification.json'


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def outputs():
    result = subprocess.run(['terraform', 'output', '-json'], check=True, capture_output=True, text=True)
    return {k: v['value'] for k, v in json.loads(result.stdout).items()}


def aws(cfg, service, operation, payload):
    # /dev/stdin keeps passwords and JWTs out of command arguments and files.
    result = subprocess.run(
        ['aws', service, operation, '--region', cfg['aws_region'],
         '--cli-input-json', 'file:///dev/stdin', '--output', 'json', '--no-cli-pager'],
        input=json.dumps(payload), capture_output=True, text=True)
    if result.returncode:
        # CLI diagnostics can echo invalid input; never forward raw stderr.
        raise RuntimeError(f'AWS {service} {operation} failed; check identity, permissions, region and input (stderr suppressed).')
    return json.loads(result.stdout) if result.stdout.strip() else {}


def claims(token):
    # Decode for inspection only. The first Lambda authorizer performs actual verification.
    part = token.split('.')[1]
    return json.loads(base64.urlsafe_b64decode(part + '=' * (-len(part) % 4)))


def call(cfg, path, token=None):
    headers = {'Authorization': 'Bearer ' + token} if token is not None else {}
    req = urllib.request.Request(cfg['api_endpoint'] + path, headers=headers)
    try:
        response = urllib.request.urlopen(req, timeout=20)
    except urllib.error.HTTPError as error:
        response = error
    with response:
        return response.status, json.loads(response.read()), response.headers.get('apigw-requestid')


def log_records(cfg, group, start, kind=None):
    records = {}
    payload = {'logGroupName': group, 'startTime': start}
    while True:
        result = aws(cfg, 'logs', 'filter-log-events', payload)
        for event in result.get('events', []):
            try:
                record = json.loads(event['message'])
                if isinstance(record, dict) and record.get('requestId') and (kind is None or record.get('kind') == kind):
                    records[record['requestId']] = record
            except (ValueError, TypeError):
                pass  # Lambda START/END/REPORT records are not our JSON.
        next_token = result.get('nextToken')
        if not next_token or next_token == payload.get('nextToken'):
            return records
        payload['nextToken'] = next_token


CLAIM_KEYS = ('iss', 'aud', 'sub', 'email', 'email_verified', 'iat', 'exp')


def inspect_token(cfg, token):
    require(len(token.split('.')) == 3 and all(token.split('.')), 'Expected a Google ID Token JWT')
    decoded = claims(token)
    require(all(k in decoded for k in CLAIM_KEYS), 'Missing required Google ID Token claims')
    require(decoded['iss'] == 'https://accounts.google.com', 'Unexpected issuer')
    require(decoded['aud'] == cfg['google_client_id'], 'Unexpected audience')
    require(decoded['sub'] and decoded['email'], 'Missing user identity')
    require(isinstance(decoded['email_verified'], bool), 'Invalid email_verified claim')
    require(decoded['iat'] <= time.time() < decoded['exp'], 'Token expired or issued in the future')
    return decoded


def serve(cfg):
    # Serve only the harness and public config, never Terraform state or repo files.
    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            if self.path == '/':
                body = (ROOT / 'web' / 'index.html').read_bytes()
                content_type = 'text/html; charset=utf-8'
            elif self.path == '/config.json':
                body = json.dumps({k: cfg[k] for k in ('api_endpoint', 'google_client_id')}).encode()
                content_type = 'application/json'
            else:
                self.send_error(404)
                return
            self.send_response(200)
            self.send_header('Content-Type', content_type)
            self.send_header('Cache-Control', 'no-store')
            self.send_header('Referrer-Policy', 'no-referrer')
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *_):
            pass

    print('Open http://localhost:8000 (Ctrl+C to stop)', flush=True)
    HTTPServer(('127.0.0.1', 8000), Handler).serve_forever()


def test(cfg, token):
    decoded = inspect_token(cfg, token)
    allowed_email = os.environ.get('TF_VAR_allowed_email', '')
    require(allowed_email, 'Set TF_VAR_allowed_email in .env and run make test.')
    allowed = decoded['email'] == allowed_email and decoded['email_verified'] is True
    report = {'checked_at': datetime.datetime.now(datetime.timezone.utc).isoformat(),
              'api_endpoint': cfg['api_endpoint'], 'google_client_id': cfg['google_client_id'],
              'issuer': decoded['iss'], 'required_claims_present': list(CLAIM_KEYS),
              'cases': []}
    # Change a signature character, preserving a syntactically valid JWT.
    parts = token.split('.')
    parts[2] = ('A' if parts[2][0] != 'A' else 'B') + parts[2][1:]
    broken = '.'.join(parts)
    start = int(time.time() * 1000) - 1000
    cases = []
    for endpoint in ('private', 'secondary'):
        path = '/' + endpoint
        cases.extend([(endpoint + '_no_header', path, None, 401),
                      (endpoint + '_random', path, 'not-a-jwt', 403),
                      (endpoint + '_broken_signature', path, broken, 403),
                      (endpoint + '_valid', path, token, 200 if allowed else 403)])
    for name, path, supplied, expected in cases:
        status, body, request_id = call(cfg, path, supplied)
        require(status == expected, f'{name}: expected {expected}, received {status}')
        require(request_id, f'{name}: missing API Gateway request ID')
        if name.endswith('_valid') and allowed:
            message = 'Hello from the first Lambda!' if path == '/private' else 'Hello from the second Lambda!'
            require(body == {'message': message, 'request_id': request_id},
                    'Unexpected business Lambda response')
        report['cases'].append({'name': name, 'request_id': request_id, 'status': status, 'path': path})
        print(f'{name}: {status}', flush=True)
    print('Waiting for API Gateway and Lambda log evidence (up to 180 seconds)...', flush=True)
    deadline = time.monotonic() + 180
    while True:
        gateway = log_records(cfg, cfg['api_log_group'], start)
        auth_records = log_records(cfg, cfg['lambda_log_group'], start, kind='authorization')
        business_by_path = {
            '/private': log_records(cfg, cfg['lambda_log_group'], start, kind='business'),
            '/secondary': log_records(cfg, cfg['secondary_lambda_log_group'], start, kind='business'),
        }
        business_records = {rid: record for records in business_by_path.values() for rid, record in records.items()}
        all_present = all(c['request_id'] in gateway for c in report['cases'])
        authorizer_present = all(c['request_id'] in auth_records for c in report['cases'] if c['status'] != 401)
        business_present = all(c['request_id'] in business_by_path[c['path']] for c in report['cases'] if c['status'] == 200)
        if all_present and authorizer_present and business_present:
            for case in report['cases']:
                rid = case['request_id']
                record = gateway[rid]
                require(str(record['status']) == str(case['status']), 'Access log status mismatch')
                require('integrationStatus' in record, 'Missing integration status evidence')
                integration = str(record['integrationStatus'])
                if case['status'] in (401, 403):
                    require(integration == '-', 'Denied request reached the business integration')
                    require(rid not in business_records, 'Denied request invoked business Lambda')
                else:
                    require(integration == '200', 'Successful request missing integration evidence')
                if case['status'] == 401:
                    require(rid not in auth_records, 'Missing-header request invoked authorizer')
                else:
                    require(auth_records[rid].get('authorized') is (case['status'] == 200),
                            'Authorizer decision evidence mismatch')
                case['integration_status'] = integration
                case['authorizer_log_found'] = rid in auth_records
                case['business_lambda_log_found'] = rid in business_records
            break
        if time.monotonic() >= deadline:
            raise RuntimeError('CloudWatch evidence incomplete; no boundary success is claimed. Retry make test.')
        time.sleep(5)
    report['authentication_boundary_verified'] = True
    report['email_allowlist_result'] = 'allowed' if allowed else 'denied'
    report['expired_token'] = 'not tested (requires waiting for genuine Google ID Token expiry)'
    destination = REPORT_PATH
    destination.parent.mkdir(exist_ok=True)
    destination.write_text(json.dumps(report, indent=2) + '\n')
    destination.chmod(0o600)
    print('PASS: authentication/authorization ran only in the first Lambda; denied requests did not invoke the business Lambda.')
    print('Evidence: .build/verification.json (no passwords or tokens)')


def main():
    command = sys.argv[1]
    if command == 'test':
        # A failed rerun must not leave a previous success report looking current.
        REPORT_PATH.unlink(missing_ok=True)
    cfg = outputs()
    if command == 'serve':
        serve(cfg)
    elif command == 'test':
        token = getpass.getpass('Google ID Token (from the local Sign-In page, hidden): ').strip()
        test(cfg, token)
    else:
        raise RuntimeError('Usage: poc.py serve|test')


if __name__ == '__main__':
    try:
        main()
    except (RuntimeError, AssertionError, subprocess.CalledProcessError, OSError, ValueError, KeyError) as error:
        # Never print exception text from AWS, networking or subprocesses: it may contain inputs.
        if isinstance(error, (RuntimeError, AssertionError)):
            print(str(error), file=sys.stderr)
        else:
            print(f'{type(error).__name__}: helper failed; check tools, Terraform outputs and AWS setup.', file=sys.stderr)
        sys.exit(1)
