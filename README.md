# AWS Cleanup Checker

> Détecte les ressources AWS facturables **oubliées** dans toutes les régions,
> y compris les fameux snapshots RDS qui continuent de coûter après suppression.

## Pourquoi ?

Après avoir supprimé une instance RDS, EC2 ou un bucket S3, il reste souvent :
- des **snapshots manuels** (RDS, EBS),
- des **AMI personnelles**,
- des **IP élastiques non associées**,
- des **volumes EBS orphelins**,
- des **buckets S3 non vidés**,
- des **clusters ECS/EKS abandonnés**…

Ces ressources sont facturées même après suppression du service principal.

## Installation

```bash
git clone https://github.com/dspitech/aws-cleanup-checker-Students.git && cd aws-cleanup-checker-Students && chmod +x aws-cleanup-check.sh && ./aws-cleanup-check.sh
```

## Utilisation

```bash
# Lancer un scan complet (toutes régions + S3 + coûts)
./aws-cleanup-check.sh

# Cibler une seule région (plus rapide)
./aws-cleanup-check.sh eu-west-3

# Rediriger le résultat dans un fichier
./aws-cleanup-check.sh 2>&1 | tee cleanup-$(date +%F).log
```

## Exemple de sortie

```
✔ Aucune ressource RDS
⚠ Snapshots RDS  : wordpressdeploy-snapshot-wpdatabase-xxx
⚠ EIP non assoc. : 15.xxx.xxx.xxx
✔ Aucun bucket S3
```

## Prérequis

- AWS CLI v2
- Identifiants configurés (`aws configure`, SSO, rôle)
- Policy IAM fournie dans `iam-policy.json`

## 📄 License

MIT
