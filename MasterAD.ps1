<#
.SYNOPSIS
MASTER AD - Outil unique regroupant les scripts AD "NoAD" dans une seule fenetre a onglets.

.DESCRIPTION
Regroupe en un seul script avec popup (WPF TabControl) :
    * Onglet "Creation"     : creation d'un utilisateur AD (login intelligent, groupes, dossier + NTFS)
    * Onglet "Modification" : edition d'un utilisateur AD existant
    * Onglet "Dossiers"     : scan AD + creation en masse des dossiers utilisateurs
    * Onglet "Verif PC"     : verification de la presence d'un poste dans l'AD

Version "NoAD" : fonctionne depuis n'importe quel PC du domaine, SANS module RSAT.
Une seule connexion (compte administrateur AD) est demandee au lancement et partagee
par tous les onglets. Acces AD en LDAP pur (System.DirectoryServices), acces serveur
de fichiers via PSDrive montes avec ces memes identifiants.

.AUTHOR
Nathan Drancourt

.VERSION
3.0 (MASTER AD - fusion multi-onglets)
#>

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

# ================================================================
# CONFIG PARTAGEE
# ================================================================
$Domain    = "EXAMPLE"
$BaseDN    = "DC=example,DC=local"
$RootLDAP  = "LDAP://$BaseDN"
$OUBase    = "OU=Utilisateurs,OU=EXAMPLE,$BaseDN"

# Serveur de fichiers :
#   $FS      = nom court, utilise uniquement pour l'affichage / les logs
#   $FSHost  = FQDN, utilise pour TOUTES les connexions authentifiees (compte admin).
#   Pourquoi le FQDN ? Windows interdit deux connexions au MEME serveur avec deux
#   comptes differents (erreur systeme 1219). Si la session a deja un lecteur monte
#   vers \\SRV-FICHIERS, on passe par \\SRV-FICHIERS.example.local : Windows les voit comme deux
#   serveurs distincts, donc pas de conflit.
$FS        = "\\SRV-FICHIERS"
$FSHost    = "SRV-FICHIERS.example.local"
$FSAuth    = "\\$FSHost"
$LogoPath  = "$FSAuth\partage\scripts\AD\Logo\logo.png"

# Fichier partage des exclusions "dossier non requis" (un login par ligne)
$ExclusionsPath = "$FSAuth\partage\scripts\AD\exclusions_dossiers.txt"

# OU des employes (services + scan dossiers)
$OUEmployes = "OU=Employes,$OUBase"

$GroupArray = @(
    "All.Utilisateurs","GRP-PROXY-STANDARD","GRP-PSO-PWD-Employes",
    "GRP-Impression","GRP-Outils",
    "GRP-Maintenance","GRP-VPN-BASIQUE","GRP-Signature"
)

# ----------------------------------------------------------------
# Generation de mots de passe aleatoires
# ----------------------------------------------------------------
# Aucun mot de passe n'est ecrit en dur dans ce script : chaque mot de
# passe (creation de compte, reinitialisation, sortie) est genere
# aleatoirement puis affiche a l'administrateur dans le journal.
function New-RandomPassword {
    param([int]$Length = 14)

    $maj    = "ABCDEFGHJKLMNPQRSTUVWXYZ"
    $min    = "abcdefghijkmnopqrstuvwxyz"
    $chiffr = "23456789"
    $spec   = "!@#$%*-_?"
    $all    = $maj + $min + $chiffr + $spec

    # Au moins un caractere de chaque categorie (complexite AD)
    $chars = @(
        $maj[(Get-Random -Maximum $maj.Length)],
        $min[(Get-Random -Maximum $min.Length)],
        $chiffr[(Get-Random -Maximum $chiffr.Length)],
        $spec[(Get-Random -Maximum $spec.Length)]
    )
    for ($i = $chars.Count; $i -lt $Length; $i++) {
        $chars += $all[(Get-Random -Maximum $all.Length)]
    }

    return -join ($chars | Sort-Object { Get-Random })
}

# Mot de passe temporaire (sortie / mot de passe oublie)
# Genere aleatoirement a chaque lancement du script.
$TempPassword = New-RandomPassword

# Groupe primaire a conserver lors d'une sortie
$KeepGroups = @("Utilisateurs du domaine","Domain Users")

# ----------------------------------------------------------------
# Configuration externe (optionnelle)
# ----------------------------------------------------------------
# Si un fichier "config.ps1" existe a cote du script, il est charge et
# surcharge les valeurs par defaut ci-dessus. Cela evite de modifier le
# script a chaque deploiement (voir config.example.ps1).
$ConfigFile = Join-Path $PSScriptRoot "config.ps1"
if (Test-Path $ConfigFile) {
    . $ConfigFile
}

$UIReady = $false

# ================================================================
# CONNEXION COMPTE ADMIN (une seule fois, partagee)
# ================================================================
$Credential = $null

try {
    $Credential = Get-Credential -Message "Connexion compte administrateur AD (MASTER AD)"
}
catch {
    [System.Windows.MessageBox]::Show("Erreur lors de la demande d'identifiants") | Out-Null
    exit
}

if (-not $Credential) {
    [System.Windows.MessageBox]::Show("Authentification annulee","Erreur") | Out-Null
    exit
}

# Validation des identifiants (bind LDAP test)
try {
    $testRoot = New-Object DirectoryServices.DirectoryEntry(
        $RootLDAP,
        $Credential.UserName,
        $Credential.GetNetworkCredential().Password
    )
    $null = $testRoot.NativeObject
}
catch {
    [System.Windows.MessageBox]::Show(
        "Connexion LDAP impossible avec ce compte.`n`nErreur : $_",
        "Authentification echouee","OK","Error") | Out-Null
    exit
}

# ================================================================
# MONTAGE PARTAGES ADMIN (pour l'onglet Dossiers)
# ================================================================
$FSDrives = @{
    "FSE" = "$FSAuth\E$"
    "FSF" = "$FSAuth\F$"
    "FSG" = "$FSAuth\G$"
    "FSH" = "$FSAuth\H$"
    "FSI" = "$FSAuth\I$"
}

$MountErrors = @()

foreach ($d in $FSDrives.GetEnumerator()) {

    if (Get-PSDrive -Name $d.Key -ErrorAction SilentlyContinue) {
        Remove-PSDrive -Name $d.Key -Force -ErrorAction SilentlyContinue
    }

    try {
        $null = New-PSDrive -Name $d.Key `
            -PSProvider FileSystem `
            -Root $d.Value `
            -Credential $Credential `
            -Scope Global `
            -ErrorAction Stop
    }
    catch {
        $MountErrors += $d.Value
    }
}

if ($MountErrors.Count -gt 0) {
    [System.Windows.MessageBox]::Show(
        "Impossible de monter certains partages avec ce compte :`n`n" +
        ($MountErrors -join "`n") +
        "`n`nLe scan et la creation de dossiers echoueront pour ces lettres.",
        "Acces serveur de fichiers limite","OK","Warning") | Out-Null
}

# ================================================================
# FONCTIONS LDAP PARTAGEES
# ================================================================
function Get-LDAPRoot {
    param([string]$Path = $RootLDAP)

    return New-Object DirectoryServices.DirectoryEntry(
        $Path,
        $Credential.UserName,
        $Credential.GetNetworkCredential().Password
    )
}

function Find-UserBySam {
    param($sam)

    $searcher = New-Object DirectoryServices.DirectorySearcher((Get-LDAPRoot))
    $searcher.Filter = "(&(objectClass=user)(objectCategory=person)(sAMAccountName=$sam))"
    $null = $searcher.PropertiesToLoad.Add("givenname")
    $null = $searcher.PropertiesToLoad.Add("sn")

    $r = $searcher.FindOne()
    if (-not $r) { return $null }

    return [pscustomobject]@{
        GivenName = $(if ($r.Properties["givenname"].Count) { $r.Properties["givenname"][0] } else { "" })
        Surname   = $(if ($r.Properties["sn"].Count)        { $r.Properties["sn"][0] }        else { "" })
    }
}

# Convertit un FILETIME (Int64) AD en date lisible
function Convert-ADFileTime {
    param($value)
    try {
        $v = [Int64]$value
        if ($v -le 0) { return $null }
        return [DateTime]::FromFileTime($v)
    } catch { return $null }
}

# Liste des controleurs de domaine (mise en cache)
$Global:DCList = $null
function Get-DomainControllers {
    if ($Global:DCList) { return $Global:DCList }
    $list = @()
    try {
        $s = New-Object DirectoryServices.DirectorySearcher((Get-LDAPRoot))
        # userAccountControl bit 8192 = SERVER_TRUST_ACCOUNT (controleur de domaine)
        $s.Filter = "(&(objectCategory=computer)(userAccountControl:1.2.840.113556.1.4.803:=8192))"
        $null = $s.PropertiesToLoad.Add("dNSHostName")
        foreach ($r in $s.FindAll()) {
            if ($r.Properties["dnshostname"].Count) { $list += $r.Properties["dnshostname"][0] }
        }
    } catch { }
    $Global:DCList = $list
    return $list
}

# Vraie derniere connexion : interroge l'attribut lastLogon (non replique) sur
# TOUS les controleurs de domaine et renvoie la valeur la plus recente.
function Get-TrueLastLogon {
    param($userDN)

    if (-not $userDN) { return $null }

    $max = [Int64]0
    foreach ($dc in (Get-DomainControllers)) {
        try {
            $root = New-Object DirectoryServices.DirectoryEntry(
                "LDAP://$dc/$userDN",
                $Credential.UserName,
                $Credential.GetNetworkCredential().Password
            )
            $s = New-Object DirectoryServices.DirectorySearcher($root)
            $s.SearchScope = "Base"
            $s.Filter = "(objectClass=*)"
            $null = $s.PropertiesToLoad.Add("lastLogon")
            $r = $s.FindOne()
            if ($r -and $r.Properties["lastlogon"].Count) {
                $v = [Int64]$r.Properties["lastlogon"][0]
                if ($v -gt $max) { $max = $v }
            }
        } catch { }
    }

    if ($max -gt 0) { return [DateTime]::FromFileTime($max) }
    return $null
}


# Cherche un utilisateur existant par prenom+nom et renvoie ses infos de connexion
function Get-ExistingUserStatus {
    param($prenom,$nom)

    if (-not $prenom -or -not $nom) { return $null }

    $escP = $prenom -replace '\\','\5c' -replace '\(','\28' -replace '\)','\29' -replace '\*','\2a'
    $escN = $nom    -replace '\\','\5c' -replace '\(','\28' -replace '\)','\29' -replace '\*','\2a'

    $searcher = New-Object DirectoryServices.DirectorySearcher((Get-LDAPRoot))
    $searcher.Filter = "(&(objectClass=user)(objectCategory=person)(givenName=$escP)(sn=$escN))"
    $searcher.SizeLimit = 1
    $null = $searcher.PropertiesToLoad.Add("lastlogontimestamp")
    $null = $searcher.PropertiesToLoad.Add("pwdlastset")
    $null = $searcher.PropertiesToLoad.Add("samaccountname")

    try {
        $r = $searcher.FindOne()
        if (-not $r) { return $null }

        $p = $r.Properties
        $ll  = if ($p["lastlogontimestamp"].Count) { Convert-ADFileTime $p["lastlogontimestamp"][0] } else { $null }
        $pls = if ($p["pwdlastset"].Count)         { Convert-ADFileTime $p["pwdlastset"][0] }         else { $null }

        return [pscustomobject]@{
            Login       = $(if ($p["samaccountname"].Count) { $p["samaccountname"][0] } else { "" })
            LastLogon   = $ll
            PwdLastSet  = $pls
            MustChange  = ($p["pwdlastset"].Count -and [Int64]$p["pwdlastset"][0] -eq 0)
        }
    }
    catch { return $null }
}

function New-UserLDAP {
    param($ouDN,$prenom,$nom,$login,$fonction,$service,$description)

    $ou = Get-LDAPRoot "LDAP://$ouDN"

    $u = $ou.Children.Add("CN=$prenom $nom","user")

    $u.Put("sAMAccountName",$login)
    $u.Put("givenName",$prenom)
    $u.Put("sn",$nom)
    $u.Put("displayName","$prenom $nom")
    $u.Put("userPrincipalName","$login@example.org")
    $u.Put("company","Example Corporation")

    if ($fonction)    { $u.Put("title",$fonction) }
    if ($service)     { $u.Put("department",$service) }
    if ($description) { $u.Put("description",$description) }

    # 1) creation de l'objet
    $u.SetInfo()

    # 2) mot de passe
    $Global:LastGeneratedPassword = New-RandomPassword
    $u.Invoke("SetPassword",$Global:LastGeneratedPassword)

    # 3) activation du compte (512 = NORMAL_ACCOUNT)
    $u.Put("userAccountControl",512)
    $u.SetInfo()

    return $u
}

function Add-UserToGroupLDAP {
    param($groupName,$userDN)

    $searcher = New-Object DirectoryServices.DirectorySearcher((Get-LDAPRoot))
    $searcher.Filter = "(&(objectClass=group)(|(sAMAccountName=$groupName)(cn=$groupName)))"

    $r = $searcher.FindOne()
    if (-not $r) { throw "Groupe introuvable : $groupName" }

    $g = Get-LDAPRoot $r.Path
    $null = $g.Properties["member"].Add($userDN)
    $g.SetInfo()
}

function Get-UniqueLogin {
    param ($prenom,$nom)

    # NOM COMPOSE
    $nomUpper = $nom.ToUpper()
    $words = $nomUpper -split "[\s']+"

    $ignore = @("DU","DES","LA","LE","LES")
    $NomNettoye = ""

    for ($i = 0; $i -lt $words.Count; $i++) {

        $word = $words[$i]

        if ($word -eq "DE") {

            $nextParts = @()

            for ($j = $i + 1; $j -lt $words.Count; $j++) {

                $next = $words[$j]

                if ($next -in $ignore) { continue }

                if ($next -eq "L") {
                    $nextParts += "l"
                    continue
                }

                if ($next -ne "") {
                    $nextParts += $next.ToLower()
                    break
                }
            }

            $NomNettoye = "de" + ($nextParts -join "")
            break
        }

        elseif ($word -notin $ignore -and $word -ne "") {
            $NomNettoye = $word.ToLower()
            break
        }
    }

    if (-not $NomNettoye) {
        $NomNettoye = ($nom -split "[\s'-]")[0].ToLower()
    }

    # PRENOM COMPOSE -> INITIALES
    $prenomParts = ($prenom -replace "-", " ").ToLower().Split(" ")

    $initiales = ""
    foreach ($p in $prenomParts) {
        if ($p -ne "") {
            $initiales += $p.Substring(0,1)
        }
    }

    if (-not $initiales) { return $null }

    # LOGIN 1 -> initiales
    $login1 = "$initiales.$NomNettoye"
    $user1 = Find-UserBySam $login1

    if (-not $user1) { return $login1 }
    if ($user1.GivenName -eq $prenom -and $user1.Surname -eq $nom) { return $null }

    # LOGIN 2 -> 2 lettres prenom
    $prenomClean = ($prenomParts -join "")
    if ($prenomClean.Length -ge 2) {

        $login2 = "$($prenomClean.Substring(0,2)).$NomNettoye"
        $user2 = Find-UserBySam $login2

        if (-not $user2) { return $login2 }
        if ($user2.GivenName -eq $prenom -and $user2.Surname -eq $nom) { return $null }
    }

    # LOGIN 3 -> prenom complet
    $login3 = "$prenomClean.$NomNettoye"
    $user3 = Find-UserBySam $login3

    if (-not $user3) { return $login3 }
    if ($user3.GivenName -eq $prenom -and $user3.Surname -eq $nom) { return $null }

    return $null
}

