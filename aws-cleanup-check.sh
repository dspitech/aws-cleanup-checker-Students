#!/usr/bin/env bash
#
# aws-cleanup-check.sh  —  v2.1
# ---------------------------------
# Scanner + nettoyeur AWS tout-en-un.
#
#   - Scanne toutes les régions (ou une seule)
#   - Détecte : RDS, EC2, EBS, EIP, AMI, S3, ELB, Lambda, DynamoDB,
#     SNS, SQS, ECR, ECS, EKS, Secrets Manager,
#     NAT Gateway, CloudWatch Logs
#   - Tableau récapitulatif + estimation du coût mensuel
#   - Menu interactif : suppression ciblée par région et/ou par ressource
#   - Whitelist par tag ou pattern
#   - Export JSON / CSV / HTML
#
# Usage :
#   ./aws-cleanup-check.sh                        # mode interactif complet
#   ./aws-cleanup-check.sh --scan-only            # scan sans menu
#   ./aws-cleanup-check.sh --region eu-west-3     # cible une région
#   ./aws-cleanup-check.sh --yes                  # non-interactif (⚠)
#   ./aws-cleanup-check.sh --dry-run              # simulation
#   ./aws-cleanup-check.sh --exclude-tag Keep=true
#   ./aws-cleanup-check.sh --exclude-pattern "prod-*"
#   ./aws-cleanup-check.sh --format json --output audit.json
#
# Licence : MIT
#

set -uo pipefail
shopt -s nullglob

VERSION="2.1"
DRY_RUN=0
SCAN_ONLY=0
AUTO_YES=0
TARGET_REGION=""
EXCLUDE_TAG=""
EXCLUDE_PATTERN=""
OUTPUT_FORMAT=""
OUTPUT_FILE=""

# ---------- Parse args ----------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --scan-only)        SCAN_ONLY=1; shift ;;
        --yes|-y)           AUTO_YES=1;  shift ;;
        --dry-run)          DRY_RUN=1;   shift ;;
        --region)           TARGET_REGION="$2"; shift 2 ;;
        --exclude-tag)      EXCLUDE_TAG="$2"; shift 2 ;;
        --exclude-pattern)  EXCLUDE_PATTERN="$2"; shift 2 ;;
        --format)           OUTPUT_FORMAT="$2"; shift 2 ;;
        --output)           OUTPUT_FILE="$2"; shift 2 ;;
        --version)          echo "aws-cleanup-check v$VERSION"; exit 0 ;;
        -h|--help)
            grep '^#' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *) echo "Option inconnue : $1"; exit 1 ;;
    esac
done

# ---------- Couleurs ----------
if [[ -t 1 ]]; then
    RED=$'\e[31m'; GREEN=$'\e[32m'; YELLOW=$'\e[33m'
    BLUE=$'\e[34m'; MAGENTA=$'\e[35m'; CYAN=$'\e[36m'
    BOLD=$'\e[1m'; DIM=$'\e[2m'; RESET=$'\e[0m'
else
    RED=""; GREEN=""; YELLOW=""; BLUE=""; MAGENTA=""
    CYAN=""; BOLD=""; DIM=""; RESET=""
fi

# ---------- Log ----------
log_info()    { echo -e "${BLUE}ℹ${RESET}  $*"; }
log_ok()      { echo -e "${GREEN}✔${RESET}  $*"; }
log_warn()    { echo -e "${YELLOW}⚠${RESET}  $*"; }
log_error()   { echo -e "${RED}✘${RESET}  $*" >&2; }
log_section() { echo -e "\n${BOLD}${CYAN}━━━ $* ━━━${RESET}"; }

# ---------- Prérequis ----------
has_cmd() { command -v "$1" >/dev/null 2>&1; }

if ! has_cmd aws; then
    log_error "AWS CLI introuvable. Installe-le : https://aws.amazon.com/cli/"
    exit 1
fi

if ! aws sts get-caller-identity >/dev/null 2>&1; then
    log_error "AWS CLI non configuré ou session expirée."
    log_info  "Lance : aws configure   (ou aws sso login)"
    exit 1
fi

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
CALLER_ARN=$(aws sts get-caller-identity --query Arn --output text)

# ---------- Avertissement compte root ----------
if [[ "$CALLER_ARN" == *":root" ]]; then
    log_warn "${RED}${BOLD}Tu utilises le compte ROOT AWS.${RESET}"
    log_warn "C'est une mauvaise pratique : crée un utilisateur IAM dédié."
    if [[ "$AUTO_YES" -eq 0 && "$SCAN_ONLY" -eq 0 ]]; then
        read -rp "  Continuer quand même ? [y/N] : " a
        [[ ! "$a" =~ ^[yY]$ ]] && { log_info "Annulé."; exit 1; }
    fi
