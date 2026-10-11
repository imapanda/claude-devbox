<#
.SYNOPSIS
    Machine de developpement AWS pour Claude Code :
    Claude Desktop en SSH (via SSM, aucun port ouvert) + bureau graphique Amazon DCV.

.DESCRIPTION
    Actions :
      Create    Cree tout : connexion au bon compte, role IAM, groupe de securite sans port entrant,
                instance Ubuntu 24.04 (Docker, bureau XFCE, DCV, arret auto), cle SSH, ~/.ssh/config, budget.
      Join      Configure un autre PC pour une VM existante : cle SSH propre au PC, ~/.ssh/config.
      Start     Demarre la machine (et reconnecte le compte AWS si la session SSO a expire).
      Stop      Arrete la machine (seul le disque reste facture).
      Status    Affiche l'etat de la machine.
      Dcv       Demarre si besoin, ouvre le tunnel DCV et le bureau dans le navigateur.
      Password  Change le mot de passe du bureau DCV (utilisateur ubuntu).
      Resize    Change le type d'instance (ex. -InstanceType c8a.4xlarge).
      Idle      Change le delai d'arret automatique (ex. -IdleMinutes 60).
      Remove    Supprime la machine, son disque et les ressources creees.

    Arret automatique : la VM s'eteint quand Claude n'a plus rien fait depuis -IdleMinutes minutes
    (fin de reponse ou attente d'une validation). Elle reste allumee tant qu'une boucle /loop tourne,
    que le bureau DCV est ouvert, que le CPU travaille (build, tests) ou apres "devbox-hold 2h" sur la VM.

    Les parametres de la creation (profil, compte, region, ID d'instance) sont memorises dans
    %USERPROFILE%\.devbox\<Name>.json : les actions suivantes n'ont besoin d'aucun parametre.

.EXAMPLE
    .\DevBox.ps1 -Action Create -AwsProfile devbox -AccountId 123456789012 -BudgetEmail moi@exemple.com
.EXAMPLE
    .\DevBox.ps1 -Action Join -AwsProfile devbox -AccountId 123456789012
.EXAMPLE
    .\DevBox.ps1 -Action Dcv
.EXAMPLE
    .\DevBox.ps1 -Action Resize -InstanceType c8a.4xlarge

.NOTES
    Si Windows bloque le script : Unblock-File .\DevBox.ps1
    ou Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
#>
[CmdletBinding()]
param(
    [ValidateSet('Create', 'Join', 'Start', 'Stop', 'Status', 'Dcv', 'Password', 'Resize', 'Idle', 'Remove')]
    [string]$Action = 'Status',
    [string]$Name = 'devbox',
    [string]$AwsProfile = 'devbox',
    [ValidatePattern('^\d{12}$')]
    [string]$AccountId,
    [string]$Region = 'eu-west-1',
    [string]$InstanceType = 'm8a.2xlarge',
    [string[]]$FutureTypes = @('c8a.4xlarge', 'm8a.4xlarge'),
    [int]$DiskGb = 100,
    [int]$DiskThroughput = 250,
    [ValidateRange(1, 1440)]
    [int]$IdleMinutes = 15,
    [int]$BudgetUsd = 150,
    [string]$BudgetEmail
)

$ErrorActionPreference = 'Stop'
$Bound = $PSBoundParameters

# --------------------------------------------------------------------------------------------
# Constantes et etat memorise
# --------------------------------------------------------------------------------------------
$StateDir       = Join-Path $env:USERPROFILE '.devbox'
$StatePath      = Join-Path $StateDir "$Name.json"
$TmpDir         = Join-Path $env:TEMP "devbox-$PID"
$SshDir         = Join-Path $env:USERPROFILE '.ssh'
$KeyPath        = Join-Path $SshDir "${Name}_ed25519"
$SshConfigPath  = Join-Path $SshDir 'config'
$UbuntuAmiParam = '/aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id'
$RoleName       = "$Name-ec2-role"
$SgName         = "$Name-sg"
$BudgetName     = "$Name-ec2"
$DcvLocalPort   = 18443

New-Item -ItemType Directory -Force -Path $StateDir, $TmpDir, $SshDir | Out-Null

$State = $null
if (Test-Path $StatePath) { $State = Get-Content $StatePath -Raw | ConvertFrom-Json }

function Resolve-Setting([string]$Key, $Current) {
    if ($Bound.ContainsKey($Key)) { return $Current }
    if ($State -and ($State.PSObject.Properties.Name -contains $Key) -and $State.$Key) { return $State.$Key }
    return $Current
}
$AwsProfile = Resolve-Setting 'AwsProfile' $AwsProfile
$AccountId  = Resolve-Setting 'AccountId'  $AccountId
$Region     = Resolve-Setting 'Region'     $Region

# --------------------------------------------------------------------------------------------
# Script d'initialisation de la machine (cloud-init)
# --------------------------------------------------------------------------------------------
$UserDataTemplate = @'
#!/bin/bash
# DevBox - initialisation (cloud-init)
set -euxo pipefail
exec > >(tee -a /var/log/devbox-init.log) 2>&1
export DEBIAN_FRONTEND=noninteractive
export HOME=/root
export NEEDRESTART_MODE=a
APT="apt-get -y -o DPkg::Lock::Timeout=600 -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold"

hostnamectl set-hostname __NAME__ || true
timedatectl set-timezone Europe/Paris || true

# Cle SSH du poste Windows
install -d -m 700 -o ubuntu -g ubuntu /home/ubuntu/.ssh
echo '__PUBKEY__' >> /home/ubuntu/.ssh/authorized_keys
chown ubuntu:ubuntu /home/ubuntu/.ssh/authorized_keys
chmod 600 /home/ubuntu/.ssh/authorized_keys

# Systeme, outils de dev, Docker
$APT update
$APT upgrade
$APT install git gh curl wget unzip zip jq htop btop tmux build-essential ca-certificates gnupg psmisc \
  docker.io docker-compose-v2 docker-buildx
usermod -aG docker ubuntu
systemctl enable --now docker

# Bureau leger pour les sessions virtuelles DCV (pas de gestionnaire de connexion necessaire)
$APT install --no-install-recommends xfce4 xfce4-terminal xfce4-taskmanager thunar dbus-x11 xauth \
  x11-xserver-utils x11-xkb-utils xfonts-base fonts-dejavu-core mesa-utils
systemctl set-default multi-user.target

# Amazon DCV : serveur, client web, serveur X virtuel
cd /tmp
wget -q https://d1uj6qtbmh3dt5.cloudfront.net/NICE-GPG-KEY
gpg --import NICE-GPG-KEY || true
wget -q https://d1uj6qtbmh3dt5.cloudfront.net/nice-dcv-ubuntu2404-x86_64.tgz
tar -xzf nice-dcv-ubuntu2404-x86_64.tgz
cd nice-dcv-*-ubuntu2404-x86_64
$APT install ./nice-dcv-server_*.deb ./nice-dcv-web-viewer_*.deb ./nice-xdcv_*.deb
usermod -aG video dcv
cd /

cat > /usr/local/bin/devbox-xfce-init <<'EOF'
#!/bin/bash
setxkbmap fr || true
exec startxfce4
EOF
chmod 755 /usr/local/bin/devbox-xfce-init

cat > /usr/local/bin/devbox-dcv-session <<'EOF'
#!/bin/bash
# Cree la session DCV virtuelle "dev" si elle n'existe pas
if ! dcv list-sessions 2>/dev/null | grep -q "'dev'"; then
  dcv create-session --type virtual --owner ubuntu --user ubuntu --init /usr/local/bin/devbox-xfce-init dev
fi
EOF
chmod 755 /usr/local/bin/devbox-dcv-session

cat > /etc/systemd/system/devbox-dcv-session.service <<'EOF'
[Unit]
Description=Session DCV virtuelle devbox
After=dcvserver.service
Requires=dcvserver.service

[Service]
Type=oneshot
ExecStartPre=/bin/sleep 5
ExecStart=/usr/local/bin/devbox-dcv-session
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

# Arret automatique base sur l'activite de Claude Code
install -d -m 755 -o ubuntu -g ubuntu /var/lib/devbox /var/lib/devbox/claude

# 1. Hooks Claude Code : chaque session note son etat (occupee / terminee / boucle active)
cat > /usr/local/bin/devbox-claude-hook <<'EOF'
#!/bin/bash
# Appele par les hooks Claude Code. Usage : devbox-claude-hook busy|idle|waiting|tool|end
DIR=/var/lib/devbox/claude
input=$(cat)
sid=$(jq -r '.session_id // empty' <<< "$input" 2>/dev/null)
[ -n "$sid" ] || exit 0
f="$DIR/$sid"
loop=0
[ -f "$f" ] && loop=$(sed -n 's/^loop=//p' "$f")
case "$1" in
  end) rm -f "$f"; exit 0 ;;
  idle) state=idle ;;
  waiting) state=waiting ;;
  tool)
    state=busy
    case "$(jq -r '.tool_name // empty' <<< "$input")" in
      CronCreate) loop=1 ;;
      CronDelete) loop=0 ;;
      ScheduleWakeup)
        if [ "$(jq -r '.tool_input.stop // false' <<< "$input")" = "true" ]; then loop=0; else loop=1; fi ;;
    esac ;;
  *) state=busy ;;
