# 「Dream 2 (Ambience)」菜单循环片段处理记录

## 资产

- 源文件：`音效/BGM/Dream 2 (Ambience).mp3`（用户提供，保留不覆盖）。
- 输出文件：`音效/BGM/dream_2_ambience_loop_110s.ogg`。
- 用途：主菜单背景音乐；由 `BgmPlayer` 路由至既有 `Ambience` 总线。运行时仅在该播放器上施加 `-4 dB` 独立响度，不改动 `Ambience` 总线或夜班 BGM。

## 源与输出参数

- 源格式：MP3、44,100 Hz、双声道、129.462850 秒。
- 输出格式：Ogg/Vorbis、44,100 Hz、双声道、110.000000 秒。
- 截取范围：`00:00.000`（含）至 `01:50.000`（止）。
- 输出日期：2026-08-13。

## 处理工具与命令

- 工具：开发机既有 FFmpeg 8.0，路径 `E:\Other\Anaconda\envs\py312\Library\bin\ffmpeg.exe`；未下载、安装或复制该工具进项目。

```powershell
& 'E:\Other\Anaconda\envs\py312\Library\bin\ffmpeg.exe' `
  -hide_banner -nostdin -v error `
  -i '音效/BGM/Dream 2 (Ambience).mp3' `
  -map 0:a:0 -t 110.000 -c:a libvorbis -q:a 8 `
  -metadata title='Dream 2 (Ambience) (0-1:50 Loop)' `
  -metadata comment='Derived from user-provided source; exact range 00:00.000-01:50.000.' `
  '音效/BGM/dream_2_ambience_loop_110s.ogg'
```

FFprobe 已复核输出为 110.000000 秒；因此 Godot 的前向循环能在精确的 1:50 边界回到 0 秒，而不依赖 MP3 没有 loop end 的 `loop_offset` 属性。

## 授权状态

- 工作区未附带该音乐的作者、来源页面或可分发授权凭据。
- 本记录仅追溯用户提供素材的技术处理，不构成授权证明；公开发布、分发或商用前仍须补齐许可。
