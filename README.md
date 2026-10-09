# blackout

把每块显示器盖成纯黑，程序继续跑，会话保持解锁。黑屏后没有输入框。打一串字，里面含有你设的口令即可，前后可以夹别的字符，然后按回车。

A fullscreen black cover for macOS. Programs keep running and the session stays unlocked. Nothing is drawn on the black screen. Type any text that contains your passphrase, then press Return.

[中文](#中文) · [English](#english)

## 中文

### 它做什么

`blackout` 在每块显示器上放一层不透明黑窗，盖住菜单栏、程序坞和普通窗口。光标会藏起来。点击、拖动、滚动和键盘会被吞掉，所以盲打的字符不会进到底下的文档里。

它不锁会话。编译、下载、播放这些进程继续跑。平常也不抢走当前应用的焦点。只有焦点当时在密码框里时才会先拿走焦点，否则 macOS 不允许别的程序看到这些按键，口令会失效。

纯英文口令会临时切到 ABC 输入法，退出后切回去。口令匹配只发生在内存里，按键不会写进日志。工具本身不联网。

### 怎么退出

屏幕上不会出现提示，也不会告诉你该打什么。你要打的是运行 `blackout set-phrase` 时自己设下的那一句。

1. 先设口令。下面这个例子把口令设成 `open-sesame`。输入时终端不回显。

   ```bash
   blackout set-phrase
   ```

2. 用 demo 练一次。画面黑 5 秒，然后自己恢复。这 5 秒里打出 `open-sesame` 再按回车，会立刻恢复。口令前后可以夹别的字，例如 `xxopen-sesameyy` 再按回车也可以。

   ```bash
   blackout demo
   ```

3. 正式黑屏后同样这么做。区分大小写。回车时这段文字里含有口令，画面才回来。没有口令就保持黑屏，刚才打的内容作废。退格键可以删掉刚打错的字符。只打口令、不按回车，不会退出。

   ```bash
   blackout
   ```

至少 5 个字符，最多 128 个。不要用同一种字符重复，别人一直按一个键时有机会撞上。口令含中文或其他非 ASCII 字符时，黑屏期间不会切换输入法，输入法候选条可能露出来。

忘了口令时，从另一台电脑 SSH 到这台 Mac，执行：

```bash
~/.local/bin/blackout off
```

这台机器上如果已经有别的终端，也可以在那里执行同一条命令。`killall blackout` 同样会揭开画面。重启之后遮罩消失，桌面按你原来的登录设置回来。

### 下载安装

打开 `Blackout-1.0.dmg`，把 Blackout 拖到「应用程序」文件夹，再双击打开。

第一次从网上打开时，macOS 会说无法验证开发者。这个安装包没有做公证。在访达里按住 Control 点 Blackout，选「打开」，再确认一次。也可以在拖进应用程序之后执行：

```bash
xattr -dr com.apple.quarantine /Applications/Blackout.app
```

还没有口令时，应用会问要不要打开终端。在终端里输入口令，输入时不显示，要再输入一次。设好之后回到访达再打开一次，它就在后台等快捷键 Control+Option+Command+B，不会立刻黑屏。这个应用不出现在程序坞里。

终端命令写在 `~/.local/bin/blackout`。如果终端提示找不到命令，执行：

```bash
export PATH="$HOME/.local/bin:$PATH"
```

第一次黑屏前，还要在「系统设置 → 隐私与安全性 → 输入监控」里允许 Blackout。允许的是已经放进「应用程序」的那一份，允许之后不要再移动它。

### 从源码编译

需要 macOS 13 或更新版本，以及 Xcode 或 Command Line Tools 里的 `swiftc`。在要使用的那台 Mac 上编译：

```bash
git clone https://github.com/ggvswild/blackout.git
cd blackout
./build.sh
```

`build.sh` 会生成 `Blackout.app`，做 ad-hoc 签名，并在 `~/.local/bin/blackout` 放一个启动脚本。请确认这个目录在 `PATH` 里。`./dmg.sh` 会先编译，再打出 `dist/Blackout-1.0.dmg`。

### 命令

| 命令 | 作用 |
| --- | --- |
| `blackout set-phrase` | 设置解锁口令。口令不作为参数传入，避免进 shell 历史。 |
| `blackout` | 立刻黑屏。解锁后进程退出。终端里直接运行就是这个行为。 |
| `blackout engage` | 同上。快捷指令请用这个，因为快捷指令通常没有终端，裸跑 `blackout` 会进入等待而不是黑屏。 |
| `blackout watch` | 常驻后台。按 Control+Option+Command+B 黑屏，解锁后继续等待。 |
| `blackout demo` | 黑 5 秒后自己恢复，用来确认每块屏都被盖住，并练习盲打。 |
| `blackout off` | 解除黑屏，不结束常驻进程。SSH 可用。 |
| `blackout quit` | 解除黑屏并结束后台进程。 |
| `blackout status` | 查看是否在运行、口令是否已设置、程序实际路径。不打印口令。 |
| `blackout --show-cursor` | 光标如果还藏着，用这个恢复。 |
| `blackout --visual-only` | 只盖黑窗，不拦全局快捷键。聚焦、切换应用、调度中心可能露出底下的窗口。 |
| `blackout --self-test` | 跑口令匹配自测，不会黑屏。 |
| `blackout help` | 在终端里看简要说明。 |

从访达打开 `Blackout.app`，或把它放进登录项时，进入等待快捷键，不会立刻黑屏。关掉启动它的终端也不会让常驻进程退出。

快捷键按的是物理 B 键，不随键盘布局改变。

### 权限

第一次黑屏会失败，并打开系统设置。这次不会盖住屏幕，避免授权窗口被自己挡住。

到「系统设置 → 隐私与安全性 → 输入监控」允许 `blackout`。列表里没有的话，再看「辅助功能」。允许后重新运行。

权限绑在 `Blackout.app` 里的可执行文件上。允许之后不要移动这个 App。`blackout status` 会打印实际路径。重新编译会改变签名，权限可能失效，把列表里的旧项删掉再允许一次。

### 口令存在哪

```text
~/.config/blackout/phrase
```

目录权限 `700`，口令文件权限 `600`。黑屏进程启动时把口令读进内存。黑屏过程中修改口令，要等这次黑屏结束后，下次才生效。

`HOME` 环境变量会决定配置目录的位置。

### 它挡不住什么

这层黑只挡住看着这块屏幕的人。

- SSH、已经连上的远程控制，或另一个管理员，都可以结束进程，画面立刻回来。
- 重启或长按电源键之后，遮罩消失。
- 整屏共享通常只能看到黑。如果共享的是某一个窗口，仍可能看到内容。
- 三指上滑进调度中心时，缩略图里有可能出现底下的窗口。触控板手势不保证经过能被拦住的事件。鼠标移动也没有被吞掉，热角仍可能触发。
- 背光还亮着。声音、键盘灯、风扇不会停。
- 合盖之后会不会出现真正的登录界面，取决于系统里「唤醒需要密码」的设置。

锁屏用 Control+Command+Q。那是登录边界，画面上会有头像和时钟，进程同样不会被杀掉。只让显示器睡眠更像关机，但任何人按一下键都能唤醒。

### 卡住了

按这个顺序试：

1. 打一串含有口令的字，然后按回车。
2. SSH 到这台 Mac，运行 `~/.local/bin/blackout off`。
3. 还在的话运行 `~/.local/bin/blackout quit`，或 `killall blackout`。
4. 光标没回来就运行 `blackout --show-cursor`。
5. 进程如果在黑屏中途崩溃，下次再运行 `blackout` 的任意命令时，会尝试把输入法切回去。

## English

### What it does

`blackout` puts an opaque black window on every display. The window covers the menu bar, the Dock, and normal windows. The cursor is hidden. Clicks, drags, scrolling, and keystrokes are swallowed, so the characters you type do not land in the document underneath.

The session stays unlocked. Builds, downloads, and playback keep running. The front app keeps focus in the normal case. Focus is taken only when it is currently in a password field. macOS hides those keystrokes from other programs, and the passphrase would not arrive otherwise.

An ASCII passphrase temporarily switches the keyboard to the ABC input source. The previous input source is restored on exit. Phrase matching stays in memory. Keystrokes are not written to a log. The tool does not use the network.

### How to get out

The black screen has no field and no hint. You type the passphrase you stored with `blackout set-phrase`.

1. Set it first. This example uses `open-sesame`. The terminal does not echo it.

   ```bash
   blackout set-phrase
   ```

2. Practice with the demo. The screen goes black for 5 seconds, then comes back by itself. During those 5 seconds, type `open-sesame` and press Return. Extra characters before or after the phrase are fine, so `xxopen-sesameyy` then Return also works.

   ```bash
   blackout demo
   ```

3. Cover the screen the same way. Matching is case-sensitive. Return checks the text you just typed. If that text contains the phrase, the cover clears. If it does not, the screen stays black and that attempt is discarded. Backspace deletes the last character. Typing the phrase without Return does nothing.

   ```bash
   blackout
   ```

Use at least 5 characters and at most 128. A passphrase made of one repeated character can be hit by someone holding a key. A passphrase with Chinese or other non-ASCII characters does not switch the input source, so an input-method candidate window may appear.

If you forget the phrase, SSH into this Mac from another computer and run:

```bash
~/.local/bin/blackout off
```

An existing terminal on this Mac can run the same command. `killall blackout` also removes the cover. After a reboot the cover is gone, and the desktop returns under your normal login settings.

### Download

Open `Blackout-1.0.dmg`, drag Blackout to Applications, then open it.

The disk image is not notarized. The first time macOS says the developer cannot be verified, Control-click Blackout in Finder, choose Open, and confirm. After it is in Applications you can also run:

```bash
xattr -dr com.apple.quarantine /Applications/Blackout.app
```

If no passphrase is stored yet, the app offers to open Terminal. Type the passphrase twice. It is not echoed. Open the app from Finder again after that. It waits for Control+Option+Command+B and does not cover the screen immediately. It does not show a Dock icon.

The command is installed at `~/.local/bin/blackout`. If the shell cannot find it:

```bash
export PATH="$HOME/.local/bin:$PATH"
```

Before the first cover, allow Blackout under System Settings → Privacy & Security → Input Monitoring. Allow the copy in Applications, and do not move it after that.

### Build from source

macOS 13 or later, and `swiftc` from Xcode or the Command Line Tools. Build it on the Mac where you will run it:

```bash
git clone https://github.com/ggvswild/blackout.git
cd blackout
./build.sh
```

`build.sh` creates `Blackout.app`, ad-hoc signs it, and writes a launcher to `~/.local/bin/blackout`. That directory needs to be on your `PATH`. `./dmg.sh` builds the app, then writes `dist/Blackout-1.0.dmg`.

### Commands

| Command | What it does |
| --- | --- |
| `blackout set-phrase` | Store the unlock phrase. It is not taken as an argument, so it does not land in shell history. |
| `blackout` | Cover the screen now. The process exits after unlock. This is what a terminal runs when you pass no arguments. |
| `blackout engage` | Same as above. Use this from Shortcuts. A bare `blackout` with no terminal starts waiting instead of covering. |
| `blackout watch` | Stay running. Control+Option+Command+B covers the screen, and unlock returns to waiting. |
| `blackout demo` | Cover for 5 seconds, then restore. Use it to check every display and to practice the phrase. |
| `blackout off` | Remove the cover and leave a resident process running. Works over SSH. |
| `blackout quit` | Remove the cover and stop the resident process. |
| `blackout status` | Show whether it is running, whether a phrase is set, and the real program path. The phrase is not printed. |
| `blackout --show-cursor` | Show the cursor again if it stays hidden. |
| `blackout --visual-only` | Draw the black windows without swallowing global hotkeys. Spotlight, app switching, and Mission Control may reveal the windows underneath. |
| `blackout --self-test` | Run the phrase-matcher checks. The screen stays visible. |
| `blackout help` | Print the short usage text. |

Opening `Blackout.app` from Finder, or adding it to Login Items, starts the waiting mode. The screen is not covered immediately. Closing the terminal that launched a resident process does not stop it.

The hotkey is the physical B key. The keyboard layout does not change which key it is.

### Permission

The first cover attempt fails and opens System Settings. The screen stays visible so the permission dialog is not hidden behind the cover.

Allow `blackout` under System Settings → Privacy & Security → Input Monitoring. If it is missing there, also check Accessibility. Run the command again after allowing it.

The grant is tied to the executable inside `Blackout.app`. Do not move the app after allowing it. `blackout status` prints the path in use. A rebuild changes the ad-hoc signature, and macOS may forget the grant. Remove the old entry and allow it again.

### Where the phrase lives

```text
~/.config/blackout/phrase
```

The directory is mode `700` and the phrase file is mode `600`. A running cover reads the phrase into memory when it engages. A phrase changed during a cover takes effect on the next cover.

The `HOME` environment variable selects the configuration directory.

### What it cannot stop

The cover hides the picture from someone looking at these displays.

- SSH, an already connected remote-control session, or another administrator can stop the process. The desktop comes back immediately.
- Reboot and a held power button remove the cover.
- A full-display share usually shows black. A share of one specific window can still show that window.
- A three-finger swipe into Mission Control may show thumbnails of the windows underneath. Trackpad gestures are not guaranteed to pass through an event this tool can swallow. Mouse movement is not swallowed either, so hot corners can still fire.
- The backlight stays on. Sound, the keyboard backlight, and the fans keep going.
- Whether closing the lid shows the real login window depends on the system setting that requires a password on wake.

The real lock is Control+Command+Q. That is the login boundary. It shows your picture and a clock, and it also leaves processes running. Putting the display to sleep looks more like the screen is off, and any key wakes it.

### If you get stuck

Try these in order:

1. Type text that contains the passphrase, then press Return.
2. SSH into this Mac and run `~/.local/bin/blackout off`.
3. If it is still covered, run `~/.local/bin/blackout quit`, or `killall blackout`.
4. If the cursor stays hidden, run `blackout --show-cursor`.
5. If the process dies while the screen is covered, the next `blackout` command tries to restore the previous input source.
