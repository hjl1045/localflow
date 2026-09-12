# LocalFlow

[English](README.md) · **中文**

按住一个键，说话，松开 —— 文字直接出现在光标处，不管你当时在用哪个 app。整条链路都跑在你自己的 Mac 上：没有云端、不用账号、不需要 API key。**音频永远不会离开你的电脑。**

```
⌃⌘M（按住）──► 说话 ──► 松开 ──► 文字落在光标位置
```

## 为什么

语音输入是把文字放进电脑最快的方式，但好用的听写工具几乎都会把你的声音传到别人的服务器上。LocalFlow 把整条流程放在 Apple 神经网络引擎（ANE）上跑，所以你可以放心口述私人消息、病历、还没发布的产品方案，不用先纠结要不要信任某个厂商。

速度足够日常使用：松开按键就开始转写，没有上传、没有网络往返。

## 功能

- **按住说话** —— 按住快捷键，说话，松开，文字粘贴到光标处。两个快捷键都在设置里自己录，选没被其他 app 占掉的组合。
- **免按模式** —— 点一下第二个快捷键开始，再点一下结束，适合长段口述。
- **多语言** —— 默认自动判断语种，也可以在设置里固定为 12 种之一（中、英、西、法、德、日、韩、葡、俄、意、印地、阿拉伯）；中英混说尤其顺。底层 Whisper 模型覆盖的语种更多，但不同语言准确度差异很大，本项目只实测过中文和英文，见 [docs/MODEL-UPDATES.md](docs/MODEL-UPDATES.md)。
- **可选的 AI 清理** —— 本地大模型负责补标点、去掉「呃」「那个」这类口头禅、处理说到一半改口的情况，同样全程离线。
- **静音不会变成文字** —— 你说完话到松开按键之间总有一小段空白，Whisper 不会忽略它：有时候加个注解（`[BLANK_AUDIO]`、`*music*`、`[laughter]`），有时候干脆编一个词出来（`Thank you.`）。所以末尾的静音在送进模型之前就被裁掉，漏网的注解再在落到光标之前去掉。
- **哪里都能用** —— 任何 app 的任何输入框：浏览器、编辑器、聊天窗口、终端、Slack、笔记。
- **菜单栏应用** —— 不占 Dock、不挡视线，录音时有一个悬浮的波形条提示正在收音。
- **最近转写记录** —— 菜单里保留最近 5 条，万一粘贴没落到正确位置还能找回来。

## 典型用法

| | |
|---|---|
| **消息和邮件** | 说一句回复，比打字快；清理那一步会把它变成有标点的正常句子，而不是一段语音流水账。 |
| **Commit message、代码注释** | 口述「为什么这么改」比敲出来快，技术词汇的识别也够稳。 |
| **笔记和日记** | 边想边说的长内容，直接进你本来就在用的笔记 app。 |
| **多语言写作** | 用一种语言说，或者说到一半切换语言，模型会跟上。 |
| **任何需要保密的场景** | 你不愿意发给第三方服务器的内容。 |

## 环境要求

