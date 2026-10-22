# Access Evidence Report: Onward Logistics secure onboarding

| | |
|---|---|
| **Prepared for** | Head of Security, Onward Logistics |
| **Prepared by** | _name_ |
| **Run date (UTC)** | _from the first line of the script output_ |
| **AWS account / environment** | _account ID_ / _prod_ |
| **Git commit deployed** | _`git rev-parse --short HEAD`_ |
| **Raw output file** | `evidence/verify-access-YYYYMMDD.txt` |

> This report contains no passwords, keys or secret values. `verify-access.sh` reads secret *metadata* only.

---

## How to produce this report

1. Sign in to the AWS CLI with **admin** credentials for the target account (region `eu-west-1`, used by every section of the script).
2. From the repository root, run:
   ```bash
   mkdir -p evidence
   ./verify-access.sh | tee evidence/verify-access-$(date +%Y%m%d).txt
   ```
   The script reads every name from the stack outputs, so nothing needs editing. It finds the onboarding stack by itself. To point it elsewhere: `STACK=<name> BOOTSTRAP_STACK=<name> ./verify-access.sh ...`
3. Copy this file to `evidence/Evidence-Report-YYYYMMDD.md`.
4. For each section below, paste the matching block of output, then tick **Pass** or **Fail** against the expected result.
5. If section 4 is empty, CloudTrail has not caught up yet. Wait five minutes and rerun only that command.

**Reading simulator results:** `allowed` = permitted. `implicitDeny` = never granted. `explicitDeny` = blocked by a deny statement in the permission boundary, which **no other policy can override**.

---

## Summary

| # | Control | Requirement it proves | Result |
|---|---|---|---|
| 1 | Day-one access | Each engineer gets only what their role needs | ☐ Pass ☐ Fail |
| 2 | Stress test | On-call engineer can never create or terminate compute, even with AdministratorAccess | ☐ Pass ☐ Fail |
| 3 | Revert | The test leaves no extra access behind | ☐ Pass ☐ Fail |
| 4 | Audit trail | Every access change is traced to a person and a time | ☐ Pass ☐ Fail |
| 5 | Boundaries | Every engineer is capped by the boundary defined in Git | ☐ Pass ☐ Fail |
| 6 | No inline policies | Access comes only from reviewed, reusable policies | ☐ Pass ☐ Fail |
| 7 | Secure first login | Generated password, forced reset, no access keys | ☐ Pass ☐ Fail |
| 8 | Outside parties | Temporary, read-only role, External ID required | ☐ Pass ☐ Fail |
| 9 | Cost visibility | Budget alerts active from day one | ☐ Pass ☐ Fail |
| 10 | Deployed from Git | The live stack is driven by CloudFormation Git sync | ☐ Pass ☐ Fail |