# --- FONCTIONS EDITION ---
function Get-UserLDAP {
    param($login)

    if (-not $login -or $login.Trim() -eq "") { return $null }

    $root = Get-LDAPRoot
    $searcher = New-Object DirectoryServices.DirectorySearcher($root)
    $searcher.Filter = "(&(objectClass=user)(sAMAccountName=$login))"
    $null = $searcher.PropertiesToLoad.Add("*")

    return $searcher.FindOne()
}

# Recherche d'utilisateurs pour l'autocompletion (login prefixe OU nom via ANR)
function Search-UsersLDAP {
    param([string]$term,[int]$max = 8)

    $results = @()
    if (-not $term -or $term.Trim().Length -lt 2) { return $results }

    $t = $term.Trim()
    # echappement des caracteres speciaux LDAP
    $esc = $t -replace '\\','\5c' -replace '\(','\28' -replace '\)','\29' -replace '\*','\2a'

    $searcher = New-Object DirectoryServices.DirectorySearcher((Get-LDAPRoot))
    # anr = recherche "nom ambigu" (prenom, nom, displayName...), + prefixe de login
    $searcher.Filter = "(&(objectClass=user)(objectCategory=person)(|(anr=$esc)(sAMAccountName=$esc*)(displayName=$esc*)))"
    $searcher.SizeLimit = $max
    $searcher.PageSize  = $max
    $null = $searcher.PropertiesToLoad.Add("samaccountname")
    $null = $searcher.PropertiesToLoad.Add("displayname")
    $null = $searcher.PropertiesToLoad.Add("givenname")
    $null = $searcher.PropertiesToLoad.Add("sn")

    try {
        foreach ($r in $searcher.FindAll()) {
            $p = $r.Properties
            if (-not $p["samaccountname"].Count) { continue }
            $login = $p["samaccountname"][0]

            if ($p["displayname"].Count) {
                $disp = $p["displayname"][0]
            } else {
                $gn = if ($p["givenname"].Count) { $p["givenname"][0] } else { "" }
                $sn = if ($p["sn"].Count) { $p["sn"][0] } else { "" }
                $disp = ("$gn $sn").Trim()
            }

            $results += [pscustomobject]@{
                Login = $login
                Label = $(if ($disp) { "$login    -    $disp" } else { $login })
            }
        }
    } catch { }

    return ($results | Sort-Object Login)
}

# Recherche d'ordinateurs pour l'autocompletion (prefixe de nom)
function Search-ComputersLDAP {
    param([string]$term,[int]$max = 8)

    $results = @()
    if (-not $term -or $term.Trim().Length -lt 2) { return $results }

    $t = $term.Trim()
    $esc = $t -replace '\\','\5c' -replace '\(','\28' -replace '\)','\29' -replace '\*','\2a'

    $searcher = New-Object DirectoryServices.DirectorySearcher((Get-LDAPRoot))
    $searcher.Filter = "(&(objectClass=computer)(|(name=$esc*)(cn=$esc*)))"
    $searcher.SizeLimit = $max
    $searcher.PageSize  = $max
    $null = $searcher.PropertiesToLoad.Add("name")
    $null = $searcher.PropertiesToLoad.Add("operatingsystem")

    try {
        foreach ($r in $searcher.FindAll()) {
            $p = $r.Properties
            if (-not $p["name"].Count) { continue }
            $name = $p["name"][0]
            $os   = if ($p["operatingsystem"].Count) { $p["operatingsystem"][0] } else { "" }

            $results += [pscustomobject]@{
                Name  = $name
                Label = $(if ($os) { "$name    -    $os" } else { $name })
            }
        }
    } catch { }

    return ($results | Sort-Object Name)
}

function Set-UserLDAP {
    param($entry,$data)

    try {
        if ($data.GivenName)   { $entry.givenName = $data.GivenName }
        if ($data.Surname)     { $entry.sn = $data.Surname }
        if ($data.Title)       { $entry.title = $data.Title }
        if ($data.Department)  { $entry.department = $data.Department }
        if ($data.Description) { $entry.description = $data.Description }
        if ($data.Telephone)   { $entry.telephoneNumber = $data.Telephone }
        if ($data.Mobile)      { $entry.mobile = $data.Mobile }

        $entry.SetInfo()
        return $true
    }
    catch {
        return $false
    }
}

function Get-Value {
    param($prop)
    if ($prop -and $prop.Count -gt 0) { return $prop[0] }
    return ""
}

# --- EXCLUSIONS DOSSIERS (personnes qui n'ont pas besoin de dossier) ---
function Get-Exclusions {
    $set = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    try {
        if (Test-Path $ExclusionsPath) {
            foreach ($line in (Get-Content -Path $ExclusionsPath -ErrorAction Stop)) {
                $l = "$line".Trim()
                if ($l) { [void]$set.Add($l) }
            }
        }
    } catch { }
    return $set
}

function Save-Exclusions {
    try {
        $dir = Split-Path $ExclusionsPath -Parent
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $lignes = @($global:Exclusions | Sort-Object)
        Set-Content -Path $ExclusionsPath -Value $lignes -Encoding UTF8 -ErrorAction Stop
        return $true
    } catch {
        return $false
    }
}

# --- MOT DE PASSE / SORTIE ---

# Reinitialise le mot de passe d'un compte (DirectoryEntry)
function Set-UserPassword {
    param($userEntry,$password)

    $userEntry.Invoke("SetPassword",$password)
    $userEntry.SetInfo()
}

# Retourne les groupes (memberOf) d'un utilisateur : @{ Name; DN }
function Get-UserGroups {
    param($userEntry)

    $list = @()
    if ($userEntry.Properties["memberOf"].Count -gt 0) {
        foreach ($dn in $userEntry.Properties["memberOf"]) {
            $cn = ($dn -split ",")[0] -replace "^CN=",""
            $list += [pscustomobject]@{ Name = $cn; DN = $dn }
        }
    }
    return $list
}

# Retire l'utilisateur de TOUS ses groupes sauf le groupe primaire (Utilisateurs du domaine)
function Remove-AllUserGroups {
    param($userEntry)

    $removed = @()
    $kept    = @()
    $errors  = @()

    # On remet le groupe primaire sur "Utilisateurs du domaine" (RID 513)
    # afin qu'aucun autre groupe ne soit protege comme groupe primaire.
    try {
        $userEntry.Properties["primaryGroupID"].Value = 513
        $userEntry.SetInfo()
    } catch { }

    $userDN = $userEntry.Properties["distinguishedName"][0]

    foreach ($grp in (Get-UserGroups $userEntry)) {

        if ($KeepGroups -contains $grp.Name) {
            $kept += $grp.Name
            continue
        }

        try {
            $g = Get-LDAPRoot "LDAP://$($grp.DN)"
            $g.Properties["member"].Remove($userDN)
            $g.SetInfo()
            $removed += $grp.Name
        }
        catch {
            $errors += "$($grp.Name) : $($_.Exception.Message)"
        }
    }

    return [pscustomobject]@{ Removed = $removed; Kept = $kept; Errors = $errors }
}

# --- FONCTION VERIF PC ---
# Seuil (en jours) au-dela duquel un poste est considere comme inactif
$InactivePCDays = 90

function Test-PCInAD {
    param ($PCName)

    try {
        $searcher = New-Object DirectoryServices.DirectorySearcher((Get-LDAPRoot))
        $searcher.Filter = "(&(objectClass=computer)(name=$PCName))"
        $null = $searcher.PropertiesToLoad.Add("lastlogontimestamp")
        $null = $searcher.PropertiesToLoad.Add("useraccountcontrol")
        $null = $searcher.PropertiesToLoad.Add("operatingsystem")
        $null = $searcher.PropertiesToLoad.Add("distinguishedName")

        $result = $searcher.FindOne()

        if (-not $result) {
            return @{ Found = $false; Inactive = $false; Message = "PC NON trouve dans l'AD" }
        }

        $p = $result.Properties

        # Compte active / desactive (bit 2 = ACCOUNTDISABLE)
        $uac = 0
        if ($p["useraccountcontrol"].Count) { $uac = [int]$p["useraccountcontrol"][0] }
        $enabled = -not ($uac -band 2)

        # Derniere connexion (lastLogonTimestamp = FILETIME replique)
        $lastLogon = $null
        if ($p["lastlogontimestamp"].Count) {
            try { $lastLogon = [DateTime]::FromFileTime([Int64]$p["lastlogontimestamp"][0]) } catch {}
        }

        $days = $null
        if ($lastLogon) { $days = [int]((Get-Date) - $lastLogon).TotalDays }

        # Inactif si : compte desactive, jamais connecte, ou au-dela du seuil
        $inactive = (-not $enabled) -or ($null -eq $lastLogon) -or ($days -ge $InactivePCDays)

        $os = if ($p["operatingsystem"].Count) { $p["operatingsystem"][0] } else { "" }
        $dn = if ($p["distinguishedname"].Count) { $p["distinguishedname"][0] } else { "" }

        return @{
            Found      = $true
            Enabled    = $enabled
            LastLogon  = $lastLogon
            Days       = $days
            Inactive   = $inactive
            OS         = $os
            DN         = $dn
            Message    = "PC trouve dans l'AD"
        }
    }
    catch {
        return @{ Found = $false; Inactive = $false; Message = "Erreur : $_" }
    }
}

# Dernier utilisateur connecte sur un poste (interroge la machine via WMI/DCOM).
# Necessite que le poste soit allume/joignable et des droits admin dessus.
function Get-LastLoggedOnUser {
    param($pcName)

    $out = @{ User = ""; Info = ""; Reason = "" }
    if (-not $pcName) { $out.Reason = "Nom de poste manquant."; return $out }

    # Pre-verification de joignabilite (rapide)
    if (-not (Test-Connection -ComputerName $pcName -Count 1 -Quiet -ErrorAction SilentlyContinue)) {
        $out.Reason = "Poste injoignable (eteint, hors reseau, ou ping bloque)."
        # on tente quand meme WMI ci-dessous, le ping peut etre filtre
    }

    $sess = $null
    try {
        $opt  = New-CimSessionOption -Protocol Dcom
        $sess = New-CimSession -ComputerName $pcName -Credential $Credential -SessionOption $opt -OperationTimeoutSec 15 -ErrorAction Stop

        # 1) Utilisateur actuellement connecte
        try {
            $cs = Get-CimInstance -CimSession $sess -ClassName Win32_ComputerSystem -ErrorAction Stop
            if ($cs.UserName) {
                $out.User = "$($cs.UserName)"
                $out.Info = "connecte actuellement"
                return $out
            }
        } catch { }

        # 2) Dernier utilisateur (registre LogonUI via StdRegProv)
        try {
            $HKLM = [uint32]2147483650
            $sub  = 'SOFTWARE\Microsoft\Windows\Authentication\LogonUI'
            $v = Invoke-CimMethod -CimSession $sess -Namespace 'root\default' -ClassName 'StdRegProv' `
                    -MethodName GetStringValue -Arguments @{ Hive = $HKLM; sSubKeyName = $sub; sValueName = 'LastLoggedOnSAMUser' } -ErrorAction Stop
            $name = $v.sValue
            if (-not $name) {
                $v2 = Invoke-CimMethod -CimSession $sess -Namespace 'root\default' -ClassName 'StdRegProv' `
                        -MethodName GetStringValue -Arguments @{ Hive = $HKLM; sSubKeyName = $sub; sValueName = 'LastLoggedOnUser' } -ErrorAction Stop
                $name = $v2.sValue
            }
            if ($name) {
                $out.User = "$name"
                $out.Info = "dernier utilisateur (ecran de connexion)"
                return $out
            }
        } catch { }

        # 3) Profil le plus recemment utilise
        try {
            $prof = Get-CimInstance -CimSession $sess -ClassName Win32_UserProfile -ErrorAction Stop |
                    Where-Object { -not $_.Special -and $_.LastUseTime } |
                    Sort-Object LastUseTime -Descending | Select-Object -First 1
            if ($prof) {
                $name = $prof.SID
                try {
                    $sid = New-Object System.Security.Principal.SecurityIdentifier($prof.SID)
                    $name = $sid.Translate([System.Security.Principal.NTAccount]).Value
                } catch { }
                $out.User = "$name"
                $out.Info = "profil le plus recent ($($prof.LastUseTime))"
                return $out
            }
        } catch { }

        if (-not $out.Reason) {
            $out.Reason = "Aucun utilisateur determinable (droits admin/WMI sur le poste ?)."
        }
    }
    catch {
        if (-not $out.Reason -or $out.Reason -like "Poste injoignable*") {
            $out.Reason = "Connexion au poste impossible : $($_.Exception.Message)"
        }
    }
    finally {
        if ($sess) { try { Remove-CimSession $sess -ErrorAction SilentlyContinue } catch { } }
    }

    return $out
}

# Liste tous les postes inactifs depuis plus de $Days jours
function Get-InactivePCs {
    param([int]$Days)

    $list  = New-Object System.Collections.ArrayList
    $limit = (Get-Date).AddDays(-$Days)

    $searcher = New-Object DirectoryServices.DirectorySearcher((Get-LDAPRoot))
    $searcher.Filter = "(objectClass=computer)"
    $searcher.PageSize = 1000
    $null = $searcher.PropertiesToLoad.Add("name")
    $null = $searcher.PropertiesToLoad.Add("lastlogontimestamp")
    $null = $searcher.PropertiesToLoad.Add("useraccountcontrol")
    $null = $searcher.PropertiesToLoad.Add("operatingsystem")
    $null = $searcher.PropertiesToLoad.Add("distinguishedName")

    foreach ($res in $searcher.FindAll()) {

        $p = $res.Properties
        if (-not $p["name"].Count) { continue }
        $name = $p["name"][0]

        # Compte active / desactive
        $uac = 0
        if ($p["useraccountcontrol"].Count) { $uac = [int]$p["useraccountcontrol"][0] }
        $enabled = -not ($uac -band 2)

        # Derniere connexion
        $lastLogon = $null
        if ($p["lastlogontimestamp"].Count) {
            try { $lastLogon = [DateTime]::FromFileTime([Int64]$p["lastlogontimestamp"][0]) } catch {}
        }

        # Inactif = jamais connecte OU derniere connexion au-dela du seuil
        $isInactive = ($null -eq $lastLogon) -or ($lastLogon -lt $limit)
        if (-not $isInactive) { continue }

        if ($lastLogon) {
            $dc    = $lastLogon.ToString("dd/MM/yyyy")
            $d     = [int]((Get-Date) - $lastLogon).TotalDays
            $inact = "$d j"
        } else {
            $dc    = "Jamais"
            $d     = 999999
            $inact = "Jamais connecte"
        }

        $os = if ($p["operatingsystem"].Count) { $p["operatingsystem"][0] } else { "-" }
        $dn = if ($p["distinguishedname"].Count) { $p["distinguishedname"][0] } else { "" }

        [void]$list.Add([PSCustomObject]@{
            Nom               = $name
            DerniereConnexion = $dc
            Inactivite        = $inact
            Etat              = $(if ($enabled) { "Active" } else { "Desactive" })
            OS                = $os
            DN                = $dn
            _Days             = $d
        })
    }

    return ($list | Sort-Object -Property _Days -Descending)
}

