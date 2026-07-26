if(NOT DEFINED ITGMANIA_SOURCE_DIR)
  message(FATAL_ERROR "ITGMANIA_SOURCE_DIR is required")
endif()

function(read_source relative_path output_var)
  set(path "${ITGMANIA_SOURCE_DIR}/${relative_path}")
  if(NOT EXISTS "${path}")
    message(FATAL_ERROR "Missing source file: ${path}")
  endif()
  file(READ "${path}" contents)
  set("${output_var}" "${contents}" PARENT_SCOPE)
endfunction()

function(require_contains haystack needle label)
  string(FIND "${haystack}" "${needle}" found_at)
  if(found_at EQUAL -1)
    message(FATAL_ERROR "Missing Metal invariant: ${label}")
  endif()
endfunction()

function(require_absent haystack needle label)
  string(FIND "${haystack}" "${needle}" found_at)
  if(NOT found_at EQUAL -1)
    message(FATAL_ERROR "Forbidden Metal invariant: ${label}")
  endif()
endfunction()

read_source("src/RageDisplay_Metal.mm" metal_display)
read_source("src/RageDisplay_Metal.h" metal_display_header)
read_source("src/RageDisplay.cpp" rage_display)
read_source("src/ScreenManager.cpp" screen_manager)
read_source(
  "src/arch/LowLevelWindow/LowLevelWindow_MacOSX.mm"
  macos_window)
read_source(
  "src/arch/LowLevelWindow/DisplayLinkPacingPolicy.cpp"
  display_link_policy)
read_source(
  "Tests/display_link_pacing_policy_test.cpp"
  display_link_policy_test)
read_source(
  "src/arch/LowLevelWindow/MacOSMetalPresenter.mm"
  metal_presenter)
read_source(
  "src/arch/LowLevelWindow/MacOSMetalPresenter.h"
  metal_presenter_header)
read_source(
  "Themes/Simply Love/Graphics/OptionRow Frame.lua"
  option_row_frame)
read_source("Data/Shaders/MSL/FixedFunction.metal" metal_shader)
read_source("src/Model.cpp" model_source)
read_source("src/PrefsManager.cpp" prefs_manager)
read_source("src/RageSoundPosMap.cpp" sound_pos_map)
read_source("src/StepMania.cpp" stepmania_source)
read_source(
  "Themes/Simply Love/Scripts/SL-OperatorMenuOptions.lua"
  operator_menu_options)

require_contains(
  "${stepmania_source}"
  "\"metal,opengl\",  // Native Metal by default"
  "macOS defaults to native Metal with an OpenGL fallback")
require_contains(
  "${stepmania_source}"
  "Using configured video renderer list '%s' instead of default '%s'"
  "an explicit supported renderer choice is informational, not a warning")
require_contains(
  "${operator_menu_options}"
  "choices = { \"OpenGL\", \"Metal\" }"
  "the hybrid OpenGL plus Metal option stays hidden")
require_contains(
  "${operator_menu_options}"
  "Keep this mapping here so it can be restored if needed"
  "the hidden hybrid option remains documented for restoration")

require_contains(
  "${metal_display}"
  "kMetalDisplayPacingHeadroomFactor = 1.0"
  "native Metal presentation cadence matches the physical display")
require_contains(
  "${prefs_manager}"
  "m_bForceLogFlush(\"ForceLogFlush\", false)"
  "synchronous per-line disk flushing is opt-in")
require_contains(
  "${sound_pos_map}"
  "m_bLoggedIntentionalNegativeMapping"
  "intentional negative audio mappings are not logged on every insertion")

require_contains(
  "${metal_display}"
  "ResetVertexWriter(&m_MainVertexWriter, true);"
  "renderer shutdown cancels the main direct vertex frame")
require_contains(
  "${metal_display}"
  "DestroyAllTextures();\n  if (m_Presenter)"
  "textures are released before presenter shutdown")
require_contains(
  "${metal_display}"
  "refusing malformed texture source"
  "texture uploads validate source shape and pitch")
require_contains(
  "${metal_display}"
  "allocated geometry mesh=%zu"
  "compiled Metal geometry rejects out-of-bounds updates")