esac
printf 'state=%s\nts=%s\nloop=%s\n' "$state" "$(date +%s)" "${loop:-0}" > "$f.tmp" && mv "$f.tmp" "$f"
exit 0
EOF
chmod 755 /usr/local/bin/devbox-claude-hook

install -d -m 700 -o ubuntu -g ubuntu /home/ubuntu/.claude
HOOKS_JSON='{
  "hooks": {
    "UserPromptSubmit": [{"hooks": [{"type": "command", "command": "/usr/local/bin/devbox-claude-hook busy", "timeout": 5}]}],
    "PreToolUse": [{"matcher": "*", "hooks": [{"type": "command", "command": "/usr/local/bin/devbox-claude-hook busy", "timeout": 5}]}],
    "PostToolUse": [{"matcher": "CronCreate|CronDelete|ScheduleWakeup", "hooks": [{"type": "command", "command": "/usr/local/bin/devbox-claude-hook tool", "timeout": 5}]}],
    "Notification": [{"matcher": "permission_prompt|idle_prompt", "hooks": [{"type": "command", "command": "/usr/local/bin/devbox-claude-hook waiting", "timeout": 5}]}],
    "Stop": [{"hooks": [{"type": "command", "command": "/usr/local/bin/devbox-claude-hook idle", "timeout": 5}]}],
    "SessionEnd": [{"hooks": [{"type": "command", "command": "/usr/local/bin/devbox-claude-hook end", "timeout": 5}]}]
  }
}'
SETTINGS=/home/ubuntu/.claude/settings.json
if [ -s "$SETTINGS" ]; then
  jq -s '.[0] * .[1]' "$SETTINGS" <(echo "$HOOKS_JSON") > "$SETTINGS.new" && mv "$SETTINGS.new" "$SETTINGS"
else
  echo "$HOOKS_JSON" > "$SETTINGS"
fi
chown ubuntu:ubuntu "$SETTINGS"

# 2. Suspendre l'arret automatique a la main (travail sans Claude)
cat > /usr/local/bin/devbox-hold <<'EOF'
#!/bin/bash
# Suspend l'arret automatique : devbox-hold 2h | devbox-hold 30m | devbox-hold off
HOLD=/var/lib/devbox/hold-until
case "$1" in
  off) rm -f "$HOLD"; echo "Arret automatique reactive"; exit 0 ;;
  *h) s=$(( ${1%h} * 3600 )) ;;
  *m) s=$(( ${1%m} * 60 )) ;;
  *) echo "Usage : devbox-hold 2h | 30m | off"; exit 1 ;;
esac
until=$(( $(date +%s) + s ))
echo "$until" > "$HOLD"
echo "Pas d'arret automatique avant $(date -d "@$until" +%H:%M)"
EOF
chmod 755 /usr/local/bin/devbox-hold

# 3. Arret manuel depuis la VM (terminal, ou Claude dans une session)
cat > /usr/local/bin/devbox-off <<'EOF'
#!/bin/bash
# Eteint la VM : devbox-off (tout de suite) | devbox-off 10 (dans 10 min) | devbox-off cancel
case "${1:-now}" in
  now) logger -t devbox "Arret manuel demande"; echo "Arret de la VM..."; sudo /sbin/shutdown -h now ;;
  cancel) sudo /sbin/shutdown -c && echo "Arret annule" ;;
  *[!0-9]*) echo "Usage : devbox-off | devbox-off 10 | devbox-off cancel"; exit 1 ;;
  *) sudo /sbin/shutdown -h "+$1" && echo "Arret prevu dans $1 min (devbox-off cancel pour annuler)" ;;
esac
EOF
chmod 755 /usr/local/bin/devbox-off

# 4. Verification chaque minute
cat > /usr/local/bin/devbox-idle-check <<'EOF'
#!/bin/bash
# Eteint la VM quand Claude a fini de travailler depuis LIMIT minutes,
# sauf boucle /loop active, bureau DCV ouvert, charge CPU ou devbox-hold.
LIMIT=__IDLE_MINUTES__
LOOP_GRACE=120     # une boucle garde la VM allumee si elle a tourne il y a moins de 120 min
BUSY_MAX=90        # une session "occupee" sans nouvelle depuis 90 min est consideree bloquee
DIR=/var/lib/devbox/claude
LAST=/var/lib/devbox/last-active
now=$(date +%s)
active() { echo "$now" > "$LAST"; exit 0; }

[ "$(cut -d. -f1 /proc/uptime)" -lt 900 ] && active
[ -f /var/lib/devbox/hold-until ] && [ "$(cat /var/lib/devbox/hold-until)" -gt "$now" ] && active

