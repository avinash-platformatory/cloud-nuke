#!/bin/bash
set -euo pipefail

# purge-cloud-account.sh
#
# Nuke all billable resources in a cloud account. Supports AWS, OCI, and Azure.
# Credentials are loaded from a JSON credentials file (see config/credentials.example.json).
#
# AWS deletes (per region, in parallel):
#   EKS node groups + clusters, EC2, ASGs, ALB/NLB/CLB, NAT gateways,
#   Elastic IPs, VPCs + sub-resources, EBS volumes, ECR repos,
#   RDS instances, Aurora clusters, ElastiCache, EFS
#   Global: S3 buckets, IAM users/policies/roles under /kafka-streamtime/,
#   IAM roles/instance profiles, OIDC providers
#
# OCI deletes (per region, in parallel):
#   OKE node pools + clusters, compute instances, LBs + NLBs,
#   block/boot volumes, File Storage, Autonomous DBs, VCNs + sub-resources,
#   OCIR repos (incl. public)
#   Global: object storage buckets
#
# Azure deletes (entire subscription, or single --region/location):
#   AKS, VMs, VMSS, load balancers, Application Gateways, NAT gateways,
#   public IPs, VNets + NSGs/route tables/private endpoints, managed disks,
#   snapshots, ACR, SQL/PostgreSQL/MySQL/Cosmos, Redis, NetApp, storage
#   accounts, Container Instances/Apps, App Services, Functions, Firewall,
#   Bastion, VPN gateways, Disk Encryption Sets; then resource groups;
#   soft-deleted Key Vaults purged.
#   Entra ID / role assignments / custom RBAC roles are NEVER deleted.
#
# Other IAM *customer-managed policies* are never deleted (AWS or OCI): not a direct
# billing line item; safe to leave for human / IaC cleanup. Exception: policies
# under /kafka-streamtime/ are deleted with their users (Fleet Manager S3 access).
# Inline policies on IAM roles may still be removed when deleting those roles (AWS).
#
# Usage:
#   ./scripts/purge-cloud-account.sh --account sub1 --credentials-file /path/to/creds.json
#   ./scripts/purge-cloud-account.sh --account oci-lab --credentials-file creds.json --dry-run
#   ./scripts/purge-cloud-account.sh --account azure-lab --credentials-file creds.json --yes
#   ./scripts/purge-cloud-account.sh --account sub1 --credentials-file creds.json --region us-east-1 --yes
#
# Options:
#   --account              Account name (key in credentials JSON; required)
#   --credentials-file     Path to credentials JSON (or CLOUD_ACCOUNTS_CREDENTIALS_FILE)
#   --region               Single region to target (default: all regions)
#   --dry-run              Print what would be deleted without acting
#   --yes                  Skip interactive confirmation (required for CI)

# ── Args ──────────────────────────────────────────────────────────────────────
ACCOUNT_NAME=""
CREDENTIALS_FILE="${CLOUD_ACCOUNTS_CREDENTIALS_FILE:-}"
TARGET_REGION=""
DRY_RUN=false
AUTO_YES=false

while [[ $# -gt 0 ]]; do
  case $1 in
    --account)            ACCOUNT_NAME="$2";       shift 2 ;;
    --credentials-file)   CREDENTIALS_FILE="$2";   shift 2 ;;
    --region)             TARGET_REGION="$2";      shift 2 ;;
    --dry-run)            DRY_RUN=true;             shift   ;;
    --yes)                AUTO_YES=true;            shift   ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

[[ -z "$ACCOUNT_NAME"     ]] && { echo "Error: --account is required" >&2; exit 1; }
[[ -z "$CREDENTIALS_FILE" ]] && { echo "Error: --credentials-file is required (or set CLOUD_ACCOUNTS_CREDENTIALS_FILE)" >&2; exit 1; }
[[ ! -f "$CREDENTIALS_FILE" ]] && { echo "Error: credentials file not found: $CREDENTIALS_FILE" >&2; exit 1; }

