# ysp-live-lua

一个把 `funwukong/ysp-live` 的央视频直播取流流程移植到 LuaJIT 的本机 HLS 清单服务。默认请求 720p（`shd`），视频分片由播放器直接从央视 CDN 拉取。

## 文件结构

- `src/ysp_service.lua`：本机 HTTP 清单服务与频道刷新逻辑
- `src/ysp_jce.lua`、`src/ysp_ckey.lua`：JCE 与 bkliveinfo/cKey 协议
- `src/ysp_channels.lua`：63 路频道元数据
- `src/ysp_gzip.lua`、`src/json.lua`：运行时依赖
- `src/ysp_runner.c`：只监听 `127.0.0.1` 的 LuaJIT HTTP 宿主
- `config/ysp_channels.m3u`：播放器导入清单

## 运行

需要 LuaJIT 开发文件、C 编译器、zlib 和 curl。编译本机宿主后，从项目根目录启动：

```sh
make
./build/ysp_runner src/ysp_service.lua 18766
```

服务只绑定回环地址。访问 `http://127.0.0.1:18766/all.m3u` 获取频道列表；播放器使用频道 URL 中的 HLS 清单直连上游 CDN。清晰度可通过 `YSP_SOURCE_QUALITY=hd|shd|fhd` 设置，默认是 `shd`。

## 来源与许可证状态

协议实现和频道元数据基于 [funwukong/ysp-live](https://github.com/funwukong/ysp-live)，参考提交 `15307414ad4fc1898a6a5faafc2536b683eb4110`。本项目为 LuaJIT 移植，相关源码文件保留了来源注释。

截至 2026-10-24，上游仓库没有 `LICENSE` 文件，README 与源码也未声明许可证。没有可据以分发该派生实现的上游开源许可，因此本仓库暂不附加许可证，也不应在获得上游作者授权或明确许可前公开发布派生代码。请勿把本段视为对上游代码授予许可。
