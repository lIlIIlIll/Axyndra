# sandbox_runtime

Linux workspace sandbox，使用 bubblewrap 强制文件系统、进程、网络、环境变量和
资源边界。调用方提交结构化 argv，不提交 shell 字符串；环境默认为空，只允许显式
allowlist/binding。Secret redactor 同时按敏感变量名和已知值处理输出。

隔离运行时缺失、namespace 被宿主禁止或策略无法表达时返回 `Unsupported`，绝不
静默降级成 host execution。逻辑 Approval 与该强制边界是两层独立控制。
