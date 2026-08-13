# 「Post Apocalyptic Wastelands」三分钟循环片段处理记录

## 资产

- 源文件：`音效/BGM/Juhani Junkala - Post Apocalyptic Wastelands [Loop Ready].ogg`
- 输出文件：`音效/BGM/post_apocalyptic_wastelands_loop_180s.ogg`
- 输出文件大小：9,470,882 字节。
- 用途：仅在夜班阶段播放的背景音乐；由唯一 `BgmPlayer` 服务中的夜班播放器路由到 `Ambience` 总线，循环从 0 秒开始。

## 源与输出参数

- 源格式：Ogg/Vorbis，44,100 Hz，双声道，时长 323.850567 秒。
- 输出格式：Ogg/Vorbis，44,100 Hz，双声道，时长 180.000000 秒。
- 截取范围：`00:00.000`（含）至 `03:00.000`（止），即用户指定的从头到三分钟。
- 输出日期：2026-08-12。
- 作者：Juhani Junkala（来自用户提供的源文件名）。

## 处理工具与命令

- 工具：FFmpeg 8.0。
- 已有本机路径：`E:\Other\Anaconda\envs\py312\Library\bin\ffmpeg.exe`。
- 来源：开发机既有 Anaconda `py312` 环境的 FFmpeg 组件；本次处理未下载、安装、更新或写入任何外部依赖，FFmpeg 二进制也未复制到项目仓库。
- 处理命令（以项目根目录为工作目录）：

```powershell
& 'E:\Other\Anaconda\envs\py312\Library\bin\ffmpeg.exe' `
  -hide_banner -nostdin -v error `
  -i '音效/BGM/Juhani Junkala - Post Apocalyptic Wastelands [Loop Ready].ogg' `
  -map 0:a:0 -t 180.000 -c:a libvorbis -q:a 10 `
  -metadata title='Post Apocalyptic Wastelands (0-3:00 Loop)' `
  -metadata artist='Juhani Junkala' `
  -metadata comment='Derived from the user-provided source; exact range 00:00.000-03:00.000.' `
  '音效/BGM/post_apocalyptic_wastelands_loop_180s.ogg'
```

## 边界与验收

- 使用 FFprobe 复核输出时长为 180.000000 秒，格式为 Ogg/Vorbis、44,100 Hz、双声道。
- Godot 4.7.1 已成功导入为 `AudioStreamOggVorbis`；运行时将循环标志设为真、循环起点设为 0 秒。
- 对源音频 `00:00` 与 `03:00` 边界附近的采样检查：末样本与首样本的绝对差相对于相邻窗口 RMS 分别为左声道 0.76%、右声道 0.08%。未加入交叉淡化或延长/缩短片段，以严格保持用户指定的 `00:00` 至 `03:00` 范围。

## 授权状态

- 工作区未附带此音乐的授权、许可证或来源页面凭据。
- 本记录仅说明用户提供资产的技术处理，**不构成授权证明**；在公开发布、分发或商用前，必须补齐可分发许可和来源凭据。
