# rexmote

Open a Mac desktop beside the terminal in a remote [Rex](https://www.superlogical.com/rex) session. Press **⌘⇧M** and the Mac hosting that session creates a virtual display for the new pane. Drag the divider to resize it. Open a second pane for a second display.

You can use the remote Mac’s apps, send keyboard shortcuts to the focused app, and copy files between Finder windows on the two Macs. The connection uses SSH and works with Apple Screen Sharing turned off.

## Quick start

Rexmote targets **macOS 14 or later**. You need two Macs, the Xcode Command Line Tools to build from source, and a remote Rex session that you can already open on the viewing Mac. Install the same revision of Rexmote on both machines. [Rex installation](https://www.superlogical.com/rex/docs/installation)

1. **On both Macs**, clone the project and enter the checkout.

   ```sh
   git clone https://github.com/rayhanadev/rexmote.git
   cd rexmote
   ```

2. **On the Mac hosting the Rex session**, sign in to the graphical desktop. In **System Settings → General → Sharing**, enable **Remote Login** for the account running that session. Install the host and open its permissions window.

   ```sh
   ./install.sh --host-only
   ~/.local/bin/rexmote setup
   ```

   Grant **Rexmote Host** Screen Recording for capture and Accessibility for keyboard and pointer input. The host needs a signed-in, unlocked graphical session for interactive use. [Apple’s Remote Login guide](https://support.apple.com/guide/mac-help/allow-a-remote-computer-to-access-your-mac-mchlp1066/mac)

3. **On the viewing Mac**, run the installer. It builds the app, installs the viewer in your graphical login session, and registers the desktop actions in Rex.

   ```sh
   ./install.sh
   ```

4. In Rex, select the session on the other Mac and press **⌘⇧M**. If SSH needs a password, enter it in the pane. Click the desktop to give the remote app keyboard focus.

## Using the pane

| Action | Control |
| --- | --- |
| Open a desktop beside the selected pane | **⌘⇧M** while Rex has keyboard focus |
| Open a desktop in its own tab | **Open Remote Desktop Tab** in the Rex command palette |
| Resize the desktop | Drag the Rex split divider |
| Close a tab in the remote browser | **⌘W** while the desktop has keyboard focus |
| Return keyboard focus to Rex | **Control–Option–backtick** |
| Focus a neighboring Rex pane | **Control–Option–arrow** |

Each display belongs to its pane until you close it. Two panes on the same host are two displays in the same macOS login session. Focus the app you want to control, just as you would on a Mac with multiple monitors.

The focused pane forwards trackpad scrolling, including horizontal motion and momentum. It also forwards pinch, rotation, smart magnify and swipe events that macOS delivers to the pane. The receiving app determines what each gesture does.

## Clipboard and Finder

Copy on either side with **⌘C** and paste on the other with **⌘V**. Panes on the same Mac and login share its clipboard, so you can paste a selection into a second pane while it is still transferring to the viewing Mac. Text, rich text, links and images travel over the pane connection, up to 32 MiB per clipboard transfer.

For files, select one or more items in Finder and press **⌘C**. Open the destination folder in Finder on the other side and press **⌘V**. When copying from the pane, paste locally once Rex reports that the files are ready. When pasting into the pane, leave the destination focused while the files arrive. Finder handles naming conflicts. File transfers report their status through [Rex program activity](https://www.superlogical.com/rex/docs/build/program-status).

Rexmote uses native Finder file URLs on each Mac and transfers the contents with the system rsync over a separate SSH channel. Files and folders need staging space on both Macs. A selection can include up to 1,024 items. This also works across the network when the Macs are far apart or use different Apple Accounts. Apple’s Universal Clipboard requires nearby devices with the same Apple Account and Handoff enabled. [Universal Clipboard requirements](https://support.apple.com/en-us/102430)

## How it works

Rex owns the split, tab and pane header. A silent process keeps the Rex block alive. The viewer positions a borderless native window over the block. Rex supplies the session host’s identity and SSH public keys, which the viewer verifies before connecting.

On the host, a helper creates the virtual display using a private Core Graphics API and captures it with ScreenCaptureKit. The stream carries lossless pixel updates, including verified runs of pixels reused while scrolling. On a Retina viewing Mac, eligible panes use a 2× backing resolution. Capture targets up to 60 Hz and 3840 × 2160 pixels. The delivered frame rate depends on the changed area and connection speed. The private display API makes compatibility with new macOS releases worth testing.

## CLI and development

The installer places the app in `~/Applications/Rexmote.app` and links `rexmote` in `~/.local/bin`. To capture a screenshot from the command line, select the remote session in Rex and run these commands on the viewing Mac with `~/.local/bin` on your PATH.

```sh
block=$(rexmote open --no-wait)
rexmote wait -b "$block" --state ready
rexmote info -b "$block" --json
rexmote screenshot desktop.png -b "$block"
```

Use `rexmote doctor` to inspect the local installation. Run `swift test` from the checkout to exercise the frame protocol, display sizing, input, clipboard and pane lifecycle. To build the signed app bundle without installing it, run `./scripts/build.sh`.

## Uninstall

Run `./uninstall.sh` from the checkout on the viewing Mac and `./uninstall.sh --host-only` on the session host.

## License and credits

Rexmote is available under the [MIT License](LICENSE).

The Rex pane workflow follows rexweb by Jordan Coeyman. Its MIT notice is included in the source and the built app. [rexweb](https://github.com/acoyfellow/rexweb) · [Upstream notice](Notices/rexweb-LICENSE)