find "$DIR" -type f -mtime +8 -delete 2>/dev/null
last=$(cat "$LAST" 2>/dev/null || echo "$now")
for f in "$DIR"/*; do
  [ -f "$f" ] || continue
  case "$f" in *.tmp) continue ;; esac
  state=$(sed -n 's/^state=//p' "$f")
  ts=$(sed -n 's/^ts=//p' "$f"); ts=${ts:-0}
  loop=$(sed -n 's/^loop=//p' "$f")
  age=$(( (now - ts) / 60 ))
  [ "$state" = "busy" ] && [ "$age" -lt "$BUSY_MAX" ] && active
  [ "$loop" = "1" ] && [ "$age" -lt "$LOOP_GRACE" ] && active
  [ "$ts" -gt "$last" ] && last=$ts
done

ss -Htn state established '( sport = :8443 )' | grep -q . && active
awk '{ exit !($1 > 1.0) }' /proc/loadavg && active

echo "$last" > "$LAST"
idle=$(( (now - last) / 60 ))
if [ "$idle" -ge "$LIMIT" ]; then
  logger -t devbox "Claude inactif depuis ${idle} min : arret"
  /sbin/shutdown -h now
fi
EOF
chmod 755 /usr/local/bin/devbox-idle-check

cat > /etc/systemd/system/devbox-idle.service <<'EOF'
[Unit]
Description=Arret automatique devbox si inactive

[Service]
Type=oneshot
ExecStart=/usr/local/bin/devbox-idle-check
EOF

cat > /etc/systemd/system/devbox-idle.timer <<'EOF'
[Unit]
Description=Verification d'inactivite devbox chaque minute

[Timer]
OnBootSec=2min
OnUnitActiveSec=1min

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now dcvserver
systemctl enable devbox-dcv-session.service
systemctl start devbox-dcv-session.service || echo "Session DCV creee plus tard par DevBox.ps1 -Action Dcv"
systemctl enable --now devbox-idle.timer

# Navigateur dans le bureau (facultatif)
snap install firefox || true

mkdir -p /var/lib/devbox
touch /var/lib/devbox/ready
echo "DevBox prete"
'@

# --------------------------------------------------------------------------------------------
# Utilitaires
# --------------------------------------------------------------------------------------------
function Write-Step([string]$Message) { Write-Host "`n==> $Message" -ForegroundColor Cyan }
function Write-Ok([string]$Message)   { Write-Host "    $Message" -ForegroundColor Green }
function Write-Info([string]$Message) { Write-Host "    $Message" }

function Invoke-Aws {
    param(
        [Parameter(Mandatory)][string[]]$Arguments,
        [switch]$AllowFail,
        [switch]$Raw,
        [switch]$NoProfile,
        [switch]$NoRegion,
        [string]$RegionOverride
    )
    $all = @($Arguments)
    if (-not $NoProfile) { $all += @('--profile', $script:AwsProfile) }
    if (-not $NoRegion) {
        $r = $script:Region
        if ($RegionOverride) { $r = $RegionOverride }
        $all += @('--region', $r)
    }
    if ($all -notcontains '--output') { $all += @('--output', 'json') }

    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { $out = & aws @all 2>&1 } finally { $ErrorActionPreference = $prev }
    $code = $LASTEXITCODE

    $stdout = ($out | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] }) -join "`n"
    $stderr = ($out | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] } | ForEach-Object { $_.ToString() }) -join "`n"
    if ($code -ne 0) {
        if ($AllowFail) { return $null }
        throw "aws $($Arguments[0..1] -join ' ') a echoue : $stderr"
    }
    if ($Raw) { return $stdout.Trim() }
    if ([string]::IsNullOrWhiteSpace($stdout)) { return $null }
    $parsed = $stdout | ConvertFrom-Json
    return $parsed
}

function Write-TempJson([string]$FileName, $Object) {
    $path = Join-Path $TmpDir $FileName
    $json = ConvertTo-Json -InputObject $Object -Depth 10 -Compress
    [IO.File]::WriteAllText($path, $json, (New-Object System.Text.UTF8Encoding $false))
    return "file://$path"
}

function Save-State([hashtable]$Data) {
    $obj = [ordered]@{}
    if ($script:State) { $script:State.PSObject.Properties | ForEach-Object { $obj[$_.Name] = $_.Value } }
    foreach ($k in $Data.Keys) { $obj[$k] = $Data[$k] }
    $json = ConvertTo-Json -InputObject ([pscustomobject]$obj) -Depth 5
    [IO.File]::WriteAllText($StatePath, $json, (New-Object System.Text.UTF8Encoding $false))
    $script:State = [pscustomobject]$obj
}

# Lance une commande interactive directement dans la console (assistant AWS, saisie de mot de passe).
# L'operateur & ne convient pas : dans une fonction dont la sortie est capturee, PowerShell redirige
# la sortie du programme et l'AWS CLI refuse alors de demarrer ("No Windows console found").
function Invoke-Interactive([string]$FilePath, [string[]]$ArgumentList) {
    $p = Start-Process -FilePath $FilePath -ArgumentList $ArgumentList -NoNewWindow -PassThru
    $null = $p.Handle
    $p.WaitForExit()
    return $p.ExitCode
}

function Set-DcvPassword {
    $code = Invoke-Interactive 'ssh' @('-t', $Name, 'sudo passwd ubuntu')
    if ($code -ne 0) { Write-Warning "Mot de passe non change. Reessaie avec : .\DevBox.ps1 -Action Password" }
}

function Update-SessionPath {
    $extra = @("$env:ProgramFiles\Amazon\AWSCLIV2", "$env:ProgramFiles\Amazon\SessionManagerPlugin\bin")
    foreach ($p in $extra) {
        if ((Test-Path $p) -and ($env:Path -notlike "*$p*")) { $env:Path += ";$p" }
    }
}

# --------------------------------------------------------------------------------------------
# Prerequis et connexion au compte
# --------------------------------------------------------------------------------------------
function Assert-Prerequisites {
    Write-Step 'Verification des outils'
    Update-SessionPath

    if (-not (Get-Command aws -ErrorAction SilentlyContinue)) {
        Write-Info 'AWS CLI v2 absente, installation via winget...'
        winget install -e --id Amazon.AWSCLI --accept-source-agreements --accept-package-agreements
        Update-SessionPath
        if (-not (Get-Command aws -ErrorAction SilentlyContinue)) {
            throw 'AWS CLI introuvable. Installe-la (https://awscli.amazonaws.com/AWSCLIV2.msi) puis relance.'
        }
    }
    $version = Invoke-Aws -Arguments @('--version') -NoProfile -NoRegion -Raw
    if ($version -notmatch 'aws-cli/2') { throw "AWS CLI v2 requise (detectee : $version)." }

    if (-not (Get-Command session-manager-plugin -ErrorAction SilentlyContinue)) {
        Write-Info 'Plugin Session Manager absent, installation via winget...'
        winget install -e --id Amazon.SessionManagerPlugin --accept-source-agreements --accept-package-agreements
        Update-SessionPath
        if (-not (Get-Command session-manager-plugin -ErrorAction SilentlyContinue)) {
            throw 'Plugin Session Manager introuvable. Installe-le : https://s3.amazonaws.com/session-manager-downloads/plugin/latest/windows/SessionManagerPluginSetup.exe'
        }
    }

    if (-not (Get-Command ssh -ErrorAction SilentlyContinue) -or -not (Get-Command ssh-keygen -ErrorAction SilentlyContinue)) {
        throw 'Client OpenSSH absent. En administrateur : Add-WindowsCapability -Online -Name OpenSSH.Client~~~~0.0.1.0'
    }
    Write-Ok 'AWS CLI v2, plugin Session Manager et OpenSSH presents'
}

function Connect-AwsAccount([switch]$ConfirmAccount) {
    Write-Step "Connexion au compte AWS (profil '$AwsProfile')"

    $profiles = @((Invoke-Aws -Arguments @('configure', 'list-profiles') -NoProfile -NoRegion -Raw -AllowFail) -split "`r?`n")
    if ($profiles -notcontains $AwsProfile) {
        Write-Info "Le profil '$AwsProfile' n'existe pas encore."
        $choice = Read-Host "Type de connexion : [1] IAM Identity Center / SSO (recommande)  [2] Cles d'acces IAM"
        if ($choice -eq '2') { $code = Invoke-Interactive 'aws' @('configure', '--profile', $AwsProfile) }
        else {
            Write-Info "Choisis le compte et le role cibles quand l'assistant les propose."
            $code = Invoke-Interactive 'aws' @('configure', 'sso', '--profile', $AwsProfile)
        }
        if ($code -ne 0) { throw 'Configuration du profil annulee.' }
        Invoke-Aws -Arguments @('configure', 'set', 'region', $Region, '--profile', $AwsProfile) -NoProfile -NoRegion -Raw | Out-Null
    }

    $id = Invoke-Aws -Arguments @('sts', 'get-caller-identity') -AllowFail
    if (-not $id) {
        $ssoSession = Invoke-Aws -Arguments @('configure', 'get', 'sso_session', '--profile', $AwsProfile) -NoProfile -NoRegion -Raw -AllowFail
        $ssoUrl     = Invoke-Aws -Arguments @('configure', 'get', 'sso_start_url', '--profile', $AwsProfile) -NoProfile -NoRegion -Raw -AllowFail
        if (-not ($ssoSession -or $ssoUrl)) {
            throw "Identifiants refuses pour le profil '$AwsProfile'. Verifie-les : aws configure --profile $AwsProfile"
        }
        Write-Info 'Session SSO absente ou expiree : ouverture du navigateur pour te reconnecter...'
        $code = Invoke-Interactive 'aws' @('sso', 'login', '--profile', $AwsProfile)
        if ($code -ne 0) { throw 'Connexion SSO echouee.' }
        $id = Invoke-Aws -Arguments @('sts', 'get-caller-identity')
    }

    if ($AccountId -and $id.Account -ne $AccountId) {
        throw ("Mauvais compte AWS : le profil '$AwsProfile' pointe sur $($id.Account), attendu $AccountId. " +
               "Reconfigure le profil (aws configure sso --profile $AwsProfile) ou corrige -AccountId.")
    }

    $alias = Invoke-Aws -Arguments @('iam', 'list-account-aliases', '--query', 'AccountAliases[0]', '--output', 'text') -Raw -AllowFail
    $label = $id.Account
    if ($alias -and $alias -ne 'None') { $label = "$label ($alias)" }
    Write-Ok "Compte $label"
    Write-Ok "Identite $($id.Arn)"

    if ($ConfirmAccount -and -not $AccountId) {
        $answer = Read-Host "Creer la machine dans le compte $label ? (o/N)"
        if ($answer -notmatch '^(o|oui|y|yes)$') { throw 'Annule. Relance avec le bon profil (-AwsProfile) ou precise -AccountId.' }
    }
    return [string]$id.Account
}

# --------------------------------------------------------------------------------------------
# Briques de creation
# --------------------------------------------------------------------------------------------
function Get-InstanceState([string]$Id) {
    $s = Invoke-Aws -Arguments @('ec2', 'describe-instances', '--instance-ids', $Id,
        '--query', 'Reservations[0].Instances[0].State.Name', '--output', 'text') -Raw -AllowFail
    if (-not $s -or $s -eq 'None') { return $null }
    return $s
}

function Get-InstanceIdOrThrow {
    if (-not $State -or -not $State.InstanceId) {
        throw "Aucune machine '$Name' enregistree sur ce PC. Cree-la (-Action Create) ou rattache ce PC a une VM existante (-Action Join)."
    }
    return [string]$State.InstanceId
}

function Select-Subnet {
    Write-Step 'Reseau'
    $vpcId = Invoke-Aws -Arguments @('ec2', 'describe-vpcs', '--filters', 'Name=isDefault,Values=true',
        '--query', 'Vpcs[0].VpcId', '--output', 'text') -Raw
    if (-not $vpcId -or $vpcId -eq 'None') {
        Write-Info "Pas de VPC par defaut dans $Region, creation..."
        $vpcId = (Invoke-Aws -Arguments @('ec2', 'create-default-vpc')).Vpc.VpcId
    }

    $azs = @(Invoke-Aws -Arguments @('ec2', 'describe-instance-type-offerings', '--location-type', 'availability-zone',
        '--filters', "Name=instance-type,Values=$InstanceType", '--query', 'InstanceTypeOfferings[].Location'))
    if ($azs.Count -eq 0) { throw "$InstanceType n'est proposee dans aucune zone de $Region." }

    foreach ($t in $FutureTypes) {
        $tAzs = @(Invoke-Aws -Arguments @('ec2', 'describe-instance-type-offerings', '--location-type', 'availability-zone',
            '--filters', "Name=instance-type,Values=$t", '--query', 'InstanceTypeOfferings[].Location'))
        $common = @($azs | Where-Object { $tAzs -contains $_ })
        if ($common.Count -gt 0) { $azs = $common }
        else { Write-Warning "$t n'existe dans aucune zone compatible : passage vers $t impossible plus tard." }
    }

    $subnets = @(Invoke-Aws -Arguments @('ec2', 'describe-subnets',
        '--filters', "Name=vpc-id,Values=$vpcId", 'Name=default-for-az,Values=true',
        '--query', 'Subnets[].{Id:SubnetId,Az:AvailabilityZone}'))
    $subnet = $subnets | Where-Object { $azs -contains $_.Az } | Sort-Object Az | Select-Object -First 1
    if (-not $subnet) { throw "Aucun sous-reseau par defaut dans les zones compatibles ($($azs -join ', '))." }

    Write-Ok "VPC $vpcId, zone $($subnet.Az) (compatible $(@($InstanceType) + $FutureTypes -join ', '))"
    return [pscustomobject]@{ VpcId = $vpcId; SubnetId = $subnet.Id; Az = $subnet.Az }
}

function Initialize-Iam {
    Write-Step 'Role IAM de la machine (SSM + licence DCV)'
    $role = Invoke-Aws -Arguments @('iam', 'get-role', '--role-name', $RoleName) -AllowFail
    if (-not $role) {
        $trust = @{
            Version   = '2012-10-17'
            Statement = @(@{ Effect = 'Allow'; Principal = @{ Service = 'ec2.amazonaws.com' }; Action = 'sts:AssumeRole' })
        }
        Invoke-Aws -Arguments @('iam', 'create-role', '--role-name', $RoleName,
            '--assume-role-policy-document', (Write-TempJson 'trust.json' $trust),
            '--description', 'DevBox - SSM et licence DCV', '--tags', "Key=Project,Value=$Name") | Out-Null
        Invoke-Aws -Arguments @('iam', 'attach-role-policy', '--role-name', $RoleName,
            '--policy-arn', 'arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore') | Out-Null
        $dcv = @{
            Version   = '2012-10-17'
            Statement = @(@{ Effect = 'Allow'; Action = 's3:GetObject'; Resource = "arn:aws:s3:::dcv-license.$Region/*" })
        }
        Invoke-Aws -Arguments @('iam', 'put-role-policy', '--role-name', $RoleName,
            '--policy-name', 'dcv-license', '--policy-document', (Write-TempJson 'dcv.json' $dcv)) | Out-Null
        Write-Ok "Role $RoleName cree"
    }
    else { Write-Ok "Role $RoleName deja present" }

    $profileInfo = Invoke-Aws -Arguments @('iam', 'get-instance-profile', '--instance-profile-name', $RoleName) -AllowFail
    if (-not $profileInfo) {
        Invoke-Aws -Arguments @('iam', 'create-instance-profile', '--instance-profile-name', $RoleName) | Out-Null
        Invoke-Aws -Arguments @('iam', 'add-role-to-instance-profile', '--instance-profile-name', $RoleName, '--role-name', $RoleName) | Out-Null
        Write-Info 'Attente de la propagation IAM (15 s)...'
        Start-Sleep -Seconds 15
    }
}

function Initialize-SecurityGroup([string]$VpcId) {
    Write-Step 'Groupe de securite'
    $sg = Invoke-Aws -Arguments @('ec2', 'describe-security-groups',
        '--filters', "Name=vpc-id,Values=$VpcId", "Name=group-name,Values=$SgName",
        '--query', 'SecurityGroups[0].GroupId', '--output', 'text') -Raw
    if (-not $sg -or $sg -eq 'None') {
        $sg = Invoke-Aws -Arguments @('ec2', 'create-security-group', '--group-name', $SgName,
            '--description', 'DevBox - aucun port entrant, acces via SSM', '--vpc-id', $VpcId,
            '--query', 'GroupId', '--output', 'text') -Raw
        Invoke-Aws -Arguments @('ec2', 'create-tags', '--resources', $sg, '--tags', "Key=Project,Value=$Name") | Out-Null
    }
    Write-Ok "$sg : aucune regle entrante"
    return $sg
}

function Initialize-SshKey {
    if (-not (Test-Path $KeyPath)) {
        $v = $PSVersionTable.PSVersion
        $emptyPassphrase = '""'
        if ($v.Major -gt 7 -or ($v.Major -eq 7 -and $v.Minor -ge 3)) { $emptyPassphrase = '' }
        & ssh-keygen -t ed25519 -f $KeyPath -N $emptyPassphrase -C "$Name-$env:COMPUTERNAME" -q | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'Generation de la cle SSH echouee.' }
        Write-Ok "Cle SSH creee : $KeyPath"
    }
    return (Get-Content "$KeyPath.pub" -Raw).Trim()
}

function Set-SshConfig([string]$InstanceId) {
    $existing = ''
    if (Test-Path $SshConfigPath) { $existing = [IO.File]::ReadAllText($SshConfigPath) }
    $existing = [regex]::Replace($existing, "(?s)# >>> $([regex]::Escape($Name)) .*?# <<< $([regex]::Escape($Name))\r?\n?", '')

    $proxy = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe -NoProfile -Command ' +
             "`"aws ssm start-session --target %h --document-name AWS-StartSSHSession --parameters portNumber=%p --profile $AwsProfile --region $Region`""
    $block = @(
        "# >>> $Name (gere par DevBox.ps1)",
        "Host $Name",
        "    HostName $InstanceId",
        '    User ubuntu',
        "    IdentityFile ~/.ssh/${Name}_ed25519",
        '    IdentitiesOnly yes',
        '    StrictHostKeyChecking accept-new',
        '    ServerAliveInterval 30',
        "    ProxyCommand $proxy",
        "# <<< $Name",
        ''
    ) -join "`n"

    $content = $existing.TrimEnd() 
    if ($content) { $content += "`n`n" }
    $content += $block
    [IO.File]::WriteAllText($SshConfigPath, $content, (New-Object System.Text.UTF8Encoding $false))
    Write-Ok "Entree '$Name' ajoutee a $SshConfigPath"
}

function Remove-SshConfig {
    if (-not (Test-Path $SshConfigPath)) { return }
    $existing = [IO.File]::ReadAllText($SshConfigPath)
    $cleaned = [regex]::Replace($existing, "(?s)\n*# >>> $([regex]::Escape($Name)) .*?# <<< $([regex]::Escape($Name))\r?\n?", "`n")
    [IO.File]::WriteAllText($SshConfigPath, $cleaned.TrimStart(), (New-Object System.Text.UTF8Encoding $false))
}

function Wait-Ssm([string]$InstanceId, [int]$TimeoutSec = 600) {
    Write-Info "Attente de l'agent SSM..."
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        $ping = Invoke-Aws -Arguments @('ssm', 'describe-instance-information',
            '--filters', "Key=InstanceIds,Values=$InstanceId",
            '--query', 'InstanceInformationList[0].PingStatus', '--output', 'text') -Raw -AllowFail
        if ($ping -eq 'Online') { Write-Ok 'Agent SSM en ligne'; return }
        Start-Sleep -Seconds 10
    }
    throw "L'agent SSM ne repond pas apres $TimeoutSec s."
}

function Wait-Ssh([int]$TimeoutSec = 600) {
    Write-Info 'Attente de la connexion SSH...'
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        while ((Get-Date) -lt $deadline) {
            & ssh -o ConnectTimeout=20 -o BatchMode=yes $Name 'true' 2>$null
            if ($LASTEXITCODE -eq 0) { Write-Ok 'SSH operationnel'; return }
            Start-Sleep -Seconds 10
        }
    }
    finally { $ErrorActionPreference = $prev }
    throw "Connexion SSH impossible apres $TimeoutSec s. Diagnostic : ssh -v $Name"
}

function Initialize-Budget([string]$Account) {
    Write-Step 'Alerte budget'
    if (-not $BudgetEmail) {
        Write-Info "Pas d'e-mail fourni : alerte non creee (relance Create avec -BudgetEmail pour l'ajouter)."
        return
    }
    $existing = Invoke-Aws -Arguments @('budgets', 'describe-budget', '--account-id', $Account, '--budget-name', $BudgetName) -RegionOverride 'us-east-1' -AllowFail
    if ($existing) { Write-Ok "Budget $BudgetName deja present"; return }

    $budget = @{
        BudgetName  = $BudgetName
        BudgetLimit = @{ Amount = [string]$BudgetUsd; Unit = 'USD' }
        TimeUnit    = 'MONTHLY'
        BudgetType  = 'COST'
        CostFilters = @{ Service = @('Amazon Elastic Compute Cloud - Compute'); Region = @($Region) }
    }
    $subscribers = @(@{ SubscriptionType = 'EMAIL'; Address = $BudgetEmail })
    $notifications = @(
        @{ Notification = @{ NotificationType = 'ACTUAL'; ComparisonOperator = 'GREATER_THAN'; Threshold = 80; ThresholdType = 'PERCENTAGE' }; Subscribers = $subscribers },
        @{ Notification = @{ NotificationType = 'FORECASTED'; ComparisonOperator = 'GREATER_THAN'; Threshold = 100; ThresholdType = 'PERCENTAGE' }; Subscribers = $subscribers }
    )
    try {
        Invoke-Aws -Arguments @('budgets', 'create-budget', '--account-id', $Account,
            '--budget', (Write-TempJson 'budget.json' $budget),
            '--notifications-with-subscribers', (Write-TempJson 'notifications.json' $notifications)) -RegionOverride 'us-east-1' | Out-Null
        Write-Ok "E-mail a $BudgetEmail a 80 % de $BudgetUsd USD/mois (reel) et a 100 % (prevision)"
    }
    catch { Write-Warning "Budget non cree : $($_.Exception.Message)" }
}

# --------------------------------------------------------------------------------------------
# Actions
# --------------------------------------------------------------------------------------------
function New-DevBox {
    $account = Connect-AwsAccount -ConfirmAccount

    if ($State -and $State.InstanceId) {
        $s = Get-InstanceState $State.InstanceId
        if ($s -and $s -ne 'terminated') {
            throw "La machine $($State.InstanceId) existe deja (etat : $s). Utilise -Action Start, ou -Action Remove pour repartir de zero."
        }
    }
    $others = Invoke-Aws -Arguments @('ec2', 'describe-instances',
        '--filters', "Name=tag:Name,Values=$Name", 'Name=instance-state-name,Values=pending,running,stopping,stopped',
        '--query', 'Reservations[].Instances[].InstanceId', '--output', 'text') -Raw
    if ($others) { throw "Une instance nommee '$Name' existe deja ($others). Supprime-la ou choisis un autre -Name." }

    $net  = Select-Subnet
    Initialize-Iam
    $sgId = Initialize-SecurityGroup $net.VpcId

    Write-Step 'Cle SSH et script d''initialisation'
    $pubKey = Initialize-SshKey
    $userData = $UserDataTemplate.Replace('__PUBKEY__', $pubKey).Replace('__IDLE_MINUTES__', [string]$IdleMinutes).Replace('__NAME__', $Name)
    $userData = $userData -replace "`r`n", "`n"
    $userDataPath = Join-Path $TmpDir 'user-data.sh'
    [IO.File]::WriteAllText($userDataPath, $userData, (New-Object System.Text.UTF8Encoding $false))
    if ((Get-Item $userDataPath).Length -gt 16000) { throw 'Script d''initialisation trop volumineux (> 16 Ko).' }
    Write-Ok 'Pret'

    Write-Step "Creation de l'instance $InstanceType"
    $bdm = @(@{
        DeviceName = '/dev/sda1'
        Ebs = @{ VolumeSize = $DiskGb; VolumeType = 'gp3'; Iops = 3000; Throughput = $DiskThroughput; Encrypted = $true; DeleteOnTermination = $true }
    })
    $tagList = @(@{ Key = 'Name'; Value = $Name }, @{ Key = 'Project'; Value = $Name })
    $tags = @(@{ ResourceType = 'instance'; Tags = $tagList }, @{ ResourceType = 'volume'; Tags = $tagList })
    $runArgs = @('ec2', 'run-instances',
        '--image-id', "resolve:ssm:$UbuntuAmiParam",
        '--instance-type', $InstanceType,
        '--subnet-id', $net.SubnetId,
        '--security-group-ids', $sgId,
        '--iam-instance-profile', "Name=$RoleName",
        '--block-device-mappings', (Write-TempJson 'bdm.json' $bdm),
        '--tag-specifications', (Write-TempJson 'tags.json' $tags),
        '--metadata-options', 'HttpTokens=required,HttpEndpoint=enabled',
        '--instance-initiated-shutdown-behavior', 'stop',
        '--user-data', "file://$userDataPath",
        '--count', '1')

    $instance = $null
    for ($i = 1; $i -le 6 -and -not $instance; $i++) {
        try { $instance = Invoke-Aws -Arguments $runArgs }
        catch {
            if ($_.Exception.Message -match 'IAM Instance Profile|iamInstanceProfile' -and $i -lt 6) {
                Write-Info 'Profil IAM pas encore propage, nouvel essai dans 10 s...'
                Start-Sleep -Seconds 10
            }
            else { throw }
        }
    }
    $instanceId = [string]$instance.Instances[0].InstanceId
    Save-State @{ AwsProfile = $AwsProfile; AccountId = $account; Region = $Region; InstanceId = $instanceId
                  InstanceType = $InstanceType; Az = $net.Az; SecurityGroupId = $sgId; CreatedAt = (Get-Date).ToString('s') }
    Write-Ok "Instance $instanceId lancee en $($net.Az)"

    Invoke-Aws -Arguments @('ec2', 'wait', 'instance-running', '--instance-ids', $instanceId) -Raw | Out-Null
    Write-Ok 'Instance demarree'
    Wait-Ssm $instanceId

    Write-Step 'Configuration SSH du poste'
    Set-SshConfig $instanceId
    Wait-Ssh

    Write-Step 'Installation du logiciel sur la machine (10 a 15 min)'
    & ssh $Name 'cloud-init status --wait > /dev/null; cloud-init status --long; test -f /var/lib/devbox/ready'
    if ($LASTEXITCODE -ne 0) {
        Write-Warning 'Initialisation incomplete. Dernieres lignes du journal :'
        & ssh $Name 'sudo tail -n 40 /var/log/devbox-init.log'
        throw "Corrige puis consulte /var/log/devbox-init.log sur la machine (ssh $Name)."
    }
    Write-Ok 'Logiciels installes'

    & ssh $Name 'test -f /var/run/reboot-required'
    if ($LASTEXITCODE -eq 0) {
        Write-Info 'Redemarrage pour appliquer les mises a jour du noyau...'
        Invoke-Aws -Arguments @('ec2', 'reboot-instances', '--instance-ids', $instanceId) | Out-Null
        Start-Sleep -Seconds 45
        Wait-Ssh
    }

    Write-Step 'Mot de passe du bureau DCV (utilisateur ubuntu)'
    Write-Info 'Choisis un mot de passe solide : il protege le bureau graphique.'
    Set-DcvPassword

    Initialize-Budget $account

    Write-Host "`nMachine prete." -ForegroundColor Green
    Write-Host @"
  Claude Desktop : onglet Code > Environnement > + Add SSH connection
                   Name : $Name   SSH Host : $Name   (laisse le port et la cle vides)
  VS Code        : Remote-SSH > $Name
  Bureau DCV     : .\DevBox.ps1 -Action Dcv
  Arret          : .\DevBox.ps1 -Action Stop   (automatique $IdleMinutes min apres la fin du travail de Claude)
  Delai d'arret  : .\DevBox.ps1 -Action Idle -IdleMinutes 60
  Demarrage      : .\DevBox.ps1 -Action Start
  Plus puissant  : .\DevBox.ps1 -Action Resize -InstanceType c8a.4xlarge
"@
}

function Start-DevBox([switch]$Quiet, [switch]$NoSsh) {
    $id = Get-InstanceIdOrThrow
    $s = Get-InstanceState $id
    switch ($s) {
        'running' { if (-not $Quiet) { Write-Ok 'Machine deja demarree' } }
        'pending' { Write-Info 'Demarrage en cours...' }
        'stopping' {
            Write-Info 'Arret en cours, attente avant redemarrage...'
            Invoke-Aws -Arguments @('ec2', 'wait', 'instance-stopped', '--instance-ids', $id) -Raw | Out-Null
            Invoke-Aws -Arguments @('ec2', 'start-instances', '--instance-ids', $id) | Out-Null
        }
        'stopped' {
            Write-Step 'Demarrage de la machine'
            Invoke-Aws -Arguments @('ec2', 'start-instances', '--instance-ids', $id) | Out-Null
        }
        default { throw "Etat inattendu de $id : $s" }
    }
    Invoke-Aws -Arguments @('ec2', 'wait', 'instance-running', '--instance-ids', $id) -Raw | Out-Null
    if ($NoSsh) { return }
    Wait-Ssh
    if (-not $Quiet) { Write-Ok "Connecte-toi depuis Claude Desktop (hote SSH : $Name)" }
}

function Find-DevBoxInstance {
    $list = @(Invoke-Aws -Arguments @('ec2', 'describe-instances',
        '--filters', "Name=tag:Name,Values=$Name", 'Name=instance-state-name,Values=pending,running,stopping,stopped',
        '--query', 'Reservations[].Instances[].{Id:InstanceId,Type:InstanceType,Az:Placement.AvailabilityZone,Sg:SecurityGroups[0].GroupId,State:State.Name}'))
    if ($list.Count -eq 0) { throw "Aucune VM '$Name' dans ce compte ($Region). Cree-la avec -Action Create, ou verifie -Name et -Region." }
    if ($list.Count -gt 1) { throw "Plusieurs VM nommees '$Name' : $(@($list | ForEach-Object { $_.Id }) -join ', ')." }
    return $list[0]
}

function Add-AuthorizedKey([string]$InstanceId, [string]$PubKey) {
    $file = '/home/ubuntu/.ssh/authorized_keys'
    $params = @{ commands = @("grep -qxF '$PubKey' $file || echo '$PubKey' >> $file") }
    $commandId = Invoke-Aws -Arguments @('ssm', 'send-command', '--instance-ids', $InstanceId,
        '--document-name', 'AWS-RunShellScript', '--comment', "DevBox Join $env:COMPUTERNAME",
        '--parameters', (Write-TempJson 'join.json' $params),
        '--query', 'Command.CommandId', '--output', 'text') -Raw
    Invoke-Aws -Arguments @('ssm', 'wait', 'command-executed', '--command-id', $commandId, '--instance-id', $InstanceId) -Raw -AllowFail | Out-Null
    $status = Invoke-Aws -Arguments @('ssm', 'get-command-invocation', '--command-id', $commandId, '--instance-id', $InstanceId,
        '--query', 'Status', '--output', 'text') -Raw
    if ($status -ne 'Success') { throw "Ajout de la cle sur la VM en echec (statut : $status)." }
}

function Join-DevBox {
    $account = Connect-AwsAccount -ConfirmAccount

    Write-Step "Recherche de la VM '$Name'"
    $vm = Find-DevBoxInstance
    Write-Ok "$($vm.Id) : $($vm.Type) en $($vm.Az), etat $($vm.State)"
    Save-State @{ AwsProfile = $AwsProfile; AccountId = $account; Region = $Region; InstanceId = [string]$vm.Id
                  InstanceType = [string]$vm.Type; Az = [string]$vm.Az; SecurityGroupId = [string]$vm.Sg; JoinedAt = (Get-Date).ToString('s') }

    Start-DevBox -Quiet -NoSsh
    Wait-Ssm $vm.Id

    Write-Step "Cle SSH de ce PC ($env:COMPUTERNAME)"
    $pubKey = Initialize-SshKey
    Add-AuthorizedKey $vm.Id $pubKey
    Write-Ok 'Cle ajoutee sur la VM'

    Write-Step 'Configuration SSH du poste'
    Set-SshConfig $vm.Id
    Wait-Ssh

    Write-Host "`nCe PC est pret." -ForegroundColor Green
    Write-Host @"
  Claude Desktop : onglet Code > Environnement > + Add SSH connection
                   Name : $Name   SSH Host : $Name   (laisse le port et la cle vides)
  Usage          : .\DevBox.ps1 -Action Start | Stop | Status | Dcv
"@
}

function Stop-DevBox {
    $id = Get-InstanceIdOrThrow
    $s = Get-InstanceState $id
    if ($s -eq 'stopped') { Write-Ok 'Machine deja arretee'; return }
    Write-Step 'Arret de la machine'
    Invoke-Aws -Arguments @('ec2', 'stop-instances', '--instance-ids', $id) | Out-Null
    Invoke-Aws -Arguments @('ec2', 'wait', 'instance-stopped', '--instance-ids', $id) -Raw | Out-Null
    $final = Get-InstanceState $id
    if ($final -ne 'stopped') { throw "La VM n'est pas arretee (etat AWS : $final). Relance -Action Stop ou verifie dans la console AWS." }
    Write-Ok "Etat confirme par AWS : $final. Seul le disque reste facture."
}

function Show-Status {
    $id = Get-InstanceIdOrThrow
    $info = Invoke-Aws -Arguments @('ec2', 'describe-instances', '--instance-ids', $id,
        '--query', 'Reservations[0].Instances[0].{State:State.Name,Type:InstanceType,Az:Placement.AvailabilityZone,Launch:LaunchTime}') -AllowFail
    Write-Step "Machine $Name"
    if (-not $info) { Write-Info "Instance $id introuvable (supprimee ?)."; return }
    Write-Info "Instance : $id"
    Write-Info "Etat     : $($info.State)"
    Write-Info "Type     : $($info.Type) ($($info.Az))"
    Write-Info "Compte   : $AccountId / profil $AwsProfile"
    if ($info.State -eq 'running') { Write-Info "Demarree : $($info.Launch)" }
}

function Open-Dcv {
    Start-DevBox -Quiet
    $id = Get-InstanceIdOrThrow
    Write-Step 'Bureau graphique DCV'
    & ssh $Name 'sudo /usr/local/bin/devbox-dcv-session'
    if ($LASTEXITCODE -ne 0) { Write-Warning 'Creation de la session DCV en echec : verifie avec ssh devbox "sudo dcv list-sessions".' }

    $tunnel = "Write-Host 'Tunnel DCV actif sur localhost:$DcvLocalPort. Ferme cette fenetre pour le couper.'; " +
              "aws ssm start-session --target $id --document-name AWS-StartPortForwardingSession " +
              "--parameters 'portNumber=8443,localPortNumber=$DcvLocalPort' --profile $AwsProfile --region $Region"
    Start-Process -FilePath 'powershell.exe' -ArgumentList "-NoExit -NoProfile -Command `"$tunnel`""
    Start-Sleep -Seconds 8
    Start-Process "https://localhost:$DcvLocalPort/#dev"
    Write-Ok 'Bureau ouvert dans le navigateur (certificat auto-signe : accepte l''avertissement)'
    Write-Info 'Identifiant : ubuntu. Mot de passe oublie : .\DevBox.ps1 -Action Password'
    Write-Info "Client DCV natif (facultatif, plus fluide) : connexion a localhost:$DcvLocalPort"
}

function Set-DevBoxType {
    if (-not $Bound.ContainsKey('InstanceType')) { throw 'Precise le nouveau type, par exemple : -InstanceType c8a.4xlarge' }
    $id = Get-InstanceIdOrThrow
    Write-Step "Passage en $InstanceType"
    Stop-DevBox
    Invoke-Aws -Arguments @('ec2', 'modify-instance-attribute', '--instance-id', $id, '--instance-type', "Value=$InstanceType") | Out-Null
    Save-State @{ InstanceType = $InstanceType }
    Write-Ok "Type change en $InstanceType"
    Start-DevBox
}

function Set-IdleDelay {
    if (-not $Bound.ContainsKey('IdleMinutes')) { throw 'Precise le delai, par exemple : -IdleMinutes 60' }
    Start-DevBox -Quiet
    Write-Step "Delai d'arret automatique : $IdleMinutes min"
    & ssh $Name "sudo sed -i 's/^LIMIT=.*/LIMIT=$IdleMinutes/' /usr/local/bin/devbox-idle-check"
    if ($LASTEXITCODE -ne 0) { throw 'Modification impossible.' }
    Save-State @{ IdleMinutes = $IdleMinutes }
    Write-Ok "La VM s'eteindra $IdleMinutes min apres la fin du travail de Claude"
}

