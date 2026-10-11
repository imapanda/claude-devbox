# claude-devbox

Une machine de développement sur AWS, allumée à la demande, pour faire tourner **Claude Code** et tes conteneurs **Docker** ailleurs que sur ton PC.

Tu la pilotes depuis **Claude Desktop** en SSH, comme si elle était locale, avec un bureau graphique **Amazon DCV** en option. Elle s'éteint toute seule quand Claude a fini de travailler.

Tout tient dans un seul script PowerShell : `DevBox.ps1`.

## Pourquoi

Claude Code lance des builds, des tests et des stacks Docker. Sur un portable avec 16 Go de RAM, ça sature vite et ça chauffe. Ici, tout tourne sur la VM : le PC ne sert plus que d'écran.

## Comment ça marche

```
PC Windows                                   AWS (eu-west-1 par défaut)
──────────                                   ─────────────────────────
Claude Desktop                               VM Ubuntu 24.04
  │  ssh devbox                                Claude Code, Docker, bureau DCV
  ▼                                            aucun port entrant
OpenSSH (~/.ssh/config)                          ▲
  │  ProxyCommand :                              │ connexion sortante
  │  aws ssm start-session                       │ de l'agent SSM
  ▼                                              │
AWS Systems Manager ─────────────────────────────┘
```

- Aucun port n'est ouvert sur Internet : SSH passe dans un tunnel **AWS Systems Manager (SSM)**.
- La VM est désignée par son **ID d'instance**, qui ne change pas entre deux arrêts. Pas d'IP fixe à payer.
- Claude Desktop installe Claude Code sur la VM à la première connexion.

## Ce que le script crée

| Élément | Détail |
|---|---|
| Instance EC2 | `m8a.2xlarge` (8 cœurs AMD, 32 Go), Ubuntu 24.04, dans une zone où `c8a.4xlarge` et `m8a.4xlarge` existent aussi (changement de taille possible plus tard) |
| Disque | gp3 chiffré, 100 Go, débit 250 Mo/s |
| Rôle IAM | SSM et licence DCV uniquement, aucune autre permission |
| Groupe de sécurité | aucune règle entrante |
| Logiciels | Docker et Compose, Git, GitHub CLI, bureau XFCE (clavier AZERTY), Amazon DCV, Firefox |
| Arrêt automatique | la VM s'éteint après une période sans activité de Claude (voir plus bas) |
| Côté PC | une clé SSH propre au PC, une entrée `devbox` dans `~/.ssh/config`, un fichier d'état dans `%USERPROFILE%\.devbox\` |
| Budget (option) | alerte e-mail à 80 % du budget mensuel (réel) et à 100 % (prévision) |

## Coûts indicatifs

Prix à la demande en Irlande (`eu-west-1`), relevés en octobre 2026. Vérifie les tarifs du moment avant de te lancer.

| Poste | Prix | Exemple sur 160 h/mois (8 h × 20 jours) |
|---|---|---|
| `m8a.2xlarge` allumée | ~0,54 $/h | ~87 $ |
| Disque 100 Go, 250 Mo/s | ~15 $/mois | facturé même VM éteinte |
| IPv4 publique | ~0,005 $/h | facturée seulement VM allumée |

Une VM éteinte ne coûte que son disque. Allumée en permanence, la même machine coûte environ 4,5 fois plus.

## Prérequis

- Windows 10 ou 11, PowerShell 5.1 ou 7.
- Le client OpenSSH de Windows (installé par défaut sur les versions récentes).
- Un compte AWS et une identité avec les droits EC2, IAM, SSM et Budgets. Pour la création, un rôle administrateur est le plus simple.
- Claude Desktop, avec un abonnement qui donne accès à Claude Code.
- L'AWS CLI v2 et le plugin Session Manager : le script les installe via `winget` s'ils manquent.

## Démarrage rapide

### 1. Récupérer le script

```powershell
git clone https://github.com/imapanda/claude-devbox.git
cd claude-devbox
Unblock-File .\DevBox.ps1
```

Si Windows bloque toujours l'exécution : `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned`.

### 2. Créer la VM

```powershell
.\DevBox.ps1 -Action Create -AwsProfile devbox -AccountId 123456789012 -BudgetEmail moi@exemple.com
```

- `-AwsProfile` : le profil AWS CLI à utiliser. S'il n'existe pas, le script lance l'assistant de configuration (SSO recommandé, ou clés d'accès IAM).
- `-AccountId` : l'ID du compte AWS attendu. Le script refuse de continuer si le profil pointe sur un autre compte. Sans ce paramètre, il te demande de confirmer le compte détecté.
- `-BudgetEmail` : facultatif, active l'alerte budget.

Compte 10 à 15 minutes. À la fin, le script te demande le mot de passe du bureau DCV (utilisateur `ubuntu`).

### 3. Ajouter la VM dans Claude Desktop

Onglet **Code** > menu **Environnement** > **+ Add SSH connection** :

- **Name** : `devbox`
- **SSH Host** : `devbox`
- laisse le port et la clé vides : tout est dans `~/.ssh/config`.

