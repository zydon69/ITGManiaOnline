# Suivi hitches ITGmania

Derniere mise a jour: 2026-06-05

Ce fichier est la source de verite finale pour la branche
`feature/audio-perf`. Les essais rejetes ne doivent pas etre reutilises sans
nouvelle mesure comparative.

## Baseline finale

### macOS / OpenGL

- Le frame pacing moteur pilote la presentation quand une cible de pacing est
  active.
- `swapInterval=0` dans ce cas; la vsync materielle forcee est rejetee.
- `kCGLCPMPSwapsInFlight=1`.
- DisplayLink actif avec presentation alignee sur l'output.
- `MacOSFramePacingOutputAlignedPresentMode=1` fixe en code.
- Offscreen present en mode auto haut refresh fixe en code:
  `MacOSOpenGLOffscreenPresentMode=1`, min rate `90`.
- Fence GPU fonctionnelle en mode auto:
  `MacOSOpenGLFencePacingWaitMs=-1`.
- Les traces fence/present sont controlees par le switch global:
  `PerfDiagnostics=0/1`.
- Adaptive lead macOS desactive.
- Continuous `glFinish()` rejete.

### Audio

- `SoundWriteAhead=32768` force uniquement sur macOS.
- `SoundPreferredSampleRate=48000` force uniquement sur macOS.
- `PlayOncePoolVoices=8`.
- `PlayOnceMaxPools=96`.
- `PlayOnceMaxCacheMB=96`.
- Le smoke test runtime PlayOnce reste disponible pour CTest.
- La tolerance de drift de position audio est exprimee en millisecondes, puis
  convertie selon le sample rate du mapping analyse.

## Points rejetes

Ces anciens essais sont verrouilles ou neutralises dans le code final:

- `MacOSOpenGLHardwareVsyncTest=1`.
- `MacOSOpenGLMPSwapsInFlight=2`.
- `FramePacingMacOSAdaptiveLead=true`.
- `MacOSFramePacingOutputAlignedPresentMode=0`, `2` ou `3`.
- `MacOSOpenGLOffscreenPresentMode=0` ou `2`.
- `OpenGLPreFramePacingContinuousFinish=true`.
- `MacOSOpenGLFenceDiagnostics` et
  `MacOSOpenGLFenceDiagnosticsWaitMs`: anciens noms rejetes, car ils melangent
  le correctif fonctionnel et les traces de diagnostic.

Les anciennes lignes correspondantes peuvent encore exister dans le
`Preferences.ini` local d'un testeur, mais elles ne doivent plus changer la
baseline finale.

## Invariants attendus

Le script `CMake/CheckAudioRefactorInvariants.cmake` doit echouer si:

- un ancien mode rejete redevient une `Preference`;
- `MPSwapsInFlight` n'est plus fixe a `1`;
- le hardware-vsync force redevient activable;
- l'adaptive lead macOS redevient activable via preferences;
- la politique OpenGL pre-frame pacing finale redevient configurable par
  preferences utilisateur;
- le wait fence macOS/OpenGL redevient conditionne par un flag diagnostics;
- l'etat des slots du driver audio logiciel redevient un enum non atomique;
- la tolerance de drift audio redevient un nombre fixe de frames;
- les valeurs audio forcees sortent du bloc macOS.

## Lecture des logs

Les logs de diagnostic de cette branche sont coupes par defaut.

Pour demander a un joueur de produire un log complet, lui faire ajouter dans
`Preferences.ini`:

```ini
PerfDiagnostics=1
```

Puis lui demander de relancer le jeu et de reproduire le probleme. Les
correctifs de pacing/audio restent actifs quand `PerfDiagnostics=0`; cette
preference ne controle que l'instrumentation verbeuse.

Indicateurs principaux:

- `PERF_SUMMARY`: resume session et gameplay.
- `PERF_TRACE: macos_swap_buffers`: blocages de presentation macOS.
- `fence_wait_actual_us`: attente reelle de la fence GPU.
- `fence_pacing_wait`: indique que le wait fence fonctionnel est actif.
- `fence_trace`: indique uniquement les traces fence additionnelles.
- `fence_wait_saturated`: saturation du budget fence.
- `present_return_interval_ms`: intervalle reel entre deux retours present.
- `UNDERRUN_TRACE: mixer_starvation`: vrai manque de frames audio pretes.
- `Mixing underruns`: compteur global audio.

Interpretation finale:

- `fence_wait_saturated=0` avec `swap_buffers_ms` eleve indique un blocage
  WindowServer/compositeur, pas un GPU encore en train de rendre.
- `swap_block` isole sous le budget perceptible reste acceptable.
- `over20ms=0` en gameplay est la cible principale.
- Les hitches de `ScreenInit` ou de changement de mode video sont hors gameplay
  et ne doivent pas piloter les reglages de gameplay.

## Commandes de verification

```sh
cmake -DITGMANIA_SOURCE_DIR=/Users/zydon/Sites/feetness/ITGmania \
  -P CMake/CheckAudioRefactorInvariants.cmake

cmake -DITGMANIA_SOURCE_DIR=/Users/zydon/Sites/feetness/ITGmania \
  -P CMake/CheckNoteSkinRuntimeCacheInvariants.cmake

ctest --test-dir Build -C RelWithDebInfo \
  -R audio_playonce_runtime_smoke --output-on-failure
```

