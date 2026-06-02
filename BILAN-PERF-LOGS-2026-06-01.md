# Bilan perf et logs ITGmania - 2026-06-01

Source analysee:

- `/Users/zydon/Library/Application Support/ITGmania/Logs/log.txt`
- Run local, joueur P1, theme Simply Love, build `2417715083`

Objectif:

- Traiter les anomalies une par une.
- Garder une trace claire de ce qui est confirme, corrige, puis a revalider en jeu.
- Ne pas masquer les problemes par du filtrage de logs tant que la cause n'est pas comprise.

## Resume court

Le jeu ne montre pas d'erreur fatale dans ce run: pas de crash, pas d'erreur Lua, pas de `Unknown file format`, pas de vrai `Couldn't load`.

Il reste quatre axes de travail:

1. Nettoyer les profils PNG `iCCP` restants hors theme Simply Love.
2. Instrumenter et eliminer les `Mixing underruns`.
3. Reduire les pics `Zeroing this update` sur transitions et evaluation.
4. Reduire les chargements repetes d'assets et de Lua communs.

## Constats confirmes

### P1 - Warnings PNG iCCP

Preuves:

```text
04:34.204: warning: iCCP: profile 'Photoshop ICC profile'
04:34.207: warning: iCCP: profile 'Photoshop ICC profile'
```

Diagnostic:

- Les PNG du theme `Themes/Simply Love` ont deja ete nettoyes.
- Les warnings restants apparaissent pendant `ScreenPlayerOptions`, au moment des previews de noteskins.
- Le scan runtime montre encore des chunks `iCCP` dans `Data/`, `Themes/_fallback/` et surtout `NoteSkins/`.

Plan:

- Supprimer uniquement les chunks PNG `iCCP` des assets runtime.
- Exclure les dossiers vendor/test comme `extern/`.
- Resynchroniser le bundle macOS.
- Relancer le jeu et verifier que `warning: iCCP` disparait du log.

Correction appliquee:

- Source runtime nettoyee:
  - `Data`: 2 PNG, 2 chunks retires.
  - `Themes/_fallback`: 27 PNG, 27 chunks retires.
  - `NoteSkins`: 399 PNG, 402 chunks retires.
  - `Themes/Simply Love`: deja propre, 0 chunk restant.
- Total de cette passe: 428 PNG corriges, 431 chunks `iCCP` retires.
- Aucun PNG invalide pendant la reecriture.
- Bundle macOS resynchronise et signe.
- Verification finale:
  - source runtime: 0 fichier `iCCP`, 0 chunk `iCCP`.
  - app runtime: 0 fichier `iCCP`, 0 chunk `iCCP`.

Revalidation:

- Nouveau `log.txt` du 2026-06-01 21:53.
- `iCCP`: 0 occurrence.
- `warning`: 0 occurrence.

Statut: corrige et valide.

### P2 - Mixing underruns

Preuves:

```text
04:43.227: Mixing underruns: 1
07:06.117: Mixing underruns: 1
11:30.053: Mixing underruns: 1
```

Diagnostic:

- Deux occurrences arrivent au demarrage de gameplay.
- Une occurrence arrive au shutdown.
- Les traces actuelles ne couvrent pas encore le point exact ou le compteur global est incremente.

Plan:

- Ajouter une trace au niveau bas du mixer, au moment precis de l'underrun.
- Journaliser au minimum: sound courant, ecran, frames demandees, frames disponibles, buffer readable/writable, timing.
- Ne pas filtrer les underruns de shutdown tant que la cause est inconnue.

Correction appliquee:

- Ajout d'une trace courte automatique `UNDERRUN_TRACE: mixer_starvation`.
- Cette trace est emise uniquement lorsqu'un vrai underrun mixer incremente le compteur global.
- Elle indique:
  - son concerne,
  - slot audio,
  - contexte ecran (`gameplay`, `evaluation`, `select_music`, etc.),
  - age du contexte,
  - frames demandees/obtenues/manquantes,
  - blocs readable/writable,
  - nombre de sons actifs,
  - sample rate,
  - frames mixer/hardware.