fi

# ---------- Registre global des ressources trouvées ----------
# Format : REGION|SERVICE|TYPE|ID|DETAILS|COUT_MENSUEL
declare -a FOUND=()

register() {
    # $1=region $2=service $3=type $4=id $5=details $6=cost
    FOUND+=("$1|$2|$3|$4|$5|${6:-0}")
}

# ---------- Filtres whitelist ----------
is_excluded() {
    # $1 = identifiant de la ressource
    local id="$1"

    if [[ -n "$EXCLUDE_PATTERN" ]]; then
        # shellcheck disable=SC2053
        if [[ "$id" == $EXCLUDE_PATTERN ]]; then
            return 0
        fi
    fi
    return 1
}

check_tag_exclusion() {
    # $1=region $2=resource_arn_or_id $3=type
    # Vérifie si la ressource porte le tag EXCLUDE_TAG (clé=valeur)
    [[ -z "$EXCLUDE_TAG" ]] && return 1
    local region="$1" id="$2" type="$3"
    local key="${EXCLUDE_TAG%%=*}"
    local val="${EXCLUDE_TAG#*=}"

    case "$type" in
        rds:instance|rds:snapshot|rds:cluster-snapshot)
            local arn="arn:aws:rds:$region:$ACCOUNT_ID:$id"
            local tags
            tags=$(aws rds list-tags-for-resource --resource-name "$arn" \
                --region "$region" --output json 2>/dev/null || echo '{}')
            echo "$tags" | grep -q "\"$key\"" && echo "$tags" | grep -q "\"$val\"" && return 0
            ;;
        ec2:*)
            local tags
            if [[ "$type" == "ec2:instance" ]]; then
                tags=$(aws ec2 describe-tags --region "$region" \
                    --filters "Name=resource-id,Values=$id" "Name=key,Values=$key" \
                    --query "Tags[?Value=='$val'].Value" --output text 2>/dev/null || true)
            fi
            [[ -n "$tags" ]] && return 0
            ;;
        s3:bucket)
            local tags
            tags=$(aws s3api get-bucket-tagging --bucket "$id" 2>/dev/null || true)
            [[ -n "$tags" ]] && echo "$tags" | grep -q "\"$key\"" && echo "$tags" | grep -q "\"$val\"" && return 0
            ;;
        *)
            # Par défaut : pas de vérification de tag pour ce type
            ;;
    esac
    return 1
}

# ---------- Wrapper API ----------
run_aws() {
    local region="$1"; shift
    aws "$@" --region "$region" --output text 2>/dev/null || true
}

# ============================================================
#  SCAN — RDS
# ============================================================
scan_rds() {
    local r="$1"
    log_section "RDS — $r"

    local instances snaps csnaps
    instances=$(run_aws "$r" rds describe-db-instances \
        --query "DBInstances[].{ID:DBInstanceIdentifier,Status:DBInstanceStatus}")
    snaps=$(run_aws "$r" rds describe-db-snapshots --snapshot-type manual \
        --query "DBSnapshots[].DBSnapshotIdentifier")
    csnaps=$(run_aws "$r" rds describe-db-cluster-snapshots --snapshot-type manual \
        --query "DBClusterSnapshots[].DBClusterSnapshotIdentifier")

    if [[ -z "$instances$snaps$csnaps" ]]; then
        log_ok "Aucune ressource RDS"
        return
    fi

    # Instances RDS (db.t3.micro = ~15 $/mois si running, stockage en plus)
    if [[ -n "$instances" ]]; then
        while IFS= read -r line; do
            [[ -z "$line" || "$line" == "None" ]] && continue
            local id st
            id=$(echo "$line" | awk '{print $1}')
            st=$(echo "$line" | awk '{print $2}')
            if is_excluded "$id" || check_tag_exclusion "$r" "$id" "rds:instance"; then
                log_info "RDS exclu (filtre) : $id"
                continue
            fi
            log_warn "Instance RDS : $id ($st)"
            register "$r" "rds" "instance" "$id" "$st" "15.00"
        done <<< "$instances"
    fi

    # Snapshots RDS (~0.095 $/Go/mois)
    if [[ -n "$snaps" ]]; then
        while IFS= read -r s; do
            [[ -z "$s" || "$s" == "None" ]] && continue
            if is_excluded "$s" || check_tag_exclusion "$r" "$s" "rds:snapshot"; then
                log_info "Snapshot RDS exclu (filtre) : $s"
                continue
            fi
            log_warn "Snapshot RDS : $s"
            register "$r" "rds" "snapshot" "$s" "" "1.90"
        done <<< "$snaps"
    fi

    if [[ -n "$csnaps" ]]; then
        while IFS= read -r s; do
            [[ -z "$s" || "$s" == "None" ]] && continue
            if is_excluded "$s" || check_tag_exclusion "$r" "$s" "rds:cluster-snapshot"; then
                log_info "Cluster snapshot exclu (filtre) : $s"
                continue
            fi
            log_warn "Snapshot cluster RDS : $s"
            register "$r" "rds" "cluster-snapshot" "$s" "" "1.90"
        done <<< "$csnaps"
    fi
}

