# SensorGuard

面向 Windows 的硬件传感器守护：持续读取 CPU / GPU / 主板 / NVMe 的温度、负载、风扇，指标持续越界时推送到飞书群机器人，便于人在外面时及时处置。

不是看板，不是时序数据库。它只做一件事：**异常了，把人和现场情况一起叫醒。**

```
LibreHardwareMonitorLib  ──►  规则状态机  ──►  飞书自定义机器人
   (温度/负载/风扇)         (持续判定/去重)      (加签 + 卡片 + 节流)
         │
         ▼
   logs/YYYY-MM-DD/*.jsonl  (采样 + 事件，可事后 grep)
```

## 为什么用它

一台 7×24 常开的 Windows 机器，最常见的两类事故不是业务挂了，而是：

- **某个进程跑飞了没停**（转码、训练、挖矿、崩溃后重启的死循环），CPU/GPU 长时间满载；
- **散热慢慢坏了**（硅脂干、风扇积灰、风道堵），同负载下温度一路爬升，等你发现时已经在降频。

这两类问题都不会瞬间报错，只会"持续偏高"，所以瞬时阈值监控要么不报，要么乱报。SensorGuard 的判定都带**持续时间**，告警里还带上**占用最高的进程**，减少你远程上去再排查的来回。

## 特性

- **温度是主角**：CPU Package、GPU 核心、GPU Hot Spot、NVMe，全部来自 LibreHardwareMonitor 的真实传感器（不是估算值）
- **持续判定**：`forSeconds` 内持续越界才告警，瞬时抖动不会吵你
- **告警要有归因**：卡片里附 top-N CPU 占用进程（PID + 百分比）
- **散热劣化早期信号**：内置 `GPU Hot Spot − GPU Core` 温差规则（大于 25 °C 通常意味着散热接触不良）
- **不刷屏**：同一轮多条规则同时触发会合并成一张卡片；同一条告警重复通知的间隔有 3 分钟硬下限，另有全局发送节流与 429 退避
- **恢复通知**：指标回落会发一条绿色的"已恢复"，不会让你永远猜现在好没好
- **日志齐全但不画图**：每天一个 JSONL 目录，采样和事件分开，随时 `grep` / `jq`
- **不做自动处置**：不杀进程、不降频、不关机。它只负责告诉你

## 实测情况

在以下配置上验证（Windows 11 + Windows PowerShell 5.1，管理员权限 + PawnIO 驱动已安装）：

| 硬件 | 传感器可读性 |
|---|---|
| Intel i5-12600KF（12 代，6P+4E） | 负载 + 温度（Package / Core Max / 各 P-Core 与 E-Core） |
| NVIDIA RTX 4060 Ti | 核心温度、Hot Spot、负载、功耗、风扇 |
| AMD RX 6600 XT | 核心温度、Hot Spot、负载、风扇 |
| KIOXIA NVMe | Composite / 各传感器温度 |
| Gigabyte Z790 D 主板 | SuperIO 风扇与温度（取决于主板支持） |

共 255 个可读传感器。`-DumpSensors` 可以在你自己的机器上核对清单。

## 快速开始

```powershell
# 1. 准备 LibreHardwareMonitor 运行库（下载官方 release 到 .\vendor）
powershell -ExecutionPolicy Bypass -File .\scripts\setup.ps1
#    网络需要代理时：-Proxy http://127.0.0.1:7897

# 1.5 安装 PawnIO 底层驱动（LHM 0.9.5+ 必需，否则读不到 CPU/主板温度）
#     需要管理员权限：winget install --id namazso.PawnIO --exact

# 2. 配置飞书机器人
notepad .\config.json        # 填 feishu.webhook 和 feishu.secret

# 3. 先核对本机能读到哪些传感器
powershell -ExecutionPolicy Bypass -File .\src\SensorGuard.ps1 -DumpSensors

# 4. 发一张测试卡片（不发真实推送则加 -DryRun）
powershell -ExecutionPolicy Bypass -File .\src\SensorGuard.ps1 -TestNotify

# 5. 前台跑一轮看看判定是否符合预期
powershell -ExecutionPolicy Bypass -File .\src\SensorGuard.ps1 -Once -DryRun

# 6. 注册开机自启（需要管理员）
powershell -ExecutionPolicy Bypass -File .\scripts\install-task.ps1 -StartNow
```

飞书群机器人：群设置 → 群机器人 → 添加机器人 → 自定义机器人。安全设置选**签名校验**，把密钥填进 `feishu.secret`；地址填 `feishu.webhook`。

## 配置

`config.json` 由 `config.example.json` 复制而来。