# ================================================================
# UI - FENETRE UNIQUE AVEC ONGLETS
# ================================================================
[xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="MASTER AD"
        Height="880" Width="1080"
        MinHeight="640" MinWidth="900"
        WindowStartupLocation="CenterScreen"
        FontFamily="Segoe UI"
        Background="#F1F5F9">

  <Window.Resources>

    <!-- ===== LIBELLE DE CHAMP ===== -->
    <Style x:Key="FieldLabel" TargetType="TextBlock">
      <Setter Property="Foreground" Value="#475569"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Margin" Value="0,12,0,4"/>
    </Style>

    <!-- ===== CARTE ===== -->
    <Style x:Key="Card" TargetType="Border">
      <Setter Property="Background" Value="White"/>
      <Setter Property="CornerRadius" Value="12"/>
      <Setter Property="BorderBrush" Value="#E2E8F0"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Effect">
        <Setter.Value>
          <DropShadowEffect Color="#94A3B8" BlurRadius="16" ShadowDepth="2" Opacity="0.15"/>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- ===== TEXTBOX ARRONDI ===== -->
    <Style TargetType="TextBox">
      <Setter Property="Height" Value="34"/>
      <Setter Property="Padding" Value="10,0"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="Foreground" Value="#0F172A"/>
      <Setter Property="Background" Value="White"/>
      <Setter Property="BorderBrush" Value="#CBD5E1"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="VerticalContentAlignment" Value="Center"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TextBox">
            <Border x:Name="bd" Background="{TemplateBinding Background}"
                    BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="{TemplateBinding BorderThickness}"
                    CornerRadius="8">
              <ScrollViewer x:Name="PART_ContentHost" Margin="{TemplateBinding Padding}"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bd" Property="BorderBrush" Value="#94A3B8"/>
              </Trigger>
              <Trigger Property="IsKeyboardFocused" Value="True">
                <Setter TargetName="bd" Property="BorderBrush" Value="#2563EB"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- ===== COMBOBOX ===== -->
    <Style TargetType="ComboBox">
      <Setter Property="Height" Value="34"/>
      <Setter Property="Padding" Value="8,0"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="Foreground" Value="#0F172A"/>
      <Setter Property="Background" Value="White"/>
      <Setter Property="BorderBrush" Value="#CBD5E1"/>
      <Setter Property="VerticalContentAlignment" Value="Center"/>
    </Style>

    <!-- ===== BOUTON PRIMAIRE ===== -->
    <Style x:Key="PrimaryButton" TargetType="Button">
      <Setter Property="Background" Value="#2563EB"/>
      <Setter Property="Foreground" Value="White"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="FontSize" Value="14"/>
      <Setter Property="Height" Value="40"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bd" Background="{TemplateBinding Background}" CornerRadius="8" Padding="16,0">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bd" Property="Background" Value="#1D4ED8"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="bd" Property="Background" Value="#1E40AF"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter TargetName="bd" Property="Background" Value="#93C5FD"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- ===== BOUTON SECONDAIRE ===== -->
    <Style x:Key="GhostButton" TargetType="Button">
      <Setter Property="Background" Value="White"/>
      <Setter Property="Foreground" Value="#334155"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="Height" Value="38"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bd" Background="{TemplateBinding Background}" BorderBrush="#CBD5E1" BorderThickness="1" CornerRadius="8" Padding="16,0">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bd" Property="Background" Value="#F1F5F9"/>
                <Setter TargetName="bd" Property="BorderBrush" Value="#94A3B8"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="bd" Property="Background" Value="#E2E8F0"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- ===== BOUTON DANGER ===== -->
    <Style x:Key="DangerButton" TargetType="Button">
      <Setter Property="Background" Value="#DC2626"/>
      <Setter Property="Foreground" Value="White"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="FontSize" Value="14"/>
      <Setter Property="Height" Value="40"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bd" Background="{TemplateBinding Background}" CornerRadius="8" Padding="16,0">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bd" Property="Background" Value="#B91C1C"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="bd" Property="Background" Value="#991B1B"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter TargetName="bd" Property="Background" Value="#FCA5A5"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- ===== SEGMENT (RadioButton en pilule) ===== -->
    <Style x:Key="SegRadio" TargetType="RadioButton">
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="RadioButton">
            <Border x:Name="bd" Background="White" BorderBrush="#CBD5E1" BorderThickness="1" CornerRadius="8" Padding="18,8" Margin="0,0,8,0">
              <TextBlock x:Name="txt" Text="{TemplateBinding Content}" Foreground="#475569" FontWeight="SemiBold" FontSize="13"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bd" Property="BorderBrush" Value="#2563EB"/>
              </Trigger>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="bd" Property="Background" Value="#2563EB"/>
                <Setter TargetName="bd" Property="BorderBrush" Value="#2563EB"/>
                <Setter TargetName="txt" Property="Foreground" Value="White"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- ===== TABCONTROL ===== -->
    <Style TargetType="TabControl">
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TabControl">
            <Grid>
              <Grid.RowDefinitions>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="*"/>
              </Grid.RowDefinitions>
              <TabPanel Grid.Row="0" IsItemsHost="True" Margin="4,0,0,0" Background="Transparent"/>
              <Border Grid.Row="1" Background="#F8FAFC" CornerRadius="12" BorderBrush="#E2E8F0" BorderThickness="1">
                <ContentPresenter ContentSource="SelectedContent"/>
              </Border>
            </Grid>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- ===== TABITEM ===== -->
    <Style TargetType="TabItem">
      <Setter Property="Foreground" Value="#64748B"/>
      <Setter Property="FontSize" Value="13.5"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TabItem">
            <Border x:Name="bd" Background="Transparent" Padding="20,11" Margin="0,0,4,0" CornerRadius="10,10,0,0">
              <ContentPresenter ContentSource="Header" HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bd" Property="Background" Value="#E2E8F0"/>
              </Trigger>
              <Trigger Property="IsSelected" Value="True">
                <Setter TargetName="bd" Property="Background" Value="#F8FAFC"/>
                <Setter Property="Foreground" Value="#2563EB"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- ===== DATAGRID ===== -->
    <Style TargetType="DataGrid">
      <Setter Property="Background" Value="White"/>
      <Setter Property="BorderBrush" Value="#E2E8F0"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="RowBackground" Value="White"/>
      <Setter Property="AlternatingRowBackground" Value="#F8FAFC"/>
      <Setter Property="GridLinesVisibility" Value="Horizontal"/>
      <Setter Property="HorizontalGridLinesBrush" Value="#EEF2F6"/>
      <Setter Property="RowHeaderWidth" Value="0"/>
      <Setter Property="CanUserAddRows" Value="False"/>
      <Setter Property="IsReadOnly" Value="True"/>
      <Setter Property="SelectionUnit" Value="FullRow"/>
      <Setter Property="Foreground" Value="#334155"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="RowHeight" Value="34"/>
    </Style>

    <Style TargetType="DataGridColumnHeader">
      <Setter Property="Background" Value="#F1F5F9"/>
      <Setter Property="Foreground" Value="#475569"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="Padding" Value="12,8"/>
      <Setter Property="BorderThickness" Value="0,0,0,1"/>
      <Setter Property="BorderBrush" Value="#E2E8F0"/>
      <Setter Property="HorizontalContentAlignment" Value="Left"/>
    </Style>

    <Style TargetType="DataGridCell">
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Padding" Value="12,0"/>
      <Setter Property="VerticalContentAlignment" Value="Center"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="DataGridCell">
            <Border Background="{TemplateBinding Background}" Padding="{TemplateBinding Padding}">
              <ContentPresenter VerticalAlignment="Center"/>
            </Border>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

  </Window.Resources>

  <DockPanel>

    <!-- BANDEAU -->
    <Border DockPanel.Dock="Top" Padding="22,14">
      <Border.Background>
        <LinearGradientBrush StartPoint="0,0" EndPoint="1,0">
          <GradientStop Color="#0F172A" Offset="0"/>
          <GradientStop Color="#1E293B" Offset="1"/>
        </LinearGradientBrush>
      </Border.Background>
      <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
        <Border Width="34" Height="34" CornerRadius="8" Background="#2563EB" Margin="0,0,12,0">
          <TextBlock Text="AD" Foreground="White" FontWeight="Bold" FontSize="15" HorizontalAlignment="Center" VerticalAlignment="Center"/>
        </Border>
        <StackPanel VerticalAlignment="Center">
          <TextBlock Text="MASTER AD" Foreground="White" FontSize="19" FontWeight="Bold"/>
          <TextBlock Text="Outils Active Directory - NoAD" Foreground="#94A3B8" FontSize="12"/>
        </StackPanel>
      </StackPanel>
    </Border>

    <TabControl Margin="12,10,12,12" Background="Transparent">

      <!-- ============================================ -->
      <!-- ONGLET 1 : CREATION                          -->
      <!-- ============================================ -->
      <TabItem Header="  Creation  ">
        <ScrollViewer VerticalScrollBarVisibility="Auto">
          <Grid Margin="0,24">
            <Border Style="{StaticResource Card}" Padding="26" Width="470" HorizontalAlignment="Center" VerticalAlignment="Top">
              <StackPanel>

                <Image Name="C_Logo" Height="48" Margin="0,0,0,8" HorizontalAlignment="Center"/>

                <TextBlock Text="Creation Utilisateur" FontSize="21" FontWeight="Bold" Foreground="#0F172A" HorizontalAlignment="Center"/>
                <TextBlock Text="Renseignez les informations du nouvel utilisateur"
                           FontSize="12" Foreground="#94A3B8" HorizontalAlignment="Center" Margin="0,3,0,18"/>

                <Grid>
                  <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="12"/>
                    <ColumnDefinition Width="*"/>
                  </Grid.ColumnDefinitions>
                  <StackPanel Grid.Column="0">
                    <TextBlock Text="Prenom" Style="{StaticResource FieldLabel}"/>
                    <TextBox Name="C_Prenom"/>
                  </StackPanel>
                  <StackPanel Grid.Column="2">
                    <TextBlock Text="Nom" Style="{StaticResource FieldLabel}"/>
                    <TextBox Name="C_Nom"/>
                  </StackPanel>
                </Grid>

                <Border Background="#EFF6FF" BorderBrush="#BFDBFE" BorderThickness="1" CornerRadius="6" Padding="10,7" Margin="0,14,0,2">
                  <StackPanel Orientation="Horizontal">
                    <TextBlock Text="Login propose : " Foreground="#1E3A8A" FontSize="13" VerticalAlignment="Center"/>
                    <TextBlock Name="C_LoginPreview" Text="-" FontWeight="Bold" FontSize="15" Foreground="#2563EB" VerticalAlignment="Center"/>
                  </StackPanel>
                </Border>

                <TextBlock Text="Fonction" Style="{StaticResource FieldLabel}"/>
                <TextBox Name="C_Fonction"/>

                <TextBlock Text="Service (choisir ou saisir un nouveau)" Style="{StaticResource FieldLabel}"/>
                <ComboBox Name="C_Service" IsEditable="True"/>

                <TextBlock Text="Description" Style="{StaticResource FieldLabel}"/>
                <TextBox Name="C_Description"/>

                <TextBlock Text="Unite d'organisation (OU)" Style="{StaticResource FieldLabel}"/>
                <ComboBox Name="C_OU"/>

                <CheckBox Name="C_CreateFolder" Content="Creer le dossier utilisateur" Margin="0,16,0,4" Foreground="#374151"/>

                <TextBlock Text="Journal" Style="{StaticResource FieldLabel}"/>
                <RichTextBox Name="C_LogBox" Height="150" Background="#111827" Foreground="White" BorderThickness="0" Padding="8" Margin="0,0,0,10"/>

                <Border Background="#F1F5F9" CornerRadius="8" Padding="11,8" Margin="0,0,0,14">
                  <TextBlock Name="C_Status" Text="Pret." FontWeight="SemiBold" Foreground="#475569" FontSize="13"/>
                </Border>

                <Button Name="C_CreateBtn" Content="Creer utilisateur" Height="44" Style="{StaticResource PrimaryButton}"/>

              </StackPanel>
            </Border>

            <Grid Name="C_Overlay" Background="#99000000" Visibility="Collapsed">
              <Border Style="{StaticResource Card}" Padding="26" HorizontalAlignment="Center" VerticalAlignment="Center" Width="260">
                <StackPanel>
                  <TextBlock Name="C_StepText" FontWeight="SemiBold" Foreground="#0F172A" Margin="0,0,0,10"/>
                  <ProgressBar Name="C_StepProgress" Minimum="0" Maximum="4" Height="8" Foreground="#2563EB" Background="#E2E8F0" BorderThickness="0"/>
                </StackPanel>
              </Border>
            </Grid>
          </Grid>
        </ScrollViewer>
      </TabItem>

      <!-- ============================================ -->
      <!-- ONGLET 2 : MODIFICATION                      -->
      <!-- ============================================ -->
      <TabItem Header="  Modification  ">
        <ScrollViewer VerticalScrollBarVisibility="Auto">
          <Grid Margin="0,24">
            <Border Style="{StaticResource Card}" Padding="26" Width="470" HorizontalAlignment="Center" VerticalAlignment="Top">
              <StackPanel>

                <Image Name="E_Logo" Height="48" Margin="0,0,0,8" HorizontalAlignment="Center"/>

                <TextBlock Text="Modification Utilisateur" FontSize="21" FontWeight="Bold" Foreground="#0F172A" HorizontalAlignment="Center"/>
                <TextBlock Text="Chargez un compte via son login puis modifiez ses attributs"
                           FontSize="12" Foreground="#94A3B8" HorizontalAlignment="Center" Margin="0,3,0,16"/>

                <Border Background="#F1F5F9" CornerRadius="8" Padding="12" Margin="0,0,0,4">
                  <StackPanel>
                    <TextBlock Name="E_UserDisplay" Text="Aucun utilisateur charge" FontWeight="Bold" FontSize="14" Foreground="#0F172A"/>
                    <Border Name="E_BadgeBorder" CornerRadius="4" Padding="8,2" Margin="0,6,0,0" HorizontalAlignment="Left" Visibility="Collapsed">
                      <TextBlock Name="E_UserBadge" Foreground="White" FontWeight="Bold" FontSize="11"/>
                    </Border>
                    <TextBlock Name="E_LastLogon" Text="Derniere connexion : -" Foreground="#475569" FontSize="12" Margin="0,8,0,0"/>
                    <TextBlock Name="E_PwdLastSet" Text="Dernier changement MDP : -" Foreground="#475569" FontSize="12"/>
                  </StackPanel>
                </Border>

                <TextBlock Text="Login" Style="{StaticResource FieldLabel}"/>
                <Grid>
                  <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="8"/>
                    <ColumnDefinition Width="Auto"/>
                  </Grid.ColumnDefinitions>
                  <TextBox Name="E_Login" Grid.Column="0"/>
                  <Button Name="E_LoadBtn" Grid.Column="2" Content="Charger" Width="110" Style="{StaticResource GhostButton}"/>

                  <Popup Name="E_SuggestPopup" Grid.Column="0"
                         PlacementTarget="{Binding ElementName=E_Login}" Placement="Bottom"
                         Width="{Binding ActualWidth, ElementName=E_Login}"
                         StaysOpen="True" AllowsTransparency="True">
                    <Border Background="White" BorderBrush="#CBD5E1" BorderThickness="1" CornerRadius="8" Margin="0,4,0,0">
                      <Border.Effect>
                        <DropShadowEffect Color="#94A3B8" BlurRadius="14" ShadowDepth="2" Opacity="0.25"/>
                      </Border.Effect>
                      <ListBox Name="E_Suggest" DisplayMemberPath="Label" MaxHeight="220"
                               Focusable="False" BorderThickness="0" Background="Transparent"
                               FontSize="13" Foreground="#334155"
                               ScrollViewer.HorizontalScrollBarVisibility="Disabled">
                        <ListBox.ItemContainerStyle>
                          <Style TargetType="ListBoxItem">
                            <Setter Property="Focusable" Value="False"/>
                            <Setter Property="Padding" Value="10,7"/>
                            <Setter Property="Cursor" Value="Hand"/>
                            <Setter Property="Template">
                              <Setter.Value>
                                <ControlTemplate TargetType="ListBoxItem">
                                  <Border x:Name="bd" Background="Transparent" Padding="{TemplateBinding Padding}" CornerRadius="6">
                                    <ContentPresenter/>
                                  </Border>
                                  <ControlTemplate.Triggers>
                                    <Trigger Property="IsMouseOver" Value="True">
                                      <Setter TargetName="bd" Property="Background" Value="#EFF6FF"/>
                                    </Trigger>
                                    <Trigger Property="IsSelected" Value="True">
                                      <Setter TargetName="bd" Property="Background" Value="#DBEAFE"/>
                                    </Trigger>
                                  </ControlTemplate.Triggers>
                                </ControlTemplate>
                              </Setter.Value>
                            </Setter>
                          </Style>
                        </ListBox.ItemContainerStyle>
                      </ListBox>
                    </Border>
                  </Popup>
                </Grid>

                <Grid>
                  <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="12"/>
                    <ColumnDefinition Width="*"/>
                  </Grid.ColumnDefinitions>
                  <StackPanel Grid.Column="0">
                    <TextBlock Text="Prenom" Style="{StaticResource FieldLabel}"/>
                    <TextBox Name="E_Prenom"/>
                  </StackPanel>
                  <StackPanel Grid.Column="2">
                    <TextBlock Text="Nom" Style="{StaticResource FieldLabel}"/>
                    <TextBox Name="E_Nom"/>
                  </StackPanel>
                </Grid>

                <Grid>
                  <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="12"/>
                    <ColumnDefinition Width="*"/>
                  </Grid.ColumnDefinitions>
                  <StackPanel Grid.Column="0">
                    <TextBlock Text="Telephone" Style="{StaticResource FieldLabel}"/>
                    <TextBox Name="E_Telephone"/>
                  </StackPanel>
                  <StackPanel Grid.Column="2">
                    <TextBlock Text="Mobile" Style="{StaticResource FieldLabel}"/>
                    <TextBox Name="E_Mobile"/>
                  </StackPanel>
                </Grid>

                <TextBlock Text="Fonction" Style="{StaticResource FieldLabel}"/>
                <TextBox Name="E_Fonction"/>

                <TextBlock Text="Service" Style="{StaticResource FieldLabel}"/>
                <ComboBox Name="E_Service"/>

                <TextBlock Text="Unite d'organisation (OU)" Style="{StaticResource FieldLabel}"/>
                <ComboBox Name="E_OU"/>

                <TextBlock Text="Description" Style="{StaticResource FieldLabel}"/>
                <TextBox Name="E_Description"/>

                <TextBlock Text="Groupes de securite" Style="{StaticResource FieldLabel}"/>
                <Border BorderBrush="#E2E8F0" BorderThickness="1" CornerRadius="8">
                  <ListBox Name="E_GroupsList" Height="120" BorderThickness="0" Background="Transparent"
                           ScrollViewer.VerticalScrollBarVisibility="Auto" FontSize="13" Foreground="#334155"/>
                </Border>

                <TextBlock Text="Journal" Style="{StaticResource FieldLabel}"/>
                <RichTextBox Name="E_LogBox" Height="140" Background="#0F172A" Foreground="White" BorderThickness="0" Padding="8" Margin="0,0,0,12"/>

                <Button Name="E_SaveBtn" Content="Enregistrer les modifications" Height="44" Style="{StaticResource PrimaryButton}"/>

                <Border BorderBrush="#E2E8F0" BorderThickness="0,1,0,0" Margin="0,16,0,0" Padding="0,14,0,0">
                  <StackPanel>
                    <TextBlock Text="Mot de passe oublie" FontWeight="SemiBold" Foreground="#0F172A" FontSize="13"/>
                    <TextBlock Text="Reinitialise le mot de passe du compte charge sur celui defini dans la configuration et force le changement a la prochaine ouverture de session."
                               FontSize="12" Foreground="#94A3B8" Margin="0,2,0,8" TextWrapping="Wrap"/>
                    <Button Name="E_ResetPwdBtn" Content="Reinitialiser le mot de passe" Height="40" Style="{StaticResource GhostButton}"/>
                  </StackPanel>
                </Border>

              </StackPanel>
            </Border>
          </Grid>
        </ScrollViewer>
      </TabItem>

      <!-- ============================================ -->
      <!-- ONGLET : SORTIE (OFFBOARDING)                -->
      <!-- ============================================ -->
      <TabItem Header="  Sortie  ">
        <ScrollViewer VerticalScrollBarVisibility="Auto">
          <Grid Margin="0,24">
            <Border Style="{StaticResource Card}" Padding="26" Width="500" HorizontalAlignment="Center" VerticalAlignment="Top">
              <StackPanel>

                <TextBlock Text="Sortie Utilisateur" FontSize="21" FontWeight="Bold" Foreground="#0F172A" HorizontalAlignment="Center"/>
                <TextBlock Text="Retire tous les groupes (sauf Utilisateurs du domaine) et applique un mot de passe temporaire"
                           FontSize="12" Foreground="#94A3B8" HorizontalAlignment="Center" TextWrapping="Wrap" Margin="0,3,0,16"/>

                <TextBlock Text="Login" Style="{StaticResource FieldLabel}"/>
                <Grid>
                  <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="12"/>
                    <ColumnDefinition Width="Auto"/>
                  </Grid.ColumnDefinitions>
                  <TextBox Name="S_Login" Grid.Column="0"/>
                  <Button Name="S_LoadBtn" Grid.Column="2" Content="Charger" Width="120" Style="{StaticResource GhostButton}"/>
                </Grid>

                <Border Background="#F1F5F9" CornerRadius="8" Padding="12" Margin="0,14,0,0">
                  <StackPanel>
                    <TextBlock Name="S_UserDisplay" Text="Aucun utilisateur charge" FontWeight="Bold" FontSize="14" Foreground="#0F172A"/>
                    <TextBlock Name="S_UserSub" Text="Chargez un compte via son login" FontSize="12" Foreground="#94A3B8" Margin="0,2,0,0"/>
                  </StackPanel>
                </Border>

                <TextBlock Text="Groupes actuels" Style="{StaticResource FieldLabel}"/>
                <Border BorderBrush="#E2E8F0" BorderThickness="1" CornerRadius="8">
                  <ListBox Name="S_GroupsList" Height="150" BorderThickness="0" Background="Transparent"
                           ScrollViewer.VerticalScrollBarVisibility="Auto" FontSize="13" Foreground="#334155"/>
                </Border>

                <Border Background="#FEF2F2" BorderBrush="#FECACA" BorderThickness="1" CornerRadius="8" Padding="11,9" Margin="0,14,0,0">
                  <TextBlock TextWrapping="Wrap" FontSize="12.5" Foreground="#991B1B">
                    <Run Text="Action de sortie :"/>
                    <LineBreak/>
                    <Run Text="- retire l'utilisateur de tous ses groupes (sauf Utilisateurs du domaine)"/>
                    <LineBreak/>
                    <Run Text="- reinitialise le mot de passe sur celui defini dans la configuration"/>
                  </TextBlock>
                </Border>

                <TextBlock Text="Journal" Style="{StaticResource FieldLabel}"/>
                <RichTextBox Name="S_LogBox" Height="140" Background="#0F172A" Foreground="White" BorderThickness="0" Padding="8" Margin="0,0,0,12"/>

                <Button Name="S_ProcessBtn" Content="Traiter la sortie" Height="44" Style="{StaticResource DangerButton}"/>
                <Button Name="S_BtnDisable" Content="Desactiver le compte" Height="40" Margin="0,8,0,0" Style="{StaticResource GhostButton}"/>

              </StackPanel>
            </Border>
          </Grid>
        </ScrollViewer>
      </TabItem>
      <TabItem Header="  Dossiers  ">
        <Grid Margin="22">
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
          </Grid.RowDefinitions>

          <TextBlock Grid.Row="0" Text="Dossiers Utilisateurs" FontSize="18" FontWeight="Bold" Foreground="#0F172A"/>
          <TextBlock Grid.Row="0" Text="Scan de l'OU Employes et creation des dossiers manquants (+ droits NTFS)"
                     FontSize="12" Foreground="#94A3B8" Margin="0,26,0,0"/>

          <!-- Dashboard -->
          <Grid Grid.Row="1" Height="86" Margin="0,16,0,14">
            <Grid.ColumnDefinitions>
              <ColumnDefinition/>
              <ColumnDefinition Width="12"/>
              <ColumnDefinition/>
              <ColumnDefinition Width="12"/>
              <ColumnDefinition/>
              <ColumnDefinition Width="12"/>
              <ColumnDefinition/>
            </Grid.ColumnDefinitions>

            <Border Grid.Column="0" Style="{StaticResource Card}">
              <StackPanel VerticalAlignment="Center" Margin="16,0">
                <TextBlock Text="UTILISATEURS" Foreground="#94A3B8" FontSize="11" FontWeight="SemiBold"/>
                <TextBlock Name="F_TxtTotal" Text="0" FontSize="26" FontWeight="Bold" Foreground="#0F172A"/>
              </StackPanel>
            </Border>

            <Border Grid.Column="2" Style="{StaticResource Card}">
              <StackPanel VerticalAlignment="Center" Margin="16,0">
                <TextBlock Text="SANS DOSSIER" Foreground="#94A3B8" FontSize="11" FontWeight="SemiBold"/>
                <TextBlock Name="F_TxtMissing" Text="0" FontSize="26" FontWeight="Bold" Foreground="#EA580C"/>
              </StackPanel>
            </Border>

            <Border Grid.Column="4" Style="{StaticResource Card}">
              <StackPanel VerticalAlignment="Center" Margin="16,0">
                <TextBlock Text="CREES" Foreground="#94A3B8" FontSize="11" FontWeight="SemiBold"/>
                <TextBlock Name="F_TxtCreated" Text="0" FontSize="26" FontWeight="Bold" Foreground="#16A34A"/>
              </StackPanel>
            </Border>

            <Border Grid.Column="6" Style="{StaticResource Card}">
              <StackPanel VerticalAlignment="Center" Margin="16,0">
                <TextBlock Text="EXCLUS" Foreground="#94A3B8" FontSize="11" FontWeight="SemiBold"/>
                <TextBlock Name="F_TxtExcluded" Text="0" FontSize="26" FontWeight="Bold" Foreground="#64748B"/>
              </StackPanel>
            </Border>
          </Grid>

          <!-- Table -->
          <DataGrid Name="F_DGUsers" Grid.Row="2" AutoGenerateColumns="False">
            <DataGrid.RowStyle>
              <Style TargetType="DataGridRow">
                <Style.Triggers>
                  <DataTrigger Binding="{Binding Statut}" Value="Absent">
                    <Setter Property="Background" Value="#FEF2F2"/>
                  </DataTrigger>
                  <DataTrigger Binding="{Binding Statut}" Value="Cree">
                    <Setter Property="Background" Value="#F0FDF4"/>
                  </DataTrigger>
                  <DataTrigger Binding="{Binding Statut}" Value="Exclu">
                    <Setter Property="Background" Value="#F1F5F9"/>
                    <Setter Property="Foreground" Value="#94A3B8"/>
                  </DataTrigger>
                </Style.Triggers>
              </Style>
            </DataGrid.RowStyle>
            <DataGrid.Columns>
              <DataGridTextColumn Header="LOGIN" Binding="{Binding Login}" Width="*"/>
              <DataGridTextColumn Header="NOM" Binding="{Binding Nom}" Width="*"/>
              <DataGridTextColumn Header="STATUT" Binding="{Binding Statut}" Width="*"/>
            </DataGrid.Columns>
          </DataGrid>

          <ProgressBar Name="F_ProgressBar" Grid.Row="3" Height="6" Margin="0,12,0,10" Foreground="#2563EB" Background="#E2E8F0" BorderThickness="0"/>

          <Grid Grid.Row="4">
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="Auto"/>
              <ColumnDefinition Width="Auto"/>
              <ColumnDefinition Width="Auto"/>
              <ColumnDefinition Width="Auto"/>
              <ColumnDefinition Width="Auto"/>
              <ColumnDefinition Width="*"/>
            </Grid.ColumnDefinitions>

            <Button Name="F_BtnScan" Grid.Column="0" Content="Scanner AD" Width="120" Margin="0,0,8,0" Style="{StaticResource PrimaryButton}"/>
            <Button Name="F_BtnCreate" Grid.Column="1" Content="Creer selection" Width="140" Margin="0,0,8,0" Style="{StaticResource GhostButton}"/>
            <Button Name="F_BtnAuto" Grid.Column="2" Content="Tout creer" Width="110" Margin="0,0,8,0" Style="{StaticResource GhostButton}"/>
            <Button Name="F_BtnExclude" Grid.Column="3" Content="Exclure" Width="110" Margin="0,0,8,0" Style="{StaticResource GhostButton}"/>
            <Button Name="F_BtnInclude" Grid.Column="4" Content="Reintegrer" Width="110" Style="{StaticResource GhostButton}"/>

            <TextBox Name="F_LogBox" Grid.Column="5" Height="40" Margin="12,0,0,0" VerticalContentAlignment="Top" AcceptsReturn="True" IsReadOnly="True" Foreground="#64748B" FontSize="12"/>
          </Grid>
        </Grid>
      </TabItem>

      <!-- ============================================ -->
      <!-- ONGLET 4 : VERIFICATION PC                   -->
      <!-- ============================================ -->
      <TabItem Header="  Gestion Ordinateur  ">
        <Grid Margin="26,22">
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
          </Grid.RowDefinitions>

          <!-- Titre -->
          <StackPanel Grid.Row="0">
            <TextBlock Text="Postes Active Directory" FontSize="18" FontWeight="Bold" Foreground="#0F172A"/>
            <TextBlock Text="Verifier un poste precis ou lister les postes inactifs"
                       FontSize="12" Foreground="#94A3B8" Margin="0,3,0,0"/>
          </StackPanel>

          <!-- CARTE : verification d'un poste -->
          <Border Grid.Row="1" Style="{StaticResource Card}" Padding="18" Margin="0,16,0,16">
            <StackPanel>
              <TextBlock Text="Verifier un poste" FontWeight="SemiBold" Foreground="#0F172A" FontSize="14" Margin="0,0,0,10"/>

              <Grid>
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width="*"/>
                  <ColumnDefinition Width="12"/>
                  <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <TextBox Name="P_TxtPCName" Grid.Column="0"/>
                <Button Name="P_BtnCheck" Grid.Column="2" Content="Verifier" Width="120" Style="{StaticResource PrimaryButton}"/>

                <Popup Name="P_SuggestPopup" Grid.Column="0"
                       PlacementTarget="{Binding ElementName=P_TxtPCName}" Placement="Bottom"
                       Width="{Binding ActualWidth, ElementName=P_TxtPCName}"
                       StaysOpen="True" AllowsTransparency="True">
                  <Border Background="White" BorderBrush="#CBD5E1" BorderThickness="1" CornerRadius="8" Margin="0,4,0,0">
                    <Border.Effect>
                      <DropShadowEffect Color="#94A3B8" BlurRadius="14" ShadowDepth="2" Opacity="0.25"/>
                    </Border.Effect>
                    <ListBox Name="P_Suggest" DisplayMemberPath="Label" MaxHeight="220"
                             Focusable="False" BorderThickness="0" Background="Transparent"
                             FontSize="13" Foreground="#334155"
                             ScrollViewer.HorizontalScrollBarVisibility="Disabled">
                      <ListBox.ItemContainerStyle>
                        <Style TargetType="ListBoxItem">
                          <Setter Property="Focusable" Value="False"/>
                          <Setter Property="Padding" Value="10,7"/>
                          <Setter Property="Cursor" Value="Hand"/>
                          <Setter Property="Template">
                            <Setter.Value>
                              <ControlTemplate TargetType="ListBoxItem">
                                <Border x:Name="bd" Background="Transparent" Padding="{TemplateBinding Padding}" CornerRadius="6">
                                  <ContentPresenter/>
                                </Border>
                                <ControlTemplate.Triggers>
                                  <Trigger Property="IsMouseOver" Value="True">
                                    <Setter TargetName="bd" Property="Background" Value="#EFF6FF"/>
                                  </Trigger>
                                  <Trigger Property="IsSelected" Value="True">
                                    <Setter TargetName="bd" Property="Background" Value="#DBEAFE"/>
                                  </Trigger>
                                </ControlTemplate.Triggers>
                              </ControlTemplate>
                            </Setter.Value>
                          </Setter>
                        </Style>
                      </ListBox.ItemContainerStyle>
                    </ListBox>
                  </Border>
                </Popup>
              </Grid>

              <Border Name="P_ResultCard" Background="#0F172A" Margin="0,14,0,0" Padding="14" CornerRadius="8" Visibility="Collapsed">
                <StackPanel>
                  <StackPanel Orientation="Horizontal" Margin="0,0,0,6">
                    <TextBlock Name="P_TxtResult" Foreground="White" FontSize="14" FontWeight="SemiBold" VerticalAlignment="Center"/>
                    <Border Name="P_BadgeBorder" CornerRadius="4" Padding="8,2" Margin="12,0,0,0" VerticalAlignment="Center" Visibility="Collapsed">
                      <TextBlock Name="P_Badge" Foreground="White" FontWeight="Bold" FontSize="11"/>
                    </Border>
                  </StackPanel>
                  <TextBlock Name="P_Detail" Foreground="#94A3B8" FontSize="12.5" TextWrapping="Wrap"/>

                  <TextBlock Name="P_LastUser" Foreground="#7DD3FC" FontSize="12.5" TextWrapping="Wrap" Margin="0,6,0,0"/>

                  <StackPanel Orientation="Horizontal" Margin="0,12,0,0">
                    <Button Name="P_BtnLastUser" Content="Dernier utilisateur connecte" Width="220" Height="34"
                            Margin="0,0,10,0" Style="{StaticResource GhostButton}" Visibility="Collapsed"/>
                    <Button Name="P_BtnDeletePC" Content="Supprimer ce poste de l'AD" Width="220" Height="34"
                            Style="{StaticResource DangerButton}" Visibility="Collapsed"/>
                  </StackPanel>
                </StackPanel>
              </Border>
            </StackPanel>
          </Border>

          <!-- En-tete : postes inactifs + segments 90/180/540 -->
          <Grid Grid.Row="2" Margin="0,0,0,12">
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="Auto"/>
              <ColumnDefinition Width="*"/>
              <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>

            <StackPanel Grid.Column="0" VerticalAlignment="Center">
              <TextBlock Text="Postes inactifs" FontWeight="SemiBold" Foreground="#0F172A" FontSize="14"/>
              <TextBlock Name="P_InactiveCount" Text="Choisissez un seuil puis lancez le scan"
                         FontSize="12" Foreground="#94A3B8" Margin="0,2,0,0"/>
            </StackPanel>

            <StackPanel Grid.Column="2" Orientation="Horizontal" VerticalAlignment="Center">
              <RadioButton Name="P_Seg90"  Content="90 j"  GroupName="InactiveSeg" IsChecked="True" Style="{StaticResource SegRadio}"/>
              <RadioButton Name="P_Seg180" Content="180 j" GroupName="InactiveSeg" Style="{StaticResource SegRadio}"/>
              <RadioButton Name="P_Seg365" Content="365 j" GroupName="InactiveSeg" Style="{StaticResource SegRadio}"/>
              <RadioButton Name="P_Seg540" Content="540 j" GroupName="InactiveSeg" Style="{StaticResource SegRadio}"/>
              <Button Name="P_BtnScanInactive" Content="Scanner" Width="120" Style="{StaticResource PrimaryButton}" Margin="6,0,0,0"/>
            </StackPanel>
          </Grid>

          <!-- Tableau des postes inactifs -->
          <Grid Grid.Row="3">
            <Grid.RowDefinitions>
              <RowDefinition Height="*"/>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="Auto"/>
            </Grid.RowDefinitions>

            <DataGrid Name="P_DGInactive" Grid.Row="0" AutoGenerateColumns="False">
              <DataGrid.RowStyle>
                <Style TargetType="DataGridRow">
                  <Style.Triggers>
                    <DataTrigger Binding="{Binding Etat}" Value="Desactive">
                      <Setter Property="Background" Value="#FEF2F2"/>
                    </DataTrigger>
                  </Style.Triggers>
                </Style>
              </DataGrid.RowStyle>
              <DataGrid.Columns>
                <DataGridTextColumn Header="POSTE" Binding="{Binding Nom}" Width="1.4*"/>
                <DataGridTextColumn Header="DERNIERE CONNEXION" Binding="{Binding DerniereConnexion}" Width="*"/>
                <DataGridTextColumn Header="INACTIF DEPUIS" Binding="{Binding Inactivite}" Width="*"/>
                <DataGridTextColumn Header="COMPTE" Binding="{Binding Etat}" Width="Auto"/>
                <DataGridTextColumn Header="SYSTEME" Binding="{Binding OS}" Width="1.6*"/>
              </DataGrid.Columns>
            </DataGrid>

            <Grid Grid.Row="1" Margin="0,12,0,0">
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="Auto"/>
              </Grid.ColumnDefinitions>
              <TextBlock Grid.Column="0" VerticalAlignment="Center" TextWrapping="Wrap" FontSize="12" Foreground="#94A3B8"
                         Text="Supprime de l'AD tous les postes listes ci-dessus (le seuil selectionne). Action irreversible."/>
              <Button Name="P_BtnDeleteInactive" Grid.Column="1" Content="Supprimer les PC inactifs"
                      Width="220" Style="{StaticResource DangerButton}"/>
            </Grid>

            <ProgressBar Name="P_ProgressBar" Grid.Row="2" Height="6" Margin="0,10,0,0"
                         Foreground="#2563EB" Background="#E2E8F0" BorderThickness="0"/>
          </Grid>

        </Grid>
      </TabItem>

    </TabControl>
  </DockPanel>
</Window>
"@

$Window = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $xaml))

