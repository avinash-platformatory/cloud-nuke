#!/bin/bash
set -euo pipefail

# purge-cloud-account.sh
#
# Nuke all billable resources in a cloud account. Supports AWS and OCI.
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
# Other IAM *customer-managed policies* are never deleted (AWS or OCI): not a direct
# billing line item; safe to leave for human / IaC cleanup. Exception: policies
# under /kafka-streamtime/ are deleted with their users (Fleet Manager S3 access).
# Inline policies on IAM roles may still be removed when deleting those roles (AWS).
#
# Usage:
#   ./scripts/purge-cloud-account.sh --account sub1 --credentials-file /path/to/creds.json
#   ./scripts/purge-cloud-account.sh --account oci-lab --credentials-file creds.json --dry-run
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
if provider not in ('aws', 'oci'):
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
# Dispatch
# ══════════════════════════════════════════════════════════════════════════════
case "$PROVIDER_TYPE" in
  aws) require_cmd aws; run_aws ;;
  oci) require_cmd oci; run_oci ;;
  *)
    echo "Error: unsupported provider type '$PROVIDER_TYPE'. Only 'aws' and 'oci' are supported." >&2
    exit 1 ;;
esac

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Purge complete for: $ACCOUNT_NAME ($PROVIDER_TYPE)"
[[ "$DRY_RUN" == "true" ]] && echo "  (dry-run — no resources were deleted)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
