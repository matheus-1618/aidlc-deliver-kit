#!/usr/bin/env python3
"""AI-DLC Deliver Kit — registra blocos, workflow e scope na plataforma.

Idempotente: POST que responder 409 vira PUT (update). Roda com um token de
platform-admin.

Uso:
  export AIDLC_API=https://<api>/dev   AIDLC_TOKEN=<id-token>
  ./register.py [--project-id <id>]    # com project-id, também faz o bind do workflow
"""

import argparse
import json
import os
import sys
import urllib.request
from pathlib import Path

KIT = Path(__file__).resolve().parent.parent
API = os.environ["AIDLC_API"].rstrip("/")
TOKEN = os.environ["AIDLC_TOKEN"]

WORKFLOW_ID = "aidlc-deliver"
SCOPE_ID = "deliver"
ENV_TAG = os.environ.get("DELIVER_ENV_TAG", "deliver-teste-sample")

# Stages (do fork do aidlc-v2) que EXECUTAM no scope deliver — lean por desenho.
DELIVER_MEMBERSHIP = [
    "workspace-scaffold", "workspace-detection", "state-init",
    "intent-capture", "requirements-analysis", "code-generation",
    "release-gate", "deploy-execute", "deploy-verify",
]


def call(method: str, path: str, body=None):
    req = urllib.request.Request(
        f"{API}/api{path}",
        method=method,
        headers={"Authorization": TOKEN, "Content-Type": "application/json"},
        data=json.dumps(body).encode() if body is not None else None,
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return r.status, json.loads(r.read() or b"{}")
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read() or b"{}")