function Remove-DevBox {
    $id = Get-InstanceIdOrThrow
    Write-Warning "Suppression definitive de $id et de son disque. Le code non pousse sur Git sera perdu."
    $confirm = Read-Host 'Tape SUPPRIMER pour confirmer'
    if ($confirm -ne 'SUPPRIMER') { Write-Info 'Annule.'; return }

    Write-Step 'Suppression de la machine'
    Invoke-Aws -Arguments @('ec2', 'terminate-instances', '--instance-ids', $id) -AllowFail | Out-Null
    Invoke-Aws -Arguments @('ec2', 'wait', 'instance-terminated', '--instance-ids', $id) -Raw -AllowFail | Out-Null
    Write-Ok "Instance $id supprimee"

    if ($State.SecurityGroupId) {
        for ($i = 0; $i -lt 6; $i++) {
            Invoke-Aws -Arguments @('ec2', 'delete-security-group', '--group-id', $State.SecurityGroupId) -Raw -AllowFail | Out-Null
            $still = Invoke-Aws -Arguments @('ec2', 'describe-security-groups', '--group-ids', $State.SecurityGroupId) -AllowFail
            if (-not $still) { break }
            Start-Sleep -Seconds 10
        }
        Write-Ok 'Groupe de securite supprime'
    }

    Invoke-Aws -Arguments @('iam', 'remove-role-from-instance-profile', '--instance-profile-name', $RoleName, '--role-name', $RoleName) -AllowFail | Out-Null
    Invoke-Aws -Arguments @('iam', 'delete-instance-profile', '--instance-profile-name', $RoleName) -AllowFail | Out-Null
    Invoke-Aws -Arguments @('iam', 'detach-role-policy', '--role-name', $RoleName, '--policy-arn', 'arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore') -AllowFail | Out-Null
    Invoke-Aws -Arguments @('iam', 'delete-role-policy', '--role-name', $RoleName, '--policy-name', 'dcv-license') -AllowFail | Out-Null
    Invoke-Aws -Arguments @('iam', 'delete-role', '--role-name', $RoleName) -AllowFail | Out-Null
    Write-Ok 'Role IAM supprime'

    Invoke-Aws -Arguments @('budgets', 'delete-budget', '--account-id', $AccountId, '--budget-name', $BudgetName) -RegionOverride 'us-east-1' -AllowFail | Out-Null
    Remove-SshConfig
    Remove-Item $StatePath -Force -ErrorAction SilentlyContinue
    Write-Ok 'Budget, entree SSH et etat local supprimes (la cle SSH est conservee)'
}