# ================================================================
# RECUPERATION DES CONTROLES
# ================================================================
# --- Creation ---
$C_Prenom       = $Window.FindName("C_Prenom")
$C_Nom          = $Window.FindName("C_Nom")
$C_LoginPreview = $Window.FindName("C_LoginPreview")
$C_Fonction     = $Window.FindName("C_Fonction")
$C_Service      = $Window.FindName("C_Service")
$C_Description  = $Window.FindName("C_Description")
$C_OU           = $Window.FindName("C_OU")
$C_CreateFolder = $Window.FindName("C_CreateFolder")
$C_LogBox       = $Window.FindName("C_LogBox")
$C_Status       = $Window.FindName("C_Status")
$C_CreateBtn    = $Window.FindName("C_CreateBtn")
$C_Overlay      = $Window.FindName("C_Overlay")
$C_StepText     = $Window.FindName("C_StepText")
$C_StepProgress = $Window.FindName("C_StepProgress")
$C_Logo         = $Window.FindName("C_Logo")

# --- Modification ---
$E_Login       = $Window.FindName("E_Login")
$E_SuggestPopup = $Window.FindName("E_SuggestPopup")
$E_Suggest      = $Window.FindName("E_Suggest")
$E_Prenom      = $Window.FindName("E_Prenom")
$E_Nom         = $Window.FindName("E_Nom")
$E_Telephone   = $Window.FindName("E_Telephone")
$E_Mobile      = $Window.FindName("E_Mobile")
$E_Fonction    = $Window.FindName("E_Fonction")
$E_Service     = $Window.FindName("E_Service")
$E_OU          = $Window.FindName("E_OU")
$E_Description = $Window.FindName("E_Description")
$E_LogBox      = $Window.FindName("E_LogBox")
$E_LoadBtn     = $Window.FindName("E_LoadBtn")
$E_SaveBtn     = $Window.FindName("E_SaveBtn")
$E_Logo        = $Window.FindName("E_Logo")
$E_UserDisplay = $Window.FindName("E_UserDisplay")
$E_UserBadge   = $Window.FindName("E_UserBadge")
$E_BadgeBorder = $Window.FindName("E_BadgeBorder")
$E_ResetPwdBtn = $Window.FindName("E_ResetPwdBtn")
$E_GroupsList  = $Window.FindName("E_GroupsList")
$E_LastLogon   = $Window.FindName("E_LastLogon")
$E_PwdLastSet  = $Window.FindName("E_PwdLastSet")

