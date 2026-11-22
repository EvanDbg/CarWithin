# 源码构建说明

本分支为 **CarWithin Local 实验版**，基于官方 1.0.3（build 15），使用独立 Bundle ID `com.evandbg.carwithin.local` 和显示名 `CarWithin Local`。源码构建及公共 CI 不包含配件身份。连接模式、验证边界与验收步骤见 [仅本机模式说明](docs/LOCAL-ONLY.md)。

使用 Xcode 打开 TDSCarKit.xcodeproj，选择 TDSCarKit scheme，配置自己的开发团队、Bundle ID 和签名，再构建 iOS 目标。最低部署目标为 iOS 16.0。

源码不包含配件认证身份、私钥、证书或 Apple 签名材料。没有可用身份时应用可编译，但本机 CarPlay 连接需要另行配置有效身份。Tools/generate_project.py 会将本地 App/BundledIdentity 内的文件加入生成的工程，请勿把该目录中的身份材料提交到公开仓库。

本分支可以在安装后通过「设置 → 配件身份 → 导入身份文件夹」选择包含 `certificate.p7b`、`leaf.cer`、`private.x963` 的文件夹。应用进行本地自检后保存到 Keychain，不修改原文件，也不会上传。Apple 应用签名与这份配件身份是两个独立条件。

`Tools/generate_project.py --fresh` 可重新生成工程并使用环境变量或本分支默认签名设置；不带该参数时保留原有 Xcode 签名选择。公共构建可运行 `bash Tools/build_local_ipa.sh`，需要 macOS 和 Xcode。编译、协议测试和回环 socket 测试均不能代替真实 iPhone 的 CarPlay 会话验证。

发布安装包与源码应对应同一代码版本。第三方许可与来源见 THIRD_PARTY_NOTICES.txt 和 LICENSES。