# ============================================================
#  SCAN — EC2 / EBS / EIP / AMI
# ============================================================
scan_ec2() {
    local r="$1"
    log_section "EC2 / EBS / EIP — $r"

    local instances volumes ebs_snaps amis eips
    instances=$(run_aws "$r" ec2 describe-instances \
        --filters "Name=instance-state-name,Values=running,stopped,pending" \
        --query "Reservations[].Instances[].InstanceId")
    volumes=$(run_aws "$r" ec2 describe-volumes --query "Volumes[].VolumeId")
    ebs_snaps=$(run_aws "$r" ec2 describe-snapshots --owner-ids self \
        --query "Snapshots[].SnapshotId")
    amis=$(run_aws "$r" ec2 describe-images --owners self \
        --query "Images[].ImageId")
    eips=$(run_aws "$r" ec2 describe-addresses \
        --query "Addresses[?AssociationId==null].[AllocationId,PublicIp]" 2>/dev/null)

    local all="$instances$volumes$ebs_snaps$amis$eips"
    if [[ -z "$all" || "$all" == "None"* ]]; then
        log_ok "Aucune ressource EC2/EBS/EIP"
        return
    fi

    for id in $instances; do
        [[ "$id" == "None" || -z "$id" ]] && continue
        is_excluded "$id" && { log_info "EC2 exclu : $id"; continue; }
        log_warn "Instance EC2 : $id"
        register "$r" "ec2" "instance" "$id" "" "8.50"
    done
    for id in $volumes; do
        [[ "$id" == "None" || -z "$id" ]] && continue
        is_excluded "$id" && { log_info "Volume exclu : $id"; continue; }
        log_warn "Volume EBS   : $id"
        register "$r" "ec2" "volume" "$id" "" "0.80"
    done
    for id in $ebs_snaps; do
        [[ "$id" == "None" || -z "$id" ]] && continue
        is_excluded "$id" && { log_info "Snapshot exclu : $id"; continue; }
        log_warn "Snapshot EBS : $id"
        register "$r" "ec2" "snapshot" "$id" "" "0.50"
    done
    for id in $amis; do
        [[ "$id" == "None" || -z "$id" ]] && continue
        is_excluded "$id" && { log_info "AMI exclue : $id"; continue; }
        log_warn "AMI perso    : $id"
        register "$r" "ec2" "ami" "$id" "" "0.00"
    done

    if [[ -n "$eips" && "$eips" != "None" ]]; then
        while IFS=$'\t' read -r alloc ip; do
            [[ -z "$alloc" || "$alloc" == "None" ]] && continue
            is_excluded "$alloc" && { log_info "EIP exclue : $alloc"; continue; }
            log_warn "EIP libre    : $alloc ($ip)"
            register "$r" "ec2" "eip" "$alloc" "$ip" "3.60"
        done <<< "$eips"
    fi
}

# ============================================================
#  SCAN — NAT Gateway
# ============================================================
scan_nat_gateway() {
    local r="$1"
    log_section "NAT Gateway — $r"

    local nats
    nats=$(run_aws "$r" ec2 describe-nat-gateways \
        --filter "Name=state,Values=available" \
        --query "NatGateways[].NatGatewayId")

    if [[ -z "$nats" || "$nats" == "None" ]]; then
        log_ok "Aucune NAT Gateway"
        return
    fi

    for id in $nats; do
        [[ "$id" == "None" || -z "$id" ]] && continue
        is_excluded "$id" && { log_info "NAT exclue : $id"; continue; }
        log_warn "NAT Gateway  : $id (~32 \$/mois !)"
        register "$r" "ec2" "nat-gateway" "$id" "" "32.40"
    done
}

