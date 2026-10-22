# How the two templates work, line by line

This explains [templates/onboarding.yaml](templates/onboarding.yaml) and [git-sync/connection-and-roles.yaml](git-sync/connection-and-roles.yaml) from top to bottom. Line numbers match the files as committed.

**The big picture:**

- `connection-and-roles.yaml` is deployed **once** by hand. It links AWS to GitHub and creates the two roles that deploy everything else.
- `onboarding.yaml` is deployed **automatically** by Git sync every time `main` changes. It creates the engineers and their access.

```text
connection-and-roles.yaml  ──creates──►  GitHub connection + GitSyncRole + StackDeployRole
                                                   │
onboarding-deployment.yaml  ──points to──►  onboarding.yaml
                                                   │  (Git sync deploys it using the two roles)
                                                   ▼
                                  boundaries, groups, secrets, users, audit trail
```

---

## Part 1: `git-sync/connection-and-roles.yaml` (the bootstrap)

Read this one first, because it must exist before the onboarding template can be deployed.

### Lines 1–18: header comment

Says what the file is, the exact command to deploy it once (`aws cloudformation deploy ... --stack-name onward-gitsync-bootstrap --capabilities CAPABILITY_NAMED_IAM`), and the one manual step: approving the GitHub connection in the console.

`CAPABILITY_NAMED_IAM` is required because the file creates IAM roles with fixed names. Without it CloudFormation refuses to run.

### Lines 19–24: template version and description

| Line | Meaning |
|---|---|
| `AWSTemplateFormatVersion: '2010-09-09'` | The only valid CloudFormation template version. Always this value. |
| `Description: >-` | Text shown in the CloudFormation console. `>-` joins the following lines into one sentence. |

### Lines 26–32: `Parameters`

| Line | Meaning |
|---|---|
| `ProviderType` | Where the Git repository is hosted. |
| `Default: GitHub` | Used unless you choose otherwise. |
| `AllowedValues: [...]` | The console only accepts these four providers. |

### Lines 38–42: `RepoConnection`, the link to GitHub

| Line | Meaning |
|---|---|
| `Type: AWS::CodeConnections::Connection` | Creates a connection between AWS and a Git provider. |
| `ConnectionName: onward-onboarding-repo` | Its name in *Developer Tools → Settings → Connections*. |
| `ProviderType: !Ref ProviderType` | `!Ref` reads the parameter above (GitHub). |

It is created as **PENDING**. A person must approve it once in the console, and then it becomes **AVAILABLE**.

### Lines 48–85: `GitSyncPolicy`, what Git sync is allowed to do

`Type: AWS::IAM::ManagedPolicy` is a reusable, named permission policy (`onward-gitsync-sync-policy`). Its statements:

| Sid (line) | Allows | Why |
|---|---|---|
| `DriveStack` (55) | `cloudformation:CreateChangeSet`, `ExecuteChangeSet`, `DescribeStacks`, … | Git sync updates the stack by creating a change set (a preview of changes) and then executing it. |
| `ManagedEventRules` (69) | `events:PutRule`, `events:PutTargets` | Git sync sets up EventBridge rules to follow the stack's progress. The `Condition` limits this to rules managed by Git sync itself. |
| `DescribeEventRules` (77) | `events:DescribeRule` | Lets Git sync read those rules. It is part of the policy AWS documents for Git sync. |
| `PassStackRole` (81) | `iam:PassRole` on `StackDeployRole` only | Lets Git sync hand the deploy role to CloudFormation, and no other role. `!GetAtt StackDeployRole.Arn` reads that role's ARN. |

### Lines 87–97: `GitSyncRole`, the identity Git sync runs as

| Line | Meaning |
|---|---|
| `Type: AWS::IAM::Role` | A role: an identity with no password that a trusted service *assumes* to get short-lived credentials. |
| `RoleName: onward-gitsync-role` | The name you choose under "Git sync role" when creating the stack. |
| `AssumeRolePolicyDocument` | The **trust policy**: who may use this role. |
| `Principal: {Service: cloudformation.sync.codeconnections.amazonaws.com}` | Only the Git sync service may use it. No person can. |
| `Action: sts:AssumeRole` | The permission to take on the role. |
| `ManagedPolicyArns: [!Ref GitSyncPolicy]` | Gives the role the permissions from lines 48–85. |

### Lines 103–117: `StackDeployPolicy`, what the onboarding stack may build

The policy `onward-onboarding-stack-deploy` allows `iam:*`, `secretsmanager:*`, `s3:*` and `cloudtrail:*`. These are exactly the four services `onboarding.yaml` uses. If the onboarding template ever uses a new service, it must be added here first, or the deployment fails.

### Lines 121–131: `StackDeployRole`, the identity CloudFormation builds with

| Line | Meaning |
|---|---|
| `RoleName: onward-onboarding-stack-role` | The name you choose as the stack's service role. |
| `Principal: {Service: cloudformation.amazonaws.com}` | Only CloudFormation may use it. |
| `ManagedPolicyArns: [!Ref StackDeployPolicy]` | Gives it the permissions from lines 103–117. |

