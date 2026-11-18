# SensorGuard 设计说明

记录取舍，而不是重复 README。

## 目标与非目标

**要解决的**：一台无人值守的 Windows 机器，在散热劣化或进程失控时，把信号送到人的手机，并且带上足够上下文让人判断"要不要现在处理"。

**不做**：

- 历史曲线与时序数据库（只需通知，日志留证）
- 自动处置（杀进程/降频/关机在服务器上风险过高）
- 外部心跳（属于另一个组件的职责，见下）

## 为什么是 PowerShell 5.1 + LibreHardwareMonitorLib

候选：

| 方案 | 否决理由 |
|---|---|
| C# + .NET 服务 | 机器上没有 SDK，需要额外安装；对使用者门槛更高 |
| LHM GUI + HTTP `/metrics` + Prometheus | 为"只通知"引入 4 个进程和一套告警链路，过重；且 LHM GUI 常驻轮询本身有 CPU 开销 |
| Windows 性能计数器 | 没有 CPU 温度、GPU Hot Spot、NVMe 温度，覆盖不了核心诉求 |
| HWiNFO | 告警能力可用，但配置散落在 GUI、无法版本管理，免费版有广告 |

结论：**进程内直接引用 LibreHardwareMonitorLib**，与 GUI 共用同一套传感器后端，但不承担 GUI 的绘制开销。PowerShell 5.1 是 Windows 自带环境，改一行即可生效，适合长期维护。

LibreHardwareMonitor 0.9.5 起移除了 WMI（.NET 10 不再支持），因此本项目的路线是"引用库"而不是"读 WMI"。

## 为什么必须有管理员权限

LHM 读取 CPU 温度需要 MSR、读取主板 SuperIO 需要 I/O 端口、读 NVMe SMART 需要驱动通道。这些都是内核级访问。非管理员时库能加载、GPU 温度能出，但 CPU/主板/磁盘温度是 `null`。

程序的处理方式：**不把 null 当 0**。启动自检输出 `missing: cpu-temperature, storage-temperature`，让人立刻知道"现在这套告警是残的"，而不是以为一切正常。

## 告警状态机

```
        ┌──────────────── 条件恢复 ────────────────┐
        ▼                                          │
       OK ──条件满足，计时──► PENDING ──满 forSeconds──► FIRING
                                        │              │
                                        │              └──每 repeatSeconds──► FIRING(重复通知)
                                        └──期间恢复，计时清零，回 OK
```

三个设计点：

1. **`forSeconds` 让判定面向"持续"**。散热问题和跑飞进程都以分钟计，瞬时阈值只能制造噪音。
2. **重复通知有硬下限 180 秒**（`if ($repeatSec -lt 180) { $repeatSec = 180 }`）。飞书 webhook 机器人有频控，超限 429；一旦被限流，真正的告警反而发不出去。硬下限写在代码里而不是只写在文档里，是因为这类参数被改小的后果是静默的。
3. **传感器消失也要收尾**。当某条正在 `FIRING` 的指标读不到时，发一条 `sensor-unavailable` 恢复通知，否则群里会长期挂着一条无法关闭的告警。

## 为什么"差值规则"值得单独支持

GPU 的 `Hot Spot` 与 `Core` 的温差是散热接触状态的直接观测：

- 温差正常：10–20 °C
- 散热器接触不良 / 硅脂老化：25 °C 以上，且随负载升高放大
- 这个信号比"绝对温度"更早出现，也更不容易被环境温度干扰

因此规则支持 `derive: { left, right }`，对同一硬件下的两个传感器取差再比较。

## 传感器选择的坑

LHM 在同一 `SensorType` 下混着**读数**和**常量**：

- `CPU Package`（读数） vs `Warning Temperature` / `Critical Temperature`（配置常量）
- `P-Core #1`（读数） vs `P-Core #1 Distance to TjMax`（差值，含义相反）

所以通配符 `sensor: "*"` 会误把常量当读数比较。实现上，**仅在通配时**排除名字含 `warning|critical|limit|distance` 的传感器；显式指定名字时不做过滤（使用者明确要它）。

## 编码：PowerShell 5.1 的隐形地雷

Windows PowerShell 5.1 读取**无 BOM** 的 UTF-8 `.ps1` 时按系统 ANSI（简体中文为 GBK）解码，源码里的中文和符号会变成乱码（`°C` → `掳C`）。

采取的规则：

- 所有 `.ps1` **保持纯 ASCII**，注释与日志文案用英文
- 所有面向用户的中文放在 `config.json` 的 `messages` 里，读取时显式 `[Text.Encoding]::UTF8`
- JSON 日志用 `UTF8Encoding($false)` 写入，避免每行带 BOM

## 日志而不画图

`sample.jsonl` 每 60 秒一行、`event.jsonl` 记录状态变化，按天分目录，按 `keepDays` 轮转。

选择 JSONL 的理由：追加写天然安全、单行可被 `jq`/`grep` 独立消费、不需要引入 SQLite 依赖。真要看趋势，把文件喂给现成的采集器即可，不必在本项目内重造图表。

## 进程归因

`Get-Process` 的 `CPU` 是**累计 CPU 秒数**，不是瞬时百分比。直接排序会把长期运行的进程永远排在前面（即使它现在空闲）。

实现上保留上一次的累计值，用差值除以经过时间和逻辑核心数得到真实占用百分比。PID 复用会导致差值为负，按 `delta < 0` 丢弃该样本。

## 边界与后续

- 外部心跳被有意排除在范围外：本机死机时本进程同样不在，应由**另一台机器或云端探活**负责，放到这里只会给人"已经覆盖了"的错觉
- 复合条件（例如"风扇转速为 0 且温度高于 70"）需要规则表达式，当前版本用多条单指标规则近似
- 进程白名单（转码/训练任务长期吃满属正常）尚未实现，目前靠调高 `threshold` / `forSeconds` 或 `enabled: false` 规避