# ============================================================
#  SCAN — CloudWatch Logs (rétention infinie)
# ============================================================
scan_cloudwatch_logs() {
    local r="$1"
    log_section "CloudWatch Logs — $r"

    local groups
    groups=$(run_aws "$r" logs describe-log-groups \
        --query "logGroups[?retentionInDays==null].logGroupName")

    if [[ -z "$groups" || "$groups" == "None" ]]; then
        log_ok "Aucun log group sans rétention"
        return
    fi

    for id in $groups; do
        [[ "$id" == "None" || -z "$id" ]] && continue
        is_excluded "$id" && { log_info "Log group exclu : $id"; continue; }
        log_warn "Log group sans rétention : $id"
        register "$r" "logs" "log-group" "$id" "rétention infinie" "0.50"
    done
}

# ============================================================
#  SCAN — ELB
# ============================================================
scan_elb() {
    local r="$1"
    log_section "Load Balancers — $r"

    local clb alb nlb
    clb=$(run_aws "$r" elb describe-load-balancers \
        --query "LoadBalancerDescriptions[].LoadBalancerName")
    alb=$(run_aws "$r" elbv2 describe-load-balancers \
        --query "LoadBalancers[?Type=='application'].LoadBalancerArn")
    nlb=$(run_aws "$r" elbv2 describe-load-balancers \
        --query "LoadBalancers[?Type=='network'].LoadBalancerArn")

    local all="$clb$alb$nlb"
    if [[ -z "$all" || "$all" == "None" ]]; then
        log_ok "Aucun load balancer"
        return
    fi

    for id in $clb; do
        [[ "$id" == "None" || -z "$id" ]] && continue
        is_excluded "$id" && continue
        log_warn "CLB : $id"
        register "$r" "elb" "classic" "$id" "" "18.00"
    done
    for id in $alb; do
        [[ "$id" == "None" || -z "$id" ]] && continue
        is_excluded "$id" && continue
        log_warn "ALB : $id"
        register "$r" "elbv2" "application" "$id" "" "18.00"
    done
    for id in $nlb; do
        [[ "$id" == "None" || -z "$id" ]] && continue
        is_excluded "$id" && continue
        log_warn "NLB : $id"
        register "$r" "elbv2" "network" "$id" "" "18.00"
    done
}

# ============================================================
#  SCAN — Serverless & conteneurs
# ============================================================
scan_serverless() {
    local r="$1"
    log_section "Serverless & conteneurs — $r"
    local found=0

    local fns; fns=$(run_aws "$r" lambda list-functions --query "Functions[].FunctionName")
    for id in $fns; do
        [[ "$id" == "None" || -z "$id" ]] && continue
        is_excluded "$id" && continue
        log_warn "Lambda      : $id"; register "$r" "lambda" "function" "$id" "" "0.00"; found=1
    done

    local tables; tables=$(run_aws "$r" dynamodb list-tables --query "TableNames[]")
    for id in $tables; do
        [[ "$id" == "None" || -z "$id" ]] && continue
        is_excluded "$id" && continue
        log_warn "DynamoDB    : $id"; register "$r" "dynamodb" "table" "$id" "" "1.00"; found=1
    done

    local topics; topics=$(run_aws "$r" sns list-topics --query "Topics[].TopicArn")
    for id in $topics; do
        [[ "$id" == "None" || -z "$id" ]] && continue
        is_excluded "$id" && continue
        log_warn "SNS topic   : $id"; register "$r" "sns" "topic" "$id" "" "0.00"; found=1
    done

    local queues
    queues=$(run_aws "$r" sqs list-queues --query "QueueUrls[]" | tr '\t' '\n' | grep -v '^None$' | grep -v '^$')
    for id in $queues; do
        [[ -z "$id" ]] && continue
        is_excluded "$id" && continue
        log_warn "SQS queue   : $id"; register "$r" "sqs" "queue" "$id" "" "0.00"; found=1
    done

    local repos; repos=$(run_aws "$r" ecr describe-repositories --query "repositories[].repositoryName")
    for id in $repos; do
        [[ "$id" == "None" || -z "$id" ]] && continue
        is_excluded "$id" && continue
        log_warn "ECR repo    : $id"; register "$r" "ecr" "repository" "$id" "" "0.10"; found=1
    done

    local clusters; clusters=$(run_aws "$r" ecs list-clusters --query "clusterArns[]")
    for id in $clusters; do
        [[ "$id" == "None" || -z "$id" ]] && continue
        is_excluded "$id" && continue
        log_warn "ECS cluster : $id"; register "$r" "ecs" "cluster" "$id" "" "0.00"; found=1
    done

    local eks; eks=$(run_aws "$r" eks list-clusters --query "clusters[]")
    for id in $eks; do
        [[ "$id" == "None" || -z "$id" ]] && continue
        is_excluded "$id" && continue
        log_warn "EKS cluster : $id (~73 \$/mois)"; register "$r" "eks" "cluster" "$id" "" "73.00"; found=1
    done

    local secrets; secrets=$(run_aws "$r" secretsmanager list-secrets --query "SecretList[].Name")
    for id in $secrets; do
        [[ "$id" == "None" || -z "$id" ]] && continue
        is_excluded "$id" && continue
        log_warn "Secret      : $id"; register "$r" "secretsmanager" "secret" "$id" "" "0.40"; found=1
    done

    [[ "$found" -eq 0 ]] && log_ok "Rien côté serverless / conteneurs"
}

