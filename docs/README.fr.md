# Turbo Optimizer : optimiseur, nettoyeur et outil de réparation gratuit pour Windows 10/11

[English](../README.md) | [العربية](README.ar.md) | [Español](README.es.md) | **Français** | [Deutsch](README.de.md) | [Português](README.pt.md) | [Русский](README.ru.md) | [简体中文](README.zh.md) | [हिन्दी](README.hi.md) | [Türkçe](README.tr.md)

Outil open source en PowerShell pour **optimiser, nettoyer et réparer Windows**. Il analyse votre PC, explique ce qui ne va pas et corrige uniquement ce que vous choisissez : démarrage lent, disque C: plein, erreurs de Windows Update, DLL manquantes, problèmes de pilotes, Wi-Fi et Bluetooth qui se coupent. Chaque modification est enregistrée et **réversible**.

Sans installation, sans publicité, sans télémétrie. Collez une ligne dans PowerShell : l'outil se télécharge, s'ouvre dans une fenêtre moderne du navigateur et vous demande ce que vous voulez.

![Résultats du Docteur](ui-doctor-ar.png)

## Fonctions

- **Docteur :** analyse mises à jour, pilotes, DLL, santé des disques, sécurité et journal d'événements, puis corrige ce que vous choisissez.
- **Nettoyeur de PC :** fichiers temporaires, caches de mises à jour et de navigateurs, analyse de l'espace, TRIM pour SSD, suppression des applis préinstallées.
- **Accélérer Windows :** mode d'alimentation performance, gestion du démarrage, services optionnels.
- **Mise à jour et réparation :** applis via winget, SFC et DISM, sauvegarde et restauration des pilotes.
- **Réseau :** correctifs Wi-Fi et Bluetooth, test DNS, contrôle du fichier hosts et du canal Wi-Fi.
- **Sécurité :** pare-feu, SMBv1, Bureau à distance, UAC et Defender désactivable de façon réversible.
- **Sécurité d'abord :** mode test, point de restauration, journal d'annulation.

## Problèmes courants

- **Bluetooth connecté mais pas de son** sous Windows 10 : correctif Bluetooth sans son.
- **Le Wi-Fi se déconnecte ou se bloque :** réinitialisation rapide du Wi-Fi, désactivation de l'économie d'énergie.
- **Disque C: plein et PC lent :** nettoyage, libération d'espace, programmes au démarrage.
- **Windows Update bloqué** ou **DLL manquante** (d3dx9, etc.) : le Docteur s'en occupe.
- **Supprimer le bloatware** et activer ou désactiver Windows Defender de façon réversible.

## Démarrage rapide

```powershell
irm https://raw.githubusercontent.com/Ebnhussein/TurboOpt/main/install.ps1 | iex
```

Ouvrez PowerShell et collez cette ligne. L'outil se télécharge, s'ouvre dans le navigateur et vous demande ce que vous voulez (y compris l'entretien automatique : nettoyage hebdomadaire ou surveillance quotidienne). Essayez d'abord le **mode test**.
