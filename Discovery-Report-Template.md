# Discovery Report: Automating Secure Onboarding at Scale for Onward Logistics

| | |
|---|---|
| **Lab** | Automating Secure Onboarding at Scale for Onward Logistics (Security & Identity Management on AWS, Week 1) |
| **Name** | Patrick Ndaziramiye |
| **Date** | 19 October 2026 |
| **Client** | Onward Logistics (see the Client Profile) |

> This report contains no keys, passwords or secrets, and neither does the repository.

---

## 1. What I found

### The client's need

Onward Logistics hires five to ten engineers a month and needs every one of them to get exactly the access their job requires, built the same way every time. Some engineers must be guaranteed never to change production compute, outsiders must only ever get temporary access, and the company must be able to show an auditor who changed access and when.

### Solutions that exist

| Solution | How it works | Trade-off for this client |
|---|---|---|
| **1. Manual set-up in the AWS Console (what they do today)** | An admin creates each user, picks policies and shares a password by hand. | **Strength:** no tooling or new skills needed. **Weakness:** this is exactly the problem the internal audit flagged. Results depend on who is on shift, over-permissioning creeps in, and there is no reliable record of who approved what. At ten hires a month it does not scale for a small platform team. |
| **2. AWS IAM Identity Center with a corporate identity provider** | Engineers sign in through single sign-on and receive short-lived credentials from permission sets mapped to their job. | **Strength:** AWS's recommended long-term model for people, with no long-lived credentials in AWS. **Weakness:** it needs AWS Organizations and an identity provider integration. That is more change than the client can absorb before the next hiring wave, and the lab requires IAM entities defined in a Git-synced template. |
| **3. Infrastructure as Code: IAM groups and permission boundaries deployed from Git with CloudFormation Git sync** | Job roles, guardrails, first-login credentials and audit logging are written once in a template. Every change is a Git commit that CloudFormation applies automatically. | **Strength:** identical, reviewable, repeatable onboarding with a permanent change history, and boundaries keep access capped even if someone over-grants later. **Weakness:** engineers still sign in as IAM users with passwords, and the team needs basic Git and CloudFormation skills. |

### What happens with no solution

If Onward Logistics keeps configuring access by hand while hiring quickly, I see four business risks:

- **Data breach and fines.** Over-broad access turns one mistake into a major incident. In the 2019 Capital One breach, an over-permissioned role let an attacker read data on about 100 million people. The bank was fined USD 80 million and later paid USD 190 million to settle customer claims. For Onward, merchant and customer data is the product, so a breach goes straight to lost trust.
- **Outages on peak days.** In 2018 a former Cisco engineer whose cloud access had not been removed deleted 456 virtual machines running WebEx Teams. About 16,000 accounts were affected for up to two weeks, and the clean-up cost around USD 1.4 million. An engineer with more rights than needed, even acting by accident, could stop Onward's live parcel tracking.
- **Failed audits and legal exposure.** Without a record of who changed access and when, Onward cannot answer an auditor's "who approved this?". Data-protection rules apply in every market it operates in.
- **Uncontrolled cost.** Anyone who can launch compute by accident can create spend nobody owns. On thin delivery margins, unexplained spend is a real problem.

### Sources

1. AWS IAM User Guide, *Permissions boundaries for IAM entities*: https://docs.aws.amazon.com/IAM/latest/UserGuide/access_policies_boundaries.html
2. AWS IAM User Guide, *Security best practices in IAM*: https://docs.aws.amazon.com/IAM/latest/UserGuide/best-practices.html
3. AWS IAM User Guide, *How to use an external ID when granting access to a third party*: https://docs.aws.amazon.com/IAM/latest/UserGuide/id_roles_create_for-user_externalid.html
4. AWS IAM Identity Center User Guide: https://docs.aws.amazon.com/singlesignon/latest/userguide/what-is.html
5. AWS CloudFormation User Guide, *Git sync*: https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/git-sync.html
6. AWS CloudTrail User Guide: https://docs.aws.amazon.com/awscloudtrail/latest/userguide/cloudtrail-user-guide.html
7. AWS Secrets Manager User Guide, *Generate a password*: https://docs.aws.amazon.com/secretsmanager/latest/userguide/generate-password.html
8. AWS Cost Management User Guide, *Managing costs with AWS Budgets*: https://docs.aws.amazon.com/cost-management/latest/userguide/budgets-managing-costs.html
9. Office of the Comptroller of the Currency, *OCC Assesses $80 Million Civil Money Penalty Against Capital One* (Aug 2020): https://www.occ.gov/news-issuances/news-releases/2020/nr-occ-2020-101.html
10. U.S. Department of Justice, N.D. California, *San Jose Man Pleads Guilty To Damaging Cisco's Network* (Aug 2020): https://www.justice.gov/usao-ndca/pr/san-jose-man-pleads-guilty-damaging-cisco-s-network

---

## 2. The business value of my solution

### My chosen approach

I chose **Solution 3: onboarding written as code in Git and deployed automatically with CloudFormation Git sync**, with permission boundaries as the safety ceiling.

It suits Onward Logistics better than the alternatives because it fixes what the audit found, which is too much access for too many people, before the next hiring wave and without first rebuilding the company's identity setup:

