# ================================================================
# config.example.ps1 - Configuration de MASTER AD
# ================================================================
# UTILISATION :
#   1. Copiez ce fichier en "config.ps1" dans le meme dossier que MasterAD.ps1
#   2. Adaptez les valeurs a votre environnement
#   3. Le script chargera automatiquement config.ps1 au demarrage
#
# NOTE : config.ps1 est ignore par Git (.gitignore) afin de ne jamais
#        publier la configuration reelle de votre infrastructure.
# ================================================================

# --- Domaine Active Directory ---
$Domain   = "EXAMPLE"                                   # Nom NetBIOS du domaine
$BaseDN   = "DC=example,DC=local"                       # DN racine
$RootLDAP = "LDAP://$BaseDN"
$OUBase   = "OU=Utilisateurs,OU=EXAMPLE,$BaseDN"        # OU racine des utilisateurs
$OUEmployes = "OU=Employes,$OUBase"                     # OU des employes

# --- Serveur de fichiers ---
# $FS     : nom court (affichage / logs uniquement)
# $FSHost : FQDN, utilise pour toutes les connexions authentifiees.
#           Le FQDN evite l'erreur systeme 1219 (deux connexions au meme
#           serveur avec des comptes differents).
$FS     = "\\SRV-FICHIERS"
$FSHost = "SRV-FICHIERS.example.local"
$FSAuth = "\\$FSHost"

# --- Chemins partages ---
$LogoPath       = "$FSAuth\partage\scripts\AD\Logo\logo.png"
$ExclusionsPath = "$FSAuth\partage\scripts\AD\exclusions_dossiers.txt"

# --- Groupes ajoutes automatiquement a la creation d'un utilisateur ---
$GroupArray = @(
    "All.Utilisateurs",
    "GRP-PROXY-STANDARD",
    "GRP-PSO-PWD-Employes",
    "GRP-Impression",
    "GRP-Outils",
    "GRP-Maintenance",
    "GRP-VPN-BASIQUE",
    "GRP-Signature"
)

# --- Groupes conserves lors d'une procedure de sortie ---
$KeepGroups = @("Utilisateurs du domaine","Domain Users")

# --- Suffixe UPN / domaine de messagerie ---
# (a adapter directement dans la fonction New-UserLDAP si necessaire)
# Exemple : $login@example.org