- **Apple Silicon Mac**（M1 及以后）—— 语音模型跑在神经网络引擎上
- **macOS 14+**
- **Xcode 或命令行工具**（Swift 5.10+）—— 用于编译
- *可选：* [Ollama](https://ollama.com) + `ollama pull gemma3:4b`，用于 AI 清理功能

## 安装

从源码编译：

```sh
git clone https://github.com/hjl1045/localflow.git
cd localflow
make install
```

这条命令会编译、安装到 `/Applications` 并启动它。装好后在菜单栏找那个麦克风图标。

如果这台 Mac 不方便往 `/Applications` 写东西 —— 比如装了端点安全软件的公司电脑，或者你没有管理员权限 —— 可以改装到自己的用户目录：

```sh
make install-user
```

同一个 app、同一个签名、同样的权限，只是装在 `~/Applications`，不碰家目录以外的任何位置。LocalFlow 本来就没有 Dock 图标（是菜单栏应用），所以它已经是个后台服务了 —— 变的只是位置。`make uninstall-user` 可以卸掉。

同一台机器只装其中一个，**不要两个都装**：两份相同 bundle id 的副本会让 macOS 分不清快捷键和登录项指的是哪一个。如果公司电脑还是拦，[docs/DISTRIBUTION.md](docs/DISTRIBUTION.md) 里写了换位置能解决什么、不能解决什么。

首次运行时，LocalFlow 会下载语音模型（约 626 MB）并为神经网络引擎编译一次，大概需要一分钟，只有第一次。

### 权限

macOS 会弹两个权限请求，两个都必须给：

| 权限 | 用途 |
|---|---|
| **麦克风** | 按住快捷键时录音 |
| **辅助功能（Accessibility）** | 把文字粘贴进你正在用的那个 app |

## 使用

1. 光标点进任意输入框。
2. 按住 <kbd>⌃</kbd><kbd>⌘</kbd><kbd>M</kbd>（默认值，可在设置里改），说话，松开。
3. 文字出现在光标处。

菜单栏图标 → **Settings…** 可以改快捷键、选语言或模型、调整波形条位置、开启 AI 清理、设置开机自启。

### AI 清理（可选）

在设置里打开 *Clean up transcript with Ollama*，本地大模型会在粘贴前先把原始转写重写一遍：补标点、大小写、去口头禅、把说到一半改口的地方理顺。需要 Ollama 在运行：

```sh
brew install ollama && brew services start ollama
ollama pull gemma3:4b
```

如果连不上 Ollama，听写照常工作，只是给你原始转写结果，同时菜单栏会说明清理为什么被跳过。

## 性能

在 M 系列 Mac 上用默认模型（Whisper large-v3-turbo，压缩后 626 MB），跑**合成语音**基准语料实测 —— 干净、语速均匀。真实口述更杂乱也更慢，所以这组数字是下限而不是承诺：

| 语音长度 | 转写耗时 |
|---|---|
| 3.5 秒 | 0.83 秒 |
| 5.9 秒 | 1.06 秒 |
| 13.1 秒 | 1.33 秒 |

启动时加载模型约 4 秒（每次启动一次）。开启 AI 清理会再多几秒。

设置里还可以选更小更快的模型（small / base / tiny），用准确率换速度。实测错误率、以及如何用你自己的声音跑基准测试，见 [docs/MODEL-UPDATES.md](docs/MODEL-UPDATES.md)。

## 工作原理

```
快捷键按下 ──► AVAudioEngine（16 kHz 单声道）──► 实时音量 → 波形浮层
快捷键松开 ──► WhisperKit large-v3-turbo（神经网络引擎）──► 原始转写
                    └─► [可选] Ollama 清理 ──► 整理后的文本
                              └─► 保存剪贴板 → 粘贴 ⌘V → 还原剪贴板
```

| 文件 | 作用 |
|---|---|
| `AppState.swift` | 状态机：快捷键 → 录音 → 转写 → 清理 → 注入 |
| `AudioRecorder.swift` | 麦克风采集、16 kHz 单声道转换、实时音量 |
| `Transcriber.swift` | WhisperKit 封装，语言与解码选项 |
| `OllamaCleaner.swift` | 本地大模型排版（绝不阻塞听写） |
| `TextInjector.swift` | 保留剪贴板内容的光标处粘贴 |
| `RecordingOverlay.swift` | 悬浮波形条 |
| `LocalFlowApp.swift` | 菜单栏界面、设置窗口、无界面测试 CLI |

不用麦克风和界面的流水线测试：

```sh
./dist.noindex/LocalFlow.app/Contents/MacOS/LocalFlow --transcribe audio.wav [--language zh] [--clean]
```

## 文档

| 文档 | 内容 |
|---|---|
| [docs/MODEL-UPDATES.md](docs/MODEL-UPDATES.md) | 保持模型更新、用自己的音频做基准测试、实测结果 |
| [docs/DISTRIBUTION.md](docs/DISTRIBUTION.md) | 装到另一台 Mac、Homebrew cask、公证 |
| [docs/FEEDBACK.md](docs/FEEDBACK.md) | 反馈 bug 或崩溃报告、报告去哪里、如何符号化崩溃日志 |

## 更新检查

菜单栏里有两项，各自说明检查的是什么：

- **Check for app updates…** —— 问 GitHub 有没有发布更新版本的 LocalFlow，并可直接打开
  release 页面。下载包已做公证（notarized），双击即可打开。
- **Check for model updates…** —— 问 Hugging Face 自上次查看以来有没有新的语音模型。

**这两次点击是 LocalFlow 唯一联网的时刻。** 两者都不会定时运行，都不会发送任何与你或你的
听写内容相关的信息，只在你主动点击时发生。音频和转写文本完全不离开你的 Mac。

当前版本号显示在设置面板底部。

## 发现 bug，或者有问题？

最快的方式是在 App 里反馈：**菜单栏图标 → "Report an issue…"**。它会自动带上版本、
模型和设置这些排查必需的信息，把**将要发送的全部内容**先展示给你，然后在你自己的
邮件客户端里打开一封草稿 —— App 本身不会发送任何东西。转写文本只在你勾选后才会包含。

也可以直接[提 issue](https://github.com/hjl1045/localflow/issues)，或发邮件到
**hello@theautonomes.ai**。

## 基于这些项目

[WhisperKit](https://github.com/argmaxinc/WhisperKit)（在神经网络引擎上跑 Whisper）· [Whisper](https://github.com/openai/whisper) · [KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts) · [Ollama](https://ollama.com)

## 许可

[MIT](LICENSE)
