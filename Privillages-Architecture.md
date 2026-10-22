# Privileges Architecture: how access is shared between users, groups and boundaries

**Project:** Onward Logistics secure onboarding · **Account:** prod · **Region:** eu-west-1
**Owner:** Patrick Ndaziramiye · **Source of truth:** [templates/onboarding.yaml](templates/onboarding.yaml) · **Proof:** [verify-access.sh](verify-access.sh)

Each engineer joins one group per job function. The group grants the day-to-day permissions through AWS managed policies. A permission boundary on every engineer sets the ceiling, so access can never grow beyond the role, even if someone over-grants later.

```text
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
  end

  subgraph GR["GROUP · AWS managed policies"]
    direction TB
    G1["<b>storage-engineers</b><br/>AmazonS3FullAccess<br/>IAMUserChangePassword"]
    G2["<b>compute-engineers</b><br/>AmazonEC2FullAccess<br/>IAMUserChangePassword"]
    G3["<b>oncall-observers</b><br/>AmazonEC2ReadOnlyAccess<br/>IAMUserChangePassword"]
  end

  subgraph BD["PERMISSION BOUNDARY · the ceiling"]
    direction TB
    B1["<b>boundary-storage</b><br/>ALLOW s3:*"]
    B2["<b>boundary-compute</b><br/>ALLOW ec2:* · elb:* · autoscaling:*<br/>ALLOW CloudWatch read"]
    B3["<b>boundary-compute-observer</b><br/>ALLOW Describe / Get / List only<br/>DENY run · start · terminate · scale<br/>DENY removing own boundary"]
  end

  subgraph EF["EFFECTIVE ACCESS"]
    direction TB
    E1["✅ Read/write S3<br/>❌ EC2"]
    E2["✅ Launch/terminate EC2<br/>✅ ELB · Auto Scaling<br/>❌ S3"]
    E3["✅ View EC2 · ELB · ASG · metrics<br/>❌ Create/terminate compute<br/>(even with AdministratorAccess)<br/>❌ S3"]
  end

  U1 -- member of --> G1 -- "∩" --> B1 -- "=" --> E1
  U2 -- member of --> G2 -- "∩" --> B2 -- "=" --> E2
  U3 -- member of --> G3 -- "∩" --> B3 -- "=" --> E3

  classDef storage fill:#e3f1e8,stroke:#2e7a4c,stroke-width:2px,color:#15202b
  classDef compute fill:#e2ebf8,stroke:#2557a3,stroke-width:2px,color:#15202b
  classDef oncall fill:#fbefdc,stroke:#a96300,stroke-width:2px,color:#15202b
  classDef neutral fill:#ffffff,stroke:#9aa7b4,stroke-width:1px,color:#15202b
  class U1 storage
  class U2 compute
  class U3 oncall
  class G1,G2,G3,B1,B2,B3,E1,E2,E3 neutral
```

| Symbol | Meaning |
|---|---|
| **member of** | The user inherits the group's managed policies. |
| **∩** | Only actions allowed by *both* the policies and the boundary work. |
| **DENY** | An explicit deny in a boundary overrides any allow, from any policy, now or later. |

---

## 2. Access matrix

| Action | s3-user (storage) | ec2-user-1 (compute) | ec2-user-2 (on-call) |
|---|---|---|---|
| Read and write S3 objects | ✅ Allowed | ⛔ Denied | ⛔ Denied |
| View EC2, load balancers, Auto Scaling | ⛔ Denied | ✅ Allowed | ✅ Allowed |
| Launch, start or terminate instances | ⛔ Denied | ✅ Allowed | ❌ Explicit deny |
| Create or resize Auto Scaling groups | ⛔ Denied | ✅ Allowed | ❌ Explicit deny |
| Read IAM configuration | ◐ Own user only | ◐ Own user only | ◐ Own user only |
| Read secret values | ⛔ Denied | ⛔ Denied | ⛔ Denied |
| Change own password | ✅ Allowed | ✅ Allowed | ✅ Allowed |
| Remove own permission boundary | ⛔ Denied | ⛔ Denied | ❌ Explicit deny |

✅ Allowed · ⛔ Denied (not granted) · ❌ Explicit deny (cannot be overridden) · ◐ Partial

---

## 3. Proof: the ceiling holds under over-granting

Section 2 of [verify-access.sh](verify-access.sh) attaches **AdministratorAccess** to both the `oncall-observers` group and `ec2-user-2` directly, then asks the IAM policy simulator what the on-call engineer can do. Section 3 removes AdministratorAccess again (it is also removed automatically if the script stops early). Expected result:

| Action tested on ec2-user-2 | Simulator result |
|---|---|
| `ec2:RunInstances` | ❌ explicitDeny |
| `ec2:TerminateInstances` | ❌ explicitDeny |
| `ec2:StartInstances` | ❌ explicitDeny |
| `autoscaling:CreateAutoScalingGroup` | ❌ explicitDeny |
| `iam:DeleteUserPermissionsBoundary` | ❌ explicitDeny |
| `ec2:DescribeInstances` | ✅ allowed |

Record each run's actual output in [evidence/Evidence-Report-Template.md](evidence/Evidence-Report-Template.md).

---

## 4. Controls shared by every engineer

| Control | How it works |
|---|---|
| **Secure first login** | Secrets Manager generates a 20-character password per engineer (`onward/prod/onboarding/<user>`). A reset is forced at first sign-in, and no access keys exist. |
| **Every change is recorded** | The multi-Region trail `onward-prod-access-audit` logs every IAM change to an encrypted, versioned bucket that is kept even if the stack is deleted. |
| **Defined once, in Git** | Users, groups and boundaries all come from `templates/onboarding.yaml`, deployed by Git sync through `onboarding-deployment.yaml`. No inline policies exist; changing access means a reviewed commit. |