**Why two roles:** people do not need permanent rights to change IAM. Only the reviewed pipeline (Git → Git sync → CloudFormation) changes access.

### Lines 137–146: `Outputs`

Values printed on the stack's **Outputs** tab after deployment.

| Output | Used for |
|---|---|
| `ConnectionArn` | The connection to approve. `verify-access.sh` §8 checks it is `AVAILABLE`. |
| `GitSyncRoleArn` | Chosen as the Git sync role. §8 checks Git sync really uses it. |
| `StackDeployRoleArn` | Chosen as the stack service role. §8 checks the stack really uses it. |

---

## Part 2: `templates/onboarding.yaml` (the engineers and their access)

### Lines 1–13: header comment

Says what the file creates, that it is deployed only by Git sync (through `onboarding-deployment.yaml`), that it runs in eu-west-1, and that `verify-access.sh` checks it.

### Lines 14–20: version and description

These work the same as in Part 1.

### Lines 22–34: `Parameters`

| Parameter | Meaning |
|---|---|
| `Environment` (24) | Text put into every name, e.g. `prod` gives `onward-prod-storage-engineers`. `AllowedPattern: '[a-z0-9-]+'` allows only lowercase letters, digits and dashes. Its value comes from `onboarding-deployment.yaml`. |
| `CreateAuditTrail` (30) | `'true'` or `'false'`. Set it to `'false'` when the account already has a trail, so the stack does not try to create a second one. |

### Lines 36–38: `Conditions`

`MakeTrail: !Equals [!Ref CreateAuditTrail, 'true']` is true only when `CreateAuditTrail` is `'true'`. Resources marked `Condition: MakeTrail` are created only then.

### Lines 40–152: section 1, permission boundaries (the ceilings)

A **permission boundary** is the maximum a user can ever do. A user's real access is what their group allows **and** what their boundary allows. Anything outside the boundary is impossible, even if someone attaches AdministratorAccess later.

**Lines 49–68: `StorageBoundary`** (`onward-prod-boundary-storage`, for s3-user)

| Sid | Effect |
|---|---|
| `StorageWork` (57) | Allow everything in S3 (`s3:*`). |
| `SelfServicePassword` (61) | Allow changing **own** password only. `${!aws:username}` becomes the signed-in user's name. The `!` stops CloudFormation from treating it as its own variable. |
| `ReadPasswordPolicy` (65) | Allow reading the password rules, so the console can show them when the password is changed. |

**Lines 72–97: `ComputeBoundary`** (`onward-prod-boundary-compute`, for ec2-user-1)

| Sid | Effect |
|---|---|
| `ComputeWork` (80) | Allow EC2, load balancers and Auto Scaling fully, and CloudWatch read-only (`Describe*`, `Get*`, `List*`). |
| `SelfServicePassword`, `ReadPasswordPolicy` (90, 94) | Same as the storage boundary. |

**Lines 101–150: `ObserverBoundary`** (`onward-prod-boundary-compute-observer`, for ec2-user-2)

| Sid | Effect |
|---|---|
| `ObserveCompute` (111) | Allow only **looking**: `Describe*`, `Get*`, `List*` on EC2, load balancers, Auto Scaling and CloudWatch. |
| `SelfServicePassword`, `ReadPasswordPolicy` (122, 126) | Same as the other boundaries. |
| `NeverCreateOrTerminateCompute` (132) | **Deny** run, start, terminate, fleets, spot requests and Auto Scaling changes. An explicit Deny beats any Allow, from any policy, now or later. |
| `NeverTouchOwnBoundary` (145) | **Deny** removing or replacing a boundary, so the user cannot lift their own ceiling. |

### Lines 154–183: section 2, groups (the job functions)

Each group gives a job's day-to-day permissions using **AWS managed policies** only (policies AWS writes and maintains). No inline policies.

| Group (line) | Name | Policies |
|---|---|---|
| `StorageEngineersGroup` (157) | `onward-prod-storage-engineers` | `AmazonS3FullAccess`, `IAMUserChangePassword` |
| `ComputeEngineersGroup` (166) | `onward-prod-compute-engineers` | `AmazonEC2FullAccess`, `IAMUserChangePassword` |
| `OnCallObserversGroup` (176) | `onward-prod-oncall-observers` | `AmazonEC2ReadOnlyAccess`, `IAMUserChangePassword` |

`!Sub arn:${AWS::Partition}:iam::aws:policy/...` builds the policy's ARN. `${AWS::Partition}` is `aws` in normal Regions.

### Lines 185–226: section 3, first-login passwords

There is one `AWS::SecretsManager::Secret` per user (lines 190, 203, 216).