# ── Helpers ───────────────────────────────────────────────────────────────────
# Parse JSON tolerantly (private keys may contain raw newlines, violating strict JSON)
# Re-injects clean JSON back into sys.stdin so callers can still use json.load(sys.stdin)
py() { python3 -c "
import json, sys, re, io
raw = sys.stdin.read()
try:
    _d = json.loads(raw)
except json.JSONDecodeError:
    _d = json.loads(raw, strict=False)
sys.stdin = io.StringIO(json.dumps(_d))
$1
" 2>/dev/null || true; }

noop() { echo "  [dry-run] $*"; }

require_cmd() {
  command -v "$1" &>/dev/null || { echo "Error: '$1' CLI not found. Install it before running this script." >&2; exit 1; }
}

# ── Load account credentials from JSON ────────────────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Loading credentials for: $ACCOUNT_NAME"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

mapfile -t _cred_lines < <(python3 -c "
import json, sys

with open('$CREDENTIALS_FILE') as f:
    data = json.load(f)

accounts = data.get('accounts', {})
if '$ACCOUNT_NAME' not in accounts:
    print(f\"Error: account '$ACCOUNT_NAME' not found in credentials file\", file=sys.stderr)
    sys.exit(1)

acct = accounts['$ACCOUNT_NAME']
provider = acct.get('provider', '')
if provider not in ('aws', 'oci', 'azure'):
    print(f\"Error: unsupported provider '{provider}' for account '$ACCOUNT_NAME'\", file=sys.stderr)
    sys.exit(1)

provider_json = {'provider': provider, 'configuration': acct.get('credentials', {})}
home_region = acct.get('home_region', '') or ''
default_region = acct.get('default_region', '') or ''
print(json.dumps(provider_json))
print(home_region)
print(default_region)
")
PROVIDER_JSON="${_cred_lines[0]}"
OCI_HOME_REGION="${_cred_lines[1]:-}"
AWS_ACCOUNT_DEFAULT_REGION="${_cred_lines[2]:-}"

PROVIDER_TYPE=$(echo "$PROVIDER_JSON" | py "import json,sys; print(json.load(sys.stdin).get('provider',''))")
echo "  Provider type: $PROVIDER_TYPE"

# ══════════════════════════════════════════════════════════════════════════════
# AWS
# ══════════════════════════════════════════════════════════════════════════════
run_aws() {
  export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
  AWS_ACCESS_KEY_ID=$(echo "$PROVIDER_JSON" | py "import json,sys; print(json.load(sys.stdin)['configuration']['aws_access_key'])")
  AWS_SECRET_ACCESS_KEY=$(echo "$PROVIDER_JSON" | py "import json,sys; print(json.load(sys.stdin)['configuration']['aws_access_secret'])")
  AWS_SESSION_TOKEN=$(echo "$PROVIDER_JSON" | py "import json,sys; print(json.load(sys.stdin)['configuration'].get('aws_session_token') or '')")
  [[ -z "$AWS_SESSION_TOKEN" ]] && unset AWS_SESSION_TOKEN

  # AWS CLI v2 requires a default region (GHA runners have no aws configure).
  export AWS_DEFAULT_REGION="${TARGET_REGION:-${AWS_ACCOUNT_DEFAULT_REGION:-us-east-1}}"
  export AWS_REGION="$AWS_DEFAULT_REGION"

  if ! aws sts get-caller-identity --output json &>/dev/null; then
    echo "Error: AWS credentials for '$ACCOUNT_NAME' are invalid or expired." >&2; exit 1
  fi
  echo "  Credentials validated."

  REGIONS=()
  if [[ -n "$TARGET_REGION" ]]; then
    REGIONS=("$TARGET_REGION")
  else
    echo "  Discovering enabled regions..."
    while IFS= read -r r; do [[ -n "$r" ]] && REGIONS+=("$r"); done < <(
      aws --output json ec2 describe-regions --all-regions \
        | py "import json,sys; [print(r['RegionName']) for r in json.load(sys.stdin).get('Regions',[]) if r.get('OptInStatus') != 'not-opted-in']"
    )
  fi
  [[ ${#REGIONS[@]} -eq 0 ]] && { echo "Error: no regions found." >&2; exit 1; }
  if [[ -z "$TARGET_REGION" ]]; then
    export AWS_DEFAULT_REGION="${REGIONS[0]}"
    export AWS_REGION="$AWS_DEFAULT_REGION"
  fi
  echo "  Regions: ${REGIONS[*]}"

  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  Account:              $ACCOUNT_NAME  (aws)"
  echo "  Regions:            ${REGIONS[*]}"
  echo "  Dry run:            $DRY_RUN"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  if [[ "$DRY_RUN" == "false" && "$AUTO_YES" == "false" ]]; then
    read -r -p "⚠  DELETE ALL resources in $ACCOUNT_NAME (AWS). Type 'yes': " C
    [[ "$C" == "yes" ]] || { echo "Aborted."; exit 0; }
  fi

  aws_sweep_region() {
    local REGION="$1"
    local A="aws --region $REGION --output json"

    local CLUSTERS INSTANCES VPCS NATS
    # Purge all billable resources in the region for this account (no ManagedBy tag gate).
    CLUSTERS=$($A eks list-clusters \
      | py "import json,sys; [print(x) for x in json.load(sys.stdin).get('clusters',[])]" 2>/dev/null || true)
    INSTANCES=$($A ec2 describe-instances \
      --filters "Name=instance-state-name,Values=pending,running,stopping,stopped" \
      | py "import json,sys; [print(i['InstanceId']) for r in json.load(sys.stdin).get('Reservations',[]) for i in r.get('Instances',[])]" 2>/dev/null || true)
    VPCS=$($A ec2 describe-vpcs \
      --filters "Name=isDefault,Values=false" \
      | py "import json,sys; [print(v['VpcId']) for v in json.load(sys.stdin).get('Vpcs',[])]" 2>/dev/null || true)
    NATS=$($A ec2 describe-nat-gateways \
      --filter "Name=state,Values=available,pending" \
      | py "import json,sys; [print(n['NatGatewayId']) for n in json.load(sys.stdin).get('NatGateways',[])]" 2>/dev/null || true)

    echo "  [aws/$REGION] sweeping (billable resources; IAM customer-managed policies skipped globally)..."

    # EKS
    for CLUSTER in $CLUSTERS; do
      echo "  [aws/$REGION] EKS: $CLUSTER"
      local NGS NG_PIDS=()
      NGS=$($A eks list-nodegroups --cluster-name "$CLUSTER" \
        | py "import json,sys; [print(x) for x in json.load(sys.stdin).get('nodegroups',[])]" 2>/dev/null || true)
      for NG in $NGS; do
        echo "  [aws/$REGION]   node group: $NG"
        [[ "$DRY_RUN" == "false" ]] && {
          ($A eks delete-nodegroup --cluster-name "$CLUSTER" --nodegroup-name "$NG" >/dev/null 2>&1
           $A eks wait nodegroup-deleted --cluster-name "$CLUSTER" --nodegroup-name "$NG" 2>/dev/null || true) &
          NG_PIDS+=($!)
        }
      done
      [[ ${#NG_PIDS[@]} -gt 0 ]] && wait "${NG_PIDS[@]}" 2>/dev/null || true
      for FP in $($A eks list-fargate-profiles --cluster-name "$CLUSTER" \
        | py "import json,sys; [print(x) for x in json.load(sys.stdin).get('fargateProfileNames',[])]" 2>/dev/null || true); do
        [[ "$DRY_RUN" == "false" ]] && $A eks delete-fargate-profile --cluster-name "$CLUSTER" --fargate-profile-name "$FP" >/dev/null 2>&1 || true
      done
      echo "  [aws/$REGION]   deleting cluster"
      [[ "$DRY_RUN" == "false" ]] && { $A eks delete-cluster --name "$CLUSTER" >/dev/null 2>&1 || true
        $A eks wait cluster-deleted --name "$CLUSTER" 2>/dev/null || true; }
    done

    # Parallel: ASGs, EC2, LBs, EBS, ECR
    { local ASGS; ASGS=$($A autoscaling describe-auto-scaling-groups \
        | py "import json,sys; [print(g['AutoScalingGroupName']) for g in json.load(sys.stdin).get('AutoScalingGroups',[])]" 2>/dev/null || true)
      for ASG in $ASGS; do echo "  [aws/$REGION] ASG: $ASG"
        [[ "$DRY_RUN" == "false" ]] && $A autoscaling delete-auto-scaling-group --auto-scaling-group-name "$ASG" --force-delete >/dev/null 2>&1 || true; done
    } &
    { if [[ -n "$INSTANCES" ]]; then echo "  [aws/$REGION] EC2 instances: $INSTANCES"
        [[ "$DRY_RUN" == "false" ]] && { $A ec2 terminate-instances --instance-ids $INSTANCES >/dev/null 2>&1 || true
          $A ec2 wait instance-terminated --instance-ids $INSTANCES 2>/dev/null || true; }; fi
    } &
    { for LB in $($A elbv2 describe-load-balancers \
        | py "import json,sys; [print(lb['LoadBalancerArn']) for lb in json.load(sys.stdin).get('LoadBalancers',[])]" 2>/dev/null || true); do
        echo "  [aws/$REGION] LB: $LB"
        [[ "$DRY_RUN" == "false" ]] && $A elbv2 delete-load-balancer --load-balancer-arn "$LB" >/dev/null 2>&1 || true; done
      for TG in $($A elbv2 describe-target-groups \
        | py "import json,sys; [print(tg['TargetGroupArn']) for tg in json.load(sys.stdin).get('TargetGroups',[])]" 2>/dev/null || true); do
        [[ "$DRY_RUN" == "false" ]] && $A elbv2 delete-target-group --target-group-arn "$TG" >/dev/null 2>&1 || true; done
      for LB in $($A elb describe-load-balancers \
        | py "import json,sys; [print(lb['LoadBalancerName']) for lb in json.load(sys.stdin).get('LoadBalancerDescriptions',[])]" 2>/dev/null || true); do
        echo "  [aws/$REGION] classic LB: $LB"
        [[ "$DRY_RUN" == "false" ]] && $A elb delete-load-balancer --load-balancer-name "$LB" >/dev/null 2>&1 || true; done
    } &
    { for VOL in $($A ec2 describe-volumes --filters "Name=status,Values=available" \
        | py "import json,sys; [print(v['VolumeId']) for v in json.load(sys.stdin).get('Volumes',[])]" 2>/dev/null || true); do
        echo "  [aws/$REGION] EBS: $VOL"
        [[ "$DRY_RUN" == "false" ]] && $A ec2 delete-volume --volume-id "$VOL" >/dev/null 2>&1 || true; done
    } &
    { for REPO in $($A ecr describe-repositories \
        | py "import json,sys; [print(r['repositoryName']) for r in json.load(sys.stdin).get('repositories',[])]" 2>/dev/null || true); do
        echo "  [aws/$REGION] ECR: $REPO"
        [[ "$DRY_RUN" == "false" ]] && $A ecr delete-repository --repository-name "$REPO" --force >/dev/null 2>&1 || true; done
    } &
    { for DB in $($A rds describe-db-instances \
        | py "import json,sys; [print(x['DBInstanceIdentifier']) for x in json.load(sys.stdin).get('DBInstances',[]) if x.get('DBInstanceStatus','') not in ('deleting','deleted') and not x.get('DBClusterIdentifier')]" 2>/dev/null || true); do
        echo "  [aws/$REGION] RDS instance: $DB"
        [[ "$DRY_RUN" == "false" ]] && $A rds delete-db-instance --db-instance-identifier "$DB" --skip-final-snapshot --delete-automated-backups 2>/dev/null || true
      done
      for CLU in $($A rds describe-db-clusters \
        | py "import json,sys; [print(x['DBClusterIdentifier']) for x in json.load(sys.stdin).get('DBClusters',[]) if x.get('Status','') not in ('deleting','deleted')]" 2>/dev/null || true); do
        echo "  [aws/$REGION] RDS cluster: $CLU"
        [[ "$DRY_RUN" == "false" ]] && $A rds delete-db-cluster --db-cluster-identifier "$CLU" --skip-final-snapshot --delete-automated-backups 2>/dev/null || true
      done
      for DB in $($A rds describe-db-instances \
        | py "import json,sys; [print(x['DBInstanceIdentifier']) for x in json.load(sys.stdin).get('DBInstances',[]) if x.get('DBInstanceStatus','') not in ('deleting','deleted')]" 2>/dev/null || true); do
        echo "  [aws/$REGION] RDS instance (remaining): $DB"
        [[ "$DRY_RUN" == "false" ]] && $A rds delete-db-instance --db-instance-identifier "$DB" --skip-final-snapshot --delete-automated-backups 2>/dev/null || true
      done
    } &
    { for RG in $($A elasticache describe-replication-groups \
        | py "import json,sys; [print(x['ReplicationGroupId']) for x in json.load(sys.stdin).get('ReplicationGroups',[]) if x.get('Status','') not in ('deleting','deleted')]" 2>/dev/null || true); do
        echo "  [aws/$REGION] ElastiCache replication group: $RG"
        [[ "$DRY_RUN" == "false" ]] && $A elasticache delete-replication-group --replication-group-id "$RG" 2>/dev/null || true
      done
      for CC in $($A elasticache describe-cache-clusters \
        | py "import json,sys; [print(x['CacheClusterId']) for x in json.load(sys.stdin).get('CacheClusters',[]) if not x.get('ReplicationGroupId')]" 2>/dev/null || true); do
        echo "  [aws/$REGION] ElastiCache cluster: $CC"
        [[ "$DRY_RUN" == "false" ]] && $A elasticache delete-cache-cluster --cache-cluster-id "$CC" 2>/dev/null || true
      done
    } &
    { for FS in $($A efs describe-file-systems \
        | py "import json,sys; [print(x['FileSystemId']) for x in json.load(sys.stdin).get('FileSystems',[]) if x.get('LifeCycleState','') not in ('deleting','deleted')]" 2>/dev/null || true); do
        echo "  [aws/$REGION] EFS: $FS"
        if [[ "$DRY_RUN" == "false" ]]; then
          for MT in $($A efs describe-mount-targets --file-system-id "$FS" \
            | py "import json,sys; [print(x['MountTargetId']) for x in json.load(sys.stdin).get('MountTargets',[])]" 2>/dev/null || true); do
            $A efs delete-mount-target --mount-target-id "$MT" 2>/dev/null || true
          done
          sleep 15
          $A efs delete-file-system --file-system-id "$FS" 2>/dev/null || true
        fi
      done
    } &
    wait

    # NAT gateways (wait before EIPs/VPCs)
    local NAT_PIDS=()
    for NAT in $NATS; do
      echo "  [aws/$REGION] NAT gateway: $NAT"
      [[ "$DRY_RUN" == "false" ]] && {
        ($A ec2 delete-nat-gateway --nat-gateway-id "$NAT" >/dev/null 2>&1
         $A ec2 wait nat-gateway-deleted --nat-gateway-ids "$NAT" 2>/dev/null || true) &
        NAT_PIDS+=($!)
      }
    done
    [[ ${#NAT_PIDS[@]} -gt 0 ]] && wait "${NAT_PIDS[@]}" 2>/dev/null || true

    # EIPs
    for ALLOC in $($A ec2 describe-addresses \
      | py "import json,sys; [print(a['AllocationId']) for a in json.load(sys.stdin).get('Addresses',[]) if 'AllocationId' in a]" 2>/dev/null || true); do
      echo "  [aws/$REGION] EIP: $ALLOC"
      [[ "$DRY_RUN" == "false" ]] && $A ec2 release-address --allocation-id "$ALLOC" >/dev/null 2>&1 || true
    done

    # VPCs (each in parallel)
    local VPC_PIDS=()
    for VPC_ID in $VPCS; do
      { echo "  [aws/$REGION] VPC: $VPC_ID"
        [[ "$DRY_RUN" == "false" ]] && {
          for IGW in $($A ec2 describe-internet-gateways --filters "Name=attachment.vpc-id,Values=$VPC_ID" \
            | py "import json,sys; [print(x['InternetGatewayId']) for x in json.load(sys.stdin).get('InternetGateways',[])]" 2>/dev/null || true); do
            $A ec2 detach-internet-gateway --internet-gateway-id "$IGW" --vpc-id "$VPC_ID" >/dev/null 2>&1 || true
            $A ec2 delete-internet-gateway --internet-gateway-id "$IGW" >/dev/null 2>&1 || true; done
          for SUBNET in $($A ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC_ID" \
            | py "import json,sys; [print(s['SubnetId']) for s in json.load(sys.stdin).get('Subnets',[])]" 2>/dev/null || true); do
            $A ec2 delete-subnet --subnet-id "$SUBNET" >/dev/null 2>&1 || true; done
          for RT in $($A ec2 describe-route-tables --filters "Name=vpc-id,Values=$VPC_ID" \
            | py "import json,sys; [print(rt['RouteTableId']) for rt in json.load(sys.stdin).get('RouteTables',[]) if not any(a.get('Main') for a in rt.get('Associations',[]))]" 2>/dev/null || true); do
            $A ec2 delete-route-table --route-table-id "$RT" >/dev/null 2>&1 || true; done
          for SG in $($A ec2 describe-security-groups --filters "Name=vpc-id,Values=$VPC_ID" \
            | py "import json,sys; [print(sg['GroupId']) for sg in json.load(sys.stdin).get('SecurityGroups',[]) if sg['GroupName'] != 'default']" 2>/dev/null || true); do
            $A ec2 delete-security-group --group-id "$SG" >/dev/null 2>&1 || true; done
          $A ec2 delete-vpc --vpc-id "$VPC_ID" >/dev/null 2>&1 || true
          echo "  [aws/$REGION]   deleted VPC $VPC_ID"
        } || echo "  [dry-run] delete VPC $VPC_ID and sub-resources"
      } &
      VPC_PIDS+=($!)
    done
    [[ ${#VPC_PIDS[@]} -gt 0 ]] && wait "${VPC_PIDS[@]}" 2>/dev/null || true

    # Remaining EBS volumes (in-use volumes often fail until instances finish terminating)
    for VOL in $($A ec2 describe-volumes \
      | py "import json,sys; [print(v['VolumeId']) for v in json.load(sys.stdin).get('Volumes',[]) if v.get('State') not in ('deleting','deleted')]" 2>/dev/null || true); do
      echo "  [aws/$REGION] EBS (final pass): $VOL"
      [[ "$DRY_RUN" == "false" ]] && $A ec2 delete-volume --volume-id "$VOL" >/dev/null 2>&1 || true
    done
  }

  # All regions in parallel
  local PIDS=()
  for REGION in "${REGIONS[@]}"; do aws_sweep_region "$REGION" & PIDS+=($!); done
  wait "${PIDS[@]}" 2>/dev/null || true

  # Global resources
  export AWS_DEFAULT_REGION="${REGIONS[0]}"
  echo ""; echo "══════════════════════════════════════════════════"
  echo "  AWS global resources"; echo "══════════════════════════════════════════════════"

  # S3 buckets (parallel)
  local BUCKET_PIDS=()
  for BUCKET in $(aws --output json s3api list-buckets | py "import json,sys; [print(b['Name']) for b in json.load(sys.stdin).get('Buckets',[])]"); do
    { echo "  [aws/global] S3: $BUCKET"
      [[ "$DRY_RUN" == "false" ]] && {
        aws s3 rm "s3://$BUCKET" --recursive 2>/dev/null || true
        local VERS; VERS=$(aws --output json s3api list-object-versions --bucket "$BUCKET" 2>/dev/null \
          | py "import json,sys
data=json.load(sys.stdin)
objs=[{'Key':x['Key'],'VersionId':x['VersionId']} for x in data.get('Versions',[])+data.get('DeleteMarkers',[])]
import json as j; print(j.dumps({'Objects':objs,'Quiet':True})) if objs else exit(1)" || true)
        [[ -n "$VERS" ]] && aws s3api delete-objects --bucket "$BUCKET" --delete "$VERS" >/dev/null 2>&1 || true
        aws s3api delete-bucket --bucket "$BUCKET" 2>/dev/null || true
      } || echo "  [dry-run] delete bucket $BUCKET"
    } &
    BUCKET_PIDS+=($!)
  done
  [[ ${#BUCKET_PIDS[@]} -gt 0 ]] && wait "${BUCKET_PIDS[@]}" 2>/dev/null || true

  # IAM users/policies/roles under /kafka-streamtime/ (Fleet Manager S3 access artifacts)
  local KS_PATH="/kafka-streamtime/"
  for USER in $(aws --output json iam list-users --path-prefix "$KS_PATH" \
    | py "import json,sys; [print(u['UserName']) for u in json.load(sys.stdin).get('Users',[])]"); do
    echo "  [aws/global] IAM user (kafka-streamtime): $USER"
    [[ "$DRY_RUN" == "false" ]] && {
      for POL in $(aws --output json iam list-attached-user-policies --user-name "$USER" \
        | py "import json,sys; [print(p['PolicyArn']) for p in json.load(sys.stdin).get('AttachedPolicies',[])]"); do
        aws iam detach-user-policy --user-name "$USER" --policy-arn "$POL" 2>/dev/null || true; done
      for KEY in $(aws --output json iam list-access-keys --user-name "$USER" \
        | py "import json,sys; [print(k['AccessKeyId']) for k in json.load(sys.stdin).get('AccessKeyMetadata',[])]"); do
        aws iam delete-access-key --user-name "$USER" --access-key-id "$KEY" 2>/dev/null || true; done
      aws iam delete-user --user-name "$USER" 2>/dev/null || true
    } || echo "  [dry-run] delete IAM user $USER"
  done

  for POL_ARN in $(aws --output json iam list-policies --scope Local --path-prefix "$KS_PATH" \
    | py "import json,sys; [print(p['Arn']) for p in json.load(sys.stdin).get('Policies',[])]"); do
    echo "  [aws/global] IAM policy (kafka-streamtime): $POL_ARN"
    [[ "$DRY_RUN" == "false" ]] && {
      for VER in $(aws --output json iam list-policy-versions --policy-arn "$POL_ARN" \
        | py "import json,sys; [print(v['VersionId']) for v in json.load(sys.stdin).get('Versions',[]) if not v.get('IsDefaultVersion')]"); do
        aws iam delete-policy-version --policy-arn "$POL_ARN" --version-id "$VER" 2>/dev/null || true; done
      aws iam delete-policy --policy-arn "$POL_ARN" 2>/dev/null || true
    } || echo "  [dry-run] delete IAM policy $POL_ARN"
  done

  for ROLE in $(aws --output json iam list-roles --path-prefix "$KS_PATH" \
    | py "import json,sys; [print(r['RoleName']) for r in json.load(sys.stdin).get('Roles',[])]"); do
    echo "  [aws/global] IAM role (kafka-streamtime): $ROLE"
    [[ "$DRY_RUN" == "false" ]] && {
      for POL in $(aws --output json iam list-attached-role-policies --role-name "$ROLE" \
        | py "import json,sys; [print(p['PolicyArn']) for p in json.load(sys.stdin).get('AttachedPolicies',[])]"); do
        aws iam detach-role-policy --role-name "$ROLE" --policy-arn "$POL" 2>/dev/null || true; done
      for POL in $(aws --output json iam list-role-policies --role-name "$ROLE" \
        | py "import json,sys; [print(p) for p in json.load(sys.stdin).get('PolicyNames',[])]"); do
        aws iam delete-role-policy --role-name "$ROLE" --policy-name "$POL" 2>/dev/null || true; done
      aws iam delete-role --role-name "$ROLE" 2>/dev/null || true
    } || echo "  [dry-run] delete IAM role $ROLE"
  done

  # IAM instance profiles
  for PROFILE in $(aws --output json iam list-instance-profiles \
    | py "import json,sys; [print(p['InstanceProfileName']) for p in json.load(sys.stdin).get('InstanceProfiles',[]) if not p['InstanceProfileName'].startswith(('AmazonEKS','AWS'))]"); do
    echo "  [aws/global] instance profile: $PROFILE"
    [[ "$DRY_RUN" == "false" ]] && {
      for ROLE in $(aws --output json iam get-instance-profile --instance-profile-name "$PROFILE" \
        | py "import json,sys; [print(r['RoleName']) for r in json.load(sys.stdin).get('InstanceProfile',{}).get('Roles',[])]"); do
        aws iam remove-role-from-instance-profile --instance-profile-name "$PROFILE" --role-name "$ROLE" 2>/dev/null || true; done
      aws iam delete-instance-profile --instance-profile-name "$PROFILE" 2>/dev/null || true
    } || echo "  [dry-run] delete instance profile $PROFILE"
  done

  # IAM roles
  for ROLE in $(aws --output json iam list-roles \
    | py "import json,sys; [print(r['RoleName']) for r in json.load(sys.stdin).get('Roles',[]) if not r['Path'].startswith('/aws-service-role/') and not r['RoleName'].startswith(('AWS','OrganizationAccountAccessRole'))]"); do
    echo "  [aws/global] IAM role: $ROLE"
    [[ "$DRY_RUN" == "false" ]] && {
      for POL in $(aws --output json iam list-attached-role-policies --role-name "$ROLE" \
        | py "import json,sys; [print(p['PolicyArn']) for p in json.load(sys.stdin).get('AttachedPolicies',[])]"); do
        aws iam detach-role-policy --role-name "$ROLE" --policy-arn "$POL" 2>/dev/null || true; done
      for POL in $(aws --output json iam list-role-policies --role-name "$ROLE" \
        | py "import json,sys; [print(p) for p in json.load(sys.stdin).get('PolicyNames',[])]"); do
        aws iam delete-role-policy --role-name "$ROLE" --policy-name "$POL" 2>/dev/null || true; done
      aws iam delete-role --role-name "$ROLE" 2>/dev/null || true
    } || echo "  [dry-run] delete role $ROLE"
  done

  # Other customer-managed IAM policies: intentionally NOT deleted (no usage charge; keep for audit / IaC).

  # OIDC providers
  for OIDC_ARN in $(aws --output json iam list-open-id-connect-providers \
    | py "import json,sys; [print(p['Arn']) for p in json.load(sys.stdin).get('OpenIDConnectProviderList',[])]"); do
    echo "  [aws/global] OIDC provider: $OIDC_ARN"
    [[ "$DRY_RUN" == "false" ]] && aws iam delete-open-id-connect-provider \
      --open-id-connect-provider-arn "$OIDC_ARN" 2>/dev/null || true
  done
}

# ══════════════════════════════════════════════════════════════════════════════
# OCI
# ══════════════════════════════════════════════════════════════════════════════
run_oci() {
  local TENANCY_OCID USER_OCID FINGERPRINT
  TENANCY_OCID=$(echo "$PROVIDER_JSON" | py "import json,sys; print(json.load(sys.stdin)['configuration']['tenancy_ocid'])")
  USER_OCID=$(echo "$PROVIDER_JSON"    | py "import json,sys; print(json.load(sys.stdin)['configuration']['user_ocid'])")
  FINGERPRINT=$(echo "$PROVIDER_JSON"  | py "import json,sys; print(json.load(sys.stdin)['configuration']['fingerprint'])")

  # Write key file (OCI CLI requires key_file in config; key content includes OCI_API_KEY label)
  OCI_KEY_FILE=$(mktemp /tmp/oci_key_XXXXXX.pem)
  OCI_CONFIG_FILE=$(mktemp /tmp/oci_cfg_XXXXXX.ini)
  trap "rm -f '$OCI_KEY_FILE' '$OCI_CONFIG_FILE' '${OCI_CONFIG_FILE}.bak'" EXIT

  echo "$PROVIDER_JSON" | python3 -c "
import json, sys, os
raw = sys.stdin.read()
try: d = json.loads(raw)
except: d = json.loads(raw, strict=False)
key = d['configuration']['private_key']
with open('$OCI_KEY_FILE', 'w') as f:
    f.write(key)
    if not key.endswith('\n'): f.write('\n')
os.chmod('$OCI_KEY_FILE', 0o600)
"

  # Discover home region from account config, target region override, or probe.
  local HOME_REGION="${TARGET_REGION:-}"
  if [[ -z "$HOME_REGION" && -n "${OCI_HOME_REGION:-}" ]]; then
    HOME_REGION="$OCI_HOME_REGION"
  fi
  # If region still unknown, probe common OCI home regions until one authenticates.
  # OCI IAM is regional — auth fails if region != tenancy home region.
  if [[ -z "$HOME_REGION" ]]; then
    for PROBE in ap-hyderabad-1 us-ashburn-1 uk-london-1 eu-frankfurt-1 ap-tokyo-1 ap-mumbai-1; do
      cat > "$OCI_CONFIG_FILE" <<EOF
[DEFAULT]
user=$USER_OCID
fingerprint=$FINGERPRINT
tenancy=$TENANCY_OCID
region=$PROBE
key_file=$OCI_KEY_FILE
EOF
      chmod 0600 "$OCI_CONFIG_FILE"
      export OCI_CLI_CONFIG_FILE="$OCI_CONFIG_FILE"
      export SUPPRESS_LABEL_WARNING=True
      if oci iam tenancy get --tenancy-id "$TENANCY_OCID" --output json &>/dev/null; then
        HOME_REGION="$PROBE"
        break
      fi
    done
    if [[ -z "$HOME_REGION" ]]; then
      echo "Error: OCI credentials for '$ACCOUNT_NAME' are invalid or expired." >&2
      exit 1
    fi
  else
    cat > "$OCI_CONFIG_FILE" <<EOF
[DEFAULT]
user=$USER_OCID
fingerprint=$FINGERPRINT
tenancy=$TENANCY_OCID
region=$HOME_REGION
key_file=$OCI_KEY_FILE
EOF
    chmod 0600 "$OCI_CONFIG_FILE"
    export OCI_CLI_CONFIG_FILE="$OCI_CONFIG_FILE"
    export SUPPRESS_LABEL_WARNING=True
    if ! oci iam tenancy get --tenancy-id "$TENANCY_OCID" --output json &>/dev/null; then
      echo "Error: OCI credentials for '$ACCOUNT_NAME' are invalid or expired." >&2
      exit 1
    fi
  fi

  # Discover actual home region from subscriptions (authoritative)
  HOME_REGION=$(oci iam region-subscription list --tenancy-id "$TENANCY_OCID" --output json \
    | py "import json,sys; subs=json.load(sys.stdin).get('data',[]); print(next((x['region-name'] for x in subs if x.get('is-home-region')), '$HOME_REGION'))")
  sed -i.bak "s/^region=.*/region=$HOME_REGION/" "$OCI_CONFIG_FILE"
  echo "  Home region: $HOME_REGION"

  # Get all subscribed regions
  REGIONS=()
  if [[ -n "$TARGET_REGION" ]]; then
    REGIONS=("$TARGET_REGION")
  else
    while IFS= read -r r; do [[ -n "$r" ]] && REGIONS+=("$r"); done < <(
      oci iam region-subscription list --tenancy-id "$TENANCY_OCID" --output json \
        | py "import json,sys; [print(x['region-name']) for x in json.load(sys.stdin).get('data',[]) if x.get('status')=='READY']"
    )
  fi
  [[ ${#REGIONS[@]} -eq 0 ]] && REGIONS=("$HOME_REGION")
  echo "  Regions: ${REGIONS[*]}"

  # Get all compartments (tenancy root + all child compartments)
  COMPARTMENTS=()
  COMPARTMENTS+=("$TENANCY_OCID")
  while IFS= read -r c; do [[ -n "$c" ]] && COMPARTMENTS+=("$c"); done < <(
    oci iam compartment list --compartment-id "$TENANCY_OCID" \
      --compartment-id-in-subtree true --all --output json \
      | py "import json,sys; [print(x['id']) for x in json.load(sys.stdin).get('data',[]) if x.get('lifecycle-state')=='ACTIVE']"
  )
  echo "  Compartments: ${#COMPARTMENTS[@]}"

  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  Account:            $ACCOUNT_NAME  (oci)"
  echo "  Tenancy:            $TENANCY_OCID"
  echo "  Regions:            ${REGIONS[*]}"
  echo "  Compartments:       ${#COMPARTMENTS[@]}"
  echo "  Dry run:            $DRY_RUN"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  if [[ "$DRY_RUN" == "false" && "$AUTO_YES" == "false" ]]; then
    read -r -p "⚠  DELETE ALL resources in $ACCOUNT_NAME (OCI). Type 'yes': " C
    [[ "$C" == "yes" ]] || { echo "Aborted."; exit 0; }
  fi

  oci_sweep_region_compartment() {
    local REGION="$1" COMPARTMENT="$2"
    local O="oci --region $REGION"
    local TAG="oci/$REGION"

    # OKE clusters (all in compartment — billable)
    for CLUSTER_ID in $($O ce cluster list --compartment-id "$COMPARTMENT" --all --output json \
      | py "import json,sys; [print(x['id']) for x in json.load(sys.stdin).get('data',[]) if x.get('lifecycle-state') not in ('DELETED','DELETING')]" 2>/dev/null || true); do
      echo "  [$TAG] OKE cluster: $CLUSTER_ID"
      # Node pools
      for NP_ID in $($O ce node-pool list --compartment-id "$COMPARTMENT" --cluster-id "$CLUSTER_ID" --all --output json \
        | py "import json,sys; [print(x['id']) for x in json.load(sys.stdin).get('data',[]) if x.get('lifecycle-state') not in ('DELETED','DELETING')]" 2>/dev/null || true); do
        echo "  [$TAG]   node pool: $NP_ID"
        [[ "$DRY_RUN" == "false" ]] && $O ce node-pool delete --node-pool-id "$NP_ID" --force 2>/dev/null || true
      done
      [[ "$DRY_RUN" == "false" ]] && $O ce cluster delete --cluster-id "$CLUSTER_ID" --force 2>/dev/null || true
    done

    # Compute instances (parallel terminate)
    local INST_PIDS=()
    for INST_ID in $($O compute instance list --compartment-id "$COMPARTMENT" --all --output json \
      | py "import json,sys; [print(x['id']) for x in json.load(sys.stdin).get('data',[]) if x.get('lifecycle-state') not in ('TERMINATED','TERMINATING')]" 2>/dev/null || true); do
      echo "  [$TAG] instance: $INST_ID"
      [[ "$DRY_RUN" == "false" ]] && { $O compute instance terminate --instance-id "$INST_ID" --force --preserve-boot-volume false 2>/dev/null || true; } &
      INST_PIDS+=($!)
    done
    [[ ${#INST_PIDS[@]} -gt 0 ]] && wait "${INST_PIDS[@]}" 2>/dev/null || true

    # LBs and NLBs (parallel)
    { for LB_ID in $($O lb load-balancer list --compartment-id "$COMPARTMENT" --all --output json \
        | py "import json,sys; [print(x['id']) for x in json.load(sys.stdin).get('data',[]) if x.get('lifecycle-state') not in ('DELETED','DELETING')]" 2>/dev/null || true); do
        echo "  [$TAG] LB: $LB_ID"
        [[ "$DRY_RUN" == "false" ]] && $O lb load-balancer delete --load-balancer-id "$LB_ID" --force 2>/dev/null || true
      done
      for NLB_ID in $($O nlb network-load-balancer list --compartment-id "$COMPARTMENT" --all --output json \
        | py "import json,sys; [print(x['id']) for x in json.load(sys.stdin).get('data',[]) if x.get('lifecycle-state') not in ('DELETED','DELETING')]" 2>/dev/null || true); do
        echo "  [$TAG] NLB: $NLB_ID"
        [[ "$DRY_RUN" == "false" ]] && $O nlb network-load-balancer delete --network-load-balancer-id "$NLB_ID" --force 2>/dev/null || true
      done
    } &

    # Block volumes (parallel)
    { for VOL_ID in $($O bv volume list --compartment-id "$COMPARTMENT" --all --output json \
        | py "import json,sys; [print(x['id']) for x in json.load(sys.stdin).get('data',[]) if x.get('lifecycle-state') not in ('TERMINATED','TERMINATING')]" 2>/dev/null || true); do
        echo "  [$TAG] block volume: $VOL_ID"
        [[ "$DRY_RUN" == "false" ]] && $O bv volume delete --volume-id "$VOL_ID" --force 2>/dev/null || true
      done
      for BV_ID in $($O compute boot-volume-attachment list --compartment-id "$COMPARTMENT" --availability-domain "$(
        $O iam availability-domain list --compartment-id "$COMPARTMENT" --output json \
          | py "import json,sys; ads=json.load(sys.stdin).get('data',[]); print(ads[0]['name'] if ads else '')" 2>/dev/null || true
        )" --output json 2>/dev/null \
        | py "import json,sys; [print(x['boot-volume-id']) for x in json.load(sys.stdin).get('data',[])]" 2>/dev/null || true); do
        echo "  [$TAG] boot volume: $BV_ID"
        [[ "$DRY_RUN" == "false" ]] && $O bv boot-volume delete --boot-volume-id "$BV_ID" --force 2>/dev/null || true
      done
    } &

    wait  # parallel LBs + volumes

    # File Storage — billable; listed per availability domain
    for AD in $($O iam availability-domain list --compartment-id "$COMPARTMENT" --output json \
      | py "import json,sys; [print(x['name']) for x in json.load(sys.stdin).get('data',[])]" 2>/dev/null || true); do
      for FSID in $($O fs file-system list --compartment-id "$COMPARTMENT" --availability-domain "$AD" --all --output json \
        | py "import json,sys; [print(x['id']) for x in json.load(sys.stdin).get('data',[]) if x.get('lifecycle-state') not in ('DELETED','DELETING')]" 2>/dev/null || true); do
        echo "  [$TAG] file system: $FSID"
        [[ "$DRY_RUN" == "false" ]] && $O fs file-system delete --file-system-id "$FSID" --force 2>/dev/null || true
      done
    done

    # Autonomous Databases (best-effort; deletion protection may block)
    for ADB in $($O db autonomous-database list --compartment-id "$COMPARTMENT" --all --output json \
      | py "import json,sys; [print(x['id']) for x in json.load(sys.stdin).get('data',[]) if x.get('lifecycle-state') not in ('TERMINATING','TERMINATED','DELETED')]" 2>/dev/null || true); do
      echo "  [$TAG] Autonomous DB: $ADB"
      [[ "$DRY_RUN" == "false" ]] && $O db autonomous-database delete --autonomous-database-id "$ADB" --force 2>/dev/null || true
    done

    # VCNs (must be after instances/LBs are gone) — all non-terminated in compartment
    for VCN_ID in $($O network vcn list --compartment-id "$COMPARTMENT" --all --output json \
      | py "import json,sys; [print(x['id']) for x in json.load(sys.stdin).get('data',[]) if x.get('lifecycle-state') not in ('TERMINATED','TERMINATING')]" 2>/dev/null || true); do
      echo "  [$TAG] VCN: $VCN_ID"
      [[ "$DRY_RUN" == "false" ]] && {
        # NAT gateways
        for GW in $($O network nat-gateway list --compartment-id "$COMPARTMENT" --vcn-id "$VCN_ID" --all --output json \
          | py "import json,sys; [print(x['id']) for x in json.load(sys.stdin).get('data',[])]" 2>/dev/null || true); do
          $O network nat-gateway delete --nat-gateway-id "$GW" --force 2>/dev/null || true; done
        # Internet gateways
        for GW in $($O network internet-gateway list --compartment-id "$COMPARTMENT" --vcn-id "$VCN_ID" --all --output json \
          | py "import json,sys; [print(x['id']) for x in json.load(sys.stdin).get('data',[])]" 2>/dev/null || true); do
          $O network internet-gateway delete --ig-id "$GW" --force 2>/dev/null || true; done
        # Service gateways
        for GW in $($O network service-gateway list --compartment-id "$COMPARTMENT" --vcn-id "$VCN_ID" --all --output json \
          | py "import json,sys; [print(x['id']) for x in json.load(sys.stdin).get('data',[])]" 2>/dev/null || true); do
          $O network service-gateway delete --service-gateway-id "$GW" --force 2>/dev/null || true; done
        # Subnets
        for SUBNET in $($O network subnet list --compartment-id "$COMPARTMENT" --vcn-id "$VCN_ID" --all --output json \
          | py "import json,sys; [print(x['id']) for x in json.load(sys.stdin).get('data',[])]" 2>/dev/null || true); do
          $O network subnet delete --subnet-id "$SUBNET" --force 2>/dev/null || true; done
        # Route tables (non-default)
        for RT in $($O network route-table list --compartment-id "$COMPARTMENT" --vcn-id "$VCN_ID" --all --output json \
          | py "import json,sys; [print(x['id']) for x in json.load(sys.stdin).get('data',[]) if not x.get('display-name','').startswith('Default')]" 2>/dev/null || true); do
          $O network route-table delete --rt-id "$RT" --force 2>/dev/null || true; done
        # Security lists (non-default)
        for SL in $($O network security-list list --compartment-id "$COMPARTMENT" --vcn-id "$VCN_ID" --all --output json \
          | py "import json,sys; [print(x['id']) for x in json.load(sys.stdin).get('data',[]) if not x.get('display-name','').startswith('Default')]" 2>/dev/null || true); do
          $O network security-list delete --security-list-id "$SL" --force 2>/dev/null || true; done
        # NSGs
        for NSG in $($O network nsg list --compartment-id "$COMPARTMENT" --vcn-id "$VCN_ID" --all --output json \
          | py "import json,sys; [print(x['id']) for x in json.load(sys.stdin).get('data',[])]" 2>/dev/null || true); do
          $O network nsg delete --nsg-id "$NSG" --force 2>/dev/null || true; done
        # VCN
        $O network vcn delete --vcn-id "$VCN_ID" --force 2>/dev/null || true
        echo "  [$TAG]   deleted VCN $VCN_ID"
      } || echo "  [dry-run] delete VCN $VCN_ID and sub-resources"
    done
  }

  # All regions × compartments in parallel
  local PIDS=()
  for REGION in "${REGIONS[@]}"; do
    # Update config region for this sweep
    local REGION_CONFIG; REGION_CONFIG=$(mktemp /tmp/oci_cfg_${REGION}.XXXXXX)
    sed "s/^region=.*/region=$REGION/" "$OCI_CONFIG_FILE" > "$REGION_CONFIG"
    for COMPARTMENT in "${COMPARTMENTS[@]}"; do
      OCI_CLI_CONFIG_FILE="$REGION_CONFIG" oci_sweep_region_compartment "$REGION" "$COMPARTMENT" &
      PIDS+=($!)
    done
  done
  wait "${PIDS[@]}" 2>/dev/null || true

  # Global: Object Storage buckets (parallel)
  echo ""; echo "══════════════════════════════════════════════════"
  echo "  OCI global resources"; echo "══════════════════════════════════════════════════"

  local BUCKET_PIDS=()
  for COMPARTMENT in "${COMPARTMENTS[@]}"; do
    { for BUCKET in $(oci os bucket list --compartment-id "$COMPARTMENT" --all --output json \
        | py "import json,sys; [print(x['name']) for x in json.load(sys.stdin).get('data',[])]" 2>/dev/null || true); do
        echo "  [oci/global] bucket: $BUCKET"
        [[ "$DRY_RUN" == "false" ]] && {
          # Delete all objects first
          for OBJ in $(oci os object list --bucket-name "$BUCKET" --all --output json \
            | py "import json,sys; [print(x['name']) for x in json.load(sys.stdin).get('data',[])]" 2>/dev/null || true); do
            oci os object delete --bucket-name "$BUCKET" --object-name "$OBJ" --force 2>/dev/null || true
          done
          oci os bucket delete --bucket-name "$BUCKET" --force 2>/dev/null || true
        } || echo "  [dry-run] delete bucket $BUCKET"
      done
    } &
    BUCKET_PIDS+=($!)
  done
  [[ ${#BUCKET_PIDS[@]} -gt 0 ]] && wait "${BUCKET_PIDS[@]}" 2>/dev/null || true

  # OCIR (Container Registry) repos
  for COMPARTMENT in "${COMPARTMENTS[@]}"; do
    for REPO_ID in $(oci artifacts container repository list --compartment-id "$COMPARTMENT" --all --output json \
      | py "import json,sys; [print(x['id']) for x in json.load(sys.stdin).get('data',[])]" 2>/dev/null || true); do
      echo "  [oci/global] OCIR repo: $REPO_ID"
      [[ "$DRY_RUN" == "false" ]] && oci artifacts container repository delete --repository-id "$REPO_ID" --force 2>/dev/null || true
    done
  done

  # IAM dynamic groups — tenancy-global; delete only Fleet Manager-managed ones
  # Fleet Manager names them "{fleet-id}-streamtime-agent-wi"
  for DG_ID in $(oci iam dynamic-group list --compartment-id "$TENANCY_OCID" --all --output json \
    | py "import json,sys; [print(x['id']) for x in json.load(sys.stdin).get('data',[]) if x.get('name','').endswith('-streamtime-agent-wi')]" 2>/dev/null || true); do
    DG_NAME=$(oci iam dynamic-group get --dynamic-group-id "$DG_ID" --output json \
      | py "import json,sys; print(json.load(sys.stdin).get('data',{}).get('name',''))" 2>/dev/null || true)
    echo "  [oci/global] dynamic group: $DG_NAME ($DG_ID)"
    [[ "$DRY_RUN" == "false" ]] && oci iam dynamic-group delete --dynamic-group-id "$DG_ID" --force 2>/dev/null || true
  done

  # IAM policies intentionally skipped — no direct billing; often managed outside fleet-manager
}

# ══════════════════════════════════════════════════════════════════════════════
# Azure
# ══════════════════════════════════════════════════════════════════════════════
run_azure() {
  local SUBSCRIPTION_ID TENANT_ID CLIENT_ID CLIENT_SECRET
  SUBSCRIPTION_ID=$(echo "$PROVIDER_JSON" | py "import json,sys; print(json.load(sys.stdin)['configuration']['subscription_id'])")
  TENANT_ID=$(echo "$PROVIDER_JSON"      | py "import json,sys; print(json.load(sys.stdin)['configuration']['tenant_id'])")
  CLIENT_ID=$(echo "$PROVIDER_JSON"      | py "import json,sys; print(json.load(sys.stdin)['configuration']['client_id'])")
  CLIENT_SECRET=$(echo "$PROVIDER_JSON"  | py "import json,sys; print(json.load(sys.stdin)['configuration']['client_secret'])")

  echo "  Logging in with service principal..."
  if ! az login --service-principal \
      -u "$CLIENT_ID" \
      -p "$CLIENT_SECRET" \
      --tenant "$TENANT_ID" \
      --output none 2>/dev/null; then
    echo "Error: Azure credentials for '$ACCOUNT_NAME' are invalid or expired." >&2
    exit 1
  fi
  if ! az account set --subscription "$SUBSCRIPTION_ID" 2>/dev/null; then
    echo "Error: cannot set subscription '$SUBSCRIPTION_ID' for '$ACCOUNT_NAME'." >&2
    exit 1
  fi
  if ! az account show --output json &>/dev/null; then
    echo "Error: Azure account validation failed for '$ACCOUNT_NAME'." >&2
    exit 1
  fi
  echo "  Credentials validated. Subscription: $SUBSCRIPTION_ID"

  # --region maps to Azure location (e.g. eastus)
  local LOCATION_FILTER="${TARGET_REGION:-}"

  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  Account:            $ACCOUNT_NAME  (azure)"
  echo "  Subscription:       $SUBSCRIPTION_ID"
  echo "  Location filter:    ${LOCATION_FILTER:-all}"
  echo "  Dry run:            $DRY_RUN"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  if [[ "$DRY_RUN" == "false" && "$AUTO_YES" == "false" ]]; then
    read -r -p "⚠  DELETE ALL billable resources in $ACCOUNT_NAME (Azure subscription). Type 'yes': " C
    [[ "$C" == "yes" ]] || { echo "Aborted."; exit 0; }
  fi

  # Helper: list resource IDs of a given type, optionally filtered by location
  azure_list_ids() {
    local TYPE="$1"
    if [[ -n "$LOCATION_FILTER" ]]; then
      az resource list --resource-type "$TYPE" --query "[?location=='$LOCATION_FILTER'].id" -o tsv 2>/dev/null || true
    else
      az resource list --resource-type "$TYPE" --query "[].id" -o tsv 2>/dev/null || true
    fi
  }

  azure_delete_ids() {
    local LABEL="$1"
    shift
    local ID
    for ID in "$@"; do
      [[ -z "$ID" ]] && continue
      echo "  [azure] $LABEL: $ID"
      [[ "$DRY_RUN" == "false" ]] && az resource delete --ids "$ID" 2>/dev/null || true
    done
  }

  azure_delete_type() {
    local LABEL="$1" TYPE="$2"
    local IDS
    mapfile -t IDS < <(azure_list_ids "$TYPE")
    [[ ${#IDS[@]} -eq 0 ]] && return 0
    azure_delete_ids "$LABEL" "${IDS[@]}"
  }

  # ── 1. Remove resource locks (block RG/resource deletes) ───────────────────
  echo ""; echo "══════════════════════════════════════════════════"
  echo "  Azure resource locks"; echo "══════════════════════════════════════════════════"
  for LOCK_ID in $(az lock list --subscription "$SUBSCRIPTION_ID" --query "[].id" -o tsv 2>/dev/null || true); do
    [[ -z "$LOCK_ID" ]] && continue
    echo "  [azure] lock: $LOCK_ID"
    [[ "$DRY_RUN" == "false" ]] && az lock delete --ids "$LOCK_ID" 2>/dev/null || true
  done

  # ── 2. AKS clusters first (create MC_* node RGs) ───────────────────────────
  echo ""; echo "══════════════════════════════════════════════════"
  echo "  Azure AKS clusters"; echo "══════════════════════════════════════════════════"
  local AKS_LINES
  if [[ -n "$LOCATION_FILTER" ]]; then
    mapfile -t AKS_LINES < <(az aks list --query "[?location=='$LOCATION_FILTER'].[resourceGroup,name]" -o tsv 2>/dev/null || true)
  else
    mapfile -t AKS_LINES < <(az aks list --query "[].[resourceGroup,name]" -o tsv 2>/dev/null || true)
  fi
  local AKS_PIDS=()
  for LINE in "${AKS_LINES[@]:-}"; do
    [[ -z "$LINE" ]] && continue
    local RG NAME
    RG=$(echo "$LINE" | awk '{print $1}')
    NAME=$(echo "$LINE" | awk '{print $2}')
    echo "  [azure] AKS: $RG/$NAME"
    if [[ "$DRY_RUN" == "false" ]]; then
      (az aks delete --resource-group "$RG" --name "$NAME" --yes --no-wait 2>/dev/null || true) &
      AKS_PIDS+=($!)
    fi
  done
  [[ ${#AKS_PIDS[@]} -gt 0 ]] && wait "${AKS_PIDS[@]}" 2>/dev/null || true
  # Wait until AKS clusters are gone (up to ~30 min)
  if [[ "$DRY_RUN" == "false" && ${#AKS_LINES[@]} -gt 0 ]]; then
    local WAIT_I=0
    while [[ $WAIT_I -lt 60 ]]; do
      local REMAINING
      if [[ -n "$LOCATION_FILTER" ]]; then
        REMAINING=$(az aks list --query "[?location=='$LOCATION_FILTER'] | length(@)" -o tsv 2>/dev/null || echo 0)
      else
        REMAINING=$(az aks list --query "length(@)" -o tsv 2>/dev/null || echo 0)
      fi
      [[ "${REMAINING:-0}" == "0" ]] && break
      echo "  [azure] waiting for AKS deletion ($REMAINING remaining)..."
      sleep 30
      WAIT_I=$((WAIT_I + 1))
    done
  fi

  # ── 3. Typed billable sweep (dependency-friendly order) ────────────────────
  echo ""; echo "══════════════════════════════════════════════════"
  echo "  Azure typed resource sweep"; echo "══════════════════════════════════════════════════"

  # Compute
  azure_delete_type "VMSS" "Microsoft.Compute/virtualMachineScaleSets"
  azure_delete_type "VM" "Microsoft.Compute/virtualMachines"
  azure_delete_type "availability set" "Microsoft.Compute/availabilitySets"
  azure_delete_type "image" "Microsoft.Compute/images"
  azure_delete_type "gallery" "Microsoft.Compute/galleries"
  azure_delete_type "snapshot" "Microsoft.Compute/snapshots"
  azure_delete_type "disk" "Microsoft.Compute/disks"
  azure_delete_type "disk encryption set" "Microsoft.Compute/diskEncryptionSets"

  # Containers / PaaS
  azure_delete_type "container instance" "Microsoft.ContainerInstance/containerGroups"
  azure_delete_type "container app" "Microsoft.App/containerApps"
  azure_delete_type "container app env" "Microsoft.App/managedEnvironments"
  azure_delete_type "ACR" "Microsoft.ContainerRegistry/registries"
  azure_delete_type "function app" "Microsoft.Web/sites"
  azure_delete_type "app service plan" "Microsoft.Web/serverFarms"

  # Databases / cache
  azure_delete_type "SQL server" "Microsoft.Sql/servers"
  azure_delete_type "PostgreSQL flexible" "Microsoft.DBforPostgreSQL/flexibleServers"
  azure_delete_type "MySQL flexible" "Microsoft.DBforMySQL/flexibleServers"
  azure_delete_type "Cosmos DB" "Microsoft.DocumentDB/databaseAccounts"
  azure_delete_type "Redis" "Microsoft.Cache/Redis"
  azure_delete_type "NetApp account" "Microsoft.NetApp/netAppAccounts"

  # Networking (LBs / gateways before VNets)
  azure_delete_type "application gateway" "Microsoft.Network/applicationGateways"
  azure_delete_type "load balancer" "Microsoft.Network/loadBalancers"
  azure_delete_type "Azure Firewall" "Microsoft.Network/azureFirewalls"
  azure_delete_type "firewall policy" "Microsoft.Network/firewallPolicies"
  azure_delete_type "Bastion" "Microsoft.Network/bastionHosts"
  azure_delete_type "VPN gateway" "Microsoft.Network/virtualNetworkGateways"
  azure_delete_type "local network gateway" "Microsoft.Network/localNetworkGateways"
  azure_delete_type "connection" "Microsoft.Network/connections"
  azure_delete_type "NAT gateway" "Microsoft.Network/natGateways"
  azure_delete_type "public IP" "Microsoft.Network/publicIPAddresses"
  azure_delete_type "public IP prefix" "Microsoft.Network/publicIPPrefixes"
  azure_delete_type "private endpoint" "Microsoft.Network/privateEndpoints"
  azure_delete_type "private DNS zone" "Microsoft.Network/privateDnsZones"
  azure_delete_type "DNS zone" "Microsoft.Network/dnszones"
  azure_delete_type "NIC" "Microsoft.Network/networkInterfaces"
  azure_delete_type "NSG" "Microsoft.Network/networkSecurityGroups"
  azure_delete_type "route table" "Microsoft.Network/routeTables"
  azure_delete_type "VNet peering" "Microsoft.Network/virtualNetworks/virtualNetworkPeerings"
  azure_delete_type "VNet" "Microsoft.Network/virtualNetworks"

  # Storage accounts — empty blobs best-effort then delete account
  echo "  [azure] sweeping storage accounts..."
  local SA_LINES
  if [[ -n "$LOCATION_FILTER" ]]; then
    mapfile -t SA_LINES < <(az storage account list --query "[?location=='$LOCATION_FILTER'].[resourceGroup,name]" -o tsv 2>/dev/null || true)
  else
    mapfile -t SA_LINES < <(az storage account list --query "[].[resourceGroup,name]" -o tsv 2>/dev/null || true)
  fi
  for LINE in "${SA_LINES[@]:-}"; do
    [[ -z "$LINE" ]] && continue
    local SA_RG SA_NAME
    SA_RG=$(echo "$LINE" | awk '{print $1}')
    SA_NAME=$(echo "$LINE" | awk '{print $2}')
    echo "  [azure] storage account: $SA_RG/$SA_NAME"
    if [[ "$DRY_RUN" == "false" ]]; then
      # Best-effort: delete blob containers (may fail without data-plane perms)
      for CONTAINER in $(az storage container list --account-name "$SA_NAME" --auth-mode login --query "[].name" -o tsv 2>/dev/null || true); do
        az storage container delete --account-name "$SA_NAME" --name "$CONTAINER" --auth-mode login --yes 2>/dev/null || true
      done
      az storage account delete --resource-group "$SA_RG" --name "$SA_NAME" --yes 2>/dev/null || true
    fi
  done

  # Catch-all: any remaining non-IAM ARM resources of common billable types
  # (skipped when doing full RG delete below; useful for --region mode)
  if [[ -n "$LOCATION_FILTER" ]]; then
    echo "  [azure] catch-all resources in location $LOCATION_FILTER..."
    for RID in $(az resource list --query "[?location=='$LOCATION_FILTER'].id" -o tsv 2>/dev/null || true); do
      [[ -z "$RID" ]] && continue
      # Skip role assignments / managed identities at Entra level — resource IDs
      # for userAssignedIdentities are ARM resources; leave them (no direct cost).
      case "$RID" in
        */providers/Microsoft.ManagedIdentity/*) continue ;;
        */providers/Microsoft.Authorization/*) continue ;;
      esac
      echo "  [azure] leftover: $RID"
      [[ "$DRY_RUN" == "false" ]] && az resource delete --ids "$RID" 2>/dev/null || true
    done
  fi

  # ── 4. Delete all resource groups (full-subscription mode only) ────────────
  if [[ -z "$LOCATION_FILTER" ]]; then
    echo ""; echo "══════════════════════════════════════════════════"
    echo "  Azure resource groups"; echo "══════════════════════════════════════════════════"
    local RGS
    mapfile -t RGS < <(az group list --query "[].name" -o tsv 2>/dev/null || true)
    local RG_PIDS=() RG_ACTIVE=0
    for RG in "${RGS[@]:-}"; do
      [[ -z "$RG" ]] && continue
      echo "  [azure] resource group: $RG"
      if [[ "$DRY_RUN" == "false" ]]; then
        (
          az group delete --name "$RG" --yes --no-wait 2>/dev/null || true
        ) &
        RG_PIDS+=($!)
        RG_ACTIVE=$((RG_ACTIVE + 1))
        # Cap parallelism to reduce ARM throttling
        if [[ $RG_ACTIVE -ge 5 ]]; then
          wait "${RG_PIDS[@]}" 2>/dev/null || true
          RG_PIDS=()
          RG_ACTIVE=0
        fi
      fi
    done
    [[ ${#RG_PIDS[@]} -gt 0 ]] && wait "${RG_PIDS[@]}" 2>/dev/null || true

    if [[ "$DRY_RUN" == "false" && ${#RGS[@]} -gt 0 ]]; then
      local WAIT_I=0
      while [[ $WAIT_I -lt 90 ]]; do
        local REMAINING
        REMAINING=$(az group list --query "length(@)" -o tsv 2>/dev/null || echo 0)
        [[ "${REMAINING:-0}" == "0" ]] && break
        echo "  [azure] waiting for resource group deletion ($REMAINING remaining)..."
        sleep 30
        WAIT_I=$((WAIT_I + 1))
      done
    fi
  else
    echo "  [azure] skipping resource group deletion (--region set)"
  fi

  # ── 5. Soft-deleted Key Vaults ─────────────────────────────────────────────
  echo ""; echo "══════════════════════════════════════════════════"
  echo "  Azure soft-deleted Key Vaults"; echo "══════════════════════════════════════════════════"
  for KV in $(az keyvault list-deleted --query "[].name" -o tsv 2>/dev/null || true); do
    [[ -z "$KV" ]] && continue
    if [[ -n "$LOCATION_FILTER" ]]; then
      local KV_LOC
      KV_LOC=$(az keyvault list-deleted --query "[?name=='$KV'].properties.location | [0]" -o tsv 2>/dev/null || true)
      [[ "$KV_LOC" != "$LOCATION_FILTER" ]] && continue
    fi
    echo "  [azure] purge Key Vault: $KV"
    [[ "$DRY_RUN" == "false" ]] && az keyvault purge --name "$KV" 2>/dev/null || true
  done

  # Entra ID apps, service principals, role assignments, and custom RBAC roles
  # are intentionally NOT deleted.
}

# ══════════════════════════════════════════════════════════════════════════════
# Dispatch
# ══════════════════════════════════════════════════════════════════════════════
case "$PROVIDER_TYPE" in
  aws)   require_cmd aws; run_aws ;;
  oci)   require_cmd oci; run_oci ;;
  azure) require_cmd az;  run_azure ;;
  *)
    echo "Error: unsupported provider type '$PROVIDER_TYPE'. Only 'aws', 'oci', and 'azure' are supported." >&2
    exit 1 ;;
esac

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Purge complete for: $ACCOUNT_NAME ($PROVIDER_TYPE)"
[[ "$DRY_RUN" == "true" ]] && echo "  (dry-run — no resources were deleted)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