- **The same every time.** Each job (storage engineer, compute engineer, on-call observer) is defined once. Ten hires a month get identical, correct access, whoever is on shift.
- **A guarantee that holds later.** Each engineer has a permission boundary, a ceiling that applies whatever is attached afterwards. The on-call boundary explicitly forbids creating, starting or terminating compute, so even if a teammate later grants that engineer administrator rights, they still cannot launch or delete servers.
- **Audit answers on demand.** Every access change is a Git commit with an author and a time, and CloudTrail records every change inside AWS. Auditors get two independent records.
- **Outsiders only get temporary access.** External parties such as auditors get no user account at all. They assume a role whose credentials expire after one hour.
- **Spend visible from day one.** A monthly budget emails the owner before money runs out.

This design also prepares the later move to IAM Identity Center (Solution 2), because the same job definitions can become permission sets.

### Services I will use

| Service | The job it does | Why this service, used this way |
|---|---|---|
| **AWS IAM groups (AWS managed policies only)** | One group per job function gives engineers their day-to-day permissions. | Access is decided once per role, not per person, so onboarding is consistent. AWS maintains the managed policies, which suits a small platform team, and I use no inline policies, as required. |
| **IAM permission boundaries** | Sets the maximum access each engineer or role can ever have. | This is the forward-looking cap the client asked for. It stops privilege creep, and it is what makes the on-call guarantee hold even after someone loosens the group's permissions. |
| **IAM users with forced password reset** | A console identity for each new engineer, with no access keys. | The engineer must set a personal password at first sign-in, so nobody else ever knows it. |
| **AWS Secrets Manager** | Generates a strong random first-login password per engineer. | No password is typed, chatted or committed to Git. CloudFormation reads it directly at deploy time. |
| **IAM role + AWS STS (temporary credentials)** | Lets outside parties assume a read-only auditor role with an External ID, for at most one hour. | Meets the Week 1 rule that outsiders get only temporary, limited access. Nothing is left behind that someone could forget to revoke. |
| **AWS CloudFormation** | Builds every resource from one template. | The same template gives the same result every time, and change sets show what will change before it happens. |
| **CloudFormation Git sync (AWS CodeConnections)** | Deploys the template automatically when the `main` branch changes. | Git becomes the single source of truth: reviewed, versioned and rebuildable from the repository, with nothing created by hand. |
| **AWS CloudTrail** | Records every API call, including IAM changes, in all Regions, with log file validation. | Answers "who changed access, and when?" with tamper-evident evidence. |
| **Amazon S3 (audit log bucket)** | Stores CloudTrail logs. | Encrypted, versioned, never public, HTTPS only, and kept if the stack is deleted. Storage engineers are explicitly blocked from it, so the evidence cannot be altered. |
| **AWS Budgets** | A monthly cost budget with email alerts at 80% of actual and 100% of forecast spend. | Makes spend visible from day one and protects thin delivery margins. |

### Who benefits, and how I will know

| Stakeholder | Benefit | How I would know |
|---|---|---|
| **Head of Security** | Can see exactly how access is defined and prove each engineer has only what their role needs. | The IAM policy simulator shows in-role actions "allowed" and everything else "denied". After AdministratorAccess is attached to the on-call engineer's group and user as a test, `RunInstances` and `TerminateInstances` are still "denied". |
| **Leadership** | Onboarding scales with hiring without adding risk or audit findings. | Every one of the five to ten monthly hires is onboarded by a single merged change, and the next internal audit has no "too much access" finding. |
| **Platform team (small team, large engineering group)** | Onboarding becomes a reviewed Git change instead of manual console work. | Onboarding time per hire falls to the time it takes to review and merge one change, and CloudTrail shows no IAM changes made outside the pipeline. |
| **New engineers (storage and compute)** | The right access on day one and a secure first login. | Each hire signs in on day one, is forced to set their own password, and raises no access tickets in their first week. |
| **On-call engineers** | They can confirm a deployment landed without any risk of accidentally stopping production. | Describe actions are allowed, all create, start and terminate actions are denied, and no incidents are caused by on-call activity. |
| **Auditors and other outside parties** | Read-only access to evidence when they need it, with no account to manage. | Role sessions expire after one hour, a request without the External ID is refused, and data and secret reads are denied. |
| **Finance / budget owner** | Spend is visible and owned from the first day. | The budget shows current spend, and an alert arrives before the monthly limit is reached. |

### Limits and risks of my design

- **IAM users still hold passwords.** These are long-lived credentials. The Client Profile asks to avoid them where possible, so the next step is IAM Identity Center with short-lived single sign-on credentials.
- **MFA is not yet enforced.** A stolen password would still work within that engineer's boundary. I would add an MFA condition to the boundaries.
- **Broad rights within each role.** Storage and compute engineers can act on every bucket or instance in the account, not just tagged ones. Scoping by tag or name would reduce the impact of a mistake.
- **The pipeline is powerful.** Anyone who can merge to `main` can change access, and the deploy role has wide IAM rights. Branch protection with required reviews is essential so that "who approved this" is always a named reviewer.
- **Manual steps remain.** Handing the first password to the hire, approving the GitHub connection once, and offboarding leavers are not yet automated. The generated secrets also remain after first sign-in.
- **Logging without alerting.** CloudTrail records changes but does not alert anyone. Real-time alerts on IAM changes would cut reaction time from days to minutes.
- **Scope.** This covers one AWS account, and users are listed individually in the template. That is fine for the current team size, but it will need restructuring as the company grows into multiple accounts.