# ============================================================
#  SCAN — S3 (global)
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
        local region count size cost
        region=$(aws s3api get-bucket-location --bucket "$b" \
            --query "LocationConstraint" --output text 2>/dev/null || echo "us-east-1")
        [[ "$region" == "None" || -z "$region" ]] && region="us-east-1"

        local summary
        summary=$(aws s3 ls "s3://$b" --recursive --summarize 2>/dev/null)
        count=$(echo "$summary" | awk '/Total Objects/{print $3}')
        size=$(echo "$summary"  | awk '/Total Size/{print $3}')
        count=${count:-0}; size=${size:-0}

        if [[ "$count" -eq 0 ]]; then
            log_info "Bucket $b [$region] — vide"
        else
            if is_excluded "$b"; then
                log_info "Bucket exclu (filtre) : $b"
                continue
            fi
            # Coût approximatif S3 Standard : ~0.023 $/Go/mois
            cost=$(awk -v s="$size" 'BEGIN{printf "%.2f", s/1024/1024/1024*0.023}')
            log_warn "Bucket $b [$region] — $count objets, $size octets (~$cost \$/mois)"
            register "$region" "s3" "bucket" "$b" "$count objects / $size bytes" "$cost"
        fi
    done
}

# ============================================================
#  Tableau récapitulatif
# ============================================================
print_summary_table() {
    echo -e "\n${BOLD}${CYAN}══════════════════════════════════════════════════════════════════════════════${RESET}"
    echo -e "${BOLD}${CYAN}  TABLEAU RÉCAPITULATIF DES RESSOURCES TROUVÉES${RESET}"
    echo -e "${BOLD}${CYAN}══════════════════════════════════════════════════════════════════════════════${RESET}\n"

    if [[ ${#FOUND[@]} -eq 0 ]]; then
        log_ok "Aucune ressource facturable détectée. Compte propre !"
        return
    fi

    printf "${BOLD}%-4s %-14s %-14s %-14s %-45s %-10s${RESET}\n" \
        "#" "RÉGION" "SERVICE" "TYPE" "IDENTIFIANT" "COÛT"
    printf "${DIM}%s${RESET}\n" "────────────────────────────────────────────────────────────────────────────────────────"

    local idx=1
    local total_cost=0
    for entry in "${FOUND[@]}"; do
        IFS='|' read -r region service type id details cost <<< "$entry"
        printf "%-4s %-14s %-14s %-14s %-45s %-8s \$/mois\n" \
            "[$idx]" "$region" "$service" "$type" "$id" "$cost"
        total_cost=$(awk -v a="$total_cost" -v b="$cost" 'BEGIN{print a+b}')
        idx=$((idx + 1))
    done

    echo ""
    log_info "Total : ${BOLD}${#FOUND[@]}${RESET} ressource(s) facturable(s)."
    log_warn "💰 Coût mensuel estimé : ${BOLD}${YELLOW}$(printf '%.2f' "$total_cost") \$/mois${RESET}"
}

# ============================================================
#  Export
# ============================================================
export_report() {
    [[ -z "$OUTPUT_FORMAT" ]] && return 0

    local out="${OUTPUT_FILE:-rapport-$(date +%Y%m%d-%H%M%S).$OUTPUT_FORMAT}"

    case "$OUTPUT_FORMAT" in
        json)
            {
                echo "{"
                echo "  \"version\": \"$VERSION\","
                echo "  \"account_id\": \"$ACCOUNT_ID\","
                echo "  \"caller_arn\": \"$CALLER_ARN\","
                echo "  \"timestamp\": \"$(date -Iseconds)\","
                echo "  \"total_resources\": ${#FOUND[@]},"
                echo "  \"resources\": ["
                local first=1
                for entry in "${FOUND[@]}"; do
                    IFS='|' read -r region service type id details cost <<< "$entry"
                    [[ $first -eq 0 ]] && echo ","
                    first=0
                    printf '    {"region":"%s","service":"%s","type":"%s","id":"%s","details":"%s","monthly_cost_usd":%s}' \
                        "$region" "$service" "$type" "$id" "$details" "$cost"
                done
                echo ""
                echo "  ]"
                echo "}"
            } > "$out"
            ;;

        csv)
            {
                echo "region,service,type,id,details,monthly_cost_usd"
                for entry in "${FOUND[@]}"; do
                    IFS='|' read -r region service type id details cost <<< "$entry"
                    printf '%s,%s,%s,%s,"%s",%s\n' \
                        "$region" "$service" "$type" "$id" "$details" "$cost"
                done
            } > "$out"
            ;;

        html)
            {
                cat <<HTML
<!DOCTYPE html>
<html lang="fr">
<head>
<meta charset="utf-8">
<title>AWS Cleanup Audit - $ACCOUNT_ID</title>
<style>
  body { font-family: -apple-system, sans-serif; background: #0d1117; color: #c9d1d9; padding: 24px; }
  h1 { color: #58a6ff; }
  table { border-collapse: collapse; width: 100%; margin-top: 16px; }
  th, td { border: 1px solid #30363d; padding: 8px 12px; text-align: left; }
  th { background: #161b22; color: #58a6ff; }
  tr:nth-child(even) { background: #161b22; }
  .cost { color: #f0883e; font-weight: bold; }
  .total { margin-top: 16px; font-size: 1.2em; color: #3fb950; }
</style>
</head>
<body>
<h1>🧹 AWS Cleanup Audit</h1>
<p><strong>Compte :</strong> $ACCOUNT_ID<br>
<strong>ARN :</strong> $CALLER_ARN<br>
<strong>Date :</strong> $(date '+%Y-%m-%d %H:%M:%S')<br>
<strong>Version :</strong> $VERSION</p>
<h2>Ressources facturables trouvées</h2>
<table>
<tr><th>#</th><th>Région</th><th>Service</th><th>Type</th><th>Identifiant</th><th>Détails</th><th>Coût (USD/mois)</th></tr>
HTML
                local idx=1 total=0
                for entry in "${FOUND[@]}"; do
                    IFS='|' read -r region service type id details cost <<< "$entry"
                    echo "<tr><td>$idx</td><td>$region</td><td>$service</td><td>$type</td><td>$id</td><td>$details</td><td class=\"cost\">\$$cost</td></tr>"
                    total=$(awk -v a="$total" -v b="$cost" 'BEGIN{print a+b}')
                    idx=$((idx + 1))
                done
                cat <<HTML
</table>
<p class="total">💰 Coût mensuel estimé : $(printf '%.2f' "$total") \$/mois</p>
</body>
</html>
HTML
            } > "$out"
            ;;

        *)
            log_error "Format inconnu : $OUTPUT_FORMAT (json|csv|html)"
            return 1
            ;;
    esac

    log_ok "Rapport exporté : ${BOLD}$out${RESET}"
}

# ============================================================
#  Suppression
# ============================================================
delete_resource() {
    local region="$1" service="$2" type="$3" id="$4"

    if [[ "$DRY_RUN" -eq 1 ]]; then
        log_info "[DRY-RUN] Suppression $service/$type $id ($region)"
        return 0
    fi

    local -a cmd=()
    case "$service:$type" in
        rds:instance)         cmd=(aws rds delete-db-instance --db-instance-identifier "$id" --skip-final-snapshot --delete-automated-backups --region "$region") ;;
        rds:snapshot)         cmd=(aws rds delete-db-snapshot --db-snapshot-identifier "$id" --region "$region") ;;
        rds:cluster-snapshot) cmd=(aws rds delete-db-cluster-snapshot --db-cluster-snapshot-identifier "$id" --region "$region") ;;

        ec2:instance)         cmd=(aws ec2 terminate-instances --instance-ids "$id" --region "$region") ;;
        ec2:volume)           cmd=(aws ec2 delete-volume --volume-id "$id" --region "$region") ;;
        ec2:snapshot)         cmd=(aws ec2 delete-snapshot --snapshot-id "$id" --region "$region") ;;
        ec2:ami)              cmd=(aws ec2 deregister-image --image-id "$id" --region "$region") ;;
        ec2:eip)              cmd=(aws ec2 release-address --allocation-id "$id" --region "$region") ;;
        ec2:nat-gateway)      cmd=(aws ec2 delete-nat-gateway --nat-gateway-id "$id" --region "$region") ;;

        elb:classic)          cmd=(aws elb delete-load-balancer --load-balancer-name "$id" --region "$region") ;;
        elbv2:*)              cmd=(aws elbv2 delete-load-balancer --load-balancer-arn "$id" --region "$region") ;;

        lambda:function)      cmd=(aws lambda delete-function --function-name "$id" --region "$region") ;;
        dynamodb:table)       cmd=(aws dynamodb delete-table --table-name "$id" --region "$region") ;;
        sns:topic)            cmd=(aws sns delete-topic --topic-arn "$id" --region "$region") ;;
        sqs:queue)            cmd=(aws sqs delete-queue --queue-url "$id" --region "$region") ;;
        ecr:repository)       cmd=(aws ecr delete-repository --repository-name "$id" --force --region "$region") ;;
        ecs:cluster)          cmd=(aws ecs delete-cluster --cluster "$id" --region "$region") ;;
        eks:cluster)          cmd=(aws eks delete-cluster --name "$id" --region "$region") ;;
        secretsmanager:secret) cmd=(aws secretsmanager delete-secret --secret-id "$id" --force-delete-without-recovery --region "$region") ;;
        logs:log-group)       cmd=(aws logs delete-log-group --log-group-name "$id" --region "$region") ;;

        s3:bucket)            cmd=(aws s3 rb "s3://$id" --force) ;;

        *) log_error "Type non supporté : $service:$type"; return 1 ;;
    esac

    echo -e "${DIM}$ ${cmd[*]}${RESET}"
    if "${cmd[@]}" >/dev/null 2>&1; then
        log_ok "Supprimé : $service/$type $id ($region)"
        return 0
    else
        log_error "Échec suppression : $service/$type $id ($region)"
        return 1
    fi
}

