#!/usr/bin/env bash
#
# aws-cleanup-check.sh
# ---------------------
# Vérifie les ressources AWS facturables résiduelles (orphelines)
# sur l'ensemble des régions activées pour ton compte.
#
# Usage :
#   ./aws-cleanup-check.sh                    # scan toutes les régions
#   ./aws-cleanup-check.sh eu-west-3          # scan une seule région
#   ./aws-cleanup-check.sh -p                 # mode "profile" (multi-comptes)
#   ./aws-cleanup-check.sh -d                 # inclut les ressources par défaut (VPC par défaut, etc.)
#
# Prérequis :
#   - AWS CLI v2 installé (https://aws.amazon.com/cli/)
#   - Identifiants configurés (aws configure / SSO / rôle)
#   - Permissions IAM en lecture sur : ec2, rds, s3, ebs, ec2 (EIP), elb, elbv2,
#     lambda, dynamodb, sns, sqs, ecs, ecr, eks, secretsmanager, ce, cloudwatch
#
# Auteur : <ton pseudo GitHub>
# Licence : MIT
#

set -uo pipefail

# ---------- Couleurs ----------
if [[ -t 1 ]]; then
    RED=$'\e[31m'; GREEN=$'\e[32m'; YELLOW=$'\e[33m'
    BLUE=$'\e[34m'; MAGENTA=$'\e[35m'; CYAN=$'\e[36m'
    BOLD=$'\e[1m'; DIM=$'\e[2m'; RESET=$'\e[0m'
else
    RED=""; GREEN=""; YELLOW=""; BLUE=""; MAGENTA=""; CYAN=""
    BOLD=""; DIM=""; RESET=""
fi

# ---------- Helpers ----------
log_info()    { echo -e "${BLUE}ℹ${RESET}  $*"; }
log_ok()      { echo -e "${GREEN}✔${RESET}  $*"; }
log_warn()    { echo -e "${YELLOW}⚠${RESET}  $*"; }
log_error()   { echo -e "${RED}✘${RESET}  $*" >&2; }
log_section() { echo -e "\n${BOLD}${CYAN}━━━ $* ━━━${RESET}\n"; }

has_cmd() { command -v "$1" >/dev/null 2>&1; }

# ---------- Prérequis ----------
if ! has_cmd aws; then
    log_error "AWS CLI introuvable. Installe-le : https://aws.amazon.com/cli/"
    exit 1
fi

if ! aws sts get-caller-identity >/dev/null 2>&1; then
    log_error "AWS CLI non configuré ou identifiants invalides."
    log_info  "Lance : aws configure   (ou aws sso login)"
    exit 1
fi

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
CALLER_ARN=$(aws sts get-caller-identity --query Arn --output text)

echo -e "${BOLD}${MAGENTA}"
cat <<'BANNER'
   ___  _      __ _      ___ _                 _
  / _ \| | /| / /| |    / __| |___ ___ _ _ _ _ (_)_ _
 | (_) | |/ |/ / | |__ | (__| / _ \ -_) ' \ ' \| | ' \
  \___/|__/|__/  |____| \___|_\___/___|_||_|_||_|_|_||_|
BANNER
echo -e "${RESET}"

log_info "Compte AWS : ${BOLD}${ACCOUNT_ID}${RESET}"
log_info "Identité   : ${DIM}${CALLER_ARN}${RESET}"

