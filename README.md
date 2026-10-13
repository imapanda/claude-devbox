# claude-devbox

Une machine de développement sur AWS, allumée à la demande, pour faire tourner **Claude Code** et tes conteneurs **Docker** ailleurs que sur ton PC.

Tu la pilotes depuis **Claude Desktop**, comme si elle était locale. Elle s'éteint toute seule quand Claude a fini de travailler. Un bureau graphique (Amazon DCV) est disponible en option.

Tout tient dans un seul script PowerShell : `DevBox.ps1`.

## Sommaire

- [Au quotidien](#au-quotidien)
- [Installation (une seule fois)](#installation-une-seule-fois)
- [Utiliser un autre PC](#utiliser-un-autre-pc)
- [Toutes les commandes](#toutes-les-commandes)
  - [Surveiller le CPU et la RAM en direct](#surveiller-le-cpu-et-la-ram-en-direct)
- [Travailler sur plusieurs projets](#travailler-sur-plusieurs-projets)
  - [Ajouter un projet](#ajouter-un-projet)
- [Arrêt automatique](#arrêt-automatique)
- [Bureau graphique (DCV)](#bureau-graphique-dcv)
- [Navigateur pour Claude](#navigateur-pour-claude)
- [OpenCode](#opencode)
- [Changer la puissance](#changer-la-puissance)
- [Depuis un téléphone](#depuis-un-téléphone)
- [Coûts](#coûts)
  - [Suivre les coûts](#suivre-les-coûts)
- [Questions fréquentes](#questions-fréquentes)
- [Dépannage](#dépannage)
- [Comment ça marche](#comment-ça-marche)
- [Sécurité](#sécurité)
- [Supprimer](#supprimer)
- [Paramètres du script](#paramètres-du-script)

## Au quotidien

Une fois l'installation faite, tu n'as que trois gestes. Les commandes se lancent dans **PowerShell**, depuis le dossier du dépôt (`cd $HOME\claude-devbox`).

| | Quoi | Comment |
|---|---|---|
| 1 | **Démarrer la VM** | `.\DevBox.ps1 -Action Start` |
| 2 | **Travailler** | Claude Desktop > onglet **Code** > nouvelle session > environnement **devbox** |
| 3 | **Arrêter** | Rien à faire : la VM s'éteint seule 15 min après la fin du travail de Claude. Pour couper tout de suite : `.\DevBox.ps1 -Action Stop` |

Pour savoir où elle en est : `.\DevBox.ps1` (sans paramètre) affiche son état.

Claude Desktop ne démarre pas la VM tout seul : lance toujours l'étape 1 avant d'ouvrir une session.

### Raccourci `devbox` (recommandé)

Pour lancer le script depuis n'importe quel dossier, sans te soucier de l'endroit où le dépôt est cloné sur chaque PC, exécute une fois **depuis le dossier du dépôt** :

```powershell
if (!(Test-Path $PROFILE)) { New-Item -ItemType File -Force $PROFILE | Out-Null }
Add-Content $PROFILE "function devbox { & '$PWD\DevBox.ps1' @args }"
. $PROFILE
```

Ensuite, dans n'importe quelle fenêtre PowerShell :

| Commande | Équivaut à |
|---|---|
| `devbox start` | `.\DevBox.ps1 -Action Start` |
| `devbox stop` | `.\DevBox.ps1 -Action Stop` |
| `devbox` | `.\DevBox.ps1` (état de la VM) |
| `devbox cost` | `.\DevBox.ps1 -Action Cost` |
| `devbox dcv` | `.\DevBox.ps1 -Action Dcv` |
| `devbox opencode` | `.\DevBox.ps1 -Action OpenCode` |

Les autres paramètres s'ajoutent comme d'habitude : `devbox resize -InstanceType c8a.4xlarge`. À refaire sur chaque PC.

## Installation (une seule fois)

Compte 30 minutes, dont 15 d'attente pendant que la VM s'installe.

### Étape 1 : vérifier les prérequis

- Windows 10 ou 11, avec PowerShell (déjà présent).
- [Git pour Windows](https://git-scm.com/downloads/win), pour récupérer le dépôt.
- [Claude Desktop](https://claude.com/download), avec un abonnement qui donne accès à Claude Code.
- Un compte AWS. Note son **ID à 12 chiffres** (en haut à droite de la console).

L'AWS CLI et le plugin Session Manager s'installent automatiquement à la première exécution du script.

### Étape 2 : créer un accès AWS pour le script

Le script a besoin d'identifiants AWS. Le plus simple : un utilisateur IAM dédié, limité à ce dont le script a besoin.

Dans la console AWS, ouvre **CloudShell** (icône `>_` en haut de la page) et colle :

```bash
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
aws iam create-user --user-name devbox-cli

cat > devbox-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    { "Sid": "Ec2SsmBudgets", "Effect": "Allow",
      "Action": ["ec2:*", "ssm:*", "budgets:*", "cloudwatch:GetMetricStatistics", "ce:GetCostAndUsage"], "Resource": "*" },
    { "Sid": "RoleDevbox", "Effect": "Allow",
      "Action": ["iam:GetRole", "iam:CreateRole", "iam:DeleteRole", "iam:TagRole",
                 "iam:AttachRolePolicy", "iam:DetachRolePolicy", "iam:PutRolePolicy", "iam:DeleteRolePolicy",
                 "iam:PassRole", "iam:GetInstanceProfile", "iam:CreateInstanceProfile",
                 "iam:DeleteInstanceProfile", "iam:AddRoleToInstanceProfile", "iam:RemoveRoleFromInstanceProfile"],
      "Resource": ["arn:aws:iam::${ACCOUNT}:role/*-ec2-role", "arn:aws:iam::${ACCOUNT}:instance-profile/*-ec2-role"] },
    { "Sid": "Alias", "Effect": "Allow", "Action": "iam:ListAccountAliases", "Resource": "*" }
  ]
}
EOF

aws iam put-user-policy --user-name devbox-cli --policy-name devbox --policy-document file://devbox-policy.json
aws iam create-access-key --user-name devbox-cli --query 'AccessKey.[AccessKeyId,SecretAccessKey]' --output text
rm devbox-policy.json
```

La dernière commande affiche la **clé d'accès** et son **secret**. Le secret n'est montré qu'une fois : garde-le pour l'étape 4 et ne le partage avec personne.

Tu utilises déjà IAM Identity Center (SSO) ? Tu peux t'en servir à la place : le script lance l'assistant de connexion SSO.

### Étape 3 : récupérer le script

Dans PowerShell :

```powershell
cd $HOME
git clone https://github.com/imapanda/claude-devbox.git
cd claude-devbox
Unblock-File .\DevBox.ps1
```

Si Windows refuse encore d'exécuter le script : `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned`.

### Étape 4 : créer la VM

Remplace l'ID de compte et l'e-mail par les tiens :

```powershell
.\DevBox.ps1 -Action Create -AwsProfile devbox -AccountId 123456789012 -BudgetEmail moi@exemple.com
```

Le script te pose quelques questions :

1. **Type de connexion** : `2` pour la clé d'accès de l'étape 2 (ou `1` pour SSO).
2. **AWS Access Key ID** et **Secret Access Key** : colle la clé et le secret.
3. **Default region** : `eu-west-1`. **Output format** : `json`.
4. Après 10 à 15 minutes d'installation : le **mot de passe du bureau graphique**, deux fois. Les caractères ne s'affichent pas, c'est normal.

À la fin, le script affiche « Machine prête ».

- `-AccountId` est un garde-fou : le script refuse de continuer si les identifiants pointent sur un autre compte.
- `-BudgetEmail` est facultatif : il active une alerte e-mail si la facture approche du budget (150 $/mois par défaut).

### Étape 5 : connecter Claude Desktop

1. **Quitte complètement Claude Desktop et relance-le** (zone de notification > Quitter). Il doit relire le PATH pour trouver l'AWS CLI qui vient d'être installée.
2. Onglet **Code** > menu **Environnement** > **+ Add SSH connection** :
   - **Name** : `devbox`
   - **SSH Host** : `devbox`
   - laisse le port et la clé vides.
3. Ouvre une nouvelle session sur l'environnement `devbox`, dossier `/home/ubuntu`. La première connexion installe Claude Code sur la VM (environ une minute).

### Étape 6 : préparer tes projets sur la VM

Connecte GitHub sur la VM et récupère un projet :

```powershell
ssh devbox
gh auth login -h github.com -p https -w   # affiche un code : ouvre https://github.com/login/device sur ton PC et colle-le
gh auth setup-git                          # git utilise ce compte pour clone/push
git config --global user.name  "Ton Nom"
git config --global user.email "<id>+<ton-compte>@users.noreply.github.com"   # GitHub > Settings > Emails
mkdir -p ~/projets && cd ~/projets
git clone https://github.com/<ton-compte>/<ton-projet>.git
exit
```

Le jeton GitHub reste sur le disque de la VM (`~/.config/gh/hosts.yml`) : à faire une seule fois, il survit aux arrêts. Pour le révoquer : `gh auth logout` sur la VM, ou GitHub > Settings > Applications > Authorized OAuth Apps > GitHub CLI.

Dans Claude Desktop, ouvre ensuite une session sur le dossier `~/projets/<ton-projet>`.

### Étape 7 : vérifier que tout marche

Après un premier échange avec Claude :

```powershell
ssh devbox "ls /var/lib/devbox/claude"
```

Un fichier doit apparaître : l'arrêt automatique voit bien Claude travailler.

## Utiliser un autre PC

Pour piloter la même VM depuis un deuxième PC (un portable, par exemple). Les deux PC partagent la VM : mêmes projets, même Docker, même connexion GitHub. Chacun garde sa propre liste de sessions dans Claude Desktop.

1. **Prérequis** : installe Git pour Windows et Claude Desktop (même compte Claude).
2. **Clé AWS pour ce PC** : dans CloudShell, crée une deuxième clé pour `devbox-cli` :
   ```bash
   aws iam create-access-key --user-name devbox-cli --query 'AccessKey.[AccessKeyId,SecretAccessKey]' --output text
   ```
   Une clé par PC permet d'en révoquer un sans toucher à l'autre (deux clés maximum par utilisateur IAM). Tu peux aussi réutiliser celle du premier PC, rangée dans `%USERPROFILE%\.aws\credentials`.
3. **Script** : récupère-le comme à l'étape 3, puis rattache le PC :
   ```powershell
   .\DevBox.ps1 -Action Join -AwsProfile devbox -AccountId 123456789012
   ```
   Réponds `2`, colle la clé et le secret, puis `eu-west-1` et `json`. Le script retrouve la VM, la démarre si besoin, crée une **clé SSH propre à ce PC**, l'ajoute sur la VM et configure SSH.
4. **Claude Desktop** : refais l'étape 5 (relance complète, puis **+ Add SSH connection** `devbox`).

Rien à refaire sur la VM. Les deux PC peuvent être connectés en même temps ; évite seulement de faire travailler deux sessions sur le même dossier (coche **worktree**).

## Toutes les commandes

### Sur le PC (PowerShell, dossier `claude-devbox`)

| Commande | Effet |
|---|---|
| `.\DevBox.ps1` | affiche l'état de la VM |
| `.\DevBox.ps1 -Action Cost` | coût du mois en cours (estimation à jour + montant facturé) |
| `.\DevBox.ps1 -Action Start` | démarre la VM (et te reconnecte à AWS si besoin) |
| `.\DevBox.ps1 -Action Stop` | arrête la VM et confirme l'état `stopped` auprès d'AWS |
| `.\DevBox.ps1 -Action Dcv` | ouvre le bureau graphique dans le navigateur |
| `.\DevBox.ps1 -Action OpenCode` | OpenCode 2 sur la VM + tunnel + lien de connexion pour l'application |
| `.\DevBox.ps1 -Action Password` | change le mot de passe du bureau graphique |
| `.\DevBox.ps1 -Action Idle -IdleMinutes 30` | change le délai d'arrêt automatique |
| `.\DevBox.ps1 -Action Resize -InstanceType c8a.4xlarge` | change la puissance de la VM |
| `.\DevBox.ps1 -Action Join ...` | rattache un nouveau PC à la VM |
| `.\DevBox.ps1 -Action Remove` | supprime la VM et tout ce que le script a créé |
| `ssh devbox` | ouvre un terminal sur la VM |

Les paramètres de création sont mémorisés sur le PC : ces commandes n'en demandent pas d'autres.

### Sur la VM (terminal `ssh devbox`, ou en le demandant à Claude dans une session)

| Commande | Effet |
|---|---|
| `devbox-off` | éteint la VM tout de suite |
| `devbox-off 10` | éteint la VM dans 10 minutes (`devbox-off cancel` pour annuler) |
| `devbox-hold 2h` | suspend l'arrêt automatique pendant 2 heures (`devbox-hold off` pour le réactiver) |

### Surveiller le CPU et la RAM en direct

Depuis PowerShell sur le PC, VM allumée :

| Pour voir | Commande | Pour quitter |
|---|---|---|
| **Courbes** CPU et RAM, réseau, disque, processus | `ssh -t devbox btop` | `q` |
| CPU par cœur, RAM et processus | `ssh -t devbox htop` | `q` |
| CPU et RAM de chaque conteneur Docker | `ssh -t devbox docker stats` | `Ctrl+C` |
| Un relevé ponctuel | `ssh devbox "free -h; uptime"` | (rien à faire) |

Ouvre-les dans un deuxième onglet du Terminal Windows pendant que Claude travaille. Ils n'empêchent pas l'arrêt automatique.

VM créée avant l'ajout de `btop` : installe-le une fois avec `ssh devbox "sudo apt-get install -y btop"`.

Historique sur plusieurs jours : console AWS > EC2 > Instances > `devbox` > onglet **Surveillance** (courbe CPU uniquement, la RAM n'y figure pas).

## Travailler sur plusieurs projets

Une seule connexion `devbox` suffit pour tous les projets.

### Ajouter un projet

Exemple avec le dépôt `mon-orga/mon-projet` (personnel ou d'une organisation) :

```powershell
.\DevBox.ps1 -Action Start
ssh devbox "mkdir -p ~/projets && cd ~/projets && gh repo clone mon-orga/mon-projet"
```

Puis dans Claude Desktop : onglet **Code** > nouvelle session > environnement **devbox** > dossier `/home/ubuntu/projets/mon-projet`. Claude travaille alors uniquement dans ce dossier.

- **Fichier `.env` hors Git** : copie-le depuis le PC avec `scp .\.env devbox:~/projets/mon-projet/`.
- **« not found » ou 403 sur un dépôt d'organisation** : l'organisation bloque sans doute les applications tierces. Un propriétaire doit autoriser GitHub CLI dans l'organisation > Settings > Third-party access > OAuth app policy.

### Règles pour plusieurs projets

- **Un dossier par projet** sur la VM (`~/projets/mon-api`, `~/projets/mon-site`), chacun avec son dépôt Git.
- **Une session Claude Desktop par tâche** : chaque session a son dossier et son historique. Elles tournent en parallèle dans la barre latérale, que tu peux filtrer et grouper par projet.
- **Plusieurs sessions sur le même projet** : coche l'option **worktree** au démarrage de la session. Chacune travaille alors sur sa propre copie Git.
- **Ports Docker** : deux stacks sur le même port entrent en conflit. Mets les ports dans un `.env` par projet, précise la règle dans le `CLAUDE.md`, et ajoute un fichier `.worktreeinclude` pour copier le `.env` dans chaque worktree.
- **Mémoire** : avec 32 Go et environ 5 Go par stack, compte 4 à 5 stacks actives en même temps.
- **CPU** : plusieurs sessions qui lancent en même temps des jobs lourds (mutation testing, `pytest -n auto`) peuvent faire monter la charge à 90 sur 8 cœurs et figer la VM. Le script crée `~/.claude/CLAUDE.md` sur la VM avec des consignes de sobriété (2 workers maximum, une seule campagne de mutation testing à la fois). Sur une VM plus ancienne, ajoute-les une fois :
  ```powershell
  $OutputEncoding = [Text.UTF8Encoding]::new($false)
  @'

  ## Ressources de la VM (partagée entre plusieurs sessions Claude)
  - Avant un job lourd (tests, mutation testing, build), regarde la charge avec `uptime` : si elle dépasse le nombre de cœurs (`nproc`), attends ou réduis.
  - Parallélisme maximum : 2 workers (`pytest -n 2`, `mutmut run --max-children 2`, `make -j2`), jamais `-n auto`.
  - Une seule campagne de mutation testing à la fois sur toute la VM.
  - Arrête les conteneurs Docker de test quand tu as fini (`docker compose down`).
  '@ | ssh devbox "tr -d '\r' >> ~/.claude/CLAUDE.md"
  ```
  Les consignes s'appliquent aux nouvelles sessions.

Le panneau Terminal de Claude Desktop ne fonctionne qu'en local : garde une fenêtre `ssh devbox` ouverte à côté si besoin.

Pour des environnements complètement séparés, crée une seconde VM avec un autre nom (`-Name devbox-perso`) : elle apparaît comme un second hôte SSH et s'allume indépendamment.

## Arrêt automatique

La VM s'éteint quand **Claude a fini de travailler** depuis 15 minutes. Une vérification tourne chaque minute sur la VM.

| Situation | Décision |
|---|---|
| Claude travaille | reste allumée |
| Claude a fini depuis moins de 15 min | reste allumée |
| Claude a fini depuis plus de 15 min | **s'éteint** |
| Claude attend ta validation depuis plus de 15 min | **s'éteint** |
| Une boucle `/loop` tourne | reste allumée |
| Bureau graphique connecté | reste allumée |
| Application OpenCode connectée | reste allumée |
| Build ou tests qui font travailler le processeur | reste allumée |
| Session Claude Desktop ouverte mais inactive | **s'éteint** |
| `devbox-hold` actif | reste allumée |

Bon à savoir :
- Le délai se change avec `.\DevBox.ps1 -Action Idle -IdleMinutes 30`.
- Les 15 premières minutes après un démarrage ne comptent pas.
- « S'éteindre » veut dire arrêtée, pas supprimée : le disque et ton code restent intacts. Relance avec `-Action Start`.
- À l'arrêt, la session Claude Desktop se coupe. Ton historique est conservé sur la VM.
- Une boucle garde la VM allumée tant que deux itérations sont espacées de moins de 2 heures.

## Bureau graphique (DCV)

```powershell
.\DevBox.ps1 -Action Dcv
```

Le script démarre la VM si besoin, ouvre un tunnel dans une petite fenêtre séparée et lance `https://localhost:18443` dans ton navigateur.

- Le certificat est auto-signé : accepte l'avertissement du navigateur.
- Identifiant : `ubuntu`. Mot de passe : celui choisi à l'installation (`-Action Password` pour le changer).
- Ferme la fenêtre du tunnel pour couper le bureau.
- Le client DCV natif, plus fluide, se connecte à `localhost:18443`.

## Navigateur pour Claude

Claude dispose du serveur MCP **Playwright** : un Chromium sans écran, dans un conteneur Docker. Il ouvre lui-même les pages de tes applications, clique, remplit des formulaires et prend des captures d'écran.

**Rien à lancer** : Claude démarre le navigateur à chaque nouvelle session et l'arrête à la fin. La configuration est sur le disque de la VM, elle survit aux arrêts et redémarrages.

**VM créée avec une version du script antérieure à l'ajout de Playwright** : installe-le une fois.

```powershell
ssh devbox
docker pull mcr.microsoft.com/playwright/mcp
curl -fsSL https://claude.ai/install.sh | bash      # installe la commande claude si elle manque
~/.local/bin/claude mcp add --scope user playwright -- docker run -i --rm --init --network host mcr.microsoft.com/playwright/mcp
exit
```

L'avertissement « ~/.local/bin is not in your PATH » de l'installeur peut être ignoré : à la connexion suivante, Ubuntu ajoute ce dossier tout seul et la commande `claude` fonctionne.

Ouvre ensuite une **nouvelle** session dans Claude Desktop (les sessions déjà ouvertes ne voient pas l'outil). `/mcp` doit afficher `playwright` connecté.

- `--network host` : le navigateur atteint les applications de la VM sur `localhost` (par exemple `http://localhost:3000`), y compris les ports publiés par Docker Compose.
- Disponible dans tous les projets (`--scope user`). Le conteneur ne tourne que pendant les sessions.
- Demande-le explicitement : « vérifie l'écran de connexion dans le navigateur et fais une capture ».
- Pour le retirer : `~/.local/bin/claude mcp remove --scope user playwright`.

## OpenCode

[OpenCode](https://opencode.ai) peut tourner sur la VM à côté de Claude Code : le serveur OpenCode 2 sur la VM, l'**application OpenCode** (ou le navigateur) sur le PC.

### Première fois

1. Installe l'application OpenCode sur le PC : [opencode.ai/download](https://opencode.ai/download).
2. Lance :
   ```powershell
   devbox opencode
   ```
   Le script démarre la VM si besoin, installe OpenCode 2 sur la VM (serveur en service, démarré avec la VM, mot de passe généré par OpenCode, joignable seulement par le tunnel), ouvre le tunnel dans une **fenêtre séparée à laisser ouverte**, et copie un **lien de connexion** dans le presse-papiers.
3. Dans l'application OpenCode, colle le lien dans l'adresse du serveur. Le lien ne sert qu'une fois et expire au bout de 5 minutes : relance `devbox opencode` pour en avoir un nouveau.
   Si l'application demande plutôt les champs d'un serveur (accueil : `Ctrl+B`), le script les affiche aussi : serveur `http://127.0.0.1:14374`, utilisateur `opencode`, mot de passe généré sur la VM, dossier `/home/ubuntu/projets`.
4. Configure ton fournisseur de modèles dans l'application : les identifiants restent sur la VM.

### Ensuite

`devbox opencode`, puis ouvre l'application : elle se reconnecte toute seule au serveur `http://127.0.0.1:14374` (connexion valable 30 jours).

Sans l'application : colle le lien dans ton navigateur, c'est la même interface en version web.

### Projets

Dans l'application, ouvre les dossiers de `~/projets` : ce sont ceux de la VM. Plusieurs projets peuvent être ouverts en même temps.

### Terminer

1. Ferme l'application, puis la fenêtre du tunnel.
2. La VM s'éteint seule 15 min après (si Claude ne travaille pas), ou tout de suite avec `devbox stop`.

Bon à savoir :
- Tant que l'application est connectée, la VM ne s'éteint pas (comme le bureau DCV).
- Un travail long d'OpenCode, application fermée, n'est vu par l'arrêt automatique que s'il occupe le CPU : sinon, `ssh devbox devbox-hold 2h`.
- Les consignes de sobriété CPU de `~/.claude/CLAUDE.md` sont copiées dans `~/.config/opencode/AGENTS.md` à l'installation.
- Le port 14374 sur le PC évite le conflit avec le serveur local que l'application peut lancer sur 49374.
- Journal du serveur : `ssh devbox "journalctl -u opencode-serve -n 50 --no-pager"`.
- Mise à jour d'OpenCode sur la VM : `ssh devbox "~/.opencode/bin/opencode upgrade && sudo systemctl restart opencode-serve"`.

## Changer la puissance

```powershell
.\DevBox.ps1 -Action Resize -InstanceType c8a.4xlarge
```

La VM s'arrête, change de type et redémarre en quelques minutes. Prix à la demande en Irlande :

| Type | Cœurs · Mémoire | Prix indicatif | Quand le choisir |
|---|---|---|---|
| `c8a.2xlarge` | 8 · 16 Go | ~0,46 $/h | mêmes cœurs, RAM peu utilisée : moins cher |
| `m8a.2xlarge` | 8 · 32 Go | ~0,54 $/h | par défaut |
| `c8a.4xlarge` | 16 · 32 Go | ~0,93 $/h | builds et tests plus rapides |
| `m8a.4xlarge` | 16 · 64 Go | ~1,09 $/h | beaucoup de conteneurs |

Chez AWS, la mémoire suit le nombre de cœurs : 2 Go par cœur en `c`, 4 Go en `m`. Il n'existe pas de taille intermédiaire (12 cœurs) : plus de 8 cœurs, c'est 16.

Pour décider, regarde `btop` sur la VM pendant une grosse session :
- **tous les cœurs à 100 % pendant les builds** : `c8a.4xlarge` ;
- **cœurs pas saturés** : plus de cœurs n'accélérera rien ; si la RAM reste sous 12 Go, `c8a.2xlarge` coûte moins cher pour la même vitesse ;
- **mémoire saturée** : `m8a.4xlarge`.

Tu peux changer dans les deux sens à tout moment : rien n'est perdu, seules les sessions ouvertes sont coupées pendant le redémarrage.

## Depuis un téléphone

Le script ne l'automatise pas encore. Pour piloter la VM depuis l'application Claude (iPhone, Android) ou depuis claude.ai/code :

1. Sur les plans Team et Enterprise, un Owner active **Remote Control** dans les réglages admin de Claude Code.
2. Sur la VM, connecte Claude Code en ligne de commande (déjà installé sur les VM récentes, sinon `curl -fsSL https://claude.ai/install.sh | bash`) :
   ```bash
   claude   # puis /login
   ```
3. Dans un dossier de projet, lance le serveur dans `tmux` :
   ```bash
   cd ~/projets/mon-api
   claude remote-control --spawn worktree
   ```
4. Dans l'application, onglet **Code** : la VM apparaît, et tu peux y ouvrir ou créer des sessions.

La VM doit être allumée : depuis le téléphone, l'application AWS Console permet de la démarrer.

## Coûts

Prix à la demande en Irlande (`eu-west-1`), relevés en octobre 2026. Vérifie les tarifs du moment.

| Poste | Prix | Exemple sur 160 h/mois (8 h × 20 jours) |
|---|---|---|
| `m8a.2xlarge` allumée | ~0,54 $/h | ~87 $ |
| Disque 100 Go, 250 Mo/s | ~15 $/mois | facturé même VM éteinte |
| IPv4 publique | ~0,005 $/h | facturée seulement VM allumée |

Une VM éteinte ne coûte que son disque.

### Suivre les coûts

```powershell
devbox cost
```

Quatre blocs, du plus frais au plus complet :

| Bloc | Contenu | Fraîcheur |
|---|---|---|
| VM AWS | heures allumée ce mois × tarif, IPv4, disque au prorata, session en cours | ~10 min, même VM éteinte |
| Facture AWS par service | montant réel de Cost Explorer, services d'IA marqués **[IA]** (Bedrock et modèles Bedrock) et total « dont IA » | ~24 h |
| IA via OpenCode | coût et jetons par modèle calculés par OpenCode, tous fournisseurs confondus (Azure, AWS, Anthropic…) | temps réel (VM allumée) |
| Facture Azure par service | montant réel de Cost Management, services d'IA marqués **[IA]** (Foundry, OpenAI…) et total « dont IA » | quelques heures |

```
==> Facture AWS du mois, par service (decalage ~24 h)
    Claude Sonnet 4.5 (Amazon Bedrock Edition)      12,40 $  [IA]
    Amazon Elastic Compute Cloud - Compute           8,10 $
    Total AWS                                       27,20 $
      dont IA                                       13,20 $

==> IA via OpenCode, ce mois (temps reel, tous fournisseurs)
    Sessions 12   Messages 340   Cost $18.42
      azure/gpt-5                  $11.20   1.2M in / 240K out
      anthropic/claude-sonnet-4-5   $7.22   800K in / 90K out

==> Facture Azure du mois, par service (Abonnement perso)
    Foundry Models                                  12,35 EUR  [IA]
    Total Azure                                     15,87 EUR
      dont IA                                       15,45 EUR
```

Le bloc OpenCode est le seul en temps réel pour l'IA : les factures AWS et Azure arrivent avec quelques heures de retard. Claude Code passe par ton abonnement Claude : pas de facturation à l'usage.

**Mise en place, une fois :**

1. AWS : ouvre **Cost Explorer** dans la console pour l'activer. Si `devbox-cli` a été créé avant cette fonction, ajoute-lui les permissions de lecture dans CloudShell :
   ```bash
   aws iam put-user-policy --user-name devbox-cli --policy-name devbox-cost --policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":["cloudwatch:GetMetricStatistics","ce:GetCostAndUsage"],"Resource":"*"}]}'
   ```
2. Azure : indique l'abonnement (et, en option, le groupe de ressources), mémorisés ensuite :
   ```powershell
   .\DevBox.ps1 -Action Cost -AzureSubscription "<nom ou ID>" [-AzureResourceGroup "<groupe>"]
   ```
   Le script installe Azure CLI si besoin et ouvre le navigateur pour `az login`. Il faut le rôle **Lecteur de gestion des coûts** (Cost Management Reader) ou **Lecteur** sur l'abonnement.

Chaque consultation de Cost Explorer coûte 0,01 $. L'alerte budget par e-mail reste le filet de sécurité.

## Questions fréquentes

**Comment démarrer la VM ?**
`.\DevBox.ps1 -Action Start` sur le PC. Sans le script : console AWS > EC2 > Instances > `devbox` > État de l'instance > Démarrer (ou l'application mobile AWS Console).

**Comment savoir si elle est allumée ?**
`.\DevBox.ps1` affiche son état. Ou la console AWS, page EC2 > Instances.

**Suis-je prévenu par e-mail quand elle démarre ou s'arrête ?**
Non. Le seul e-mail est l'alerte budget, si tu as renseigné `-BudgetEmail`.

**Est-ce que je perds mon travail quand elle s'éteint ?**
Non. Les fichiers, les dépôts et l'historique des sessions restent sur le disque. Seuls les processus en cours (conteneurs, serveurs de dev) s'arrêtent, et le travail non poussé sur Git reste sur la VM.

**Je dois emporter le script partout ?**
Non : il est sur GitHub. Sur un nouveau PC, clone le dépôt et lance `-Action Join` une fois.

**Je peux l'utiliser depuis mon PC portable en plus du PC fixe ?**
Oui, voir [Utiliser un autre PC](#utiliser-un-autre-pc). Projets, Docker et GitHub sont partagés ; les sessions Claude Desktop restent propres à chaque PC.

**Comment la VM accède-t-elle à mon GitHub ?**
Par GitHub CLI, connecté une seule fois à l'[étape 6](#étape-6--préparer-tes-projets-sur-la-vm). Le jeton reste sur le disque de la VM.

**Comment travailler sur un dépôt précis dans son propre dossier ?**
Voir [Ajouter un projet](#ajouter-un-projet).

**Claude dit qu'aucun navigateur n'est disponible pour vérifier l'écran.**
Installe-lui le navigateur Playwright : voir [Navigateur pour Claude](#navigateur-pour-claude).

**Comment voir l'utilisation du CPU et de la RAM ?**
`ssh -t devbox btop` pour les courbes en direct. Les autres commandes sont dans [Surveiller le CPU et la RAM](#surveiller-le-cpu-et-la-ram-en-direct).

## Dépannage

| Symptôme | Que faire |
|---|---|
| Bloqué sur « Attente de la connexion SSH... » | Au bout de 2 min, le script affiche la dernière erreur et l'état de l'agent SSM. **Agent injoignable** : VM saturée ou figée, fais `-Action Stop` puis `-Action Start`. **Agent en ligne** + `publickey` : relance `-Action Join` sur ce PC. **Agent en ligne** sans autre erreur : le réseau (proxy, inspection SSL) bloque `ssmmessages.eu-west-1.amazonaws.com` ; teste en partage de connexion 4G |
| Claude Desktop n'arrive pas à se connecter | La VM est-elle allumée (`.\DevBox.ps1`) ? Claude Desktop a-t-il été relancé après l'installation ? Teste `ssh -v devbox exit` dans PowerShell |
| `aws` introuvable | Ferme et rouvre PowerShell, puis relance la commande |
| `Identifiants refusés` | Vérifie la clé : `aws sts get-caller-identity --profile devbox` |
| `InsufficientInstanceCapacity` à la création | Réessaie plus tard, ou choisis un autre type d'instance |
| Installation incomplète | Journal sur la VM : `ssh devbox "sudo tail -n 100 /var/log/devbox-init.log"` |
| La VM s'éteint trop tôt | Augmente le délai (`-Action Idle -IdleMinutes 30`) ou utilise `devbox-hold 2h` |
| La VM ne s'éteint jamais | `ssh devbox "ls /var/lib/devbox/claude; journalctl -t devbox"` |
| Bureau graphique injoignable | `ssh devbox "sudo dcv list-sessions"`, puis relance `-Action Dcv` |
| Caractères parasites (graphiques de `btop`) dans PowerShell | La VM s'est éteinte pendant que `btop` tournait, le terminal n'a pas été remis en état : tape `cls`, ou ferme l'onglet |
| `cd` : chemin introuvable | Le dépôt n'est pas au même endroit sur chaque PC : utilise le [raccourci `devbox`](#raccourci-devbox-recommandé) |

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
- Claude Code tourne **sur la VM** : Claude Desktop n'est que l'interface.

Ce que le script crée :

| Élément | Détail |
|---|---|
| Instance EC2 | `m8a.2xlarge` (8 cœurs AMD, 32 Go), Ubuntu 24.04, dans une zone où `c8a.4xlarge` et `m8a.4xlarge` existent aussi |
| Disque | gp3 chiffré, 100 Go, débit 250 Mo/s |
| Rôle IAM de la VM | SSM et licence DCV uniquement |
| Groupe de sécurité | aucune règle entrante |
| Logiciels | Docker et Compose, Git, GitHub CLI, Claude Code en ligne de commande, OpenCode 2 (au premier `-Action OpenCode`), navigateur Playwright pour Claude, htop et btop, bureau XFCE (clavier AZERTY), Amazon DCV, Firefox |
| Sur le PC | une clé SSH propre au PC, une entrée `devbox` dans `~/.ssh/config`, un fichier d'état dans `%USERPROFILE%\.devbox\` |
| Budget (option) | alerte e-mail à 80 % du budget mensuel (réel) et à 100 % (prévision) |

## Sécurité

- **Aucun port entrant** : SSH et le bureau graphique passent par SSM, qui exige tes identifiants AWS.
- **Contrôle du compte** : chaque action vérifie que les identifiants pointent sur le compte attendu.
- **IMDSv2 obligatoire**, disque chiffré, rôle IAM de la VM limité à SSM et à la licence DCV.
- **La clé d'accès AWS** est stockée en clair dans `%USERPROFILE%\.aws\credentials`. Pour la révoquer : console AWS > IAM > Utilisateurs > `devbox-cli` > Identifiants de sécurité.
- **Une clé SSH par PC.** Pour révoquer un PC :
  ```powershell
  ssh devbox "sed -i '/devbox-NOM-DU-PC$/d' ~/.ssh/authorized_keys"
  ```
- **Le jeton GitHub de la VM** donne à Claude les mêmes droits que toi : cloner, pousser et ouvrir des PR sur tous tes dépôts, y compris ceux de tes organisations. Pour le limiter à quelques dépôts, crée un jeton *fine-grained* restreint (GitHub > Settings > Developer settings) et connecte-le avec `gh auth login --with-token`.
- Ne mets pas d'identifiants de production sur la VM, surtout si Claude y travaille en mode Auto.
- Ne publie jamais de clé ni de fichier d'état : le `.gitignore` les bloque.

## Supprimer

```powershell
.\DevBox.ps1 -Action Remove
```

Supprime l'instance et son disque, le groupe de sécurité, le rôle IAM, le budget, l'entrée SSH et l'état local. **Pousse ton code sur Git avant** : le disque est détruit. La clé SSH du PC et l'utilisateur IAM `devbox-cli` sont conservés.

## Paramètres du script

| Paramètre | Défaut | Rôle |
|---|---|---|
| `-Action` | `Status` | `Create`, `Join`, `Start`, `Stop`, `Status`, `Cost`, `Dcv`, `OpenCode`, `Password`, `Resize`, `Idle`, `Remove` |
| `-Name` | `devbox` | nom de la VM, de l'hôte SSH et des ressources AWS |
| `-AwsProfile` | `devbox` | profil AWS CLI |
| `-AccountId` | | ID du compte AWS attendu (12 chiffres) |
| `-Region` | `eu-west-1` | région AWS |
| `-InstanceType` | `m8a.2xlarge` | type d'instance |
| `-FutureTypes` | `c8a.4xlarge`, `m8a.4xlarge` | types vers lesquels pouvoir basculer plus tard |
| `-DiskGb` | `100` | taille du disque en Go |
| `-DiskThroughput` | `250` | débit du disque en Mo/s |
| `-IdleMinutes` | `15` | délai d'arrêt après la fin du travail de Claude |
| `-BudgetUsd` | `150` | budget mensuel de l'alerte |
| `-BudgetEmail` | | e-mail de l'alerte budget |
| `-AzureSubscription` | | abonnement Azure lu par `-Action Cost` (mémorisé) |
| `-AzureResourceGroup` | | groupe de ressources Azure à isoler (mémorisé) |

## Licence

[MIT](LICENSE)
