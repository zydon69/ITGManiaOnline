<div align="center">

# ✨ What’s New in Our ITGmania Fork

### More ways to play. Less setup. An experience built around dance pads.

[![Online](https://img.shields.io/badge/ONLINE-P1_%2F_P1%2BP2-7c3aed?style=for-the-badge&logo=socketdotio&logoColor=white)](#-itg-online--play-together-from-anywhere)
[![Game modes](https://img.shields.io/badge/MODES-DOUBLE_%E2%80%A2_COUPLE_%E2%80%A2_ROUTINE-f43f5e?style=for-the-badge)](#-double-couple-and-routine)
[![macOS Metal](https://img.shields.io/badge/macOS-NATIVE_METAL-0ea5e9?style=for-the-badge&logo=apple&logoColor=white)](#-native-metal-on-macos)
[![Teejusb FSR](https://img.shields.io/badge/PAD-TEEJUSB_FSR-10b981?style=for-the-badge)](#-teejusb-fsr-built-directly-into-itgmania)

This fork expands **ITGmania + Simply Love** with a richer local and online
experience, while preserving the accuracy and readability expected from a
serious rhythm game.

</div>

---

## 🌈 At a Glance

| | Feature | What it changes |
|:--:|---|---|
| 🕺 | **Double / Couple / Routine** | New ways to play solo, together, or through a shared choreography |
| 🌐 | **ITG Online** | Synchronized rooms for P1 alone or P1 + P2 on the same machine |
| 📦 | **Pack downloads** | Guided pack discovery and installation through StepManiaOnline |
| 🎚️ | **Multi-offset** | Six named offset profiles, available in the options or through <kbd>F3</kbd> + <kbd>B</kbd> |
| 🦶 | **Native teejusb FSR support** | Read, configure, and monitor your pad directly from ITGmania |
| 🍎 | **Metal on macOS** | A native rendering engine designed for modern Macs |
| 🎛️ | **Option presets** | Six independently saved configurations for each player |
| 👤 | **Modernized profiles** | Profile creation, selection, and score-service logins in a clearer flow |
| 🛡️ | **Stability** | Memory leak fixes and improved diagnostics |

---

## 🕺 Double, Couple, and Routine

The engine and theme now support three additional ways to enjoy compatible
charts:

- **Double** — one player uses both sides of the pad;
- **Couple** — two players play coordinated charts, one on each side;
- **Routine** — two players share one choreography and one combined result.

Support goes beyond presentation: difficulty selection, chart validation,
gameplay, and score consolidation have all been adapted for these styles.

> [!TIP]
> Available charts still depend on which modes are actually included in your
> song packs.

---

## 🌐 ITG Online — Play Together from Anywhere

<div align="center">

![P1](https://img.shields.io/badge/LOCAL-P1-2563eb?style=flat-square)
![P1 + P2](https://img.shields.io/badge/LOCAL-P1_%2B_P2-db2777?style=flat-square)
![Live leaderboard](https://img.shields.io/badge/SCORE-LIVE_LEADERBOARD-f59e0b?style=flat-square)
![Authoritative server](https://img.shields.io/badge/SYNC-AUTHORITATIVE_SERVER-16a34a?style=flat-square)

</div>

Online mode lets you join or manage a room with:

- **P1 alone** on one machine;
- **P1 + P2** playing together on the same machine;
- synchronized song and difficulty selection;
- a coordinated options screen before gameplay;
- a live leaderboard followed by a shared final ranking;
- proper handling of disconnects, early exits, failures, and returns to the
  room.

The server remains authoritative over the room and round state. Clients
resynchronize after a connection loss so stale local data cannot override the
room’s actual state.

### 📦 Missing a Pack? Let ITGmania Handle It

When a player does not have the selected song, the game can:

1. look for a genuinely compatible chart in the local library;
2. query **[StepManiaOnline](https://stepmaniaonline.net/)**;
3. let the player choose the correct pack when several matches exist;
4. ask the server for permission to start the download;
5. download and extract the pack;
6. reload the song library without restarting the game;
7. validate the chart using its metadata and hashes before marking the player
   as ready.

Download status and progress are shared with the room. Once a download has been
authorized and started, it becomes part of the round synchronization protocol.

<details>
<summary><strong>🔍 For Developers — Online Architecture</strong></summary>

The client separates local identity, score transport, ready-state coordination,
realtime event routing, and room-state transitions. Live scores use synchronized
musical positions, while the final result follows a separate, immutable
submission flow.

Client setup and behavior are documented in
[`Docs/ITGOnline.md`](Docs/ITGOnline.md).

</details>

---

## 🎚️ Six Global Offset Profiles

Changing displays, headphones, sound cards, or complete setups should not mean
losing a carefully calibrated timing value.

The **Multi-offset** system provides **six persistent slots**:

- every profile has its own name and offset value;
- the active profile and its settings persist between sessions;
- profiles can be selected and renamed from the options;
- <kbd>F3</kbd> + <kbd>B</kbd> quickly switches to the next profile;
- a recovery backup protects the configuration if the primary file becomes
  invalid.

For example: `Headphones`, `Television`, `Projector`, `Arcade`, `Capture` — name
them to match your own setups.

---

## 🦶 Teejusb FSR Built Directly into ITGmania

The **teejusb-fsr** integration communicates with the controller directly over
serial. You no longer need to run the local monitoring server just to play.

From the dedicated configuration screen, you can:

- detect controllers and assign them to players;
- read all four FSR values from a pad in realtime;
- adjust each threshold;
- load thresholds from the controller;
- save thresholds back to the controller;
- display FSR values during gameplay for pad diagnostics.

Multiple controllers can be monitored and assigned independently, with support
for up to four players.

> [!NOTE]
> The flashing tools and external monitor remain useful for installing,
> updating, or diagnosing the controller outside the game. They are simply no
> longer required for everyday monitoring inside ITGmania.

---

## 🍎 Native Metal on macOS

This fork adds a true **Metal** rendering engine for macOS, featuring:

- native presentation through `CAMetalLayer`;
- proper Retina and window-resize handling;
- presentation pacing tied to the physical display;
- Metal shaders for the rendering pipeline;
- an **OpenGL** fallback when needed.

Metal is the default native choice on macOS in this fork. The OpenGL renderer
remains available from the graphics options.

---

## 🎛️ Presets for the Options Screen

Each player gets **six persistent, renameable presets** directly on the options
screen.

A preset remembers the relevant gameplay settings stored in that player’s
profile. Speed, appearance, reading options, and other preferences can be
recalled instantly instead of being configured one row at a time before every
round.

P1 and P2 presets are independent: each player gets their own settings back
when their profile is loaded.

---

## 👤 Profiles and Score Services, Brought Together

### A Modernized Profile Flow

The **profile creation and selection screen**, adapted from work by
**[Arrow Cloud](https://arrowcloud.dance/)**, makes it easier to create, select,
and edit a local profile before playing.

### HardEX

The **HardEX** scoring mode, also adapted from Arrow Cloud’s work, is available
alongside ITG Classic and EX scoring.

### One Clear Login Screen for Every Player

One unified screen brings together
**[GrooveStats](https://groovestats.com/)** and
**[Arrow Cloud](https://arrowcloud.dance/)** login. P1 and P2 each retain their
own account state inside their own profile, keeping player identities separate
without requiring a different login flow for each service.

> [!IMPORTANT]
> GrooveStats, Arrow Cloud, and StepManiaOnline are third-party services. Their
> availability, accounts, and APIs are managed independently by their
> respective teams.

---

## 🛡️ Stability and Performance Diagnostics

This version fixes several resource-management and memory-leak issues discovered
during extended play sessions.

Targeted diagnostics have also been added around:

- screen transitions;
- graphics-resource loading;
- rendering and frame pacing;
- networking, downloads, and Online scores.

The goal is simple: keep long sessions running smoothly and make problems
reproducible when hardware, a song pack, or a network connection behaves
unexpectedly.

---

## 💜 Credits

This project is, above all, a community effort. This fork builds upon work from:

- **[ITGmania](https://github.com/itgmania/itgmania)** and **StepMania** for the
  engine;
- **[Simply Love](https://github.com/Simply-Love/Simply-Love-SM5)** for the
  theme;
- **teejusb** for the teejusb-fsr ecosystem;
- **[Arrow Cloud](https://arrowcloud.dance/)** for the profile screen and
  HardEX scoring mode;
- **[GrooveStats](https://groovestats.com/)** and
  **[StepManiaOnline](https://stepmaniaonline.net/)** for their community
  services.

<div align="center">

### Ready to Step onto the Pad?

![Play local](https://img.shields.io/badge/PLAY-LOCAL-06b6d4?style=for-the-badge)
![Play online](https://img.shields.io/badge/PLAY-ONLINE-8b5cf6?style=for-the-badge)
![Open source](https://img.shields.io/badge/BUILD-TOGETHER-ec4899?style=for-the-badge)

</div>
