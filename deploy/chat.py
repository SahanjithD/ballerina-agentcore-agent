#!/usr/bin/env python3
"""Talk to the deployed agent over plain HTTPS.

No AWS CLI. This POSTs straight to the AgentCore data-plane URL:

    https://bedrock-agentcore.<region>.amazonaws.com/runtimes/<arn>/invocations?qualifier=DEFAULT

The runtime uses IAM inbound auth, so the request must carry a SigV4 signature.
botocore is used purely as the signer -- the request itself goes out over urllib.
Signing is not hand-rolled on purpose: the runtime ARN is percent-encoded inside
the path, and getting canonical-URI encoding subtly wrong yields a 403 that looks
identical to a permissions problem.

Usage:
    pip install botocore
    python3 deploy/chat.py                      # new conversation
    SESSION_ID=<id> python3 deploy/chat.py      # resume one
"""
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request
import uuid

try:
    from botocore.auth import SigV4Auth
    from botocore.awsrequest import AWSRequest
    from botocore.session import Session
except ImportError:
    sys.exit("botocore is required for SigV4 signing:  pip install botocore")

REGION = os.environ.get("AWS_REGION", "us-east-1")
AGENT_NAME = os.environ.get("AGENT_NAME", "ballerina_agent")
RUNTIME_ARN = os.environ.get("RUNTIME_ARN", "")
SERVICE = "bedrock-agentcore"

CYAN, RED, BOLD, OFF = "\033[36m", "\033[31m", "\033[1m", "\033[0m"


def resolve_arn(session):
    """Look the ARN up once, unless RUNTIME_ARN pins it."""
    if RUNTIME_ARN:
        return RUNTIME_ARN
    client = session.create_client("bedrock-agentcore-control", region_name=REGION)
    for rt in client.list_agent_runtimes().get("agentRuntimes", []):
        if rt.get("agentRuntimeName") == AGENT_NAME:
            return rt["agentRuntimeArn"]
    sys.exit(f"No runtime named {AGENT_NAME} in {REGION}. Set RUNTIME_ARN to skip the lookup.")


def invoke(creds, url, session_id, prompt):
    body = json.dumps({"prompt": prompt})
    headers = {
        "Content-Type": "application/json",
        "Accept": "application/json",
        # AgentCore pins a session to one container, and service.bal uses this same
        # id as the agent's memory key -- so reusing it is what creates continuity.
        "X-Amzn-Bedrock-AgentCore-Runtime-Session-Id": session_id,
    }
    signed = AWSRequest(method="POST", url=url, data=body, headers=headers)
    SigV4Auth(creds, SERVICE, REGION).add_auth(signed)

    req = urllib.request.Request(url, data=body.encode(), method="POST")
    for key, value in signed.headers.items():
        req.add_header(key, value)
    with urllib.request.urlopen(req, timeout=300) as resp:
        return resp.read().decode()


def render(raw):
    try:
        body = json.loads(raw)
    except json.JSONDecodeError:
        return f"{RED}agent>{OFF} {raw.strip()}"
    text = body.get("response") or body.get("message") or json.dumps(body, indent=2)
    return f"{CYAN}agent>{OFF} {text}"


def main():
    session = Session()
    frozen = session.get_credentials()
    if frozen is None:
        sys.exit("No AWS credentials found (env vars, AWS_PROFILE, or ~/.aws/credentials).")
    creds = frozen.get_frozen_credentials()

    arn = resolve_arn(session)
    # Everything after /runtimes/ is one path segment, so the ARN's colons and slash
    # must be percent-encoded -- safe="" is doing the work here.
    url = (f"https://{SERVICE}.{REGION}.amazonaws.com/runtimes/"
           f"{urllib.parse.quote(arn, safe='')}/invocations?qualifier=DEFAULT")

    # AgentCore requires at least 33 characters.
    session_id = os.environ.get("SESSION_ID") or (uuid.uuid4().hex + uuid.uuid4().hex)

    print(f"agent   {AGENT_NAME}")
    print(f"url     {url[:72]}...")
    print(f"session {session_id}")
    print('Type your message. Ctrl-D or "exit" to quit.\n')

    while True:
        try:
            prompt = input(f"{BOLD}you >{OFF} ").strip()
        except (EOFError, KeyboardInterrupt):
            print()
            break
        if not prompt:
            continue
        if prompt in ("exit", "quit"):
            break
        try:
            print(render(invoke(creds, url, session_id, prompt)) + "\n")
        except urllib.error.HTTPError as e:
            detail = e.read().decode(errors="replace").strip()
            print(f"{RED}agent> HTTP {e.code}{OFF} {detail}\n")
        except urllib.error.URLError as e:
            print(f"{RED}agent> connection failed:{OFF} {e.reason}\n")

    print(f"\nSession {session_id} ended.")


if __name__ == "__main__":
    main()
