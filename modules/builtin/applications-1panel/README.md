# 1Panel v2 Management

使用 1Panel 官方 v2 安装地址，但不再 `curl | bash`。平台随版本维护入口脚本的 SHA-256，下载校验通过后才运行；如果上游脚本发生变化，安装会安全停止并等待平台目录更新。官方入口脚本仍会继续下载 1Panel 软件包，因此该模块保持 `external-root` 风险级别。
