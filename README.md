# About this fork

This is my personal build of [Ghostty](https://github.com/ghostty-org/ghostty)
with trackpad gesture support on macOS. Terminals normally use the trackpad
only for scrolling, and I wanted pinches, smart zoom, and multi-finger swipes
to work as regular terminal input, so this fork adds a gesture engine and a
protocol that lets terminal applications receive gestures themselves. I would
like this work to land in upstream Ghostty so the fork stops being necessary,
and until then I rebase it on top of every official release.

## What it adds

- **Bindable trackpad gestures.** The `gesture` config key binds a gesture to
  any keybind action, with the syntax
  `gesture = [mods+]<gesture>[:<fingers>] = [flags:]<action>`. Recognized
  gestures are `pinch-in`, `pinch-out`, `smart-magnify` (two-finger double
  tap), and directional swipes with two, three, or four fingers. The defaults
  bind pinch to font size, smart magnify to a temporary font zoom toggle, and
  two-finger horizontal swipes to tab switching.

  ```ini
  gesture = cmd+swipe-left:2 = goto_split:left
  gesture = swipe-up:3 = toggle_quick_terminal
  gesture = pinch-in = once:text:\x02s
  ```

- **Scroll arbitration.** Two-finger swipes share their motion with scrolling,
  so unmodified swipe bindings defer to programs that enabled mouse reporting
  and honor the macOS "Swipe between pages" preference. Modified triggers and
  `force:` bindings always fire.
- **Gesture reporting mode (DEC private mode 2035).** An application can
  enable `CSI ? 2035 h` and receive gestures as escape sequences instead of
  the terminal handling them. The wire format is specified in
  [PROTOCOL-GESTURES.md](https://github.com/pszypowicz/tmux/blob/feat/gestures/PROTOCOL-GESTURES.md)
  in the companion tmux fork.
- **No auto-update mechanism.** The Sparkle auto-update stack is removed from
  the app. Updates ship through my Homebrew tap instead, so `brew upgrade` is
  the whole update story.

## The companion tmux fork

I also daily drive a [tmux fork](https://github.com/pszypowicz/tmux) (branch
`feat/gestures`) that decodes gesture reporting mode into bindable keys such
as `Swipe2Left`, `PinchIn`, and `SmartMagnify`, so gestures can drive tmux
windows, panes, and tree mode directly. I proposed the protocol to upstream
tmux in [tmux/tmux#5462](https://github.com/tmux/tmux/issues/5462); the
maintainer found the idea and the code reasonable on a first look, but wants
to see the protocol supported in more terminals before tmux adopts it.

## Branches

| Branch                | Content                                                                                                             |
| --------------------- | ------------------------------------------------------------------------------------------------------------------- |
| `main`                | The upstream release commit the fork is based on (the commit tagged v1.4.0), untouched.                             |
| `feat/gestures`       | Gesture recognition and config bindings. [Draft PR #5](https://github.com/pszypowicz/ghostty/pull/5) describes it.  |
| `feat/gesture-report` | Gesture reporting mode (DEC 2035), stacked on `feat/gestures`.                                                      |
| `personal`            | `feat/gesture-report` plus the Sparkle removal and this README. This is what I ship and the branch you are reading. |

Gesture recognition itself lives in
[TrackpadKit](https://github.com/pszypowicz/TrackpadKit), an MIT-licensed
Swift package with a raw-NSTouch recognizer, palm rejection, and
fixture-replay tests. The fork consumes it through SPM, and it is reusable by
any macOS app that wants gesture input.

## Installing with Homebrew

```sh
brew install --cask pszypowicz/tap/ghostty-personal
brew install pszypowicz/tap/tmux-gestures
```

The cask is Developer ID signed and notarized, and it conflicts with the
official Ghostty casks because both install `Ghostty.app`. The formula
conflicts with core `tmux` for the same reason.

## Upstream status

Trackpad gestures are not an accepted Ghostty feature yet, and upstream asks
that pull requests be associated with previously accepted issues, so the work
lives here for now. If you want this upstream, these are the places to say so:

- [ghostty-org/ghostty discussion #3506](https://github.com/ghostty-org/ghostty/discussions/3506),
  the long-standing trackpad gestures request
- [ghostty-org/ghostty discussion #13442](https://github.com/ghostty-org/ghostty/discussions/13442),
  my feature announcement for this implementation
- [ghostty-org/ghostty discussion #13446](https://github.com/ghostty-org/ghostty/discussions/13446),
  my vouch request
- [tmux/tmux#5462](https://github.com/tmux/tmux/issues/5462), the protocol RFC
  on the tmux side

Problems with the fork builds belong in
[this repo's issues](https://github.com/pszypowicz/ghostty/issues), not in the
upstream tracker. The upstream README follows below.

---

<!-- LOGO -->
<h1>
<p align="center">
  <img src="https://github.com/user-attachments/assets/fe853809-ba8b-400b-83ab-a9a0da25be8a" alt="Logo" width="128">
  <br>Ghostty
</h1>
  <p align="center">
    Fast, native, feature-rich terminal emulator pushing modern features.
    <br />
    A native GUI or embeddable library via <code>libghostty</code>.
    <br />
    <a href="#about">About</a>
    ·
    <a href="https://ghostty.org/download">Download</a>
    ·
    <a href="https://ghostty.org/docs">Documentation</a>
    ·
    <a href="CONTRIBUTING.md">Contributing</a>
    ·
    <a href="HACKING.md">Developing</a>
  </p>
</p>

## About

Ghostty is a terminal emulator that differentiates itself by being
fast, feature-rich, and native. While there are many excellent terminal
emulators available, they all force you to choose between speed,
features, or native UIs. Ghostty provides all three.

**`libghostty`** is a cross-platform, zero-dependency C and Zig library
for building terminal emulators or utilizing terminal functionality
(such as style parsing). Anyone can use `libghostty` to build a terminal
emulator or embed a terminal into their own applications. See
[Ghostling](https://github.com/ghostty-org/ghostling) for a minimal complete project
example or the [`examples` directory](https://github.com/ghostty-org/ghostty/tree/main/example)
for smaller examples of using `libghostty` in C and Zig.

For more details, see [About Ghostty](https://ghostty.org/docs/about).

## Download

See the [download page](https://ghostty.org/download) on the Ghostty website.

## Documentation

See the [documentation](https://ghostty.org/docs) on the Ghostty website.

## Contributing and Developing

If you have any ideas, issues, etc. regarding Ghostty, or would like to
contribute to Ghostty through pull requests, please check out our
["Contributing to Ghostty"](CONTRIBUTING.md) document. Those who would like
to get involved with Ghostty's development as well should also read the
["Developing Ghostty"](HACKING.md) document for more technical details.

## Roadmap and Status

Ghostty is stable and in use by millions of people and machines daily.

The high-level ambitious plan for the project, in order:

|  #  | Step                                                    | Status |
| :-: | ------------------------------------------------------- | :----: |
|  1  | Standards-compliant terminal emulation                  |   ✅   |
|  2  | Competitive performance                                 |   ✅   |
|  3  | Rich windowing features -- multi-window, tabbing, panes |   ✅   |
|  4  | Native Platform Experiences                             |   ✅   |
|  5  | Cross-platform `libghostty` for Embeddable Terminals    |   ✅   |
|  6  | Ghostty-only Terminal Control Sequences                 |   ❌   |

Additional details for each step in the big roadmap below:

#### Standards-Compliant Terminal Emulation

Ghostty implements all of the regularly used control sequences and
can run every mainstream terminal program without issue. For legacy sequences,
we've done a [comprehensive xterm audit](https://github.com/ghostty-org/ghostty/issues/632)
comparing Ghostty's behavior to xterm and building a set of conformance
test cases.

In addition to legacy sequences (what you'd call real "terminal" emulation),
Ghostty also supports more modern sequences than almost any other terminal
emulator. These features include things like the Kitty graphics protocol,
Kitty image protocol, clipboard sequences, synchronized rendering,
light/dark mode notifications, and many, many more.

We believe Ghostty is one of the most compliant and feature-rich terminal
emulators available.

Terminal behavior is partially a de jure standard
(i.e. [ECMA-48](https://ecma-international.org/publications-and-standards/standards/ecma-48/))
but mostly a de facto standard as defined by popular terminal emulators
worldwide. Ghostty takes the approach that our behavior is defined by
(1) standards, if available, (2) xterm, if the feature exists, (3)
other popular terminals, in that order. This defines what the Ghostty project
views as a "standard."

#### Competitive Performance

Ghostty is generally in the same performance category as the other highest
performing terminal emulators.

"The same performance category" means that Ghostty is much faster than
traditional or "slow" terminals and is within an unnoticeable margin of the
well-known "fast" terminals. For example, Ghostty and Alacritty are usually within
a few percentage points of each other on various benchmarks, but are both
something like 100x faster than Terminal.app and iTerm. However, Ghostty
is much more feature rich than Alacritty and has a much more native app
experience.

This performance is achieved through high-level architectural decisions and
low-level optimizations. At a high-level, Ghostty has a multi-threaded
architecture with a dedicated read thread, write thread, and render thread
per terminal. Our renderer uses OpenGL on Linux and Metal on macOS.
Our read thread has a heavily optimized terminal parser that leverages
CPU-specific SIMD instructions. Etc.

#### Rich Windowing Features

The Mac and Linux (build with GTK) apps support multi-window, tabbing, and
splits with additional features such as tab renaming, coloring, etc. These
features allow for a higher degree of organization and customization than
single-window terminals.

#### Native Platform Experiences

Ghostty is a cross-platform terminal emulator but we don't aim for a
least-common-denominator experience. There is a large, shared core written
in Zig but we do a lot of platform-native things:

- The macOS app is a true SwiftUI-based application with all the things you
  would expect such as real windowing, menu bars, a settings GUI, etc.
- macOS uses a true Metal renderer with CoreText for font discovery.
- macOS supports AppleScript, Apple Shortcuts (AppIntents), etc.
- The Linux app is built with GTK.
- The Linux app integrates deeply with systemd if available for things
  like always-on, new windows in a single instance, cgroup isolation, etc.

Our goal with Ghostty is for users of whatever platform they run Ghostty
on to think that Ghostty was built for their platform first and maybe even
exclusively. We want Ghostty to feel like a native app on every platform,
for the best definition of "native" on each platform.

#### Cross-platform `libghostty` for Embeddable Terminals

In addition to being a standalone terminal emulator, Ghostty is a
C-compatible library for embedding a fast, feature-rich terminal emulator
in any 3rd party project. This library is called `libghostty`.

Due to the scope of this project, we're breaking libghostty down into
separate libraries, starting with `libghostty-vt`. The goal of
this project is to focus on parsing terminal sequences and maintaining
terminal state. This is covered in more detail in this
[blog post](https://mitchellh.com/writing/libghostty-is-coming).

`libghostty-vt` is already available and usable today for Zig and C and
is compatible for macOS, Linux, Windows, and WebAssembly. The functionality
is extremely stable (since its been proven in Ghostty GUI for a long time),
but the API signatures are still in flux.

`libghostty` is already heavily in use. See [`examples`](https://github.com/ghostty-org/ghostty/tree/main/example)
for small examples of using `libghostty` in C and Zig or the
[Ghostling](https://github.com/ghostty-org/ghostling) project for a
complete example. See [awesome-libghostty](https://github.com/Uzaaft/awesome-libghostty)
for a list of projects and resources related to `libghostty`.

We haven't tagged libghostty with a version yet and we're still working
on a better docs experience, but our [Doxygen website](https://libghostty.tip.ghostty.org/)
is a good resource for the C API.

#### Ghostty-only Terminal Control Sequences

We want and believe that terminal applications can and should be able
to do so much more. We've worked hard to support a wide variety of modern
sequences created by other terminal emulators towards this end, but we also
want to fill the gaps by creating our own sequences.

We've been hesitant to do this up until now because we don't want to create
more fragmentation in the terminal ecosystem by creating sequences that only
work in Ghostty. But, we do want to balance that with the desire to push the
terminal forward with stagnant standards and the slow pace of change in the
terminal ecosystem.

We haven't done any of this yet.

## Crash Reports

Ghostty has a built-in crash reporter that will generate and save crash
reports to disk. The crash reports are saved to the `$XDG_STATE_HOME/ghostty/crash`
directory. If `$XDG_STATE_HOME` is not set, the default is `~/.local/state`.
**Crash reports are _not_ automatically sent anywhere off your machine.**

Crash reports are only generated the next time Ghostty is started after a
crash. If Ghostty crashes and you want to generate a crash report, you must
restart Ghostty at least once. You should see a message in the log that a
crash report was generated.

> [!NOTE]
>
> Use the `ghostty +crash-report` CLI command to get a list of available crash
> reports. A future version of Ghostty will make the contents of the crash
> reports more easily viewable through the CLI and GUI.

Crash reports end in the `.ghosttycrash` extension. The crash reports are in
[Sentry envelope format](https://develop.sentry.dev/sdk/envelopes/). You can
upload these to your own Sentry account to view their contents, but the format
is also publicly documented so any other available tools can also be used.
The `ghostty +crash-report` CLI command can be used to list any crash reports.
A future version of Ghostty will show you the contents of the crash report
directly in the terminal.

To send the crash report to the Ghostty project, you can use the following
CLI command using the [Sentry CLI](https://docs.sentry.io/cli/installation/):

```shell-session
SENTRY_DSN=https://e914ee84fd895c4fe324afa3e53dac76@o4507352570920960.ingest.us.sentry.io/4507850923638784 sentry-cli send-envelope --raw <path to ghostty crash>
```

> [!WARNING]
>
> The crash report can contain sensitive information. The report doesn't
> purposely contain sensitive information, but it does contain the full
> stack memory of each thread at the time of the crash. This information
> is used to rebuild the stack trace but can also contain sensitive data
> depending on when the crash occurred.
