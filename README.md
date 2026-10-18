<div align="center">

<h1>
  <img src="https://raw.githubusercontent.com/Seggys116/Orbit/main/.github/assets/icon.png" alt="" width="72" align="absmiddle" />
  &nbsp;Orbit
</h1>

**The open-source Arc we have all been waiting for.**

A native macOS browser built on WebKit.
Local-first. No account, no telemetry.

</div>

<div align="center">

<img src="https://raw.githubusercontent.com/Seggys116/Orbit/main/.github/assets/window.png" alt="An Orbit window: the sidebar in a blue-themed Work space with a favourites grid, a Q4 Launches folder and today's tabs, next to a loaded page." width="900" />

</div>

---

<div align="center">

<img src="https://raw.githubusercontent.com/Seggys116/Orbit/main/.github/assets/window-focus.png" alt="An Orbit window with the sidebar hidden, the page running the full width of the content card." width="900" />

<img src="https://raw.githubusercontent.com/Seggys116/Orbit/main/.github/assets/sidebar.png" alt="Orbit's sidebar in a violet-themed Personal space: a favourites grid, a Reading folder of pinned tabs, today's tabs, and the space switcher along the bottom." width="900" />

<img src="https://raw.githubusercontent.com/Seggys116/Orbit/main/.github/assets/command-bar.png" alt="Orbit's command bar open over a page, the query “design” typed in, ranking an open tab above favourites and Google suggestions." width="900" />

<img src="https://raw.githubusercontent.com/Seggys116/Orbit/main/.github/assets/split-view.png" alt="Three panes side by side in one Orbit window, each with its own address bar and its own page loaded." width="900" />

</div>

## Building

Requires macOS 15.4 or later and Xcode.

```
git clone https://github.com/Seggys116/Orbit.git
cd Orbit
open Orbit.xcodeproj
```

Then press Build. There is no bootstrap step to run first.

The app renders with the system WebKit. Chrome extensions load through WebKit's
extension controller, with Orbit's chrome API wrapper for the namespaces WebKit
does not implement itself.

---

Licensed under [AGPL-3.0](LICENSE).

<div align="center">

<a href="https://www.buymeacoffee.com/seggy116"><img src="https://cdn.buymeacoffee.com/buttons/v2/default-violet.png" alt="Buy me a coffee" height="50" /></a>

</div>
