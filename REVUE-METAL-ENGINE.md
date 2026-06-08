# Revue de code — moteur Metal natif (`feature/metal-renderer-engine`)

Date : 2026-06-07 · Lecture seule (aucun fichier modifié) · Base de diff : `feature/macos-metal-present` (`b277397`).

## Périmètre revu

`src/RageDisplay_Metal.h/.mm` (1681 l.), `Data/Shaders/MSL/FixedFunction.metal` + `PresentPassthrough.metal`, les ajouts de `src/arch/LowLevelWindow/MacOSMetalPresenter.mm` (+1664 l. : encodage GPU, PSO, blend, present, render targets, textures), l'intégration factory (`StepMania.cpp`), les deltas `RageDisplay_OGL.cpp`, et les changements thème/`ScreenSelectMusic.cpp`.

**Constat général : implémentation de très haute qualité, idiomatique Metal, qui suit fidèlement le plan et en traite tous les risques identifiés.** Aucun défaut bloquant. Avec OpenGL en défaut et un fallback automatique, le risque produit est faible. Les findings sont surtout de la robustesse long-terme et de l'hygiène de branche.

---

## 🔴 Bloquant
Aucun.

## 🟠 Moyen

**M1 — Handles de texture sans réutilisation : croissance non bornée.**
`RageDisplay_Metal.mm` : `m_iNextTextureHandle++` est monotone et `m_Textures` est indexé par handle ; `DeleteTexture` (l.760) libère le `MTLTexture` mais **ne recycle jamais le slot**. Sur une session courte c'est invisible, mais SM/ITG fait énormément de churn de textures (chaque changement de chanson recharge bannières/CDtitles/jaquettes). Sur une borne d'arcade qui tourne des heures/jours, `m_iNextTextureHandle` et le vecteur `m_Textures` croissent sans limite (~60 o/slot → dizaines de Mo + cache locality qui se dégrade). *Correction* : free-list des handles libérés (réutiliser les indices de slots `texture==nullptr`).

**M2 — Scope creep dans la branche renderer (hygiène, pas un défaut de code).**
La branche `feature/metal-renderer-engine` contient des changements **sans rapport avec Metal** :
- `src/ScreenSelectMusic.cpp` (+54) : suspension de la preview musicale sur prompt (`m_bPreviewSuspendedForPrompt`, `StartSampleMusicPreviewNow`) — feature UX gameplay.
- `Themes/Simply Love/…/ColumnCues.lua`, `ScreenSelectPlayMode/default.lua`, `Thonk overlay/default.lua`, `_shared background/Normal.lua` + `RainbowMode.lua` : 0 mention de Metal/renderer dans leurs diffs.
Ça complique la revue, le blame et un éventuel rollback du renderer. *Recommandation* : extraire ces changements dans une branche/PR distincte avant de merger le moteur Metal. (À l'inverse, `SL-OperatorMenuOptions.lua`, `ScreenshotHandler.lua`, `metrics.ini` sont légitimement liés — toggle renderer + chemin screenshot Metal.)

## 🟡 Faible

**L1 — Transformation des vertices sur CPU.**
`ToMetalSolidVertex`/`ApplyDepthRange` (l.231-262) appliquent la MVP et le lighting **sur CPU**, le vertex shader étant un passthrough. C'est un choix malin (il évacue proprement les conventions de matrices Metal — clip Z [0,1] — et le flip Y, risques R2/R3 du plan). Deux réserves : (a) coût CPU par frame proportionnel au nombre de vertices (acceptable en 2D, mais c'est du travail que le GPU ferait gratuitement) ; (b) en perspective 3D, les vertices sont pré-divisés et passés avec `w=1` → pas de correction perspective GPU sur l'interpolation de texcoords, donc **mapping de texture affine** (léger warp) sur les fonds 3D / personnages. À valider visuellement sur un background 3D ; sans impact en 2D.

**L2 — Couleur de clear du present non-noire.**
`FlushBatches` (l.1183-1185) présente avec un clear `(0.04, 0.055, 0.075)` (slate sombre) au lieu du noir. Aux zones non couvertes (letterbox, bordures, frames partielles) ça diverge du backend OpenGL qui clear en noir. *Reco* : confirmer que c'est intentionnel (sinon `0,0,0`), et aligner sur OpenGL pour la parité A/B. (Les render targets clear bien en `0,0,0,0` transparent — correct.)

**L3 — Textures forcées en puissance-de-deux.**
`CreateTexture`/`UploadTexturePixels` (l.567) : `power_of_two(img->w/h)`. Inutile en Metal (NPOT natif) et gaspille de la VRAM (ex. 1920→2048). Conservateur et sûr (compatibilité avec le système de texcoords de SM), mais optimisable plus tard en NPOT.

**L4 — Shader de scaling de texture désactivé sur macOS OpenGL.**
`RageDisplay_OGL.cpp` (l.1043+) supprime `g_bTextureMatrixShader` sur macOS (binding d'attribut instable). Conséquence : l'effet « texture matrix scaling » est OFF sur le backend **OpenGL macOS**, alors que le backend **Metal** le conserve (fait CPU-side via `TransformTextureCoord`). Divergence inter-backend sur macOS à connaître ; correct côté Metal.

**L5 — Indices uint16 dans la géométrie compilée.**
`RageCompiledGeometryMetal::Change` (l.126) : `static_cast<uint16_t>(vertexIndex)`. Troncature silencieuse si un mesh dépasse 65535 vertices. Improbable pour un notefield, mais une borne explicite ou un index 32-bit serait plus sûr.

## 🔵 Informationnel / positifs

- `celStage == 1` renvoie une couleur plate codée en dur (`FixedFunction.metal:97`) — approximation du pass cel-shading, rarement utilisé dans les thèmes ; acceptable pour v1.
- **Excellents choix d'architecture** : batching par état identique (`ActiveBatch`, mitige R1) ; un seul encoder avec minimisation des changements PSO/uniform/texture ; ring de 3 vertex buffers persistants avec offset partagé entre flushes (render target + main) ; in-flight borné à 3 (`kMetalMaxSolidFramesInFlight`) ; PSO précalculés par (blendMode × variante shader) ; depth states par (ZTest × zWrite) ; mapping `BlendMode → MTLBlendFactor` complet et correct ; alpha-test en `discard_fragment` (R4) ; **shader distance-field séparé avec antialiasing par dérivées d'écran** (R6, le texte SDF) ; sauvegarde/restauration des batches main autour des render targets ; refcount MRC cohérent ; fallback OpenGL automatique via la boucle `CreateDisplay` ; toggle operator-menu propre ; instrumentation `PerfDiagnostics` riche (bounds NDC, staging, present).

---

## Reco prioritaire

1. **M2** — sortir le scope-creep (`ScreenSelectMusic.cpp` + 5 fichiers Lua non-Metal) dans une PR séparée avant merge. C'est le point le plus important pour la qualité du merge, même si ce n'est pas un défaut de code.
2. **M1** — ajouter un free-list des handles de texture (le seul vrai risque de fuite sur sessions longues).
3. **L1/L2** — valider visuellement les fonds 3D (warp affine) et la couleur de clear, dans le cadre de la validation A/B de phase 8.
4. **L3/L5** — optimisations/durcissements différables.

Globalement : c'est un portage sérieux, complet et bien pensé — tous les pièges du plan (R1 batching, R2/R3 transform CPU, R4 alpha-test, R6 SDF) sont traités, et la séparation renderer-CPU / encodage-GPU (presenter) est propre. Garde OpenGL en défaut jusqu'à la validation A/B multi-Mac, puis le free-list (M1) avant toute activation par défaut.
