# Privileges Architecture: how access is shared between users, groups and boundaries

**Project:** Onward Logistics secure onboarding · **Account:** prod · **Region:** us-east-1
**Owner:** Patrick Ndaziramiye · **Source of truth:** [templates/onboarding.yaml](templates/onboarding.yaml)

Each engineer joins one group per job function. The group grants the day-to-day permissions through AWS managed policies. A permission boundary on every identity sets the ceiling, so access can never grow beyond the role, even if someone over-grants later. Outside parties never get a user account; they assume a short-lived role.

```
Effective access  =  Group policies  ∩  Permission boundary        (an explicit Deny always wins)
```

---

## 1. Access architecture

Read each lane left to right. In AWS, group and boundary names carry the `onward-prod-` prefix.

```mermaid
flowchart LR
  subgraph ID["IDENTITY"]
    direction TB
    U1["<b>s3-user</b><br/>Storage engineer<br/>IAM user · no access keys"]
    U2["<b>ec2-user-1</b><br/>Compute engineer<br/>IAM user · no access keys"]
    U3["<b>ec2-user-2</b><br/>On-call engineer<br/>IAM user · no access keys"]
    U4["<b>external-auditor</b><br/>IAM role · no user account<br/>AssumeRole + External ID · 1 h"]
  end

  subgraph GR["GROUP · AWS managed policies"]
    direction TB
    G1["<b>storage-engineers</b><br/>AmazonS3FullAccess<br/>IAMUserChangePassword"]
    G2["<b>compute-engineers</b><br/>AmazonEC2FullAccess<br/>IAMUserChangePassword"]
    G3["<b>oncall-observers</b><br/>AmazonEC2ReadOnlyAccess<br/>IAMUserChangePassword"]
    G4["<b>SecurityAudit</b><br/>attached to the role<br/>(no group)"]
  end

  subgraph BD["PERMISSION BOUNDARY · the ceiling"]
    direction TB
    B1["<b>boundary-storage</b><br/>ALLOW s3:*<br/>DENY audit log bucket"]
    B2["<b>boundary-compute</b><br/>ALLOW ec2:* · elb:* · autoscaling:*<br/>ALLOW CloudWatch read"]
    B3["<b>boundary-compute-observer</b><br/>ALLOW Describe / Get / List only<br/>DENY run · start · terminate · scale<br/>DENY removing own boundary"]
    B4["<b>boundary-external-auditor</b><br/>ALLOW read config + CloudTrail<br/>DENY object reads · secret values"]
  end

  subgraph EF["EFFECTIVE ACCESS"]
    direction TB
    E1["✅ Read/write S3<br/>❌ Audit log bucket<br/>❌ EC2"]
    E2["✅ Launch/terminate EC2<br/>✅ ELB · Auto Scaling<br/>❌ S3"]
    E3["✅ View EC2 · ELB · ASG · metrics<br/>❌ Create/terminate compute<br/>(even with AdministratorAccess)<br/>❌ S3"]
    E4["✅ Review config + audit history<br/>❌ Read data or secrets<br/>❌ Change anything"]
  end

  U1 -- member of --> G1 -- "∩" --> B1 -- "=" --> E1
  U2 -- member of --> G2 -- "∩" --> B2 -- "=" --> E2
  U3 -- member of --> G3 -- "∩" --> B3 -- "=" --> E3
  U4 -- attached --> G4 -- "∩" --> B4 -- "=" --> E4

  classDef storage fill:#e3f1e8,stroke:#2e7a4c,stroke-width:2px,color:#15202b
  classDef compute fill:#e2ebf8,stroke:#2557a3,stroke-width:2px,color:#15202b
  classDef oncall fill:#fbefdc,stroke:#a96300,stroke-width:2px,color:#15202b
  classDef external fill:#f5e4eb,stroke:#85385a,stroke-width:2px,color:#15202b
  classDef neutral fill:#ffffff,stroke:#9aa7b4,stroke-width:1px,color:#15202b
  class U1 storage
  class U2 compute
  class U3 oncall
  class U4 external
  class G1,G2,G3,G4,B1,B2,B3,B4,E1,E2,E3,E4 neutral
```

| Symbol | Meaning |
|---|---|
| **member of** | The user inherits the group's managed policies. |
| **∩** | Only actions allowed by *both* the policies and the boundary work. |
| **DENY** | An explicit deny in a boundary overrides any allow, from any policy, now or later. |

---

## 2. Access matrix

| Action | s3-user (storage) | ec2-user-1 (compute) | ec2-user-2 (on-call) | external-auditor (role) |
|---|---|---|---|---|
| Read and write S3 objects | ✅ Allowed | ⛔ Denied | ⛔ Denied | ❌ Explicit deny |
| Modify the audit log bucket | ❌ Explicit deny | ⛔ Denied | ⛔ Denied | ◐ Settings only |
| View EC2, load balancers, Auto Scaling | ⛔ Denied | ✅ Allowed | ✅ Allowed | ✅ Allowed |
| Launch, start or terminate instances | ⛔ Denied | ✅ Allowed | ❌ Explicit deny | ⛔ Denied |
| Create or resize Auto Scaling groups | ⛔ Denied | ✅ Allowed | ❌ Explicit deny | ⛔ Denied |
| Look up CloudTrail history | ⛔ Denied | ⛔ Denied | ⛔ Denied | ✅ Allowed |
| Read IAM configuration | ◐ Own user only | ◐ Own user only | ◐ Own user only | ✅ Allowed |
| Read secret values | ⛔ Denied | ⛔ Denied | ⛔ Denied | ❌ Explicit deny |
| Change own password | ✅ Allowed | ✅ Allowed | ✅ Allowed | n/a |
| Remove own permission boundary | ⛔ Denied | ⛔ Denied | ❌ Explicit deny | ⛔ Denied |

✅ Allowed · ⛔ Denied (not granted) · ❌ Explicit deny (cannot be overridden) · ◐ Partial

---

## 3. Proof: the ceiling holds under over-granting

On **19 October 2026**, [verify-access.sh](verify-access.sh) attached **AdministratorAccess** to both the `oncall-observers` group and `ec2-user-2` directly, then asked the IAM policy simulator what the on-call engineer could do. The script removed AdministratorAccess again afterwards.

| Action tested on ec2-user-2 | Simulator result |
|---|---|
| `ec2:RunInstances` | ❌ explicitDeny |
| `ec2:TerminateInstances` | ❌ explicitDeny |
| `ec2:StartInstances` | ❌ explicitDeny |
| `autoscaling:CreateAutoScalingGroup` | ❌ explicitDeny |
| `iam:DeleteUserPermissionsBoundary` | ❌ explicitDeny |
| `ec2:DescribeInstances` | ✅ allowed |

---

## 4. Controls shared by every identity

| Control | How it works |
|---|---|
| **Secure first login** | Secrets Manager generates a 20-character password per engineer (`onward/prod/onboarding/<user>`). A reset is forced at first sign-in, and no access keys exist. |
| **Every change is recorded** | The multi-Region trail `onward-prod-access-audit` logs every IAM change to an encrypted, versioned bucket. Storage engineers are explicitly denied that bucket. |
| **Defined once, in Git** | Users, groups, boundaries and the auditor role all come from `templates/onboarding.yaml`. No inline policies exist; changing access means a reviewed commit. |