## Note pour upstream

Le probleme mesure a 120 Hz sur macOS/OpenGL n'etait pas principalement un cout
de rendu gameplay. Les traces ont separe:

- cout CPU/render;
- attente fence GPU;
- `CGLFlushDrawable`;
- intervalle present-a-present;
- underruns audio.

La solution retenue combine:

- prebuffer audio plus large sur macOS;
- cache/pool PlayOnce;
- fence GPU plafonnee avant present;
- pacing DisplayLink fixe et non adaptatif;
- rejet des modes hardware-vsync, MPS=2 et adaptive lead qui degradaient ou ne
  stabilisaient pas les mesures.

Le backend OpenGL macOS reste limite par le WindowServer. Un backend Metal avec
presentation programmee serait la solution structurelle pour aller plus loin.

## Registre des risques assumes

### RA-001 - Prebuffer fort synchrone dans `StartMixing`

- Statut: connu assume.
- Owner: moteur audio ITGmania.
- Perimetre: `src/arch/Sound/RageSoundDriver_Generic_Software.cpp`.
- Risque: pour une musique qui demande un strong prebuffer, `StartMixing` peut
  bloquer le thread appelant pendant les retries de remplissage initial
  (`240 x 1 ms`), puis pendant la last-chance (`500 x 1 ms`) dans le pire cas
  theorique.
- Impact attendu: spike possible sur `ScreenInit` ou transition de lancement de
  musique; pas de latence ajoutee pendant le gameplay une fois la musique
  demarree.
- Justification: le blocage est volontaire pour remplir suffisamment de blocs
  audio avant le depart et reduire le risque de `mixer_starvation` au debut
  d'une chanson.
- Garde-fous: toute reduction des bornes de prebuffer doit etre validee par un
  test A/B avec logs `UNDERRUN_TRACE: start_mixing_ready`,
  `UNDERRUN_TRACE: mixer_starvation`, `Mixing underruns` et temps de transition
  `ScreenGameplay`.
- Horizon de sortie: refonte dediee `async music prebuffer before ScreenGameplay`
  si les spikes `ScreenInit` restent perceptibles apres stabilisation
  macOS/OpenGL. Ne pas traiter dans le correctif anti-hitch gameplay actuel.

### RA-002 - Chemin Metal avec copie backbuffer et fence CPU plafonnee

- Statut: connu assume.
- Owner: backend presentation macOS.
- Perimetre:
  `src/arch/LowLevelWindow/LowLevelWindow_MacOSX.mm`,
  `src/arch/LowLevelWindow/MacOSMetalPresenter.mm`.
- Risque: le chemin Metal actuel copie chaque frame du backbuffer OpenGL vers
  une IOSurface, puis attend une fence GL plafonnee avant d'encoder la
  presentation Metal. Cela ajoute une copie GPU plein ecran et une petite
  synchronisation CPU sur le chemin critique.
- Impact attendu: cout d'optimisation, pas un risque de correctness. Les logs
  doivent rester surveilles via `PerfDiagnostics=1`:
  `macos_metal_backbuffer_present_unavailable`, `encode_submit_ms`,
  `command_buffer_ms`, `present_return_interval_ms`.
- Justification: le rendu direct dans un FBO IOSurface a cree des artefacts
  visuels sur les fonds 3D. La copie backbuffer garde le rendu OpenGL stable et
  limite Metal a la presentation.
- Garde-fous: le polling des IOSurfaces est borne court et le fallback cache la
  layer Metal pour laisser OpenGL presenter proprement si le chemin Metal n'est
  pas pret.
- Horizon de sortie: remplacer cette synchro CPU/copie par un handoff GPU-GPU
  (`MTLSharedEvent` ou equivalent valide pour l'interop GL/Metal) puis retester
  le rendu direct IOSurface sur scenes 3D avant toute activation par defaut.

### RA-003 - Selection du device Metal sur Mac multi-GPU

- Statut: connu assume.
- Owner: backend presentation macOS.
- Perimetre: `src/arch/LowLevelWindow/MacOSMetalPresenter.mm`.
- Risque: `MTLCreateSystemDefaultDevice()` peut ne pas correspondre au GPU du
  contexte OpenGL sur anciens Mac Intel multi-GPU/eGPU, ce qui peut introduire
  une copie cross-device implicite.
- Impact attendu: nul sur Apple Silicon mono-GPU; potentiel cout performance
  ou incompatibilite interop sur configurations Intel/dGPU non testees.
- Justification: la branche Metal vise d'abord Apple Silicon/ProMotion, qui est
  la machine de mesure actuelle et le cas ou les hitches 120 Hz ont ete
  reproduits.
- Garde-fous: conserver OpenGL comme fallback first-class et ne pas activer
  Metal par defaut sur Intel sans validation dediee.
- Horizon de sortie: ajouter une selection/verification explicite device GL ↔
  Metal lors d'une campagne de test Intel/dGPU.