require_contains(
  "${metal_display}"
  "0x00FF0000, 0x0000FF00, 0x000000FF, 0xFF000000"
  "Metal BGRA readback uses explicit little-endian masks")
require_contains(
  "${option_row_frame}"
  "METAL_PREVIEW_TRACE"
  "noteskin ActorProxy resolution is traceable")
require_contains(
  "${metal_display}"
  "MacOSMetalPresenterSetNativeRendererActive(true);"
  "native Metal renderer claims window presentation ownership")
require_contains(
  "${macos_window}"
  "MacOSMetalPresenterNativeRendererActive()"
  "OpenGL-to-Metal bridge is suppressed for the native renderer")
require_contains(
  "${metal_presenter}"
  "setFrontFacingWinding:MTLWindingCounterClockwise"
  "Metal model culling preserves authored model winding")
require_contains(
  "${metal_presenter}"
  "layer.colorspace = nil;"
  "Metal presentation uses the same device-native color path as OpenGL")
require_contains(
  "${model_source}"
  "DISPLAY->Scale(1, -1, 1)"
  "the Model Y-axis transform remains explicit during winding review")
require_contains(
  "${metal_display}"
  "AppendTriangle(&batch.vertices, v[i + 2], v[i + 1], v[i + 3])"
  "quad-strip triangles preserve OpenGL winding")
require_contains(
  "${metal_display}"
  "m_bClearDepthNextFrame = true;\n  m_bLayerReconfiguredForResolutionChange = false;"
  "Metal clears persistent model depth at the beginning of every frame")
require_contains(
  "${metal_shader}"
  "outputColor.rgb /= sampleColor.a"
  "Unpremultiply matches the OpenGL shader")
require_contains(
  "${metal_shader}"
  "return float4(in.color.rgb, in.color.a * coverage)"
  "distance-field output matches the OpenGL shader")
require_contains(
  "${metal_display_header}"
  "int GetNumTextureUnits() override { return 2; }"
  "Metal advertises the two texture units implemented by its shader")
require_contains(
  "${metal_display}"
  "m_PendingTextureDeletes.push_back(iTexHandle);"
  "texture deletion is deferred until queued CPU batches are submitted")
require_contains(
  "${metal_display}"
  "void RageDisplay_Metal::ResolutionChanged()"
  "Metal refreshes engine and CAMetalLayer dimensions after a window resize")
require_contains(
  "${metal_presenter}"
  "setFragmentSamplerState:sampler1 atIndex:1"
  "the second texture unit has an independent sampler")
require_contains(
  "${metal_shader}"
  "source2.sample(sourceSampler2, in.texcoord2)"
  "the second texture unit uses independent coordinates and sampling state")
require_contains(
  "${metal_shader}"
  "texture_stage_compose("
  "normal multitexture rendering composes every supported texture mode")
require_contains(
  "${metal_display}"
  "m_MaterialSpecular.r * light.specular.r * specularIntensity"
  "Metal model lighting preserves fixed-function specular highlights")
require_contains(
  "${metal_display}"
  "TransformNormalInverseTranspose(modelVertex.n, modelView)"
  "Metal model lighting uses the inverse-transpose normal transform")
require_contains(
  "${metal_presenter}"
  "CheckedVertexBufferLength"
  "Metal vertex staging rejects overflowing buffer lengths")
require_contains(
  "${metal_presenter_header}"
  "sizeof(MacOSMetalTransformUniforms) == 144"
  "the CPU transform uniform layout is compile-time checked")
require_contains(
  "${metal_presenter_header}"
  "offsetof(MacOSMetalTransformUniforms, padding) == 132"
  "the CPU transform uniform offsets are compile-time checked")
require_contains(
  "${metal_shader}"
  "float padding[3]"
  "the MSL transform padding matches the CPU scalar-array layout")
require_absent(
  "${metal_shader}"
  "float3 padding"
  "the MSL transform layout must not use aligned float3 padding")
require_contains(
  "${metal_display}"
  "out-of-range local vertex index"
  "compiled geometry validates indices against each source mesh")