# ============================================================
#  Menu interactif
# ============================================================
interactive_menu() {
    if [[ ${#FOUND[@]} -eq 0 ]]; then
        log_ok "Rien à supprimer."
        return
    fi

    while true; do
        echo ""
        echo -e "${BOLD}${CYAN}══════════════════════════════════════════════════════════════════════════════${RESET}"
        echo -e "${BOLD}${CYAN}  MENU DE SUPPRESSION${RESET}"
        echo -e "${BOLD}${CYAN}══════════════════════════════════════════════════════════════════════════════${RESET}"
        echo ""
        echo -e "  ${BOLD}1${RESET}) Supprimer UNE ressource (par numéro)"
        echo -e "  ${BOLD}2${RESET}) Supprimer TOUTES les ressources d'UNE région"
        echo -e "  ${BOLD}3${RESET}) Supprimer TOUTES les ressources d'une LISTE de régions"
        echo -e "  ${BOLD}4${RESET}) Supprimer TOUTES les ressources de TOUTES les régions"
        echo -e "  ${BOLD}5${RESET}) Afficher à nouveau le tableau"
        echo -e "  ${BOLD}0${RESET}) Quitter"
        echo ""
        read -rp "  Votre choix : " choice
        echo ""

        case "$choice" in
            1)
                read -rp "  Numéro de la ressource à supprimer : " n
                if ! [[ "$n" =~ ^[0-9]+$ ]] || (( n < 1 || n > ${#FOUND[@]} )); then
                    log_error "Numéro invalide."
                    continue
                fi
                IFS='|' read -r region service type id details cost <<< "${FOUND[$((n-1))]}"
                echo -e "  Cible : ${BOLD}$service/$type${RESET} — $id — région ${BOLD}$region${RESET}"
                confirm_and_delete "$region" "$service" "$type" "$id"
                ;;

            2)
                read -rp "  Région : " r
                delete_by_region "$r"
                ;;

            3)
                read -rp "  Régions (séparées par des espaces) : " regions
                for r in $regions; do
                    delete_by_region "$r"
                done
                ;;

            4)
                log_warn "${RED}${BOLD}Tu vas supprimer TOUTES les ressources listées dans TOUTES les régions.${RESET}"
                if [[ "$AUTO_YES" -eq 0 ]]; then
                    read -rp "  Tape 'SUPPRIMER TOUT' pour confirmer : " confirm
                    [[ "$confirm" != "SUPPRIMER TOUT" ]] && { log_warn "Annulé."; continue; }
                fi
                local snapshot=("${FOUND[@]}")
                for entry in "${snapshot[@]}"; do
                    IFS='|' read -r region service type id details cost <<< "$entry"
                    delete_resource "$region" "$service" "$type" "$id"
                done
                FOUND=()
                log_ok "Toutes les ressources ont été traitées."
                ;;

            5) print_summary_table ;;

            0|q|quit) log_info "Bye."; return ;;

            *) log_error "Choix invalide." ;;
        esac

        if [[ ${#FOUND[@]} -eq 0 ]]; then
            log_ok "Plus aucune ressource restante."
            return
        fi
    done
}

confirm_and_delete() {
    local region="$1" service="$2" type="$3" id="$4"
    if [[ "$AUTO_YES" -eq 0 ]]; then
        read -rp "  Confirmer la suppression ? [y/N] : " ans
        [[ ! "$ans" =~ ^[yY]$ ]] && { log_info "Annulé."; return; }
    fi
    if delete_resource "$region" "$service" "$type" "$id"; then
        remove_from_found "$region" "$service" "$type" "$id"
    fi
}

delete_by_region() {
    local r="$1"
    local matched=0
    local snapshot=("${FOUND[@]}")
    for entry in "${snapshot[@]}"; do
        IFS='|' read -r region service type id details cost <<< "$entry"
        [[ "$region" != "$r" ]] && continue
        matched=1
        echo -e "  → $service/$type $id"
        if [[ "$AUTO_YES" -eq 0 ]]; then
            read -rp "    Confirmer ? [y/N] : " ans
            [[ ! "$ans" =~ ^[yY]$ ]] && { log_info "  ignoré"; continue; }
        fi
        delete_resource "$region" "$service" "$type" "$id" && \
            remove_from_found "$region" "$service" "$type" "$id"
    done
    [[ "$matched" -eq 0 ]] && log_warn "Aucune ressource pour la région $r."
}

remove_from_found() {
    local region="$1" service="$2" type="$3" id="$4"
    local new=()
    for entry in "${FOUND[@]}"; do
        IFS='|' read -r er es et ei ed ec <<< "$entry"
        if [[ "$er" == "$region" && "$es" == "$service" && "$et" == "$type" && "$ei" == "$id" ]]; then
            continue
        fi
        new+=("$entry")
    done
    FOUND=("${new[@]}")
}

# ============================================================
#  Coûts
# ============================================================
scan_costs() {
    log_section "Coût des 7 derniers jours"
    local start end
    start=$(date -d "-7 days" +%Y-%m-%d 2>/dev/null || date -v-7d +%Y-%m-%d 2>/dev/null)
    end=$(date +%Y-%m-%d)

    if ! aws ce get-cost-and-usage \
            --time-period "Start=$start,End=$end" \
            --granularity DAILY --metrics "UnblendedCost" --region us-east-1 \
            >/dev/null 2>&1; then
        log_warn "Cost Explorer indisponible (permission ou non activé)."
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
#  Main
# ============================================================
clear 2>/dev/null || true
echo -e "${BOLD}${MAGENTA}"
cat <<'BANNER'
   ___  _      __ _      ___ _                 _
  / _ \| | /| / /| |    / __| |___ ___ _ _ _ _ (_)_ _
 | (_) | |/ |/ / | |__ | (__| / _ \ -_) ' \ ' \| | ' \
  \___/|__/|__/  |____| \___|_\___/___|_||_|_||_|_|_||_|
                       v2.1  •  Scanner + Cleanup
BANNER
echo -e "${RESET}"

log_info "Compte AWS : ${BOLD}${ACCOUNT_ID}${RESET}"
log_info "Identité   : ${DIM}${CALLER_ARN}${RESET}"

if [[ -n "$EXCLUDE_TAG" ]]; then
    log_info "Exclusion par tag : ${BOLD}$EXCLUDE_TAG${RESET}"
fi
if [[ -n "$EXCLUDE_PATTERN" ]]; then
    log_info "Exclusion par pattern : ${BOLD}$EXCLUDE_PATTERN${RESET}"
fi

if [[ -n "$TARGET_REGION" ]]; then
    REGIONS=("$TARGET_REGION")
else
    REGIONS=($(aws ec2 describe-regions --region us-east-1 \
        --query "Regions[?OptInStatus!='not-opted-in'].RegionName" \
        --output text 2>/dev/null))
fi
log_info "Régions scannées : ${#REGIONS[@]}"

for r in "${REGIONS[@]}"; do
    echo -e "\n${BOLD}${MAGENTA}════════════════════════════════════════════════════════${RESET}"
    echo -e "${BOLD}${MAGENTA}  Région : $r${RESET}"
    echo -e "${BOLD}${MAGENTA}════════════════════════════════════════════════════════${RESET}"
    scan_rds "$r"
    scan_ec2 "$r"
    scan_nat_gateway "$r"
    scan_cloudwatch_logs "$r"
    scan_elb "$r"
    scan_serverless "$r"
done

scan_s3
scan_costs

print_summary_table

# Export
if [[ -n "$OUTPUT_FORMAT" ]]; then
    export_report
fi

if [[ "$SCAN_ONLY" -eq 1 ]]; then
    log_info "Mode --scan-only : pas de suppression."
    exit 0
fi

if [[ ${#FOUND[@]} -gt 0 ]]; then
    interactive_menu
fi

echo -e "\n${DIM}Terminé à $(date '+%Y-%m-%d %H:%M:%S')${RESET}\n"
