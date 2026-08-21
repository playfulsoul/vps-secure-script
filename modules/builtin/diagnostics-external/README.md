# Verified External Diagnostics

兼容旧版集成的 YABS、Bench、流媒体、NextTrace、Fusion 和 IP Quality。平台目录固定入口脚本的上游提交、许可证和 SHA-256，下载校验成功后才从临时目录执行，禁止 `curl | bash`。

这些工具属于第三方 root 代码，其中部分入口脚本会继续下载二进制或辅助脚本。平台对固定入口文件做完整性校验，但不能把该校验误称为对全部下游代码的审计；普通菜单会在运行前明确提示资源和信任风险。
