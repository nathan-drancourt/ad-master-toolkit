# 🗂️ MASTER AD — Outil d'administration Active Directory

> Application PowerShell **à interface graphique** (WPF) regroupant les tâches courantes d'administration Active Directory : création et modification de comptes, procédure de sortie, gestion des dossiers utilisateurs et inventaire des postes.

**Particularité principale : aucun module RSAT requis.** L'outil interroge l'annuaire en **LDAP pur** via `System.DirectoryServices`, ce qui lui permet de fonctionner depuis n'importe quel poste du domaine, sans installation préalable.

---

## ✨ Fonctionnalités

L'outil est organisé en onglets, dans une fenêtre unique :

| Onglet | Rôle |
|--------|------|
| **Création** | Création d'un utilisateur AD : génération intelligente du login, ajout automatique aux groupes, création du dossier personnel et application des droits NTFS |
| **Modification** | Édition d'un compte existant (fonction, service, description, groupes) |
| **Sortie** | Procédure de départ : retrait de tous les groupes sauf le groupe primaire, application d'un mot de passe temporaire |
| **Dossiers** | Scan de l'annuaire et création en masse des dossiers utilisateurs manquants |
| **Vérif PC** | Vérification de la présence d'un poste dans l'AD, dernier utilisateur connecté |
| **PC inactifs** | Détection des postes sans connexion depuis N jours |

---

## 🔑 Points techniques notables

- **LDAP natif, sans RSAT** — `System.DirectoryServices` au lieu du module `ActiveDirectory`. L'outil est portable sur tout poste du domaine.
- **Authentification unique** — les identifiants administrateur sont demandés une seule fois au lancement (`Get-Credential`) puis partagés par tous les onglets. **Aucun mot de passe n'est stocké dans le script.**
- **Contournement de l'erreur système 1219** — Windows interdit deux connexions simultanées au même serveur avec des comptes différents. L'outil se connecte via le **FQDN** plutôt que le nom court : Windows considère alors qu'il s'agit de deux serveurs distincts, ce qui évite le conflit.
- **Génération intelligente du login** — gestion des noms composés et des particules françaises (« de », « du », « de la »…), initiales pour les prénoms composés, et détection des collisions avec les comptes existants.
- **Dernière connexion fiable** — interrogation de **tous les contrôleurs de domaine** pour obtenir le `lastLogon` le plus récent (cet attribut n'étant pas répliqué entre DC).
- **Mots de passe aléatoires** — chaque mot de passe (création, réinitialisation, sortie) est généré aléatoirement avec respect des règles de complexité, puis affiché à l'administrateur dans le journal.

---

## ✅ Prérequis

- **Windows** avec **PowerShell 5.1** (ou supérieur)
- Un poste **membre du domaine**
- Un **compte administrateur** disposant des droits de création/modification dans l'AD
- Les **partages administratifs** accessibles sur le serveur de fichiers (pour l'onglet Dossiers)

> Aucun module complémentaire n'est nécessaire : ni RSAT, ni module `ActiveDirectory`.

---

## 🚀 Installation

1. **Récupérer le script**

   ```powershell
   git clone https://github.com/ImNvthan/ad-master-toolkit.git
   cd ad-master-toolkit
   ```

2. **Créer votre configuration**

   ```powershell
   Copy-Item config.example.ps1 config.ps1
   ```

   Puis éditez `config.ps1` avec les valeurs de **votre** environnement (domaine, OU, serveur de fichiers, groupes).

   > 🔒 `config.ps1` est listé dans le `.gitignore` : votre configuration réelle ne sera jamais publiée.

3. **Lancer l'outil**

   ```powershell
   powershell -ExecutionPolicy Bypass -File .\MasterAD.ps1
   ```

   Une fenêtre demande les identifiants administrateur, puis l'interface s'ouvre.

---

## ⚙️ Configuration

Toutes les valeurs propres à l'environnement sont regroupées dans `config.example.ps1` :

| Variable | Description |
|----------|-------------|
| `$Domain` | Nom NetBIOS du domaine |
| `$BaseDN` | DN racine de l'annuaire |
| `$OUBase` | OU racine des utilisateurs |
| `$OUEmployes` | OU contenant les employés (services + scan dossiers) |
| `$FS` / `$FSHost` | Serveur de fichiers (nom court / FQDN) |
| `$LogoPath` | Chemin du logo affiché dans l'interface |
| `$ExclusionsPath` | Fichier listant les comptes ne nécessitant pas de dossier |
| `$GroupArray` | Groupes ajoutés automatiquement à la création |
| `$KeepGroups` | Groupes conservés lors d'une sortie |

---

## 🔒 Sécurité

- Aucun identifiant ni mot de passe n'est écrit en dur dans le script.
- Les identifiants administrateur sont saisis via `Get-Credential` et conservés uniquement en mémoire pour la durée de la session.
- Les mots de passe utilisateurs sont **générés aléatoirement** (14 caractères, complexité AD respectée).
- La configuration réelle de l'infrastructure est externalisée et exclue du dépôt.

> ⚠️ Cet outil effectue des opérations sensibles sur l'annuaire (création, modification, retrait de groupes). Testez-le dans un environnement de préproduction avant tout usage réel.

---

## 📄 Licence

Distribué sous licence **MIT**. Voir [`LICENSE`](LICENSE).

## 👤 Auteur

**Nathan Drancourt** — Administrateur Systèmes & Réseaux
GitHub : [@ImNvthan](https://github.com/ImNvthan)