# --- Sortie ---
$S_Login       = $Window.FindName("S_Login")
$S_LoadBtn     = $Window.FindName("S_LoadBtn")
$S_UserDisplay = $Window.FindName("S_UserDisplay")
$S_UserSub     = $Window.FindName("S_UserSub")
$S_GroupsList  = $Window.FindName("S_GroupsList")
$S_LogBox      = $Window.FindName("S_LogBox")
$S_ProcessBtn  = $Window.FindName("S_ProcessBtn")
$S_BtnDisable  = $Window.FindName("S_BtnDisable")

# --- Dossiers ---
$F_DGUsers     = $Window.FindName("F_DGUsers")
$F_TxtTotal    = $Window.FindName("F_TxtTotal")
$F_TxtMissing  = $Window.FindName("F_TxtMissing")
$F_TxtCreated  = $Window.FindName("F_TxtCreated")
$F_TxtExcluded = $Window.FindName("F_TxtExcluded")
$F_BtnScan     = $Window.FindName("F_BtnScan")
$F_BtnCreate   = $Window.FindName("F_BtnCreate")
$F_BtnAuto     = $Window.FindName("F_BtnAuto")
$F_BtnExclude  = $Window.FindName("F_BtnExclude")
$F_BtnInclude  = $Window.FindName("F_BtnInclude")
$F_ProgressBar = $Window.FindName("F_ProgressBar")
$F_LogBox      = $Window.FindName("F_LogBox")

# --- Verif PC ---
$P_TxtPCName   = $Window.FindName("P_TxtPCName")
$P_BtnCheck    = $Window.FindName("P_BtnCheck")
$P_TxtResult   = $Window.FindName("P_TxtResult")
$P_ResultCard  = $Window.FindName("P_ResultCard")
$P_BadgeBorder = $Window.FindName("P_BadgeBorder")
$P_Badge       = $Window.FindName("P_Badge")
$P_Detail      = $Window.FindName("P_Detail")
$P_BtnDeletePC = $Window.FindName("P_BtnDeletePC")
$P_LastUser    = $Window.FindName("P_LastUser")
$P_BtnLastUser = $Window.FindName("P_BtnLastUser")
$P_InactiveCount   = $Window.FindName("P_InactiveCount")
$P_Seg90           = $Window.FindName("P_Seg90")
$P_Seg180          = $Window.FindName("P_Seg180")
$P_Seg365          = $Window.FindName("P_Seg365")
$P_Seg540          = $Window.FindName("P_Seg540")
$P_BtnScanInactive = $Window.FindName("P_BtnScanInactive")
$P_DGInactive      = $Window.FindName("P_DGInactive")
$P_ProgressBar     = $Window.FindName("P_ProgressBar")
$P_BtnDeleteInactive = $Window.FindName("P_BtnDeleteInactive")
$P_SuggestPopup = $Window.FindName("P_SuggestPopup")
$P_Suggest      = $Window.FindName("P_Suggest")

# ================================================================
# FONCTIONS DE LOG (une par onglet)
# ================================================================
function Write-CreateLog {
    param([string]$msg,[string]$type = "INFO")

    $time = Get-Date -Format "HH:mm:ss"

    $paragraph = New-Object System.Windows.Documents.Paragraph
    $paragraph.Margin = "0"

    $timeRun = New-Object System.Windows.Documents.Run
    $timeRun.Text = "$time  "
    $timeRun.Foreground = [System.Windows.Media.Brushes]::Gray

    $run = New-Object System.Windows.Documents.Run
    $run.Text = $msg

    switch ($type) {
        "OK"    { $run.Foreground = [System.Windows.Media.Brushes]::ForestGreen; $run.FontWeight = "SemiBold" }
        "ERROR" { $run.Foreground = [System.Windows.Media.Brushes]::Crimson;     $run.FontWeight = "Bold" }
        "WARN"  { $run.Foreground = [System.Windows.Media.Brushes]::DarkOrange }
        "USER"  { $run.Foreground = [System.Windows.Media.Brushes]::DarkCyan;    $run.FontWeight = "SemiBold" }
        default { $run.Foreground = [System.Windows.Media.Brushes]::SteelBlue }
    }

    $paragraph.Inlines.Add($timeRun)
    $paragraph.Inlines.Add($run)

    $C_LogBox.Document.Blocks.Add($paragraph)
    $C_LogBox.ScrollToEnd()

    $Window.Dispatcher.Invoke([action]{}, "Render")
}

function Write-EditLog {
    param($msg,$type = "INFO")

    if (-not $UIReady) { return }

    $msg = [System.Text.Encoding]::UTF8.GetString(
        [System.Text.Encoding]::Default.GetBytes($msg)
    )

    $p = New-Object System.Windows.Documents.Paragraph
    $r = New-Object System.Windows.Documents.Run
    $r.Text = "$(Get-Date -Format HH:mm:ss) - $msg"

    switch ($type) {
        "ERROR"  { $r.Foreground = "Red" }
        "OK"     { $r.Foreground = "Green" }
        "ACTION" { $r.Foreground = "DodgerBlue" }
        "WARN"   { $r.Foreground = "Orange" }
    }

    $p.Inlines.Add($r)
    $E_LogBox.Document.Blocks.Add($p)
    $E_LogBox.ScrollToEnd()
}

function Write-FolderLog {
    param($msg)
    $F_LogBox.AppendText("$msg`n")
    $F_LogBox.ScrollToEnd()
}

function Write-SortieLog {
    param($msg,$type = "INFO")

    $p = New-Object System.Windows.Documents.Paragraph
    $p.Margin = "0"
    $r = New-Object System.Windows.Documents.Run
    $r.Text = "$(Get-Date -Format HH:mm:ss) - $msg"

    switch ($type) {
        "ERROR"  { $r.Foreground = [System.Windows.Media.Brushes]::Salmon;      $r.FontWeight = "Bold" }
        "OK"     { $r.Foreground = [System.Windows.Media.Brushes]::LightGreen;   $r.FontWeight = "SemiBold" }
        "ACTION" { $r.Foreground = [System.Windows.Media.Brushes]::Gold }
        "WARN"   { $r.Foreground = [System.Windows.Media.Brushes]::Orange }
        default  { $r.Foreground = [System.Windows.Media.Brushes]::White }
    }

    $p.Inlines.Add($r)
    $S_LogBox.Document.Blocks.Add($p)
    $S_LogBox.ScrollToEnd()
    $Window.Dispatcher.Invoke([action]{}, "Render")
}