**Overall:** ☐ All controls pass ☐ Exceptions listed in [Findings](#findings-and-follow-up)

---

## 1. Day-one access

**Proves:** each engineer can do their job, and nothing outside it.

| User | Action | Expected |
|---|---|---|
| s3-user | `s3:ListAllMyBuckets` | allowed |
| s3-user | `s3:PutObject`, `s3:GetObject` on a normal bucket | allowed |
| s3-user | `s3:PutObject`, `s3:DeleteObject` on the audit log bucket | explicitDeny |
| s3-user | `ec2:RunInstances`, `ec2:DescribeInstances` | implicitDeny |
| ec2-user-1 | `ec2:RunInstances`, `ec2:TerminateInstances`, `ec2:DescribeInstances` | allowed |
| ec2-user-1 | `s3:PutObject` | implicitDeny |
| ec2-user-2 | `ec2:DescribeInstances` | allowed |
| ec2-user-2 | `ec2:RunInstances`, `ec2:TerminateInstances` | explicitDeny |
| ec2-user-2 | `s3:PutObject` | implicitDeny |

```text
<paste section 1 output>
```

☐ Pass ☐ Fail. Notes:

---

## 2. Stress test: over-grant the on-call engineer

**Proves:** the observer boundary holds even when someone loosens permissions. The script attaches **AdministratorAccess** to both the `onward-<env>-oncall-observers` group and `ec2-user-2` directly, then asks the simulator again.

| Action on ec2-user-2 | Expected |
|---|---|
| `ec2:RunInstances` | explicitDeny |
| `ec2:TerminateInstances` | explicitDeny |
| `ec2:StartInstances` | explicitDeny |
| `autoscaling:CreateAutoScalingGroup` | explicitDeny |
| `iam:DeleteUserPermissionsBoundary` | explicitDeny |
| `ec2:DescribeInstances` | allowed |

```text
<paste section 2 output>
```

☐ Pass ☐ Fail. Notes:

---

## 3. Revert the stress test

**Proves:** the test leaves no extra access behind. The script also removes AdministratorAccess automatically if it stops early for any reason.

**Expected:** the two lists show only `AmazonEC2ReadOnlyAccess` / `IAMUserChangePassword` for the group and nothing for the user. `AdministratorAccess` does **not** appear.

```text
<paste section 3 output>
```

☐ Pass ☐ Fail. Notes:

---

## 4. Who changed access, and when

**Proves:** CloudTrail recorded the stress test with a named person and a timestamp.

**Expected:** `AttachGroupPolicy`, `AttachUserPolicy`, `DetachGroupPolicy` and `DetachUserPolicy` each show an entry at the run time, under the admin who ran the script. `CreateUser` shows the CloudFormation deployment that created the engineers.

```text
<paste section 4 output>
```

| Event | Time (UTC) | Who |
|---|---|---|
| AttachGroupPolicy | | |
| AttachUserPolicy | | |
| DetachGroupPolicy | | |
| DetachUserPolicy | | |

☐ Pass ☐ Fail. Notes:

---

## 5. Permission boundaries attached as defined in Git

**Expected:**

| User | Boundary ARN ends with |
|---|---|
| s3-user | `policy/onward-<env>-boundary-storage` |
| ec2-user-1 | `policy/onward-<env>-boundary-compute` |
| ec2-user-2 | `policy/onward-<env>-boundary-compute-observer` |

```text
<paste section 5 output>
```

☐ Pass ☐ Fail. Notes:

---

## 6. No inline policies

**Proves:** all access comes from AWS managed policies and reviewed boundaries, never from one-off policies hidden on a single user or group.

**Expected:** every count is `0` (three users, three groups).

```text
<paste section 6 output>
```

☐ Pass ☐ Fail. Notes:

---

## 7. Secure first login

**Proves:** nobody typed, chatted or committed a password, and no long-lived keys exist.

**Expected, for each of the three users:**
- `PasswordResetRequired` is `True` (until the engineer has signed in and changed it, after which AWS shows `False`. Note which applies.)
- `access keys: 0`
- A secret named `onward/<env>/onboarding/<user>` exists. Only its name and creation date are printed.

```text
<paste section 7 output>
```

☐ Pass ☐ Fail. Notes:

---

## 8. Outside parties: temporary, read-only role

**Proves:** outsiders never get a user account, only a short-lived role they cannot widen.

| Check | Expected |
|---|---|
| Max session duration | `3600` (one hour) |
| Permission boundary | `policy/onward-<env>-boundary-external-auditor` |
| Trust policy condition | `sts:ExternalId` required |
| `cloudtrail:LookupEvents`, `iam:ListUsers`, `ec2:DescribeInstances` | allowed |
| `s3:GetObject`, `secretsmanager:GetSecretValue` | explicitDeny |
| `ec2:RunInstances`, `iam:CreateUser` | implicitDeny |

```text
<paste section 8 output>
```

☐ Pass ☐ Fail. Notes:

---

## 9. Spend visible from day one

| Check | Expected |
|---|---|
| Budget | `onward-<env>-monthly-cost`, `MONTHLY`, limit matches `MonthlyBudgetUsd` in `onboarding-deployment.yaml` |
| Alert 1 | `ACTUAL` / `GREATER_THAN` / `80` |
| Alert 2 | `FORECASTED` / `GREATER_THAN` / `100` |
| Email subscription | Confirmed in the inbox of `BudgetAlertEmail` (check manually) |

```text
<paste section 9 output>
```

☐ Pass ☐ Fail. Notes:

---

## 10. Deployed by CloudFormation Git sync, wired to the bootstrap

**Proves:** the live stack comes from this repository through the reviewed pipeline, not from someone's laptop. The script compares the onboarding stack with the outputs of the bootstrap stack (`onward-gitsync-bootstrap`) and prints `PASS` or `FAIL` for each line.

| Check | Expected |
|---|---|
| Stack status | `CREATE_COMPLETE` or `UPDATE_COMPLETE` |
| Git connection status | `PASS` (`AVAILABLE`) |
| Stack service role | `PASS` (`role/onward-onboarding-stack-role`) |
| Git sync role | `PASS` (`role/onward-gitsync-role`) |
| Git sync branch | `PASS` (`main`) |
| Git sync deployment file | `PASS` (`onboarding-deployment.yaml`) |

```text
<paste section 10 output>
```

☐ Pass ☐ Fail. Notes:

---

## Findings and follow-up

List any section that failed, or any unexpected result, with an owner and a date.

| # | Section | What was seen | Risk | Action | Owner | Due |
|---|---|---|---|---|---|---|
| 1 | | | | | | |

---

## Sign-off

| Role | Name | Date | Signature |
|---|---|---|---|
| Ran the evidence script | | | |
| Reviewed (Head of Security) | | | |
