# Suivi des features ArrowCloud a etudier

Ce fichier sert de registre pour comparer le theme ArrowCloud externe avec notre theme Simply Love modifie, puis decider proprement ce qui merite d'etre recupere.

Reference externe a ne pas copier en bloc :

- Theme ArrowCloud : `/Users/zydon/Sites/feetness/Arrow Cloud Theme 20260525`
- Module ArrowCloud : `/Users/zydon/Sites/feetness/ArrowCloud.lua`
- Dossier a ignorer dans notre repo : `Themes/Arrow Cloud/`

Principe de travail :

- Ne jamais remplacer notre theme par leur theme complet.
- Porter uniquement des modules isoles, audites, testes visuellement et compatibles avec notre online/lobby/pack-sync.
- Eviter les ajouts gameplay lourds tant que la stabilite perf/hitches reste prioritaire.
- Garder les changements ArrowCloud optionnels via `EnableArrowCloud`.

## Tableau de suivi

| Feature | Ce qu'ils ont | Etat chez nous | Interet | Risque | Decision | Statut |
| --- | --- | --- | --- | --- | --- | --- |
| Scorebox ArrowCloud Song Select | Petit affichage du score ArrowCloud par chart dans Song Select | Integre dans notre `ScreenSelectMusic overlay/PerPlayer/Scorebox.lua` | Eleve | Faible a moyen | Garder | Recupere |
| Module ArrowCloud | Module Lua complet : login, QR, auth-check, soumission, hooks menu | Integre et adapte dans `Themes/Simply Love/Modules/ArrowCloud.lua` | Eleve | Moyen | Garder notre version adaptee | Recupere |
| Allow host ArrowCloud | Necessite `*.arrowcloud.dance` dans les hosts autorises | Ajoute cote moteur dans `NetworkManager.cpp` | Eleve | Faible | Garder | Recupere |
| Options ArrowCloud | Ecran option/theme pref pour activer/desactiver | Ajoute via `EnableArrowCloud` | Eleve | Faible | Garder | Recupere |
| Auth status Title Menu | Indicateur visuel de connexion ArrowCloud | Adapte avec fallback profil local | Moyen | Faible | Garder, a surveiller | Recupere |
| Menu Left+Right / SortMenu ArrowCloud | Insertion d'une entree ArrowCloud/Login dans le menu Song Select | Partiellement integre, avec alignement UI corrige | Eleve | Moyen | Garder et tester | Recupere |
| Leaderboard ArrowCloud complet | Vrai panneau `ACLeaderboard.lua` avec input handler dedie | Integre dans le SortMenu Song Select avec lecture API key/hash autonome | Tres eleve | Moyen | Garder et tester en jeu | Recupere |
| Recherche Song Select avancee | Recherche enrichie autour titre/artiste et logique menu differente | Integree proprement : titre, sous-titre, artiste, translit, pack/song, difficulte, BPM | Moyen | Moyen | Garder notre version robuste | Recupere |
| Ecran evaluation enrichi | Panes supplementaires, scatter plots, stream info, graphes | Non integre | Moyen | Eleve | Porter seulement par morceaux | A faire |
| Ghost data / target score | `TrackGhostData`, `GetTargetScore`, `SaveGhostData`, target/ghost tracking | Non integre | Moyen | Eleve | Interessant mais pas prioritaire | A faire |
| Gameplay StepStatistics enrichi | Scorebox gameplay, GIFs, density graph, offset calc, banner2 | Non integre | Faible a moyen | Eleve perf/hitches | Ne pas porter en bloc | En attente |
| Notefield mods / per-column graphics | `NotefieldMods.lua`, `PerColumnJudgmentGraphics.lua` | Non integre | Faible a moyen | Eleve gameplay/perf | Eviter sauf besoin precis | En attente |
| Polish visuel ArrowCloud | Logos, fonts, petites decorations, textes dedies | Partiellement integre : logo principal uniquement | Moyen | Faible | Recuperer progressivement | A faire |
| Fonts supplementaires | Mega, Unprofessional, variantes Miso, combos | Non integre | Faible | Moyen, bruit repo | Ne pas importer sans besoin | En attente |
| Judgment/hold assets supplementaires | Nombreux packs visuels de jugements/holds | Non integre | Faible | Moyen a eleve | Eviter pour l'instant | En attente |
| Micro-optimisations Lua | Certains updates espaces avec `sleep(0.2)`, graphes non recalcules chaque frame | Non repris specifiquement | Faible | Faible | S'en inspirer au cas par cas | En attente |

## Notes perf/hitches

Le theme ArrowCloud ne semble pas contenir de correction structurelle des hitches :

- pas de patch moteur macOS/OpenGL ;
- pas de fence OpenGL ;
- pas de correction `CGLFlushDrawable` ;
- pas de refonte audio/prebuffer/drift ;
- pas de strategie de pacing comparable a notre branche moteur.

Leur theme ajoute meme plusieurs elements gameplay potentiellement plus lourds :

- ghost tracking ;
- step statistics enrichies ;
- GIFs ;
- graphes ;
- overlays supplementaires ;
- per-column judgment graphics.

Conclusion : recuperer leurs features ArrowCloud/score progressivement, mais ne pas copier leur gameplay overlay complet sans audit perf.

## Priorites recommandees

1. Porter le leaderboard ArrowCloud complet de Song Select.
2. Verifier que le menu Left+Right reste propre, aligne et stable apres integration.
3. Etudier la recherche Song Select avancee.
4. Porter le polish visuel ArrowCloud utile, sans importer tous les assets.
5. Etudier l'evaluation enrichie fichier par fichier.
6. Reporter ghost/target tracking tant que la priorite reste stabilite gameplay/perf.

## Journal

| Date | Action | Resultat |
| --- | --- | --- |
| 2026-06-05 | Creation du registre de suivi ArrowCloud | Base de decision creee |
| 2026-06-05 | Portage du leaderboard ArrowCloud complet Song Select | `ACLeaderboard.lua` et input handler integres, test en jeu requis |
| 2026-06-05 | Portage recherche Song Select avancee | Recherche plain-text robuste sur titre/sous-titre/artiste + detail artiste dans les resultats |