# ================================================================
# LOGOS
# ================================================================
if (Test-Path $LogoPath) {
    try {
        $bmp = New-Object System.Windows.Media.Imaging.BitmapImage
        $bmp.BeginInit()
        $bmp.UriSource = New-Object System.Uri($LogoPath, [System.UriKind]::Absolute)
        $bmp.CacheOption = "OnLoad"
        $bmp.EndInit()
        $bmp.Freeze()
        $C_Logo.Source = $bmp
        $E_Logo.Source = $bmp
    } catch { }
}

# ================================================================
# CHARGEMENT OU (Creation = Subtree, Modification = OneLevel)
# ================================================================
# --- Creation ---
try {
    $searcher = New-Object DirectoryServices.DirectorySearcher((Get-LDAPRoot "LDAP://$OUBase"))
    $searcher.Filter = "(objectClass=organizationalUnit)"
    $null = $searcher.PropertiesToLoad.Add("name")
    $null = $searcher.PropertiesToLoad.Add("distinguishedName")
    $searcher.SearchScope = "Subtree"

    foreach ($res in $searcher.FindAll()) {
        $item = New-Object System.Windows.Controls.ComboBoxItem
        $item.Content = $res.Properties["name"][0]
        $item.Tag     = $res.Properties["distinguishedname"][0]
        $null = $C_OU.Items.Add($item)
    }
}
catch {
    Write-CreateLog "Erreur chargement OU" "ERROR"
}

# --- Modification ---
try {
    $searcher = New-Object DirectoryServices.DirectorySearcher((Get-LDAPRoot "LDAP://$OUBase"))
    $searcher.Filter = "(objectClass=organizationalUnit)"
    $null = $searcher.PropertiesToLoad.Add("name")
    $null = $searcher.PropertiesToLoad.Add("distinguishedName")
    $searcher.SearchScope = "OneLevel"

    $E_OU.Items.Clear()
    foreach ($res in $searcher.FindAll()) {
        $item = New-Object System.Windows.Controls.ComboBoxItem
        $item.Content = $res.Properties["name"][0]
        $item.Tag     = $res.Properties["distinguishedname"][0]
        $null = $E_OU.Items.Add($item)
    }
}
catch { }

# ================================================================
# CHARGEMENT SERVICES (depuis OU Employes) -> Creation + Modification
# ================================================================
try {
    $searcher = New-Object DirectoryServices.DirectorySearcher((Get-LDAPRoot "LDAP://$OUEmployes"))
    $searcher.Filter = "(&(objectClass=user)(objectCategory=person)(department=*))"
    $null = $searcher.PropertiesToLoad.Add("department")

    $services = @()
    foreach ($res in $searcher.FindAll()) {
        if ($res.Properties["department"]) {
            $services += $res.Properties["department"][0]
        }
    }
    $services = $services | Sort-Object -Unique

    $null = $C_Service.Items.Add("")
    $E_Service.Items.Clear()
    $null = $E_Service.Items.Add("")

    foreach ($service in $services) {
        $null = $C_Service.Items.Add($service)
        $null = $E_Service.Items.Add($service)
    }
    $C_Service.SelectedIndex = 0
    $E_Service.SelectedIndex = 0
}
catch {
    Write-CreateLog "Erreur recuperation services AD (OU Employes)" "ERROR"
}

Write-CreateLog "Connecte en LDAP avec : $($Credential.UserName)" "OK"

# ================================================================
# ONGLET CREATION : LOGIN LIVE + BOUTON CREER
# ================================================================
$C_Prenom.Add_TextChanged({
    if ($C_Prenom.Text -and $C_Nom.Text) {
        $loginTest = Get-UniqueLogin $C_Prenom.Text $C_Nom.Text
        if ($loginTest) { $C_LoginPreview.Text = $loginTest }
        else            { $C_LoginPreview.Text = "Existe deja" }
    }
})

$C_Nom.Add_TextChanged({
    if ($C_Prenom.Text -and $C_Nom.Text) {
        $loginTest = Get-UniqueLogin $C_Prenom.Text $C_Nom.Text
        if ($loginTest) { $C_LoginPreview.Text = $loginTest }
        else            { $C_LoginPreview.Text = "Existe deja" }
    }
})

$C_CreateBtn.Add_Click({

try {

    $C_Overlay.Visibility = "Visible"
    $C_StepProgress.Value = 0

    $prenom = $C_Prenom.Text.Trim()
    $nom    = $C_Nom.Text.Trim().ToUpper()

    $login = Get-UniqueLogin $prenom $nom

    if (-not $login) {
        Write-CreateLog "Impossible de generer un login unique" "ERROR"
        $C_Status.Text = "Impossible de generer un login unique"
        $C_Status.Foreground = [System.Windows.Media.Brushes]::Crimson
        return
    }

    $ouDN   = $C_OU.SelectedItem.Tag
    $OUName = ($ouDN -split ",")[0] -replace "OU="
    $UserDN = "CN=$prenom $nom,$ouDN"

    # STEP 1 : compte AD
    $C_StepText.Text = "Creation compte AD..."
    $C_StepProgress.Value = 1

    $null = New-UserLDAP -ouDN $ouDN `
        -prenom $prenom `
        -nom $nom `
        -login $login `
        -fonction $C_Fonction.Text `
        -service $C_Service.Text `
        -description $C_Description.Text

    Write-CreateLog "----- Debut creation utilisateur -----"
    Write-CreateLog "Nom : $nom"
    Write-CreateLog "Prenom : $prenom"
    Write-CreateLog "Login genere : $login"
    Write-CreateLog "OU selectionnee : $OUName"
    Write-CreateLog "Utilisateur AD cree (LDAP)" "OK"
    Write-CreateLog "UPN : $login@example.org"
    Write-CreateLog "Mot de passe genere : $Global:LastGeneratedPassword" "OK"

    # STEP 2 : groupes
    $C_StepText.Text = "Ajout des groupes..."
    $C_StepProgress.Value = 2

    foreach ($group in $GroupArray) {
        try {
            Add-UserToGroupLDAP $group $UserDN
            Write-CreateLog "Ajout groupe : $group"
        } catch {
            Write-CreateLog "Erreur groupe : $group" "ERROR"
        }
    }

    # STAGIAIRES
    if ($OUName -eq "Stagiaires") {
        try {
            Add-UserToGroupLDAP "Stagiaires" $UserDN
            Write-CreateLog "Utilisateur detecte comme STAGIAIRE" "INFO"
            Write-CreateLog "Ajout groupe Stagiaires" "OK"
        } catch {
            Write-CreateLog "Erreur groupe : Stagiaires" "ERROR"
        }
    }

    # EMPLOYES : groupe GU + dossier + NTFS
    if ($OUName -eq "Employes") {

        $NomNettoye  = ($nom -split "[ -]")[0].ToLower()
        $FirstLetter = $NomNettoye.Substring(0,1)

        switch -regex ($FirstLetter) {
            "^[a-e]" { $UserGroup = "GU-Users_A_E"; $BasePath = "$FSAuth\E$\Users_A_E" }
            "^[f-j]" { $UserGroup = "GU-Users_F_J"; $BasePath = "$FSAuth\F$\Users_F_J" }
            "^[k-o]" { $UserGroup = "GU-Users_K_O"; $BasePath = "$FSAuth\G$\Users_K_O" }
            "^[p-t]" { $UserGroup = "GU-Users_P_T"; $BasePath = "$FSAuth\H$\Users_P_T" }
            "^[u-z]" { $UserGroup = "GU-Users_U_Z"; $BasePath = "$FSAuth\I$\Users_U_Z" }
        }

        try {
            Add-UserToGroupLDAP $UserGroup $UserDN
        } catch {
            Write-CreateLog "Erreur groupe : $UserGroup" "ERROR"
        }

        Write-CreateLog "Utilisateur detecte comme EMPLOYE"
        Write-CreateLog "Lettre detectee : $FirstLetter"
        Write-CreateLog "Groupe attribue : $UserGroup"

        # STEP 3 : dossier
        $C_StepText.Text = "Creation dossier..."
        $C_StepProgress.Value = 3

        $DriveName = "CORPFS"
        if (Get-PSDrive -Name $DriveName -ErrorAction SilentlyContinue) {
            Remove-PSDrive -Name $DriveName -Force
        }

        $null = New-PSDrive -Name $DriveName `
            -PSProvider FileSystem `
            -Root $BasePath `
            -Credential $Credential `
            -ErrorAction Stop

        $FullPath = "${DriveName}:\$login"
        Write-CreateLog "Chemin dossier : $BasePath\$login"

        if (-not (Test-Path $FullPath)) {
            New-Item $FullPath -ItemType Directory | Out-Null
        }
        Write-CreateLog "Dossier cree avec succes" "OK"

        # STEP 4 : ACL
        $C_StepText.Text = "Droits..."
        $C_StepProgress.Value = 4
        Write-CreateLog "Application droits utilisateur..."
        Write-CreateLog "User : $Domain\$login"

        $maxRetry = 6
        $applied  = $false

        for ($try = 1; $try -le $maxRetry -and -not $applied; $try++) {
            try {
                $Acl = Get-Acl $FullPath
                $Acl.SetAccessRuleProtection($true,$false)

                $UserFull = "$Domain\$login"

                $RuleUser = New-Object System.Security.AccessControl.FileSystemAccessRule(
                    $UserFull,
                    [System.Security.AccessControl.FileSystemRights]::Modify,
                    "ContainerInherit,ObjectInherit","None","Allow")

                $SidAdmins = New-Object System.Security.Principal.SecurityIdentifier("S-1-5-32-544")
                $RuleAdmins = New-Object System.Security.AccessControl.FileSystemAccessRule(
                    $SidAdmins,
                    [System.Security.AccessControl.FileSystemRights]::FullControl,
                    "ContainerInherit,ObjectInherit","None","Allow")

                $SidSystem = New-Object System.Security.Principal.SecurityIdentifier("S-1-5-18")
                $RuleSystem = New-Object System.Security.AccessControl.FileSystemAccessRule(
                    $SidSystem,
                    [System.Security.AccessControl.FileSystemRights]::FullControl,
                    "ContainerInherit,ObjectInherit","None","Allow")

                $Acl.Access | ForEach-Object { $null = $Acl.RemoveAccessRule($_) }
                $Acl.AddAccessRule($RuleUser)
                $Acl.AddAccessRule($RuleAdmins)
                $Acl.AddAccessRule($RuleSystem)

                Set-Acl $FullPath $Acl
                $applied = $true
            }
            catch {
                if ($try -lt $maxRetry) {
                    Write-CreateLog "Compte pas encore resolu par $FS, nouvel essai ($try/$maxRetry)..." "WARN"
                    Start-Sleep -Seconds 5
                } else {
                    throw
                }
            }
        }

        Write-CreateLog "Droits NTFS appliques au user" "OK"
        Write-CreateLog "Admins + SYSTEM OK"

        Remove-PSDrive -Name $DriveName -Force -ErrorAction SilentlyContinue
    }

    Write-CreateLog "----- Fin creation utilisateur -----"

    $C_Status.Text = "Compte utilisateur cree"
    $C_Status.Foreground = [System.Windows.Media.Brushes]::ForestGreen

}
catch {
    Write-CreateLog "ERREUR : $_" "ERROR"
}
finally {
    $C_Overlay.Visibility = "Collapsed"
    Remove-PSDrive -Name "CORPFS" -Force -ErrorAction SilentlyContinue
}

})

# ================================================================
# ONGLET MODIFICATION : CHARGER + ENREGISTRER
# ================================================================

# --- Autocompletion du champ Login ---
$Global:ESuppressSuggest = $false

function Close-ESuggest {
    $E_SuggestPopup.IsOpen = $false
    $E_Suggest.ItemsSource = $null
}

function Apply-ESuggest {
    param($item)
    if (-not $item) { return }
    $Global:ESuppressSuggest = $true
    $E_Login.Text = $item.Login
    $E_Login.CaretIndex = $E_Login.Text.Length
    $Global:ESuppressSuggest = $false
    Close-ESuggest
    # chargement automatique du compte selectionne
    $E_LoadBtn.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Button]::ClickEvent)))
}

$E_Login.Add_TextChanged({
    if ($Global:ESuppressSuggest) { return }

    $term = $E_Login.Text
    if (-not $term -or $term.Trim().Length -lt 2) {
        Close-ESuggest
        return
    }

    $matches = @(Search-UsersLDAP $term)

    if ($matches.Count -eq 0) {
        Close-ESuggest
        return
    }

    $E_Suggest.ItemsSource = $matches
    $E_SuggestPopup.IsOpen = $true
})

# Clic sur une suggestion : on applique DES L'APPUI (avant toute bascule de focus),
# en lisant l'element reellement clique par hit-test (pas SelectedItem)
$E_Suggest.Add_PreviewMouseLeftButtonDown({
    param($s,$e)

    $dep = $e.OriginalSource
    while ($dep -and -not ($dep -is [System.Windows.Controls.ListBoxItem])) {
        if ($dep -is [System.Windows.Media.Visual]) {
            $dep = [System.Windows.Media.VisualTreeHelper]::GetParent($dep)
        } else {
            break
        }
    }

    if ($dep -is [System.Windows.Controls.ListBoxItem]) {
        $item = $E_Suggest.ItemContainerGenerator.ItemFromContainer($dep)
        if ($item) {
            $e.Handled = $true
            Apply-ESuggest $item
        }
    }
})

# Navigation clavier (le focus reste dans le champ : les items ne sont pas focusables)
$E_Login.Add_PreviewKeyDown({
    param($s,$e)

    if (-not $E_SuggestPopup.IsOpen) { return }
    if ($E_Suggest.Items.Count -eq 0) { return }

    switch ($e.Key) {
        "Down" {
            $i = $E_Suggest.SelectedIndex + 1
            if ($i -ge $E_Suggest.Items.Count) { $i = $E_Suggest.Items.Count - 1 }
            $E_Suggest.SelectedIndex = $i
            $E_Suggest.ScrollIntoView($E_Suggest.SelectedItem)
            $e.Handled = $true
        }
        "Up" {
            $i = $E_Suggest.SelectedIndex - 1
            if ($i -lt 0) { $i = 0 }
            $E_Suggest.SelectedIndex = $i
            $E_Suggest.ScrollIntoView($E_Suggest.SelectedItem)
            $e.Handled = $true
        }
        "Enter" {
            $sel = if ($E_Suggest.SelectedItem) { $E_Suggest.SelectedItem } else { $E_Suggest.Items[0] }
            Apply-ESuggest $sel
            $e.Handled = $true
        }
        "Escape" {
            Close-ESuggest
            $e.Handled = $true
        }
    }
})

# Fermeture quand le champ perd le focus, SAUF si la souris est sur la liste
# (au moment d'un clic sur une suggestion, la souris est au-dessus -> on ne ferme pas)
$E_Login.Add_LostKeyboardFocus({
    param($s,$e)
    if ($E_Suggest.IsMouseOver -or $E_SuggestPopup.IsMouseOver) { return }
    Close-ESuggest
})