# --------------------------------------------------------------------------------------------
# Point d'entree
# --------------------------------------------------------------------------------------------
try {
    if ($Action -eq 'Status' -and -not $State) {
        Write-Host "Aucune machine '$Name' enregistree sur ce PC."
        Write-Host '  Nouvelle VM        : .\DevBox.ps1 -Action Create -AwsProfile <profil> -AccountId <12 chiffres> -BudgetEmail <e-mail>'
        Write-Host '  VM deja existante  : .\DevBox.ps1 -Action Join -AwsProfile <profil> -AccountId <12 chiffres>'
        return
    }
    Assert-Prerequisites
    if ($Action -notin @('Create', 'Join')) { Connect-AwsAccount | Out-Null }
    switch ($Action) {
        'Create'   { New-DevBox }
        'Join'     { Join-DevBox }
        'Start'    { Start-DevBox }
        'Stop'     { Stop-DevBox }
        'Status'   { Show-Status }
        'Dcv'      { Open-Dcv }
        'Password' { Start-DevBox -Quiet; Set-DcvPassword }
        'Resize'   { Set-DevBoxType }
        'Idle'     { Set-IdleDelay }
        'Remove'   { Remove-DevBox }
    }
}
catch {
    Write-Host "`nERREUR : $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
finally {
    Remove-Item $TmpDir -Recurse -Force -ErrorAction SilentlyContinue
}
