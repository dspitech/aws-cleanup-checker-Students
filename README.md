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

## Fonctionnalités

- Scan automatique de 13 services AWS sur toutes les régions
- Tableau récapitulatif clair
- Menu interactif de suppression ciblée
- Suppression par ressource, par région, multi-régions, ou globale
- Mode `--dry-run` pour tester sans rien casser
- Mode `--scan-only` pour intégration CI/CD

## Installation

```bash
git clone https://github.com/dspitech/aws-cleanup-checker-Students.git && cd aws-cleanup-checker-Students && chmod +x aws-cleanup-check.sh && ./aws-cleanup-check.sh
```

## Utilisation

#### Commandes de base
| Commande | Description |
|---|---|
| `./aws-cleanup-check.sh` | Scan complet + menu interactif |
| `./aws-cleanup-check.sh --region eu-west-3` | Cible une région |
| `./aws-cleanup-check.sh --scan-only` | Audit sans suppression |
| `./aws-cleanup-check.sh --dry-run` | Simulation |
| `./aws-cleanup-check.sh --yes` | Non-interactif  |
| `./aws-cleanup-check.sh --help` | Aide |

#### Filtres & exclusions
| Commande | Description |
|---|---|
| `--exclude-tag Keep=true` | Exclut par tag |
| `--exclude-pattern "prod-*"` | Exclut par nom |
| `--older-than 30d` | Ressources anciennes |

#### Export & notifications
| Commande | Description |
|---|---|
| `--format json\|csv\|html` | Format du rapport |
| `--output <fichier>` | Fichier de sortie |
| `--notify-slack <webhook>` | Notification Slack |


## Exemple de sortie

```
- Aucune ressource RDS
- Snapshots RDS  : wordpressdeploy-snapshot-wpdatabase-xxx
- EIP non assoc. : 15.xxx.xxx.xxx
- Aucun bucket S3
```

## Prérequis

- AWS CLI v2
- Identifiants configurés (`aws configure`, SSO, rôle)
- Policy IAM fournie dans `iam-policy.json`

## License

MIT