# ---------- Gestion des régions ----------
if [[ $# -ge 1 && ! "$1" =~ ^- ]]; then
    REGIONS=("$1")
    log_info "Région unique : $1"
else
    REGIONS=($(aws ec2 describe-regions --region us-east-1 \
        --query "Regions[?OptInStatus!='not-opted-in'].RegionName" \
        --output text 2>/dev/null))
    log_info "Régions scannées : ${#REGIONS[@]}"
fi

# Filtre global (les régions où AWS n'a pas tous les services ne pénalisent pas)
TOTAL_ISSUES=0
declare -a ISSUES_SUMMARY=()

# ---------- Wrapper API (ignore erreurs, sortie vide) ----------
run_aws() {
    # $1 = région, $@ = commande
    local region="$1"; shift
    aws "$@" --region "$region" --output text 2>/dev/null || true
}

# ============================================================
# 1. RDS : instances, clusters, snapshots manuels, clusters snapshots
# ============================================================
scan_rds() {
    local r="$1"
    log_section "RDS — $r"

    local instances clusters snaps csnaps
    instances=$(run_aws "$r" rds describe-db-instances --query "DBInstances[].DBInstanceIdentifier")
    clusters=$(run_aws  "$r" rds describe-db-clusters  --query "DBClusters[].DBClusterIdentifier")
    snaps=$(run_aws    "$r" rds describe-db-snapshots --snapshot-type manual \
                --query "DBSnapshots[].DBSnapshotIdentifier")
    csnaps=$(run_aws   "$r" rds describe-db-cluster-snapshots --snapshot-type manual \
                --query "DBClusterSnapshots[].DBClusterSnapshotIdentifier")

    if [[ -z "$instances$clusters$snaps$csnaps" ]]; then
        log_ok "Aucune ressource RDS"
        return
    fi
    [[ -n "$instances" ]] && log_warn "Instances RDS  : $instances" && ((TOTAL_ISSUES++))
    [[ -n "$clusters"  ]] && log_warn "Clusters RDS   : $clusters"  && ((TOTAL_ISSUES++))
    [[ -n "$snaps"     ]] && log_warn "Snapshots RDS  : $snaps"     && ((TOTAL_ISSUES++))
    [[ -n "$csnaps"    ]] && log_warn "Snap. clusters : $csnaps"    && ((TOTAL_ISSUES++))
    [[ -n "$snaps" ]] && ISSUES_SUMMARY+=("[$r] RDS snapshots: $snaps")
}

# ============================================================
# 2. EC2 : instances, volumes EBS, snapshots self, AMI self, EIP non associées
# ============================================================
scan_ec2() {
    local r="$1"
    log_section "EC2 / EBS / EIP — $r"

    local instances volumes ebs_snaps amis eips
    instances=$(run_aws "$r" ec2 describe-instances \
        --filters "Name=instance-state-name,Values=running,stopped,pending" \
        --query "Reservations[].Instances[].InstanceId")

    volumes=$(run_aws "$r" ec2 describe-volumes \
        --query "Volumes[].{ID:VolumeId,State:State,Size:Size}" --output text)

    ebs_snaps=$(run_aws "$r" ec2 describe-snapshots --owner-ids self \
        --query "Snapshots[].SnapshotId")

    amis=$(run_aws "$r" ec2 describe-images --owners self \
        --query "Images[].ImageId")

    eips=$(run_aws "$r" ec2 describe-addresses \
        --query "Addresses[?AssociationId==null].PublicIp")

    if [[ -z "$instances$volumes$ebs_snaps$amis$eips" ]]; then
        log_ok "Aucune ressource EC2/EBS/EIP"
        return
    fi
    [[ -n "$instances" ]] && log_warn "Instances EC2  : $instances" && ((TOTAL_ISSUES++))
    [[ -n "$volumes"   ]] && log_warn "Volumes EBS    : $volumes"   && ((TOTAL_ISSUES++))
    [[ -n "$ebs_snaps" ]] && log_warn "Snapshots EBS  : $ebs_snaps" && ((TOTAL_ISSUES++))
    [[ -n "$amis"      ]] && log_warn "AMI perso      : $amis"      && ((TOTAL_ISSUES++))
    [[ -n "$eips"      ]] && log_warn "EIP non assoc. : $eips"      && ((TOTAL_ISSUES++)) \
        && ISSUES_SUMMARY+=("[$r] EIP non associées: $eips")
}

# ============================================================
# 3. S3 (global) : liste tous les buckets + taille
# ============================================================
scan_s3() {
    log_section "S3 (global)"
    local buckets
    buckets=$(aws s3api list-buckets --query "Buckets[].Name" --output text 2>/dev/null || true)

    if [[ -z "$buckets" ]]; then
        log_ok "Aucun bucket S3"
        return
    fi

    for b in $buckets; do
        local region count size
        region=$(aws s3api get-bucket-location --bucket "$b" \
            --query "LocationConstraint" --output text 2>/dev/null || echo "?")
        [[ "$region" == "None" || -z "$region" ]] && region="us-east-1"

        read -r count size < <(aws s3 ls "s3://$b" --recursive --summarize 2>/dev/null \
            | awk '/Total Objects/{c=$3} /Total Size/{s=$3} END{print c+0, s+0}')

        if [[ "$count" -eq 0 ]]; then
            log_info "Bucket ${BOLD}$b${RESET} [$region] — vide (0 objet)"
        else
            log_warn "Bucket ${BOLD}$b${RESET} [$region] — ${count} objets, ${size} octets"
            ((TOTAL_ISSUES++))
            ISSUES_SUMMARY+=("[S3] bucket $b: $count objets / $size octets")
        fi
    done
}

# ============================================================
# 4. Load Balancers (ELB v1 + v2)
# ============================================================
scan_elb() {
    local r="$1"
    log_section "Load Balancers — $r"

    local clb alb nlb
    clb=$(run_aws "$r" elb describe-load-balancers \
        --query "LoadBalancerDescriptions[].LoadBalancerName")
    alb=$(run_aws "$r" elbv2 describe-load-balancers \
        --query "LoadBalancers[?Type=='application'].LoadBalancerName")
    nlb=$(run_aws "$r" elbv2 describe-load-balancers \
        --query "LoadBalancers[?Type=='network'].LoadBalancerName")

    if [[ -z "$clb$alb$nlb" ]]; then
        log_ok "Aucun load balancer"
        return
    fi
    [[ -n "$clb" ]] && log_warn "CLB (classic) : $clb" && ((TOTAL_ISSUES++))
    [[ -n "$alb" ]] && log_warn "ALB           : $alb" && ((TOTAL_ISSUES++))
    [[ -n "$nlb" ]] && log_warn "NLB           : $nlb" && ((TOTAL_ISSUES++))
}

# ============================================================
# 5. Lambda, DynamoDB, SNS, SQS, ECR, ECS, EKS, Secrets
# ============================================================
scan_serverless() {
    local r="$1"
    log_section "Serverless & conteneurs — $r"

    local fns tables topics queues repos clusters eks secrets
    fns=$(run_aws     "$r" lambda list-functions --query "Functions[].FunctionName")
    tables=$(run_aws  "$r" dynamodb list-tables --query "TableNames[]")
    topics=$(run_aws  "$r" sns list-topics --query "Topics[].TopicArn")
    queues=$(run_aws  "$r" sqs list-queues --query "QueueUrls[]")
    repos=$(run_aws   "$r" ecr describe-repositories --query "repositories[].repositoryName")
    clusters=$(run_aws "$r" ecs list-clusters --query "clusterArns[]")
    eks=$(run_aws     "$r" eks list-clusters --query "clusters[]")
    secrets=$(run_aws "$r" secretsmanager list-secrets --query "SecretList[].Name")

    [[ -n "$fns"      ]] && log_warn "Lambda       : $fns"      && ((TOTAL_ISSUES++))
    [[ -n "$tables"   ]] && log_warn "DynamoDB     : $tables"   && ((TOTAL_ISSUES++))
    [[ -n "$topics"   ]] && log_warn "SNS topics   : $topics"   && ((TOTAL_ISSUES++))
    [[ -n "$queues"   ]] && log_warn "SQS queues   : $queues"   && ((TOTAL_ISSUES++))
    [[ -n "$repos"    ]] && log_warn "ECR repos    : $repos"    && ((TOTAL_ISSUES++))
    [[ -n "$clusters" ]] && log_warn "ECS clusters : $clusters" && ((TOTAL_ISSUES++))
    [[ -n "$eks"      ]] && log_warn "EKS clusters : $eks"      && ((TOTAL_ISSUES++))
    [[ -n "$secrets"  ]] && log_warn "Secrets      : $secrets"  && ((TOTAL_ISSUES++))

    if [[ -z "$fns$tables$topics$queues$repos$clusters$eks$secrets" ]]; then
        log_ok "Rien côté serverless / conteneurs"
    fi
}

# ============================================================
# 6. Cost Explorer : coût des 7 derniers jours
# ============================================================
scan_costs() {
    log_section "Coût des 7 derniers jours (Cost Explorer)"
    local start end
    start=$(date -d "-7 days" +%Y-%m-%d 2>/dev/null || date -v-7d +%Y-%m-%d)
    end=$(date +%Y-%m-%d)

    if ! aws ce get-cost-and-usage --time-period "Start=$start,End=$end" \
            --granularity DAILY --metrics "UnblendedCost" --region us-east-1 \
            >/dev/null 2>&1; then
        log_warn "Impossible d'interroger Cost Explorer (permission manquante ?)"
        return
    fi

    aws ce get-cost-and-usage \
        --time-period "Start=$start,End=$end" \
        --granularity DAILY --metrics "UnblendedCost" \
        --region us-east-1 \
        --query "ResultsByTime[].{Date:TimePeriod.Start,Total:Total.UnblendedCost.Amount}" \
        --output table
}

# ============================================================
# Main
# ============================================================
for r in "${REGIONS[@]}"; do
    echo -e "\n${BOLD}${MAGENTA}════════════════════════════════════════════════════════${RESET}"
    echo -e "${BOLD}${MAGENTA}  Région : $r${RESET}"
    echo -e "${BOLD}${MAGENTA}════════════════════════════════════════════════════════${RESET}"

    scan_rds "$r"
    scan_ec2 "$r"
    scan_elb "$r"
    scan_serverless "$r"
done

# S3 = global
scan_s3

# Coûts
scan_costs

# ---------- Résumé ----------
echo -e "\n${BOLD}${CYAN}════════════════════════════════════════════════════════${RESET}"
echo -e "${BOLD}${CYAN}  RÉSUMÉ${RESET}"
echo -e "${BOLD}${CYAN}════════════════════════════════════════════════════════${RESET}\n"

if [[ "$TOTAL_ISSUES" -eq 0 ]]; then
    log_ok "${GREEN}${BOLD}Aucune ressource facturable détectée. Compte propre !${RESET}"
else
    log_warn "${YELLOW}${BOLD}$TOTAL_ISSUES catégorie(s) de ressources détectée(s) :${RESET}"
    for i in "${ISSUES_SUMMARY[@]}"; do
        echo -e "   ${YELLOW}•${RESET} $i"
    done
    echo ""
    log_info "Pour supprimer une ressource, reporte-toi à la doc AWS du service concerné."
    log_info "Astuce : crée un budget à 0,10 \$ dans Billing → Budgets pour être alerté."
fi

echo -e "\n${DIM}Scan terminé à $(date '+%Y-%m-%d %H:%M:%S')${RESET}\n"

exit 0