| Line | Meaning |
|---|---|
| `Name: !Sub onward/${Environment}/onboarding/s3-user` | Where the admin finds the password. |
| `GenerateSecretString` | Secrets Manager **generates** the password, so nobody types it and it is never in Git. |
| `SecretStringTemplate: '{"username":"s3-user"}'` | The secret is stored as JSON with the user name… |
| `GenerateStringKey: password` | …and the generated value is added under the key `password`. |
| `PasswordLength: 20`, `RequireEachIncludedType: true` | 20 characters, with uppercase, lowercase, digits and symbols. |
| `ExcludeCharacters` | Leaves out characters that are awkward to type or that break quoting. |

### Lines 228–270: section 4, users

There is one `AWS::IAM::User` per engineer: `S3User` (233), `Ec2User1` (246) and `Ec2User2` (259).

| Line | Meaning |
|---|---|
| `UserName: s3-user` | The sign-in name. |
| `Groups: [!Ref StorageEngineersGroup]` | Puts the user in their job group. |
| `PermissionsBoundary: !Ref StorageBoundary` | Attaches their ceiling from section 1. |
| `LoginProfile` → `Password: '{{resolve:secretsmanager:...:password}}'` | Gives the user a console password. `{{resolve:...}}` is a **dynamic reference**: CloudFormation reads the password from the secret at deploy time, so it never appears in the template or the stack. |
| `PasswordResetRequired: true` | Forces a new password at first sign-in, so the admin never knows the working one. |
| `Tags: Role` | A label (`storage-engineer`, `compute-engineer`, `oncall-observer`) for searching and reporting. |

No access keys are created, so no long-lived programmatic credentials exist.

### Lines 272–346: section 5, audit trail

All three resources have `Condition: MakeTrail`, so they exist only when `CreateAuditTrail` is `'true'`.

**Lines 278–295: `AuditBucket`**, where CloudTrail logs are stored

| Line | Meaning |
|---|---|
| `DeletionPolicy: Retain`, `UpdateReplacePolicy: Retain` | The bucket is **kept** even if the stack is deleted or the bucket replaced. It is audit evidence. |
| `VersioningConfiguration: Enabled` | Every overwrite or delete keeps the old version. |
| `BucketEncryption: AES256` | Logs are encrypted at rest. |
| `PublicAccessBlockConfiguration` (four `true`) | The bucket can never be made public. |
| `ObjectOwnership: BucketOwnerEnforced` | Disables ACLs; the account owns every object. |

**Lines 299–331: `AuditBucketPolicy`**, who may write to the bucket

This is a policy attached to the bucket (a resource policy), not to a user, so it is not an IAM inline policy.

| Sid (line) | Effect |
|---|---|
| `CloudTrailAclCheck` (307) | Allows CloudTrail to check the bucket before writing. |
| `CloudTrailWrite` (315) | Allows CloudTrail to write logs under `AWSLogs/<account>/`. |
| Both conditions: `aws:SourceArn` = this stack's trail | Only **this** trail may write. This stops another account's trail from using your bucket. |
| `DenyInsecureTransport` (323) | Denies any request not using HTTPS (`aws:SecureTransport: false`). |

**Lines 335–346: `AuditTrail`**, the recorder

| Line | Meaning |
|---|---|
| `DependsOn: AuditBucketPolicy` | Creates the bucket policy first, or CloudTrail cannot write and creation fails. |
| `TrailName: onward-prod-access-audit` | The trail's name. |
| `IsLogging: true` | Starts recording immediately. |
| `IsMultiRegionTrail: true` | Records activity in **all** Regions. |
| `IncludeGlobalServiceEvents: true` | Includes IAM, so user, group and policy changes are captured. |
| `EnableLogFileValidation: true` | Adds signed digest files, so anyone can prove the logs were not altered. |

### Lines 351–406: `Outputs`

Values shown on the stack's **Outputs** tab. `verify-access.sh` reads them instead of guessing names, so a rename here is followed automatically.

| Outputs | What they give |
|---|---|
| `Environment`, `ConsoleSignInUrl` | Name prefix; the URL new engineers sign in at. |
| `S3UserName`, `Ec2User1Name`, `Ec2User2Name` | The three user names. |
| `...GroupName` (×3) | The three group names. |
| `...BoundaryArn` (×3) | The boundary each user should have (script §5 compares them). |
| `...SecretArn` (×3) | Where each first-login password is. These are ARNs only, never the password. |
| `AuditTrailName`, `AuditBucketName` | The trail and its bucket (only when `MakeTrail` is true). |

---

## Words used above

| Term | Meaning |
|---|---|
| `!Ref X` | The value of parameter `X`, or the name/ID of resource `X`. |
| `!Sub '...${X}...'` | Builds text by inserting values. |
| `!GetAtt X.Arn` | A specific attribute of resource `X`, here its ARN. |
| ARN | Amazon Resource Name: the unique ID of anything in AWS, e.g. `arn:aws:iam::123456789012:user/s3-user`. |
| Sid | A label for one statement in a policy. |
| Allow / Deny | A policy grants with Allow. An explicit Deny always wins over any Allow. |
| Stack | The set of resources CloudFormation creates from one template. |