Ensuite, à chaque nouvelle session, choisis l'environnement `devbox` et un dossier **sur la VM**.

## Utiliser un autre PC

Sur le nouveau PC, récupère le dépôt puis :

```powershell
.\DevBox.ps1 -Action Join -AwsProfile devbox -AccountId 123456789012
```

Le script retrouve la VM par son nom, la démarre si besoin, crée une clé SSH propre à ce PC, l'ajoute sur la VM via SSM et écrit `~/.ssh/config`. Il ne reste qu'à ajouter la connexion dans Claude Desktop (étape 3 ci-dessus).

Chaque PC a sa propre clé, nommée `devbox-<NOM-DU-PC>`, ce qui permet d'en révoquer une sans toucher aux autres (voir [Sécurité](#sécurité)).

## Usage quotidien

| Commande | Effet |
|---|---|
| `.\DevBox.ps1` | état de la VM |
| `.\DevBox.ps1 -Action Start` | démarre la VM (et te reconnecte si la session SSO a expiré) |
| `.\DevBox.ps1 -Action Stop` | arrête la VM |
| `.\DevBox.ps1 -Action Dcv` | ouvre le bureau graphique dans le navigateur |
| `.\DevBox.ps1 -Action Password` | change le mot de passe du bureau DCV |
| `.\DevBox.ps1 -Action Resize -InstanceType c8a.4xlarge` | change la taille de la VM |
| `.\DevBox.ps1 -Action Idle -IdleMinutes 60` | change le délai d'arrêt automatique |
| `.\DevBox.ps1 -Action Remove` | supprime la VM et tout ce que le script a créé |

Les paramètres de création sont mémorisés : ces commandes n'en demandent pas d'autres.

Claude Desktop ne démarre pas la VM tout seul : lance `-Action Start` avant d'ouvrir une session. La console AWS (web ou application mobile) permet aussi de la démarrer.

## Travailler sur plusieurs projets

Une seule connexion SSH suffit pour tous les projets.

- Range chaque projet dans son dossier sur la VM, par exemple `~/projets/mon-api` et `~/projets/mon-site`, chacun avec son dépôt Git.
- Dans Claude Desktop, chaque session a son dossier et son historique. Elles tournent en parallèle dans la barre latérale, que tu peux filtrer et grouper par projet.
- Pour plusieurs sessions sur **le même** projet, coche l'option **worktree** au démarrage : chaque session travaille sur sa propre copie Git.
- **Ports Docker** : deux stacks qui écoutent sur le même port entrent en conflit. Mets les ports dans un `.env` par projet, précise la règle dans le `CLAUDE.md`, et ajoute un fichier `.worktreeinclude` pour copier le `.env` dans chaque worktree.
- **RAM** : avec 32 Go et environ 5 Go par stack, compte 4 à 5 stacks actives en même temps. Au-delà, passe en `m8a.4xlarge`.

Le panneau Terminal de Claude Desktop n'est disponible qu'en local : garde une fenêtre `ssh devbox` ouverte à côté si besoin.

Pour des environnements complètement séparés, crée une seconde VM avec un autre nom : `-Name devbox-perso`. Elle apparaît comme un second hôte SSH et s'allume indépendamment.

## Bureau graphique (DCV)

```powershell
.\DevBox.ps1 -Action Dcv
```

Le script démarre la VM si besoin, ouvre un tunnel SSM dans une fenêtre séparée et lance `https://localhost:18443` dans le navigateur. Le certificat est auto-signé : accepte l'avertissement. Identifiant `ubuntu`, avec le mot de passe choisi à la création. Ferme la fenêtre du tunnel pour couper la connexion.

Le client DCV natif, plus fluide, se connecte à `localhost:18443`.

## Arrêt automatique

Des *hooks* Claude Code installés sur la VM notent l'état de chaque session. Une vérification tourne chaque minute.

| Situation | Décision |
|---|---|
| Claude travaille | reste allumée |
| Claude a fini depuis moins que le délai | reste allumée |
| Claude a fini depuis plus que le délai | **arrêt** |
| Claude attend ta validation depuis plus que le délai | **arrêt** |
| Une boucle `/loop` tourne | reste allumée |
| Bureau DCV connecté | reste allumée |
| Build ou tests qui chargent le CPU | reste allumée |
| Session Claude Desktop ouverte mais inactive | **arrêt** |

- Délai par défaut : 15 minutes. À la création : `-IdleMinutes 30`. Après coup : `-Action Idle -IdleMinutes 30`.
- Pour travailler sans Claude (terminal, outils), suspends l'arrêt sur la VM : `devbox-hold 2h`, puis `devbox-hold off`.
- Une boucle garde la VM allumée tant que deux itérations sont espacées de moins de 2 heures.
- Une session restée « occupée » sans nouvelle depuis 90 minutes est considérée comme plantée.
- Les 15 premières minutes après un démarrage ne comptent pas.
- L'arrêt éteint l'instance sans la supprimer : disque et code restent intacts.

