# AI disclosure — RE Village Archipelago

*(Version française plus bas)*

## Was AI used?

Yes. This project was developed with the help of an AI assistant.

## Which tools?

- **Claude** (Anthropic), through **Claude Code**, for code, tools and documentation.

## For what, and how much?

- **Code**: most of the code (REFramework Lua client, apworld, launcher, installer, PopTracker pack and build
  scripts) was written by Claude, following my instructions and design decisions.
- **Research**: the game's internals (items, rooms, the Duke's shop, bosses, inventory) were found together
  during play sessions: I play and test in the game, Claude writes the REFramework scripts that dump or scan
  data and analyses the results.
- **Documentation**: README, setup guide and release notes were drafted by Claude and reviewed by me.
- **Images**: map and item icons in the PopTracker pack are extracted from the game by script.

## What I do myself

- Design choices: what is shuffled, options, logic, goals, what goes in each version.
- **Testing**: every version is installed and played in the game before release; bugs found by me and by
  players are reported, diagnosed and fixed.
- Review of the changes, releases and support on the Discord.

I am responsible for everything published here, AI-assisted parts included. If something is wrong or unclear,
please open an issue or ask on the [Discord](https://discord.gg/yqKUMMkWhr).

## Other people's work

Built on [REFramework](https://github.com/praydog/REFramework) and
[lua-apclientpp](https://github.com/black-sliver/lua-apclientpp) (see `client/THIRD_PARTY_NOTICES.txt`).
Inspired by the Resident Evil 7 Archipelago client and the Resident Evil 4 Archipelago launcher; no code was
copied from them. See the [README](README.md) for credits.

---

# Déclaration IA

## IA utilisée ?

Oui. Ce projet a été développé avec l'aide d'un assistant IA.

## Quels outils ?

- **Claude** (Anthropic), via **Claude Code**, pour le code, les outils et la documentation.

## Pour quoi, et à quel point ?

- **Code** : la plus grande partie du code (client Lua REFramework, apworld, launcher, installateur, pack
  PopTracker et scripts de build) a été écrite par Claude, selon mes instructions et mes choix.
- **Recherche** : le fonctionnement interne du jeu (objets, salles, boutique du Duc, boss, inventaire) a été
  trouvé ensemble pendant des sessions de jeu : je joue et je teste, Claude écrit les scripts REFramework qui
  relèvent les données et analyse les résultats.
- **Documentation** : README, guide d'installation et notes de version rédigés par Claude et relus par moi.
- **Images** : la carte et les icônes du pack PopTracker sont extraites du jeu par script.

## Ce que je fais moi-même

- Les choix : ce qui est mélangé, les options, la logique, les objectifs, le contenu de chaque version.
- **Les tests** : chaque version est installée et jouée en jeu avant publication ; les bugs (les miens et
  ceux des joueurs) sont signalés, analysés et corrigés.
- La relecture des changements, les publications et le support sur le Discord.

Je suis responsable de tout ce qui est publié ici, parties faites avec l'IA comprises. Une erreur ou une
question : ouvrez une issue ou passez sur le [Discord](https://discord.gg/yqKUMMkWhr).

## Le travail des autres

Basé sur [REFramework](https://github.com/praydog/REFramework) et
[lua-apclientpp](https://github.com/black-sliver/lua-apclientpp) (voir `client/THIRD_PARTY_NOTICES.txt`).
Inspiré du client Archipelago de Resident Evil 7 et du launcher Archipelago de Resident Evil 4, sans reprise de
leur code. Crédits dans le [README](README.md).
