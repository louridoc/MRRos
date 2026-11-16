# ADR 0001 — Initial architecture

Date: 2026-11-15 · Status: accepted

## Context
Replace the UIKit/SceneKit/CocoaPods HRI app with a modular AR app that maps the environment
for a manipulator's planning scene and aligns the robot in AR, supporting FANUC CRX and UR arms
on labs that may run ROS 2 Humble, Jazzy or Lyrical.

## Decision
The eight decisions D1–D8 in `docs/PLAN.md` §2: RoboStack on macOS for development (Jazzy
default, all three distros creatable), rosbridge + `ar_bridge` companion node, RealityKit/SwiftUI
iOS 18+, generic URDF with bundled meshes for priority robots, latched PointCloud2 + file output,
manual-then-fiducial alignment, private GitHub monorepo, three-distro CI matrix.

## Consequences
- Point clouds never traverse rosbridge JSON; a second (HTTP) channel must be kept in sync via a
  versioned protocol doc.
- Mesh conversion happens twice (offline bundle, online fallback) with one lookup key.
- Pure-Swift packages must stay macOS-buildable to keep tests fast.
- ROS-side Python stays 3.10-compatible; distro differences are quarantined in one module.