Vérifier que les hooks fonctionnent : après un premier message dans une session, `ls /var/lib/devbox/claude` sur la VM doit afficher un fichier par session.

## Changer la puissance

```powershell
.\DevBox.ps1 -Action Resize -InstanceType c8a.4xlarge
```

La VM s'arrête, change de type et redémarre en quelques minutes.

| Type | Cœurs · RAM | Prix indicatif (Irlande) | Quand |
|---|---|---|---|
| `m8a.2xlarge` | 8 · 32 Go | ~0,54 $/h | par défaut |
| `c8a.4xlarge` | 16 · 32 Go | ~0,93 $/h | builds et tests plus rapides |
| `m8a.4xlarge` | 16 · 64 Go | ~1,09 $/h | beaucoup de conteneurs |

Surveille `htop` pendant une grosse session : CPU à 100 % pendant les builds, prends `c8a.4xlarge` ; RAM saturée, prends `m8a.4xlarge`. Évite les familles Intel en `i` : à prix égal, elles ont deux fois moins de vrais cœurs.

## Depuis un téléphone (Remote Control)

Le script ne l'automatise pas encore. Pour piloter la VM depuis l'application Claude (iPhone, Android) ou claude.ai/code :

1. Sur les plans Team et Enterprise, un Owner active **Remote Control** dans les réglages admin de Claude Code.
2. Sur la VM, installe Claude Code en ligne de commande et connecte-toi :
   ```bash
   curl -fsSL https://claude.ai/install.sh | bash
   claude   # puis /login
   ```
3. Dans un dossier de projet, lance le serveur dans `tmux` :
   ```bash
   cd ~/projets/mon-api
   claude remote-control --spawn worktree
   ```
4. Dans l'application, onglet **Code** : la VM apparaît, et tu peux y ouvrir ou créer des sessions.

La VM doit être allumée. Les sessions Remote Control utilisent les mêmes hooks : l'arrêt automatique les prend en compte.

## Sécurité

- **Aucun port entrant** : SSH et DCV passent par SSM, qui exige tes identifiants AWS.
- **Contrôle du compte** : chaque action vérifie que le profil pointe sur le compte attendu (`-AccountId`).
- **IMDSv2 obligatoire**, disque chiffré, rôle IAM limité à SSM et à la licence DCV.
- **Une clé SSH par PC.** Pour révoquer un PC :
  ```powershell
  ssh devbox "sed -i '/devbox-NOM-DU-PC$/d' ~/.ssh/authorized_keys"
  ```
- **Mode Auto ou contournement des permissions** : ne mets pas d'identifiants de production sur la VM.
- Ne publie jamais de clé ni de fichier d'état : le `.gitignore` les bloque, et active la *push protection* de GitHub.

## Dépannage

| Symptôme | Piste |
|---|---|
| `Identifiants refusés` ou session expirée | relance `-Action Start` : le script refait `aws sso login` |
| Claude Desktop n'arrive pas à se connecter | la VM est-elle allumée ? Teste `ssh -v devbox` dans PowerShell |
| `InsufficientInstanceCapacity` à la création | réessaie plus tard, ou change de type ou de région |
| Installation incomplète | journal sur la VM : `sudo tail -n 100 /var/log/devbox-init.log` |
| La VM s'éteint trop tôt | augmente le délai (`-Action Idle`) ou utilise `devbox-hold` |
| La VM ne s'éteint jamais | vérifie les hooks (`ls /var/lib/devbox/claude`) et le journal : `journalctl -t devbox` |
| Bureau DCV injoignable | `ssh devbox "sudo dcv list-sessions"`, puis relance `-Action Dcv` |

## Supprimer

```powershell
.\DevBox.ps1 -Action Remove
```

Supprime l'instance et son disque, le groupe de sécurité, le rôle IAM, le budget, l'entrée SSH et l'état local. La clé SSH du PC est conservée. Pousse ton code sur Git avant.

## Paramètres

| Paramètre | Défaut | Rôle |
|---|---|---|
| `-Action` | `Status` | `Create`, `Join`, `Start`, `Stop`, `Status`, `Dcv`, `Password`, `Resize`, `Idle`, `Remove` |
| `-Name` | `devbox` | nom de la VM, de l'hôte SSH et des ressources AWS |
| `-AwsProfile` | `devbox` | profil AWS CLI |
| `-AccountId` | | ID du compte AWS attendu (12 chiffres) |
| `-Region` | `eu-west-1` | région AWS |
| `-InstanceType` | `m8a.2xlarge` | type d'instance |
| `-FutureTypes` | `c8a.4xlarge`, `m8a.4xlarge` | types vers lesquels pouvoir basculer plus tard |
| `-DiskGb` | `100` | taille du disque |
| `-DiskThroughput` | `250` | débit du disque en Mo/s |
| `-IdleMinutes` | `15` | délai d'arrêt après la fin du travail de Claude |
| `-BudgetUsd` | `150` | budget mensuel de l'alerte |
| `-BudgetEmail` | | e-mail de l'alerte budget |

## Licence

[MIT](LICENSE)
