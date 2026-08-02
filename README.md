# Cloud Nuke

Scheduled and on-demand cleanup of billable cloud resources in AWS, OCI, and Azure accounts.

Credentials live in a GitHub secret. Which accounts are purged is controlled by a versioned config file in this repo — remove an account from the list to disable cleanup without rotating secrets.

## Setup

### 1. GitHub secret

Create repository secret `CLOUD_ACCOUNTS_CREDENTIALS` with JSON like [`config/credentials.example.json`](config/credentials.example.json):

```json
{
  "version": 1,
  "accounts": {
    "sub1": {
      "provider": "aws",
      "default_region": "ap-south-1",
      "credentials": {
        "aws_access_key": "AKIA...",
        "aws_access_secret": "..."
      }
    },
    "oci-lab": {
      "provider": "oci",
      "home_region": "ap-hyderabad-1",
      "credentials": {
        "tenancy_ocid": "ocid1.tenancy...",
        "user_ocid": "ocid1.user...",
        "fingerprint": "aa:bb:cc:...",
        "private_key": "-----BEGIN PRIVATE KEY-----\n...\n-----END PRIVATE KEY-----\n"
      }
    },
    "azure-lab": {
      "provider": "azure",
      "credentials": {
        "subscription_id": "00000000-0000-0000-0000-000000000000",
        "tenant_id": "11111111-1111-1111-1111-111111111111",
        "client_id": "22222222-2222-2222-2222-222222222222",
        "client_secret": "..."
      }
    }
  }
}
```

- Add or remove accounts in the secret when credentials change.
- `default_region` is optional for AWS; bootstrap region for CLI calls when `--region` is not set (defaults to `us-east-1`).
- `home_region` is optional for OCI; if omitted, the script probes common regions.
- Azure uses a service principal (`subscription_id`, `tenant_id`, `client_id`, `client_secret`). Cleanup covers the **entire subscription**.

### 2. Enabled accounts

Edit [`config/enabled-accounts.yaml`](config/enabled-accounts.yaml). Only accounts listed here are purged on schedule or by default manual runs.

To disable cleanup for `sub1`, remove its entry from the YAML and merge. Credentials for `sub1` can stay in the secret.

### 3. Test before enabling schedule

1. **Actions → Cleanup Cloud Accounts → Run workflow**
2. Set `dry_run: true` and optionally target a single `account`
3. Review logs
4. Run again with `dry_run: false` for one account
5. The workflow also runs automatically at **midnight IST** (`30 18 * * *` UTC)

## Local usage

```bash
# Single account (credentials file on disk)
./scripts/purge-cloud-account.sh \
  --account sub1 \
  --credentials-file /path/to/credentials.json \
  --dry-run

# All enabled accounts
./scripts/run-enabled-purges.sh \
  --credentials-file /path/to/credentials.json \
  --dry-run
```

Interactive runs prompt for `yes` before deleting. Pass `--yes` to skip (required in CI).

## What gets deleted

See script header in [`scripts/purge-cloud-account.sh`](scripts/purge-cloud-account.sh). Summary:

**AWS (per region + global):** EKS, EC2, ASGs, load balancers, NAT gateways, EIPs, VPCs, EBS, ECR, RDS, ElastiCache, EFS, S3, IAM roles/instance profiles, OIDC providers. Customer-managed IAM policies are **not** deleted (except `/kafka-streamtime/`).

**OCI (per region/compartment + global):** OKE, compute, LBs/NLBs, block/boot volumes, File Storage, Autonomous DBs, VCNs, object storage buckets, OCIR repos, Fleet Manager dynamic groups. IAM policies are **not** deleted.

**Azure (entire subscription, or single `--region` location):** Resource locks removed; AKS; VMs/VMSS; load balancers and Application Gateways; NAT gateways and public IPs; VNets and related networking; managed disks/snapshots; ACR; SQL/PostgreSQL/MySQL/Cosmos; Redis; NetApp; storage accounts; Container Instances/Apps; App Services/Functions; Firewall/Bastion/VPN; then all resource groups; soft-deleted Key Vaults purged. Entra ID apps, service principals, role assignments, and custom RBAC roles are **not** deleted.

## Safety

- Scheduled runs perform **real deletions**. The enabled-accounts config is the primary guardrail.
- Use dedicated cleanup IAM/OCI/Azure SP users with delete permissions scoped to test accounts only.
- Workflow uses concurrency control to prevent overlapping purges.
- Manual dispatch supports `dry_run` and single-account targeting.
