# 双渠道离线构建资产

两个 Release 构建共用一个只读输入目录。默认位置为 `~/Library/Application Support/LiveCopilotBuildAssets/v1`。设置 `LIVECOPILOT_ASSET_ROOT` 可以指定另一份经校验的构建资产库。应用启动后只读取包内资源。

`assets.json` 列出 26 个相对路径和每个文件的 SHA-256。分组为 Arctic 模型与词表、W8 G64 编译图与外置词表、模型许可、原生头文件、Universal 运行库和 Zipformer/Silero。Arctic 固定来源与版本见 `arctic.json`，W8 G64 的验收图文件见 `w8-g64-receipt.json`，Zipformer 见仓库的 `docs/zipformer-model-manifest.json`。W8 的已验收编译图和动态库需要随内部构建资产镜像备份；一份源码 checkout 需要另行挂载或导入该镜像。请在生成新模型收据前单独完成数值验收。

从仓库根目录执行。第一条可在新机器从只读镜像导入，目标已存在时只校验。源、复制后的临时目录都通过校验，才会将目录改名提交到目标位置。有缺件或散列不同会退出。

```sh
python3 StealthApp/scripts/stage-offline-runtime.py --import-assets "/Volumes/BuildAssets/LiveCopilot/v1"
python3 StealthApp/scripts/stage-offline-runtime.py --verify-assets
bash StealthApp/scripts/build.sh
python3 StealthApp/scripts/build-mas.py --evidence-dir "$PWD/StealthApp/build/mas-evidence"
```

需要本机 Xcode、XcodeGen 和 Python 3.9+。官网的 prepare-sparkle.sh 会校验固定版本的官方归档。离线构建时可预置其要求的归档到 StealthApp/build/SparkleTools。所有模型与原生头文件均从上面的资产库读取。MAS 从原始动态库创建临时副本，为两个架构设置 macOS 14.0 部署下限，再完成签名。