def upsert(kind: str, block: dict):
    status, out = call("POST", f"/blocks/{kind}", block)
    if status == 409:
        status, out = call("PUT", f"/blocks/{kind}/{block['id']}", block)
    ok = status in (200, 201)
    print(f"  [{'ok' if ok else status}] {kind}/{block['id']}")
    if not ok:
        print("      ", json.dumps(out)[:300]); sys.exit(1)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--project-id")
    args = ap.parse_args()

    print("== blocos ==")
    upsert("agent", {
        "id": "aidlc-release-manager-agent",
        "name": "Release Manager",
        "description": "Conducts merge->pipeline->verify through the github MCP; never holds cloud credentials",
        "body": (KIT / "blocks/agents/aidlc-release-manager-agent.md").read_text(),
    })

    upsert("knowledge", {
        "id": "deliver-static-site-flavor",
        "name": "Deliver Flavor: static-site",
        "agentRef": "shared",
        "tier": "team",
        "body": (KIT / "blocks/knowledge/deliver-static-site-flavor.md").read_text()
            .replace("deliver-teste-sample", ENV_TAG),
    })

    upsert("knowledge", {
        "id": "deliver-lambda-backend-flavor",
        "name": "Deliver Flavor: lambda-backend",
        "agentRef": "shared",
        "tier": "team",
        "body": (KIT / "blocks/knowledge/deliver-lambda-backend-flavor.md").read_text()
            .replace("deliver-teste-sample", ENV_TAG),
    })

    upsert("artifact", {
        "id": "environment-manifest",
        "name": "Environment Manifest",
        "description": "Machine-readable record of a deployed environment: url, commit, pipeline run, resources",
        "body": "environments/production.json — required keys: environment, flavor, status, "
                "url, commit, pipeline_run, deployed_at, verified_http_status, "
                "resources{site_bucket, distribution_id}.",
    })

    upsert("artifact", {
        "id": "release-notes",
        "name": "Release Notes",
        "description": "Release candidate record: PR, resources the IaC creates, flavor invariant check, cost order-of-magnitude, rollback path",
        "body": "release-notes.md — written by release-gate. Required sections: PR number/URL, resources to be created, invariant checklist, estimated cost, rollback path.",
    })

    upsert("artifact", {
        "id": "deploy-verification",
        "name": "Deploy Verification",
        "description": "Independent post-deploy verification: observed HTTP status, manifest, teardown instruction. Terminal artifact (consumed by humans, not stages).",
        "body": "deploy-verification.md — written by deploy-verify. Required sections: URL + observed status, environment manifest (fenced), teardown instruction.",
    })

    upsert("sensor", {
        "id": "deliver-manifest",
        "name": "Deliver Manifest Check",
        "severity": "blocking",
        "runtime": "bun",
        "command": "bun {{HARNESS_DIR}}/tools/deliver-manifest.ts",
        "matches": "**/environments/production.json",
        "script": (KIT / "blocks/sensors/deliver-manifest.ts").read_text(),
    })

    upsert("sensor", {
        "id": "deliver-flavor-conformance",
        "name": "Deliver Flavor Conformance",
        "severity": "blocking",
        "runtime": "bun",
        "command": "bun {{HARNESS_DIR}}/tools/deliver-flavor-conformance.ts",
        "matches": "**/infra/main.tf",
        "script": (KIT / "blocks/sensors/deliver-flavor-conformance.ts").read_text(),
    })

    stages_raw = (KIT / "blocks/stages/deliver-stages.md").read_text().split("---8<---STAGE-SPLIT---")
    stage_defs = [
        {
            "id": "release-gate", "name": "Release Gate", "phase": "operation",
            "leadAgent": "aidlc-release-manager-agent", "supportAgents": [],
            "requires": ["code-generation"],
            "consumes": [], "produces": ["release-notes"], "optionalProduces": [],
            "humanValidation": "required", "sensors": ["deliver-flavor-conformance"], "mode": "inline",
            "execution": "CONDITIONAL",
            "condition": "Execute when the intent delivers deployable code (deliver scope)",
            "inputs": "The intent branch with site/ and infra/ from Construction",
            "outputs": "release-notes.md (under this stage's record dir, engine-resolved)",
            "body": stages_raw[0],
        },
        {
            "id": "deploy-execute", "name": "Deploy Execute", "phase": "operation",
            "leadAgent": "aidlc-release-manager-agent", "supportAgents": [],
            "requires": ["release-gate"],
            "consumes": [{"artifact": "release-notes", "required": True}],
            "produces": ["deployment-log"], "optionalProduces": [],
            "humanValidation": None, "sensors": [], "mode": "inline",
            "execution": "CONDITIONAL",
            "condition": "Execute after the release gate approves",
            "inputs": "release-notes.md from release-gate (PR number)",
            "outputs": "deployment-log.md (under this stage's record dir, engine-resolved)",
            "body": stages_raw[1],
        },
        {
            "id": "deploy-verify", "name": "Deploy Verify", "phase": "operation",
            "leadAgent": "aidlc-release-manager-agent", "supportAgents": [],
            "requires": ["deploy-execute"],
            "consumes": [{"artifact": "deployment-log", "required": True}],
            "produces": ["deploy-verification"], "optionalProduces": [],
            "humanValidation": "required", "sensors": ["deliver-manifest"],
            "mode": "inline", "execution": "CONDITIONAL",
            "condition": "Execute after deploy-execute reports a pipeline conclusion",
            "inputs": "deployment-log.md from deploy-execute (deploy-outputs JSON)",
            "outputs": "deploy-verification.md (record dir); environments/production.json (repo root)",
            "body": stages_raw[2],
        },
    ]
    for s in stage_defs:
        upsert("stage", s)

    upsert("scope", {
        "id": SCOPE_ID, "name": "Deliver",
        "description": "Idea to verified production deploy: lean inception, construction, "
                       "release gate, pipeline-driven deploy, independent verification",
        "depth": "Minimal", "testStrategy": "Standard", "keywords": ["deploy", "release", "deliver"],
    })

    print("== workflow ==")
    status, out = call("POST", "/workflows", {
        "id": WORKFLOW_ID, "name": "AI-DLC Deliver",
        "objective": "aidlc-v2 extended with a platform-conducted last mile",
        "basedOn": "aidlc-v2", "defaultScope": SCOPE_ID,
    })
    print(f"  [{'ok' if status in (200,201) else status}] workflow {WORKFLOW_ID}", "" if status in (200, 201, 409) else out)
    if status not in (200, 201, 409):
        sys.exit(1)

    status, out = call("POST", f"/workflows/{WORKFLOW_ID}/scopes", {"scopeId": SCOPE_ID, "scopeTenant": "default"})
    print(f"  [{'ok' if status in (200,201,409) else status}] scopeRef {SCOPE_ID}")

    for i, sid in enumerate(["release-gate", "deploy-execute", "deploy-verify"]):
        status, out = call("POST", f"/workflows/{WORKFLOW_ID}/placements", {
            "stageId": sid, "stageTenant": "default", "phasePath": "05", "order": 32 + i,
            "scopeMembership": {SCOPE_ID: "EXECUTE"},
        })
        print(f"  [{'ok' if status in (200,201,409) else status}] placement {sid} @ order {32+i}")
        if status not in (200, 201, 409):
            print("      ", json.dumps(out)[:300]); sys.exit(1)

    status, out = call("PUT", f"/workflows/{WORKFLOW_ID}/scopes/{SCOPE_ID}/membership",
                       {"stageIds": DELIVER_MEMBERSHIP})
    print(f"  [{'ok' if status == 200 else status}] membership deliver = {len(DELIVER_MEMBERSHIP)} stages")
    if status != 200:
        print("      ", json.dumps(out)[:300]); sys.exit(1)

    if args.project_id:
        print("== bind do projeto ==")
        status, out = call("PUT", f"/projects/{args.project_id}", {"workflowId": WORKFLOW_ID})
        print(f"  [{'ok' if status == 200 else status}] projeto {args.project_id} -> {WORKFLOW_ID}",
              "" if status == 200 else json.dumps(out)[:200])

    print("pronto.")


if __name__ == "__main__":
    main()
