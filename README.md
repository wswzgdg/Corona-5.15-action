# Corona Kernel 5.15 Action

为了OnePlus sm8550 Corona内核定制 GKI 内核GitHub Actions🥰

## 支持的 ROOT 管理器

| 管理器 | 来源 | 分支 | KPM |
|--------|------|------|-------|-----|
| ReSukiSU | [ReSukiSU/ReSukiSU](https://github.com/ReSukiSU/ReSukiSU) | main | 支持 |
| SukiSU Ultra | [ShirkNeko/SukiSU-Ultra](https://github.com/ShirkNeko/SukiSU-Ultra) | builtin | 支持 |
| KSUNext | [pershoot/KernelSU-Next](https://github.com/pershoot/KernelSU-Next) | dev-susfs | - |
| KSU | [tiann/KernelSU](https://github.com/tiann/KernelSU) | dev | | - |
| KowSU | [KOWX712/KernelSU](https://github.com/KOWX712/KernelSU) | master | - |
| none | - | - | - | - |

所有管理器均集成 [SUSFS](https://gitlab.com/simonpunk/susfs4ksu) 内核补丁。

## 构建流程

``````

### 编译参数

- **工具链**：LLVM/Clang 22.1.0
- **架构**：arm64
- **内核Common**：[Corona-oplus-kernel/kernel_common_oplus](https://github.com/Corona-oplus-kernel/kernel_common_oplus)（android13-5.15-lts）

| Secret | 用途 |
|--------|------|
| `KERNEL_COMMON_TOKEN` | 访问 kernel_common_oplus 私有仓库 |
| `AK3_TOKEN` | 访问 AnyKernel3 私有仓库 （已公开） |

```
.github/workflows/
├── build-kernel-matrix.yml         # 构建内核 + 发布
├── kernel-build.yml                # 可复用构建模块
├── main.yml                        # 单次测试构建
├── clear-cache.yml                 # 缓存清理工具
├── test-release-metadata.yml       # 发布元数据测试
└── all_managers/
    ├── common.sh                   # 核心构建脚本
    ├── run_all.sh                  # 本地顺序构建
    ├── sukisu.sh                   # ↓各管理器包装脚本
    ├── resukisu.sh
    ├── ksunext.sh
    ├── ksu.sh
    └── kowsu.sh
```

欢迎使用github issues对本内核提出问题❛˓◞˂̵✧