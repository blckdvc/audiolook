# audiolook — LoopLook

Lecteur de **boucles audio** pour macOS, en fenêtre flottante, avec time‑stretch et
transposition de **haute qualité** (moteur Signalsmith Stretch, rendu hors‑ligne).
Pensé pour auditionner et préparer des samples avant de les glisser dans un DAW (Logic…).

![LoopLook — fenêtre principale](docs/screenshot-main.jpg)
![LoopLook — région de boucle A/B](docs/screenshot-loop-ab.jpg)

## Fonctions

- **Forme d'onde** avec tête de lecture ; clic pour se positionner.
- **Boucle A/B** : deux poignées pour délimiter la région bouclée (fondu enchaîné, sans clic).
- **Volume** temps réel.
- **Tempo (BPM)** — détection automatique du tempo ; cale le sample à un BPM cible
  (time‑stretch, hauteur inchangée). BPM source éditable, ou saisie du nombre de temps.
- **Transposition** (−24…+24 demi‑tons) — tempo inchangé.
- **Grille magnétique** : les poignées A/B se calent sur la grille (1/16, 1/8, 1/4, mesure),
  déduite du BPM.
- **Désactiver le traitement** : joue l'original sans re‑rendu.
- **Transparence** réglable de la fenêtre ; **barre de titre masquée**.
- Valeurs saisissables au clavier (champs texte) à côté de chaque réglage.
- Réglages **conservés d'un fichier à l'autre** (volume / tempo / pitch / bypass).
- **Suivi de la sélection du Finder** : sélectionner un fichier audio ouvre et joue LoopLook
  automatiquement ; une sélection non‑audio arrête la lecture.
- **Export vers un DAW** : glisser‑déposer du WAV traité (24 bits) vers n'importe quel DAW
  (ou le Finder), bouton « Rendre… », et **import dans le DAW au premier plan**
  (Logic, Digital Performer…).

## Installation (DMG)

Télécharge [`dist/LoopLook.dmg`](dist/LoopLook.dmg), ouvre‑le et glisse **LoopLook** dans **Applications**.

LoopLook est une app de **barre de menus** (pas d'icône dans le Dock) : après le lancement,
une icône forme d'onde apparaît en haut à droite. Sélectionne un fichier audio dans le Finder
(il s'ouvre tout seul), ou appuie sur **⌥Espace**.

> App signée en ad hoc (pas de compte développeur). Au premier lancement, autorise‑la via
> clic droit › Ouvrir si Gatekeeper la bloque.

## Raccourcis

| Touche | Action |
|---|---|
| ⌥Espace | Ouvrir la sélection du Finder |
| Espace | Lecture / pause |
| L | Boucle on/off |
| ←/→ | Fichier précédent / suivant du dossier |
| Échap | Fermer la fenêtre |

## Export vers un DAW

- **Glisser vers un DAW / Finder** : tire la pastille dans l'arrangement de ton DAW (ou le Finder).
- **Rendre…** : écrit le WAV traité et le révèle dans le Finder.
- **Importer dans le DAW** : import automatique dans le DAW **au premier plan** (celui utilisé juste
  avant de cliquer — Logic, Digital Performer…). LoopLook repère une commande d'import audio dans
  le menu de l'app et y saisit le fichier ; nécessite d'autoriser LoopLook dans
  *Réglages Système › Confidentialité et sécurité › Accessibilité*. Selon le DAW, le glisser‑déposer
  reste la méthode la plus fiable.
- Case **Région A/B** : limite l'export/le glisser à la région bouclée.

## Compilation (sans Xcode)

Les **Command Line Tools** suffisent :

```bash
./build.sh
```

Le script compile le pont C++ (Signalsmith) avec `clang++`, puis l'app avec `swiftc`,
la signe en ad hoc et l'installe dans `~/Applications/LoopLook.app`.
`DEVELOPER_DIR` est forcé sur les Command Line Tools (évite la licence Xcode).

Pour fabriquer le DMG : `./makedmg.command` (génère `dist/LoopLook.dmg`).

## Architecture

```
Src/
  main.swift                app (agent barre de menus)
  AppDelegate.swift         raccourci global, suivi de la sélection Finder, fenêtre
  PlayerViewController.swift interface (forme d'onde, réglages, export)
  LoopPlayer.swift          lecture en boucle A/B, fondus, re-rendu
  SampleProcessor.swift     lecture fichier + rendu Signalsmith + export WAV
  BPMDetector.swift         détection de tempo (enveloppe RMS + autocorrélation)
  WaveformView.swift        forme d'onde + poignées A/B + grille magnétique
  WaveformAnalyzer.swift    calcul pics/RMS
  LogicImporter.swift       export WAV, drag source, import dans le DAW actif
  StretchBridge.{h,cpp}     pont C vers Signalsmith Stretch
  Bridging.h                bridging header Swift/C
Vendor/                     Signalsmith Stretch + Linear (headers)
```

## Licences

Code tiers dans `Vendor/` (voir `LICENSE-THIRD-PARTY.md`) :
- [Signalsmith Stretch](https://github.com/Signalsmith-Audio/signalsmith-stretch) — MIT
- [Signalsmith Linear](https://github.com/Signalsmith-Audio/linear) — MIT