require_contains(
  "${metal_display}"
  "surface != m_LockedSurface"
  "texture unlock requires the exact surface that was locked")
require_contains(
  "${metal_presenter}"
  "RecordMetalCommandBufferCompletion"
  "asynchronous Metal command failures are recorded")
require_contains(
  "${metal_presenter}"
  "MacOSMetalPresentResult::Skipped"
  "dropped presentation frames are distinct from hard failures")
require_contains(
  "${metal_presenter}"
  "MetalDrawablePrefetchRenderWaitUsec(targetHz)"
  "drawable prefetch waits scale with the physical frame interval")
require_contains(
  "${display_link_policy}"
  "candidateDelta == bestDelta"
  "display-link phase correction selects the nearest physical output")
require_contains(
  "${display_link_policy_test}"
  "nearest-phase selection must bound early correction"
  "nearest display-link phase selection has executable regression coverage")
require_contains(
  "${macos_window}"
  "outputPhase.valid && !outputPhase.phase_accepted"
  "a fixed display-link phase miss cannot stall for the callback timeout")
require_contains(
  "${rage_display}"
  "g_iFramePacerNextPresentUsec =\n          waitStats.display_link_selected_output_usec"
  "the engine cadence must adopt the selected physical display phase")
require_contains(
  "${rage_display}"
  "g_iFramePacerNextPresentUsec > alignedPresentLeadUsec"
  "wake-lateness telemetry must use the adopted physical phase")
require_absent(
  "${macos_window}"
  "CappedDisplayLinkDesiredPresentUsec"
  "the engine target cannot cap away a valid future physical phase")
require_contains(
  "${metal_display}"
  "framePresentResult == MacOSMetalPresentResult::Presented"
  "legacy FPS counters only count successful native Metal submissions")
require_contains(
  "${rage_display}"
  "g_iFramesAttemptedSinceLastCheck > 0"
  "zero frame attempts cannot divide the VPF statistic by zero")
require_contains(
  "${rage_display}"
  "g_iFramesRenderedSinceLastReset / cumulativeTime"
  "cumulative FPS uses elapsed time instead of sample-count averaging")
require_contains(
  "${rage_display}"
  "std::clamp(1000000 / safeTargetFps / 4, 1000, 10000)"
  "inactive-window yielding must scale below the requested frame interval")
require_contains(
  "${metal_display}"
  "MacOSMetalPresenterGetRuntimeStatsLine()"
  "native Metal exposes presentation telemetry through the display contract")
require_contains(
  "${screen_manager}"
  "PERF_SNAPSHOT: screen_transition"
  "screen transitions snapshot presentation telemetry for log correlation")
require_absent(
  "${metal_display}"
  "m_MaterialDiffuse.a < 0.999f"
  "Metal must not override model culling and depth writes by material alpha")
require_contains(
  "${metal_presenter}"
  "convertRectToBacking:[layerView bounds]"
  "CAMetalLayer drawable dimensions use Retina backing pixels")
require_contains(
  "${metal_presenter}"
  "CreateDepthTexture(impl->device, drawableWidth, drawableHeight)"
  "layer reconfiguration prepares matching depth storage transactionally")
require_contains(
  "${metal_presenter}"
  "Native Metal renderer requires complete fixed-function GPU"
  "native Metal startup rejects partial pipeline and render state sets")
require_contains(
  "${metal_presenter}"
  "rejected batch with unavailable pipeline"
  "native Metal never substitutes a semantically different fallback pipeline")

string(FIND "${metal_shader}"
  "saturate(float4(in.color.rgb, in.color.a * coverage) + in.color)"
  distance_field_add_at)
if(NOT distance_field_add_at EQUAL -1)
  message(FATAL_ERROR
    "Metal distance-field shader must not inherit TextureMode_Add composition")
endif()

string(FIND "${metal_shader}"
  "1.0) * in.color"
  yuyv_vertex_tint_at)
if(NOT yuyv_vertex_tint_at EQUAL -1)
  message(FATAL_ERROR
    "Metal YUYV422 conversion must not apply an OpenGL-incompatible vertex tint")
endif()