| 字段 | 说明 |
|---|---|
| `intervalSeconds` | 采样与判定周期，默认 15 秒（最小 5） |
| `lhm.dllPath` | 自定义运行库路径；为空时依次找 `vendor\`、`%TEMP%\lhm\` |
| `feishu.enabled` | 是否真实发送；`false` 时只写日志 |
| `feishu.webhook` | 机器人地址，`REPLACE_ME` 视为未配置 |
| `feishu.secret` | 加签密钥，留空则不加签 |
| `feishu.minRepeatSeconds` | 重复通知间隔，**硬下限 180 秒** |
| `logging.dir` / `keepDays` | 日志目录与保留天数（默认 14 天） |
| `logging.sampleIntervalSeconds` | 采样快照写入间隔（默认 60 秒） |
| `attribution.enabled` / `topN` | 告警是否附进程归因，取前几个 |
| `messages.*` | 飞书卡片上的中文文案，可自行改写 |

### 规则字段

```json
{
  "id": "gpu-temp-critical",
  "enabled": true,
  "hardwareType": "Gpu*",
  "sensorType": "Temperature",
  "sensor": "GPU Core",
  "op": ">",
  "threshold": 88,
  "forSeconds": 120,
  "severity": "critical"
}
```

- `hardwareType`：`Cpu` / `GpuNvidia` / `GpuAmd` / `Gpu*` / `Memory` / `Storage` / `Motherboard` / `*`
- `sensorType`：`Temperature` / `Load` / `Fan` / `Power` / `Clock`
- `sensor`：传感器名，支持通配符 `*`。通配时会自动排除 `Warning Temperature`、`Critical Temperature`、`Distance to TjMax` 这类常量传感器
- `hardware`（可选）：限定某块硬件名，例如内存只取 `"Total Memory"` 那张
- `derive`（可选）：不写 `sensor` 而写两个传感器，判定它们的差值

```json
{
  "id": "gpu-hotspot-delta",
  "hardwareType": "Gpu*",
  "sensorType": "Temperature",
  "derive": { "left": "GPU Hot Spot", "right": "GPU Core" },
  "op": ">", "threshold": 25, "forSeconds": 300, "severity": "warning"
}
```

一条规则如果同时匹配多块硬件（比如两块 GPU），每块硬件独立计时、独立告警。

## 告警语义

```
OK ──条件满足 forSeconds──► FIRING ──每 minRepeatSeconds──► FIRING ...
                                └──── 条件恢复 ────► OK（发恢复通知）
```

- `forSeconds` 期间回落，计时清零，不会因为抖动误报
- `FIRING` 后重复通知的间隔取 `repeatSeconds` 与硬下限 180 秒的较大值
- 传感器突然消失（驱动重启、硬件掉线）会发一条 `sensor unavailable` 的恢复通知，避免群里的告警永远挂着

## 日志

```
logs/
└── 2026-11-18/
    ├── sample.jsonl   # 每 60 秒一行：温度 + GPU 负载快照
    └── event.jsonl    # 触发 / 重复 / 恢复 / 发送结果
```

事件行示例：

```json
{"ts":"2026-11-18T21:44:25+08:00","type":"firing-new","ruleId":"gpu-temp-critical",
 "hardware":"NVIDIA GeForce RTX 4060 Ti","sensor":"GPU Core","value":95,"unit":"C",
 "op":">","threshold":88,"heldSeconds":130,"severity":"critical","notified":true}
```

事后排查：

```bash
# 今天所有告警
grep firing logs/2026-11-18/event.jsonl
# 某段时间的 GPU 温度趋势
jq -c '.sensors[] | select(.hw|contains("NVIDIA"))' logs/2026-11-18/sample.jsonl
```

## 权限

**能不能读到温度，由两件事共同决定：**

**1）管理员权限。** LHM 通过内核驱动访问 MSR / IO 端口，非管理员时这些读取全部失败。

**2）PawnIO 驱动。** LibreHardwareMonitor 0.9.5 起用 [PawnIO](https://pawnio.eu/) 取代了 WinRing0（后者有提权漏洞），并把驱动从发行包里移了出去。**只装库不装驱动时，只有走厂商 API 的值能读**：GPU 走 NVML/DXGI、NVMe 走 SMART，而 CPU 温度和主板 SuperIO 全空。

```powershell
winget install --id namazso.PawnIO --exact    # 需要管理员
```

装好后服务状态应为 Running：

```powershell
Get-Service PawnIO
```

参考量级：同一台机器，装 PawnIO 前 118 个可读传感器、CPU 温度 0 个；装后 255 个传感器、CPU 温度 23 个。

非管理员时程序不会假装读到 0，而是在启动自检里明确列出 `missing: cpu-temperature, storage-temperature`，并在日志中提示。

`install-task.ps1` 默认注册为交互式登录账号的**最高权限**计划任务。若机器不自动登录，用 `-S4U` 注册为免登录运行（出站 webhook 仍可用）。

## 已知限制

- **不存历史曲线**。要趋势图请把 `sample.jsonl` 喂给 Prometheus / Grafana，或另配 exporter
- **不做自动处置**
- **不做外部心跳**。本机死机/断电/蓝屏时本程序同样不在，需要另外的看门存活（另一台机器探活、Uptime 类服务）
- 依赖 LibreHardwareMonitor 的传感器覆盖；个别主板/笔记本的 SuperIO 可能完全读不到，属于驱动支持范畴
- 进程归因基于 `Get-Process` 的 CPU 时间差值，对刚启动的短命进程可能不准确

## 目录

```
src/
  SensorGuard.ps1       入口：主循环、日志、退出
  lib/Collector.ps1     LHM 封装、传感器归一化、启动自检
  lib/Rules.ps1         规则匹配与告警状态机
  lib/Notify.ps1        飞书加签、卡片、节流、重试
  lib/Procs.ps1         进程归因
  lib/Logging.ps1       JSONL 日志与轮转
scripts/
  setup.ps1             下载 LHM 运行库、生成 config.json
  install-task.ps1      注册开机自启计划任务（需管理员）
  uninstall-task.ps1    移除计划任务
docs/design.md          设计决策与取舍
```

## License

MIT
