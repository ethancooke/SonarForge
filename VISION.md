# SonarForge Vision (Original Requirements)

This document preserves the original project vision and requirements as provided by the project owner. It serves as the source of truth for scope, philosophy, and constraints.

---

## Vision

SonarForge is a free, open-source, native macOS system-wide parametric equalizer designed as a focused, high-quality competitor to eqMac. It prioritizes a clean, modern native SwiftUI experience and essential EQ functionality only. The goal is to deliver reliable, low-CPU, artifact-free audio processing with excellent headphone profile support (especially easy AutoEQ integration) while remaining deliberately trimmed in scope.

## Positioning

- Fully free and open source (no Pro tier, no paywalls).
- Superior native SwiftUI interface: modern, resizable, native dark mode, menu-bar/status item, thoughtful keyboard shortcuts, and strong accessibility.
- Focused on essentials rather than feature breadth.
- Excellent for critical listening and precise headphone sound profile correction.

## Licensing

Use the Apache License 2.0. Include proper attribution where code or techniques are inspired by existing open-source work (e.g., eqMac’s driver components).

## Target Platform

- Primary: macOS 14.2 and later on Apple Silicon (M1 and newer) only.
- Native Swift + SwiftUI throughout.
- Real-time audio performance with minimal CPU usage and zero audible artifacts is mandatory.

## Core Feature Scope (MVP / Essentials Only)

The application must include:

- System-wide audio capture and processing (via user-space driver or Core Audio Taps).
- High-quality parametric EQ (multiple bands, standard filter types: peaking, low/high shelf, etc., with gain, frequency, and Q/bandwidth control).
- Real-time spectrum analyzer (FFT-based, toggleable, efficient via Accelerate).
- Headphone profile system with easy import and application of AutoEQ parametric settings (with clear attribution and good UX for searching/applying profiles).
- Profile management: save, load, export, import, favorites, and quick switching.
- Basic preamp / output gain staging.
- Global bypass and A/B comparison.
- Clean status item / menu-bar access for quick control.
- Resizable main window with native dark mode support.
- Thoughtful keyboard shortcuts and full keyboard + VoiceOver accessibility.

## Non-Goals / Explicitly Deferred

Do not implement in the initial versions:

- Audio Unit (AU) hosting or plugin chaining.
- Spatial audio, 3D effects, or advanced DSP effects.
- Per-application volume mixing or routing.
- Convolution / FIR filtering (unless it becomes trivially easy later).
- Heavy visual effects or non-essential UI chrome.
- Any form of monetization or feature gating.

Keep the scope narrow so the project remains maintainable as open source.

## Technical Constraints & Principles

- Prioritize modularity: Keep the DSP/audio engine cleanly separated from the SwiftUI interface.
- Performance is critical — audio thread must remain stable with very low latency and CPU impact.
- Study and appropriately attribute techniques from eqMac’s open-source user-space Null Audio driver implementation where relevant.
- All audio processing must be local. No cloud dependencies for core functionality.
- Support common sample rates (44.1 kHz to at least 96 kHz) and graceful handling of device/sample-rate changes.

## UI/UX Principles

- Modern, clean, professional SwiftUI design that feels native to macOS.
- Main window should feel spacious yet efficient, with a visual frequency response curve/editor and clear controls.
- Status item should be minimal but useful (toggle, current profile, quick access).
- Keyboard shortcuts must be discoverable and consistent.
- Excellent accessibility support is required.

---

**Note**: Later clarifications locked the platform to **macOS 14.2+ on Apple Silicon only** (see `DECISIONS.md` and `AGENTS.md`). The capture mechanism decision (Core Audio Taps as primary) is also recorded in the Decision Records.