- Le mode verbose `--audio-underrun-trace` reste disponible pour les traces de scheduler/refill.
- Le chemin du son est maintenant mis en cache par slot audio afin d'eviter de relire `m_pSound` depuis le thread mixer au moment de la trace.
- Deuxieme passe:
  - les sons crees via `LoadSoundReader()` peuvent maintenant recevoir un debug path explicite.
  - le reader synthetique `AutoKeysounds` expose maintenant `AutoKeysounds:<titre>:<music path>` au driver audio.
  - le driver conserve une identite fixe par slot (`serial`, chemin, prebuffer) dans un buffer stable lisible par le thread mixer.
  - la trace `mixer_starvation` inclut maintenant le resume des slots audio actifs.

Statut: instrumentation appliquee, a revalider sur nouveau run.

### P3 - Audio position mismatch et hitches gameplay

Preuves:

```text
05:46.792: GAMEPLAY_FRAME_HITCH: delta=0.038123 music=61.505959 beat=163.610062 fps=119
11:12.571: Audio position mismatch: relation=gap closest_dist=18
11:19.275: GAMEPLAY_FRAME_HITCH: delta=0.054624 music=162.335663 beat=299.947388 fps=120
```

Diagnostic:

- Le mismatch a `11:12.571` est pendant gameplay, mais le gap mesure est faible.
- Le hitch a `11:19.275` arrive juste apres la fin de chanson, avant l'evaluation.
- Il faut distinguer les vrais hitches en pleine chanson des hitches de transition.

Plan:

- Conserver les traces gameplay.
- Ajouter une correlation avec le thread audio apres instrumentation des underruns.
- Revalider sur une partie longue.

Statut: a traiter apres `Mixing underruns`.

### P4 - Gros Zeroing this update

Preuves principales:

```text
11:20.113: Zeroing this update. Was 0.317496 - ScreenSelectMusic
11:19.460: Zeroing this update. Was 0.316300 - ScreenEvaluationStage
00:25.339: Zeroing this update. Was 0.168236 - ScreenSelectStyle
04:34.319: Zeroing this update. Was 0.164792 - ScreenPlayerOptions
```

Diagnostic:

- `ScreenEvaluationStage` charge vite officiellement, mais le premier frame apres push absorbe encore du travail lazy.
- `ScreenSelectMusic` reste le plus gros pic de transition.
- `ScreenPlayerOptions` s'est ameliore mais garde un pic lie aux previews et aux sons/options.

Plan:

- Lisser le lazy-load evaluation sur plusieurs frames.
- Continuer le travail sur `ScreenSelectMusic`.
- Ne pas casser les infos d'evaluation deja restaurees.

Statut: a traiter apres audio.

### P5 - Chargements repetes

Top repetitions observees:

```text
52x Graphics/_header.lua
52x Graphics/_footer.lua
35x ScreenInit overlay/logo.png
26x NoteSkins/dance/cel/Down Tap Note.lua
24x BGAnimations/_modules/NoteSkinPreview.lua
22x shared background lua files
```

Diagnostic:

- Plusieurs repetitions sont normales dans l'architecture StepMania/ITGmania.
- Certaines peuvent encore etre reduites par cache ou par simplification de theme.

Plan:

- Ne traiter qu'apres stabilisation audio.
- Prioriser les repetitions visibles dans les transitions et non les chargements froids inevitables.

Statut: a traiter plus tard.

## Ordre de traitement

1. `iCCP` runtime.
2. Instrumentation bas niveau des `Mixing underruns`.
3. Correction robuste des underruns selon traces.
4. Lissage `ScreenEvaluationStage`.
5. Optimisation `ScreenSelectMusic`.
6. Nettoyage des chargements repetes restants.

## Criteres de validation

- Aucun `warning: iCCP` dans un nouveau `log.txt`.
- Aucun `Mixing underruns` pendant gameplay normal.
- Aucun `GAMEPLAY_FRAME_HITCH` superieur a 50 ms en pleine chanson.
- Les transitions principales restent sous 100 ms hors chargement initial inevitable.
- Aucun regression visuelle sur:
  - choix style/joueurs,
  - choix mode `Decontracte / ITG`,
  - options joueur,
  - gameplay,
  - evaluation.