$E_LoadBtn.Add_Click({

    Close-ESuggest

    $E_LogBox.Document.Blocks.Clear()
    $E_LastLogon.Text  = "Derniere connexion : -"
    $E_PwdLastSet.Text = "Dernier changement MDP : -"

    $login = $E_Login.Text.Trim()
    if (-not $login) {
        Write-EditLog "Login vide" "ERROR"
        return
    }

    $result = Get-UserLDAP $login
    if (-not $result) {
        Write-EditLog "Utilisateur introuvable" "ERROR"
        return
    }

    $user = New-Object DirectoryServices.DirectoryEntry(
        $result.Path,
        $Credential.UserName,
        $Credential.GetNetworkCredential().Password
    )

    $p = $result.Properties

    # OU selection
    foreach ($item in $E_OU.Items) {
        if ($item.Tag -eq $p.distinguishedname[0].Substring($p.distinguishedname[0].IndexOf("OU="))) {
            $E_OU.SelectedItem = $item
        }
    }

    $E_Prenom.Text      = Get-Value $p.givenname
    $E_Nom.Text         = Get-Value $p.sn
    $E_Fonction.Text    = Get-Value $p.title
    $E_Service.Text     = Get-Value $p.department
    $E_Description.Text = Get-Value $p.description
    $E_Telephone.Text   = Get-Value $p.telephonenumber
    $E_Mobile.Text      = Get-Value $p.mobile

    $Global:OldValues = @{
        GivenName   = "$(Get-Value $p.givenname)"
        Surname     = "$(Get-Value $p.sn)"
        Title       = "$(Get-Value $p.title)"
        Department  = "$(Get-Value $p.department)"
        Description = "$(Get-Value $p.description)"
        Telephone   = "$(Get-Value $p.telephonenumber)"
        Mobile      = "$(Get-Value $p.mobile)"
    }

    $E_UserDisplay.Text = "$(Get-Value $p.givenname) $(Get-Value $p.sn)"

    # Derniere connexion (valeur exacte via lastLogon sur tous les DC,
    # repli sur lastLogonTimestamp si indisponible) + dernier changement MDP
    $ll = Get-TrueLastLogon $p.distinguishedname[0]
    if (-not $ll -and $p.lastlogontimestamp.Count) {
        $ll = Convert-ADFileTime $p.lastlogontimestamp[0]
    }
    if ($ll) {
        $E_LastLogon.Text = "Derniere connexion : $($ll.ToString('dd/MM/yyyy HH:mm'))"
    } else {
        $E_LastLogon.Text = "Derniere connexion : jamais / inconnue"
    }

    $mustChange = ($p.pwdlastset.Count -and [Int64]$p.pwdlastset[0] -eq 0)
    $pls = if ($p.pwdlastset.Count) { Convert-ADFileTime $p.pwdlastset[0] } else { $null }
    if ($mustChange) {
        $E_PwdLastSet.Text = "Dernier changement MDP : doit changer a la prochaine connexion"
    } elseif ($pls) {
        $E_PwdLastSet.Text = "Dernier changement MDP : $($pls.ToString('dd/MM/yyyy HH:mm'))"
    } else {
        $E_PwdLastSet.Text = "Dernier changement MDP : -"
    }

    $dn = $p.distinguishedname[0]
    $E_BadgeBorder.Visibility = "Visible"
    if ($dn -match "Stagiaires") {
        $E_UserBadge.Text = "STAGIAIRE"
        $E_BadgeBorder.Background = [System.Windows.Media.Brushes]::OrangeRed
    } else {
        $E_UserBadge.Text = "EMPLOYE"
        $E_BadgeBorder.Background = [System.Windows.Media.Brushes]::ForestGreen
    }

    $Global:CurrentUserEntry = $user

    # Groupes de securite (memberOf)
    $E_GroupsList.Items.Clear()
    $grps = Get-UserGroups $user | Sort-Object Name
    if ($grps.Count -eq 0) {
        $null = $E_GroupsList.Items.Add("(aucun groupe secondaire)")
    } else {
        foreach ($g in $grps) { $null = $E_GroupsList.Items.Add($g.Name) }
    }

    Write-EditLog "Utilisateur charge ($($grps.Count) groupe(s))" "OK"
})

$E_SaveBtn.Add_Click({

    if (-not $Global:CurrentUserEntry) {
        Write-EditLog "Aucun utilisateur charge" "ERROR"
        return
    }

    $hasChange = $false

    if ("$($Global:OldValues.GivenName)"  -ne "$($E_Prenom.Text)")     { Write-EditLog "Prenom : $($Global:OldValues.GivenName) -> $($E_Prenom.Text)" "ACTION"; $hasChange = $true }
    if ("$($Global:OldValues.Surname)"    -ne "$($E_Nom.Text)")        { Write-EditLog "Nom : $($Global:OldValues.Surname) -> $($E_Nom.Text)" "ACTION"; $hasChange = $true }
    if ("$($Global:OldValues.Title)"      -ne "$($E_Fonction.Text)")   { Write-EditLog "Fonction : $($Global:OldValues.Title) -> $($E_Fonction.Text)" "ACTION"; $hasChange = $true }
    if ("$($Global:OldValues.Department)" -ne "$($E_Service.Text)")    { Write-EditLog "Service : $($Global:OldValues.Department) -> $($E_Service.Text)" "ACTION"; $hasChange = $true }
    if ("$($Global:OldValues.Telephone)"  -ne "$($E_Telephone.Text)")  { Write-EditLog "Telephone : $($Global:OldValues.Telephone) -> $($E_Telephone.Text)" "ACTION"; $hasChange = $true }
    if ("$($Global:OldValues.Mobile)"     -ne "$($E_Mobile.Text)")     { Write-EditLog "Mobile : $($Global:OldValues.Mobile) -> $($E_Mobile.Text)" "ACTION"; $hasChange = $true }
    if ("$($Global:OldValues.Description)" -ne "$($E_Description.Text)"){ Write-EditLog "Description modifiee" "ACTION"; $hasChange = $true }

    $data = @{
        GivenName   = $E_Prenom.Text
        Surname     = $E_Nom.Text
        Title       = $E_Fonction.Text
        Department  = $E_Service.Text
        Description = $E_Description.Text
        Telephone   = $E_Telephone.Text
        Mobile      = $E_Mobile.Text
    }

    $ok = Set-UserLDAP $Global:CurrentUserEntry $data

    if ($ok) { Write-EditLog "Modification appliquee dans l'AD" "OK" }
    else     { Write-EditLog "Erreur modification" "ERROR" }

    if (-not $hasChange) { Write-EditLog "Aucune modification detectee" "WARN" }
})

# --- Mot de passe oublie (reset sur un mot de passe temporaire) ---
$E_ResetPwdBtn.Add_Click({

    if (-not $Global:CurrentUserEntry) {
        Write-EditLog "Chargez d'abord un utilisateur" "ERROR"
        return
    }

    try {
        Set-UserPassword $Global:CurrentUserEntry $TempPassword

        # Coche "L'utilisateur doit changer le mot de passe a la prochaine ouverture de session"
        try {
            $Global:CurrentUserEntry.Properties["pwdLastSet"].Value = 0
            $Global:CurrentUserEntry.SetInfo()
            Write-EditLog "Mot de passe reinitialise : $TempPassword (changement force a la prochaine connexion)" "OK"
        }
        catch {
            Write-EditLog "Mot de passe reinitialise : $TempPassword" "OK"
            Write-EditLog "Impossible de forcer le changement a la prochaine connexion : $($_.Exception.Message)" "WARN"
        }
    }
    catch {
        Write-EditLog "Erreur reinitialisation : $($_.Exception.Message)" "ERROR"
    }
})

# ================================================================
# ONGLET SORTIE : RETRAIT GROUPES + MOT DE PASSE TEMPORAIRE
# ================================================================
function Update-SortieGroups {
    $S_GroupsList.Items.Clear()

    if (-not $Global:SortieUserEntry) { return }

    $Global:SortieUserEntry.RefreshCache()
    $groups = Get-UserGroups $Global:SortieUserEntry | Sort-Object Name

    if ($groups.Count -eq 0) {
        $null = $S_GroupsList.Items.Add("(aucun groupe secondaire - uniquement le groupe primaire)")
    } else {
        foreach ($g in $groups) {
            $null = $S_GroupsList.Items.Add($g.Name)
        }
    }
}

$S_LoadBtn.Add_Click({

    $S_LogBox.Document.Blocks.Clear()
    $S_GroupsList.Items.Clear()
    $Global:SortieUserEntry = $null

    $login = $S_Login.Text.Trim()
    if (-not $login) {
        Write-SortieLog "Login vide" "ERROR"
        return
    }

    $result = Get-UserLDAP $login
    if (-not $result) {
        $S_UserDisplay.Text = "Aucun utilisateur charge"
        $S_UserSub.Text = "Utilisateur introuvable"
        Write-SortieLog "Utilisateur introuvable : $login" "ERROR"
        return
    }

    $user = New-Object DirectoryServices.DirectoryEntry(
        $result.Path,
        $Credential.UserName,
        $Credential.GetNetworkCredential().Password
    )

    $Global:SortieUserEntry = $user

    $p = $result.Properties
    $S_UserDisplay.Text = "$(Get-Value $p.givenname) $(Get-Value $p.sn)"
    $S_UserSub.Text = "$login"

    Update-SortieGroups

    $nb = (Get-UserGroups $user).Count
    Write-SortieLog "Utilisateur charge : $login ($nb groupe(s))" "OK"
})

$S_ProcessBtn.Add_Click({

    if (-not $Global:SortieUserEntry) {
        Write-SortieLog "Chargez d'abord un utilisateur" "ERROR"
        return
    }

    $nom = $S_UserDisplay.Text

    $confirm = [System.Windows.MessageBox]::Show(
        "Confirmer la sortie de :`n`n$nom`n`n" +
        "- retrait de TOUS les groupes (sauf Utilisateurs du domaine)`n" +
        "- mot de passe remis a '$TempPassword'`n`n" +
        "Cette action est irreversible.",
        "Confirmation de sortie","YesNo","Warning")

    if ($confirm -ne "Yes") {
        Write-SortieLog "Sortie annulee" "WARN"
        return
    }

    Write-SortieLog "----- Debut sortie : $nom -----"

    # 1) Retrait des groupes
    try {
        $res = Remove-AllUserGroups $Global:SortieUserEntry

        foreach ($g in $res.Removed) { Write-SortieLog "Groupe retire : $g" "ACTION" }
        foreach ($g in $res.Kept)    { Write-SortieLog "Groupe conserve : $g" }
        foreach ($e in $res.Errors)  { Write-SortieLog "Erreur groupe : $e" "ERROR" }

        Write-SortieLog "$($res.Removed.Count) groupe(s) retire(s)" "OK"
    }
    catch {
        Write-SortieLog "Erreur lors du retrait des groupes : $($_.Exception.Message)" "ERROR"
    }

    # 2) Mot de passe temporaire
    try {
        Set-UserPassword $Global:SortieUserEntry $TempPassword
        Write-SortieLog "Mot de passe remis a : $TempPassword" "OK"
    }
    catch {
        Write-SortieLog "Erreur mot de passe : $($_.Exception.Message)" "ERROR"
    }

    Update-SortieGroups
    Write-SortieLog "----- Fin sortie -----" "OK"
})

# --- Desactiver le compte ---
$S_BtnDisable.Add_Click({

    if (-not $Global:SortieUserEntry) {
        Write-SortieLog "Chargez d'abord un utilisateur" "ERROR"
        return
    }

    $nom = $S_UserDisplay.Text
    $confirm = [System.Windows.MessageBox]::Show(
        "Desactiver le compte de :`n`n$nom ?",
        "Desactivation du compte","YesNo","Warning")

    if ($confirm -ne "Yes") { return }

    try {
        # bit 2 = ACCOUNTDISABLE
        $uac = [int]$Global:SortieUserEntry.Properties["userAccountControl"].Value
        $Global:SortieUserEntry.Properties["userAccountControl"].Value = ($uac -bor 2)
        $Global:SortieUserEntry.SetInfo()
        Write-SortieLog "Compte DESACTIVE" "OK"
    }
    catch {
        Write-SortieLog "Erreur desactivation : $($_.Exception.Message)" "ERROR"
    }
})

# ================================================================
# ONGLET DOSSIERS : SCAN + CREATION
# ================================================================
$global:Users        = @()
$global:CreatedCount = 0
$global:Exclusions   = Get-Exclusions

function Update-FolderCounts {
    $F_TxtTotal.Text    = $global:Users.Count
    $F_TxtMissing.Text  = @($global:Users | Where-Object { $_.Statut -eq "Absent" }).Count
    $F_TxtCreated.Text  = $global:CreatedCount
    $F_TxtExcluded.Text = @($global:Users | Where-Object { $_.Statut -eq "Exclu" }).Count
}

function Invoke-FolderScan {

    Write-FolderLog "Scan AD en cours..."
    $global:Users = @()
    $global:Exclusions = Get-Exclusions

    $Searcher = New-Object DirectoryServices.DirectorySearcher
    $Searcher.SearchRoot = New-Object DirectoryServices.DirectoryEntry(
        "LDAP://$OUEmployes",
        $Credential.UserName,
        $Credential.GetNetworkCredential().Password
    )
    $Searcher.Filter = "(objectClass=user)"
    $Searcher.PageSize = 1000
    $null = $Searcher.PropertiesToLoad.Add("sn")
    $null = $Searcher.PropertiesToLoad.Add("sAMAccountName")

    $results = $Searcher.FindAll()

    $F_ProgressBar.Maximum = $results.Count
    $F_ProgressBar.Value = 0

    foreach ($User in $results) {

        if ($User.Properties["sn"].Count -eq 0 -or $User.Properties["samaccountname"].Count -eq 0) {
            continue
        }

        $Nom   = $User.Properties["sn"][0]
        $Login = $User.Properties["samaccountname"][0]

        $FolderName  = $Login.ToLower()
        $NomNettoye  = ($Nom -split "[- ]")[0].ToLower()
        $FirstLetter = $NomNettoye.Substring(0,1)

        switch -regex ($FirstLetter) {
            "^[a-e]" { $BasePath = "$FSAuth\E$\Users_A_E" }
            "^[f-j]" { $BasePath = "$FSAuth\F$\Users_F_J" }
            "^[k-o]" { $BasePath = "$FSAuth\G$\Users_K_O" }
            "^[p-t]" { $BasePath = "$FSAuth\H$\Users_P_T" }
            "^[u-z]" { $BasePath = "$FSAuth\I$\Users_U_Z" }
            default  { continue }
        }

        $FullPath = Join-Path $BasePath $FolderName
        # Verification fiable (evite le faux positif de Test-Path sur un PSDrive credential)
        $exists = [System.IO.Directory]::Exists($FullPath)

        if ($global:Exclusions.Contains($Login)) {
            $statut = "Exclu"
        } elseif ($exists) {
            $statut = "OK"
        } else {
            $statut = "Absent"
        }

        $global:Users += [PSCustomObject]@{
            Login  = $Login
            Nom    = $Nom
            Path   = $FullPath
            Exists = $exists
            Statut = $statut
        }

        $F_ProgressBar.Value++
    }

    $F_DGUsers.ItemsSource = $global:Users
    Update-FolderCounts

    $nbOK  = @($global:Users | Where-Object { $_.Statut -eq "OK" }).Count
    $nbAbs = @($global:Users | Where-Object { $_.Statut -eq "Absent" }).Count
    Write-FolderLog "Scan termine : $($global:Users.Count) utilisateurs, $nbOK avec dossier, $nbAbs sans dossier"
}

