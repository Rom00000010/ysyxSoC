# ysyxSoC 个人实现版本

本仓库基于上游 [ysyxSoC](https://github.com/OSCPU/ysyxSoC) 项目，用于个人 RV32E 处理器 NPC 的 SoC 集成与全系统仿真。仓库保留上游提供的 SoC、总线和外设框架，并完善了项目验证所需的关键存储设备模型与访问链路。

<p align="center">
  <img src="docs/soc.svg" alt="ysyxSoC 结构" width="58%">
  <br>
  <sub>ysyxSoC 结构</sub>
</p>

## 主要改动

- 完善 SDRAM 颗粒仿真模型，支持 Bank/Row 组织、模式寄存器、CAS 延迟及突发读写等行为。
- 完善 PSRAM 读写仿真与数据存储接口。
- 完善 SPI Flash 访问及 XIP 启动链路，使处理器能够从 Flash 取指并加载程序。
- 配合 NPC 的 AM 平台适配、链接脚本与 Bootloader，完成程序装载及 RT-Thread 启动验证。

## 与主仓库的关系

- [ysyx](https://github.com/Rom00000010/ysyx)：NEMU、NPC、Verilator 仿真、Difftest 与运行时环境
- [thesis](https://github.com/Rom00000010/thesis)：毕业论文、答辩材料与系统设计说明

## 上游来源

本仓库是在 ysyxSoC 上游代码基础上的个人实现版本。上游代码及第三方外设模块的版权与许可证归各自作者所有。
