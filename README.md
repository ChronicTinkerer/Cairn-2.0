# Cairn-2.0

A modern alternative to Ace3 for World of Warcraft addon authors.

Composable libraries — Addon, DB, Slash, Events, Locale, Log, Util, Hooks, Timer, Settings, Callback, Media — with a flagship Settings library that bridges to Blizzard's native Settings panel and registers EditMode anchors.

This is the in-development successor to the original Cairn library. **Status: scaffold only — no libraries shipped yet.** The first lib (Cairn-Addon) is in progress; the rest land one at a time once they pass the design rule below.

## Design rule

Keep things simple wherever possible. When complexity is unavoidable, be intentional about it, and wrap it behind an interface that lets consumers stay simple.

This is the one-sentence test for every design decision in Cairn-2.0. Every lib, every public method, every internal abstraction either passes it or doesn't ship.

## Why Cairn-2.0 (and not just Cairn)

The original Cairn library accumulated overlapping libs, alternative paths to the same outcome, and a v1/v2 GUI split that became hard to reason about. Cairn-2.0 starts from the lessons of that build with a much sharper scope discipline.

The Cairn-Gui-2.0 family from the original repo is preserved unchanged — it's already feature-complete and meets the design rule. The Cairn-Gui-1.0 family has been extracted to a separate "Diesal Continued" project.

## Status

| Lib | Status |
| --- | --- |
| `Cairn-Addon` | In design — first lib to ship |
| `Cairn-DB` | Planned |
| `Cairn-Slash` | Planned |
| `Cairn-Events` | Planned |
| `Cairn-Locale` | Planned |
| `Cairn-Log` | Planned |
| `Cairn-Util` | Planned |
| `Cairn-Hooks` | Planned |
| `Cairn-Timer` | Planned |
| `Cairn-Settings` | Planned (flagship) |
| `Cairn-Callback` | Planned |
| `Cairn-Media` | Planned |

There is no release timeline. Cairn-2.0 ships when ready.

## Naming

LibStub MAJORs have no version suffix. Use `LibStub("Cairn-Addon")`, not `LibStub("Cairn-Addon-2.0")`. The original v1 libs already carry `-1.0` in their MAJORs, so the namespaces don't collide.

(One exception: `Cairn-Gui-2.0` keeps its existing MAJOR, since it's not being rewritten.)

## License

MIT. See `LICENSE`.

## Status of v1

The original Cairn library at `ChronicTinkerer/Cairn` is in maintenance-only mode. New work happens here. Existing users migrate at their own pace, using both libs side by side during the transition — MAJORs do not collide.
