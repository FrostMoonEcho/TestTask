# Security Policy and Operating Controls

## Scope

This document covers the `cell-01` billing-service assessment stack: Terraform,
the K3s runtime, Helm chart, GitHub Actions delivery workflow, and provisioning
script. Identifiers and domains are placeholders.

## Security reporting

Do not open a public issue for a suspected vulnerability. Use the private
security contact and incident channel configured by the organization. Include
the affected cell/service, observed behavior, timestamps, and non-sensitive
reproduction details. Never include credentials, customer content, or database
records.

## SOC 2 operating controls

Exactly three primary SOC 2 criteria are implemented for Part B.

| Criterion | Control implementation | Evidence |
|---|---|---|
| **CC6 - Logical access** | No public K3s API or SSH; SSM administration; GitHub OIDC temporary credentials; branch-scoped build trust and environment-scoped deploy trust; production Environment restricted to `main`; least-privilege EC2/build/deploy roles; namespace-scoped deploy identity; Kubernetes `secretKeyRef`; API-gateway-only NetworkPolicy | Terraform IAM/SG plan, OIDC trust policy, GitHub Environment approval/branch policy, CloudTrail role sessions, SSM session logs, rendered NetworkPolicy/RBAC review |
| **CC7 - System operations** | `npm audit`; Trivy CRITICAL gate against the exact ECR digest; probes and resource limits; encrypted logs/audit output; security-event triage; monitored backup and secret-rotation failures | Workflow logs, Trivy/npm reports, ECR scan findings, Kubernetes events, provisioning JSONL log, incident tickets, remediation SLA report |
| **CC8 - Change management** | Protected `main`; peer review/CODEOWNERS expected; locked dependencies; Terraform plan before apply; saved-plan checksum; manually approved production environment; immutable SHA tag and digest-pinned Helm release; atomic deployment and rollback history | Approved PR, lockfile diff, Terraform plan/hash, CI run, environment approval, ECR digest, Helm history and rollout result |

Controls must operate throughout the audit period. A secure configuration
snapshot without recurring review, evidence, and remediation is insufficient
for SOC 2 Type II.

## Top five risks

| # | Risk | Impact | Mitigation | Residual risk / owner |
|---|---|---|---|---|
| 1 | Administrative network or runner compromise | Unauthorized Kubernetes/API access to `cell-01` | Private API, no SSH, SSM, MFA/JIT access, protected runner, namespace-scoped identity, session/audit logs | A trusted private runner remains privileged within its namespace. Platform Engineering owns patching and access review. |
| 2 | Overbroad OIDC trust or IAM permissions | An untrusted workflow could push/deploy code or modify AWS resources | Exact `aud`/`sub`, separate branch build and protected-environment deploy roles, one-hour sessions, resource-scoped ECR permissions, no AWS keys | Repository administrators can change settings. Security owns quarterly trust/policy review. |
| 3 | Secret disclosure or failed rotation | Database/payment compromise, token forgery, outage | Secrets Manager source of truth, `secretKeyRef`, no values in Git/Terraform/Helm, overlapping rotation, immediate incident rotation, audit evidence | The assessment assumes an external secret controller. Application owners must test reload/rollout behavior. |
| 4 | Vulnerable dependency or base image | Remote code execution or supply-chain compromise | Lockfile, `npm audit`, Trivy CRITICAL gate on the release digest, ECR scan-on-push, immutable SHA tags, digest-pinned deployment, minimal non-root image, patch SLA | Scanners can miss unknown vulnerabilities. Product Security owns exception approval and rescans. |
| 5 | Single-node/data/state failure | Service outage or unrecoverable infrastructure change | RDS Multi-AZ/PITR/final snapshot, S3 versioning, remote state/versioning/locking, saved plans, documented restore/rollback | K3s itself is single-node and not HA. Platform Engineering must move production to three-node K3s or EKS. |

## Vulnerability management

- CRITICAL findings block the release and are remediated within 24 hours.
- HIGH findings are remediated within 7 days.
- MEDIUM/LOW findings follow the normal patch cycle based on exposure.
- An exception requires owner, justification, compensating control, approver,
  and expiry date. Expired exceptions block release.
- Base images and dependencies are rebuilt/rescanned even when application code
  has not changed.

## Credential rotation runbook

### Triggers

- Scheduled rotation: database application credential every 30 days; payment
  token at least every 90 days or vendor maximum; JWT signing key based on the
  cryptographic policy.
- Immediate rotation: suspected disclosure, staff/runner compromise, failed
  access review, vendor notification, or unauthorized use.

### Preconditions

1. Open a change/incident ticket and identify the cell, credential, owner,
   approver, and rollback window.
2. Confirm current service health and that no unrelated deployment is running.
3. Confirm Secrets Manager, external secret reconciliation, Kubernetes rollout,
   application logs, and audit destinations are available.
4. Never copy a secret value into the ticket, terminal recording, GitHub log,
   or chat.

### RDS application password

1. Start managed/alternating-user rotation in Secrets Manager.
2. Create/test the new database user or password with the same minimal grants.
3. Allow the external secret controller to reconcile the new version to
   `billing-service-secrets`.
4. Restart/roll out billing-service so new connection pools use the new value.
5. Verify readiness, authentication success, error rate, and a read/write smoke
   transaction.
6. Drain old connections, revoke the old credential, and verify it fails.
7. Record the Secrets Manager version IDs, rotation event, rollout revision,
   approver, and verification result without recording values.
8. If verification fails, restore the previous secret stage and roll back the
   workload before revoking the old user.

The RDS master password is managed by AWS through
`manage_master_user_password`; applications should use a separate
least-privilege user.

### JWT signing secret/key

1. Generate a cryptographically strong new key in the approved key/secret
   service and assign a new `kid`.
2. Publish both old and new verification keys.
3. Reconcile/deploy the new key and begin signing new tokens with the new `kid`.
4. Verify new token issuance, validation, refresh, and service-to-service auth.
5. Wait at least the maximum old token lifetime plus clock skew.
6. Remove/revoke the old signing key and verify old tokens are rejected after
   their intended expiry.
7. Preserve ticket, key-version metadata, rollout, and validation evidence.

If the stub application cannot support multiple verification keys, the
rotation requires a maintenance window and invalidates active sessions; this
must be communicated before rotation.

### Payment provider key

1. Create a second provider key without revoking the active key.
2. Store the new value as a new Secrets Manager version.
3. Reconcile and roll out billing-service.
4. Validate with a provider-supported harmless test/health transaction.
5. Monitor payment errors and authorization failures.
6. Revoke the old provider key after the validation/rollback window.
7. Record provider key ID, timestamps, approver, workflow run, and result
   without recording the secret value.

### Emergency completion

After any emergency rotation:

- revoke active sessions and investigate CloudTrail/SSM/GitHub/Kubernetes logs;
- rotate adjacent credentials that may share the same exposure path;
- scan repositories, artifacts, images, state, and logs for the old value;
- notify affected parties through the incident process;
- complete a post-incident review and track corrective actions.

## Backup and recovery expectations

- RDS automated backups have seven-day retention and a final snapshot on
  intentional deletion.
- S3 exports and Terraform state use versioning.
- The remote backend bucket and DynamoDB table are protected bootstrap
  resources outside this stack.
- Restore testing must verify application behavior, not only resource creation.
- RDS deletion protection is disabled only through an approved change.

## Security limitations

The assessment intentionally remains small. The single K3s node, one NAT
Gateway, external runner, external secret controller, and backend bootstrap are
documented limitations rather than claims of full production HA.