function New-UserFolder($user) {
    try {
        New-Item -Path $user.Path -ItemType Directory -Force | Out-Null

        $Acl = Get-Acl $user.Path
        $Acl.SetAccessRuleProtection($true,$false)

        $UserFull = "$Domain\$($user.Login)"

        $RuleUser = New-Object System.Security.AccessControl.FileSystemAccessRule(
            $UserFull,"Modify","ContainerInherit,ObjectInherit","None","Allow")

        # BUILTIN\Administrators via SID (identique quelle que soit la langue du serveur)
        $SidAdmins  = New-Object System.Security.Principal.SecurityIdentifier("S-1-5-32-544")
        $RuleAdmins = New-Object System.Security.AccessControl.FileSystemAccessRule(
            $SidAdmins,"FullControl","ContainerInherit,ObjectInherit","None","Allow")

        $Acl.SetAccessRule($RuleUser)
        $Acl.AddAccessRule($RuleAdmins)

        Set-Acl $user.Path $Acl

        $user.Statut = "Cree"
        $global:CreatedCount++

        Write-FolderLog "$($user.Login) cree"
    }
    catch {
        Write-FolderLog "Erreur $($user.Login) : $($_.Exception.Message)"
    }
}

$F_BtnScan.Add_Click({ Invoke-FolderScan })

$F_BtnCreate.Add_Click({
    foreach ($user in $F_DGUsers.SelectedItems) {
        if ($user.Statut -eq "Absent") { New-UserFolder $user; $user.Exists = $true }
    }
    $F_DGUsers.Items.Refresh()
    Update-FolderCounts
})

$F_BtnAuto.Add_Click({
    foreach ($user in $global:Users) {
        if ($user.Statut -eq "Absent") { New-UserFolder $user; $user.Exists = $true }
    }
    $F_DGUsers.Items.Refresh()
    Update-FolderCounts
    Write-FolderLog "Creation automatique terminee"
})

# Exclure la selection (ces personnes n'ont pas besoin de dossier)
$F_BtnExclude.Add_Click({
    $sel = @($F_DGUsers.SelectedItems)
    if ($sel.Count -eq 0) {
        Write-FolderLog "Selectionnez d'abord une ou plusieurs lignes a exclure"
        return
    }

    foreach ($user in $sel) {
        [void]$global:Exclusions.Add($user.Login)
        $user.Statut = "Exclu"
    }

    if (Save-Exclusions) {
        Write-FolderLog "$($sel.Count) personne(s) exclue(s) (dossier non requis)"
    } else {
        Write-FolderLog "Exclusions appliquees mais ECHEC d'enregistrement du fichier partage"
    }

    $F_DGUsers.Items.Refresh()
    Update-FolderCounts
})

# Reintegrer la selection (retire de la liste d'exclusion)
$F_BtnInclude.Add_Click({
    $sel = @($F_DGUsers.SelectedItems)
    if ($sel.Count -eq 0) {
        Write-FolderLog "Selectionnez d'abord une ou plusieurs lignes a reintegrer"
        return
    }

    foreach ($user in $sel) {
        [void]$global:Exclusions.Remove($user.Login)
        $user.Statut = $(if ($user.Exists) { "OK" } else { "Absent" })
    }

    if (Save-Exclusions) {
        Write-FolderLog "$($sel.Count) personne(s) reintegree(s)"
    } else {
        Write-FolderLog "Reintegration appliquee mais ECHEC d'enregistrement du fichier partage"
    }

    $F_DGUsers.Items.Refresh()
    Update-FolderCounts
})

# ================================================================
# ONGLET VERIF PC
# ================================================================

# --- Autocompletion du champ PC ---
$Global:PSuppressSuggest = $false

function Close-PSuggest {
    $P_SuggestPopup.IsOpen = $false
    $P_Suggest.ItemsSource = $null
}

function Apply-PSuggest {
    param($item)
    if (-not $item) { return }
    $Global:PSuppressSuggest = $true
    $P_TxtPCName.Text = $item.Name
    $P_TxtPCName.CaretIndex = $P_TxtPCName.Text.Length
    $Global:PSuppressSuggest = $false
    Close-PSuggest
    # verification automatique du poste choisi
    $P_BtnCheck.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Button]::ClickEvent)))
}

$P_TxtPCName.Add_TextChanged({
    if ($Global:PSuppressSuggest) { return }

    $term = $P_TxtPCName.Text
    if (-not $term -or $term.Trim().Length -lt 2) {
        Close-PSuggest
        return
    }

    $matches = @(Search-ComputersLDAP $term)
    if ($matches.Count -eq 0) {
        Close-PSuggest
        return
    }

    $P_Suggest.ItemsSource = $matches
    $P_SuggestPopup.IsOpen = $true
})

$P_Suggest.Add_PreviewMouseLeftButtonDown({
    param($s,$e)
    $dep = $e.OriginalSource
    while ($dep -and -not ($dep -is [System.Windows.Controls.ListBoxItem])) {
        if ($dep -is [System.Windows.Media.Visual]) {
            $dep = [System.Windows.Media.VisualTreeHelper]::GetParent($dep)
        } else { break }
    }
    if ($dep -is [System.Windows.Controls.ListBoxItem]) {
        $item = $P_Suggest.ItemContainerGenerator.ItemFromContainer($dep)
        if ($item) {
            $e.Handled = $true
            Apply-PSuggest $item
        }
    }
})

$P_TxtPCName.Add_PreviewKeyDown({
    param($s,$e)
    if (-not $P_SuggestPopup.IsOpen) { return }
    if ($P_Suggest.Items.Count -eq 0) { return }

    switch ($e.Key) {
        "Down" {
            $i = $P_Suggest.SelectedIndex + 1
            if ($i -ge $P_Suggest.Items.Count) { $i = $P_Suggest.Items.Count - 1 }
            $P_Suggest.SelectedIndex = $i
            $P_Suggest.ScrollIntoView($P_Suggest.SelectedItem)
            $e.Handled = $true
        }
        "Up" {
            $i = $P_Suggest.SelectedIndex - 1
            if ($i -lt 0) { $i = 0 }
            $P_Suggest.SelectedIndex = $i
            $P_Suggest.ScrollIntoView($P_Suggest.SelectedItem)
            $e.Handled = $true
        }
        "Enter" {
            $sel = if ($P_Suggest.SelectedItem) { $P_Suggest.SelectedItem } else { $P_Suggest.Items[0] }
            Apply-PSuggest $sel
            $e.Handled = $true
        }
        "Escape" {
            Close-PSuggest
            $e.Handled = $true
        }
    }
})

$P_TxtPCName.Add_LostKeyboardFocus({
    param($s,$e)
    if ($P_Suggest.IsMouseOver -or $P_SuggestPopup.IsMouseOver) { return }
    Close-PSuggest
})

$P_BtnCheck.Add_Click({

    Close-PSuggest

    $pc = $P_TxtPCName.Text.Trim()

    $P_ResultCard.Visibility  = "Visible"
    $P_BadgeBorder.Visibility = "Collapsed"
    $P_BtnDeletePC.Visibility = "Collapsed"
    $P_BtnLastUser.Visibility = "Collapsed"
    $P_LastUser.Text = ""
    $Global:PCheckDN = $null
    $Global:PCheckName = $null
    $P_Detail.Text = ""

    if (-not $pc) {
        $P_TxtResult.Text = "Entre un nom de PC"
        $P_TxtResult.Foreground = "Orange"
        return
    }

    $result = Test-PCInAD -PCName $pc
    $P_TxtResult.Text = $result.Message

    # PC introuvable ou erreur
    if (-not $result.Found) {
        $P_TxtResult.Foreground = "#F87171"
        return
    }

    $P_TxtResult.Foreground = "#4ADE80"

    # Memorise le poste trouve (pour suppression eventuelle)
    $Global:PCheckDN   = $result.DN
    $Global:PCheckName = $pc

    # Vraie derniere connexion (lastLogon sur tous les DC), repli sur la valeur repliquee
    $trueLL = Get-TrueLastLogon $result.DN
    if ($trueLL) {
        $result.LastLogon = $trueLL
        $result.Days = [int]((Get-Date) - $trueLL).TotalDays
    }

    # Badge ACTIF / INACTIF
    $P_BadgeBorder.Visibility = "Visible"
    if ($result.Inactive) {
        $P_Badge.Text = "PC INACTIF"
        $P_BadgeBorder.Background = [System.Windows.Media.Brushes]::OrangeRed
    } else {
        $P_Badge.Text = "PC ACTIF"
        $P_BadgeBorder.Background = [System.Windows.Media.Brushes]::ForestGreen
    }

    # Details
    $lignes = @()

    if ($result.Enabled) { $lignes += "Compte : active" }
    else                 { $lignes += "Compte : DESACTIVE" }

    if ($result.LastLogon) {
        $d = $result.LastLogon.ToString("dd/MM/yyyy HH:mm")
        $lignes += "Derniere connexion : $d  (il y a $($result.Days) j)"
    } else {
        $lignes += "Derniere connexion : jamais / inconnue"
    }

    if ($result.OS) { $lignes += "OS : $($result.OS)" }

    if ($result.Inactive) {
        $lignes += "-> Poste inactif (seuil : $InactivePCDays jours)"
    }

    $P_Detail.Text = ($lignes -join "`n")

    # Boutons disponibles si on a le DN
    if ($Global:PCheckDN) {
        $P_BtnDeletePC.Visibility = "Visible"
        $P_BtnLastUser.Visibility = "Visible"
    }
})

# --- Dernier utilisateur connecte sur le poste ---
$P_BtnLastUser.Add_Click({
    if (-not $Global:PCheckName) { return }

    $P_LastUser.Text = "Recherche du dernier utilisateur sur $($Global:PCheckName)..."
    $P_BtnLastUser.IsEnabled = $false
    $Window.Dispatcher.Invoke([action]{}, "Render")

    $r = Get-LastLoggedOnUser $Global:PCheckName

    $P_BtnLastUser.IsEnabled = $true

    if ($r.User) {
        $P_LastUser.Text = "Dernier utilisateur : $($r.User)  ($($r.Info))"
        $P_LastUser.Foreground = [System.Windows.Media.Brushes]::LightSkyBlue
    } else {
        $P_LastUser.Text = $r.Reason
        $P_LastUser.Foreground = [System.Windows.Media.Brushes]::Orange
    }
})

# --- Suppression du poste recherche ---
$P_BtnDeletePC.Add_Click({

    if (-not $Global:PCheckDN) {
        return
    }

    $confirm = [System.Windows.MessageBox]::Show(
        "Supprimer DEFINITIVEMENT ce poste de l'Active Directory ?`n`n" +
        "$($Global:PCheckName)`n`nCette action est irreversible.",
        "Confirmation de suppression","YesNo","Warning")

    if ($confirm -ne "Yes") { return }

    try {
        $comp = Get-LDAPRoot "LDAP://$($Global:PCheckDN)"
        $comp.DeleteTree()

        $P_TxtResult.Text = "Poste supprime de l'AD"
        $P_TxtResult.Foreground = "#F87171"
        $P_BadgeBorder.Visibility = "Collapsed"
        $P_Detail.Text = "$($Global:PCheckName) a ete supprime."
        $P_BtnDeletePC.Visibility = "Collapsed"
        $Global:PCheckDN = $null
    }
    catch {
        [System.Windows.MessageBox]::Show(
            "Echec de la suppression :`n`n$($_.Exception.Message)",
            "Suppression","OK","Error") | Out-Null
    }
})

# --- Scan des postes inactifs (filtre 90 / 180 / 365 / 540 jours) ---
function Get-SelectedInactiveDays {
    if ($P_Seg180.IsChecked) { return 180 }
    if ($P_Seg365.IsChecked) { return 365 }
    if ($P_Seg540.IsChecked) { return 540 }
    return 90
}

function Invoke-InactiveScan {
    $days = Get-SelectedInactiveDays

    $P_InactiveCount.Text = "Scan en cours..."
    $P_ProgressBar.IsIndeterminate = $true
    $P_BtnScanInactive.IsEnabled = $false
    $P_BtnDeleteInactive.IsEnabled = $false
    $Window.Dispatcher.Invoke([action]{}, "Render")

    try {
        $items = @(Get-InactivePCs -Days $days)
        $P_DGInactive.ItemsSource = $items

        $n = $items.Count
        if ($n -eq 0) {
            $P_InactiveCount.Text = "Aucun poste inactif depuis plus de $days jours"
        } else {
            $P_InactiveCount.Text = "$n poste(s) inactif(s) depuis plus de $days jours"
        }
    }
    catch {
        $P_InactiveCount.Text = "Erreur lors du scan : $_"
    }
    finally {
        $P_ProgressBar.IsIndeterminate = $false
        $P_BtnScanInactive.IsEnabled = $true
        $P_BtnDeleteInactive.IsEnabled = $true
    }
}

$P_BtnScanInactive.Add_Click({ Invoke-InactiveScan })

# --- Suppression des postes inactifs listes ---
$P_BtnDeleteInactive.Add_Click({

    $items = @($P_DGInactive.ItemsSource)

    if ($items.Count -eq 0) {
        [System.Windows.MessageBox]::Show(
            "Lancez d'abord un scan : aucun poste a supprimer.",
            "Suppression","OK","Information") | Out-Null
        return
    }

    $days = Get-SelectedInactiveDays

    # Confirmation (action irreversible)
    $confirm = [System.Windows.MessageBox]::Show(
        "Vous allez SUPPRIMER DEFINITIVEMENT de l'Active Directory " +
        "$($items.Count) poste(s) inactif(s) depuis plus de $days jours.`n`n" +
        "Cette action est IRREVERSIBLE.`n`nContinuer ?",
        "Confirmation de suppression","YesNo","Warning")

    if ($confirm -ne "Yes") { return }

    $P_ProgressBar.IsIndeterminate = $true
    $P_BtnDeleteInactive.IsEnabled = $false
    $P_BtnScanInactive.IsEnabled = $false
    $P_InactiveCount.Text = "Suppression en cours..."
    $Window.Dispatcher.Invoke([action]{}, "Render")

    $deleted = 0
    $errors  = @()

    foreach ($it in $items) {
        if (-not $it.DN) { continue }
        try {
            $comp = Get-LDAPRoot "LDAP://$($it.DN)"
            $comp.DeleteTree()
            $deleted++
        }
        catch {
            $errors += "$($it.Nom) : $($_.Exception.Message)"
        }
    }

    $P_ProgressBar.IsIndeterminate = $false
    $P_BtnDeleteInactive.IsEnabled = $true
    $P_BtnScanInactive.IsEnabled = $true

    $msg = "$deleted poste(s) supprime(s)."
    if ($errors.Count -gt 0) {
        $msg += "`n`n$($errors.Count) echec(s) :`n" + (($errors | Select-Object -First 15) -join "`n")
        if ($errors.Count -gt 15) { $msg += "`n..." }
    }
    [System.Windows.MessageBox]::Show($msg,"Suppression terminee","OK",
        $(if ($errors.Count -gt 0) { "Warning" } else { "Information" })) | Out-Null

    # Rafraichit la liste
    Invoke-InactiveScan
})

# ================================================================
# AFFICHAGE + NETTOYAGE
# ================================================================
$Window.Add_ContentRendered({
    $Window.Activate()
    $Window.Topmost = $false   # ne reste pas toujours au-dessus apres l'ouverture
})

$UIReady = $true

# Force l'affichage au premier plan a l'ouverture
$Window.Topmost = $true
$Window.WindowState = "Normal"
$null = $Window.Activate()

$Window.ShowDialog() | Out-Null

# Nettoyage des lecteurs montes au lancement
foreach ($name in $FSDrives.Keys) {
    Remove-PSDrive -Name $name -Force -ErrorAction SilentlyContinue
}
Remove-PSDrive -Name "CORPFS" -Force -ErrorAction SilentlyContinue