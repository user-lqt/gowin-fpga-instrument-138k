# Verilog 最小语法卡（成员 C 用）

> 只收录本项目真正会用到的语法。背完这一页，就能写出 `i2s_tx` 和 `clock_gen`。
> 每一条都配"常见错误写法"，那些都是新手一定会犯的。

---

## 1. 模块的标准骨架

```verilog
//===========================================================
// file: zero_out.v
// desc: 输出恒定 0
//===========================================================
`timescale 1ns/1ps          // 仿真时间单位

module zero_out (
    output wire zero        // 端口列表：名字 + 方向 + 类型，逗号分隔
);                          // ★ 这里必须有分号
                            //   没有端口也要写 module foo ();
    // ---- 模块体 ----

    assign zero = 1'b0;     // ★ 用 assign 描述"连线上的恒定值"

endmodule                   // ★ endmodule 后面不要分号
```

### 这个骨架里的四个"必须"

| # | 规则 | 写错会怎样 |
|---|---|---|
| 1 | 端口列表用**圆括号**包起来 | 编译报语法错误 |
| 2 | `);` 处要有**分号** | 报 `syntax error` |
| 3 | 给 `output` 赋值要用 `assign`（组合）或 `always`（时序） | 报 `is not a variable` 之类 |
| 4 | 每个语句结尾要有**分号** | 报 `syntax error near ...` |
| 5 | `endmodule` 后**不加分号** | 报多余 token |

---

## 2. 完整对照：错误的写法 → 正确的写法

### ❌ 常见错误写法

```verilog
module top_module(
    output zero        // ① 缺 wire/reg 类型（HDLBits 允许省略，但 Gowin 建议写全）
    zero = 0           // ② 缺 assign；③ 缺分号；④ 企图在模块体里"执行赋值语句"
);// Module body starts after semicolon

endmodule
```

问题逐条：

1. **`zero = 0` 不是合法的 Verilog 语句。** Verilog 里 `=` 只能出现在 `assign` 之后（组合）或 `always` 块内部（过程赋值）。模块体里不能直接写 `x = y;`
2. **缺分号。**
3. **`0` 没有位宽。** Verilog 里常量要写位宽和进制：`1'b0`、`8'd255`、`16'hABCD`。虽然 `0` 大多数情况能被接受，但**养成写全的习惯**，否则位宽推断出问题时会很难查。
4. 端口建议显式声明 `wire` / `reg`，便于阅读。

### ✅ 正确写法（三种都可以，按场景选）

```verilog
// 方法一：连续赋值（最简，推荐用于纯组合/常量）
module zero_out (
    output wire zero
);
    assign zero = 1'b0;
endmodule
```

```verilog
// 方法二：用 always 组合逻辑（需要 if/case 时用）
module zero_out (
    output reg zero
);
    always @(*) begin
        zero = 1'b0;
    end
endmodule
```

```verilog
// 方法三：直接接常量（最省资源，综合器会优化成接地）
module zero_out (
    output wire zero
);
    assign zero = 1'b0;
endmodule
```

> **`wire` 与 `reg` 怎么选？**
> - 用 `assign` 赋值 → 声明 `wire`
> - 用 `always` 赋值 → 声明 `reg`
>
> **`wire` 表示"一根线"，`reg` 表示"一个有记忆的存储单元"。** 名字里的 reg 不等于硬件寄存器：在 `always @(*)` 里的 `reg` 实际还是组合逻辑。

---

## 2.5 wire 到底是什么（补充说明）

### 一句话

> **`wire` 就是一根导线（铜线）。它不存值、不记忆，只是"把 A 点连到 B 点"。**

### 关键特性

| 特性 | 含义 |
|---|---|
| **没有记忆** | 这一刻输入变，下一刻输出跟着变（都有微小延时，但概念上是"一直跟着"） |
| **必须有人驱动** | 由 `assign`、模块输出端口、或门电路的输出驱动 |
| **没人驱动 = `z`（高阻）或 `x`（未知）** | 仿真里会看到红色/虚线波形，上板可能是乱值 |
| **只能有一个驱动源** | 两处同时 `assign` 同一根 wire 会冲突（I2C 的双向总线除外，那要用三态 `z`） |

### 三种声明方式的区别

```verilog
wire a;              // 1 位线
wire [7:0] b;        // 8 位线（总线）
wire [23:0] l, r;    // 两根 24 位线（逗号分隔）

assign b = 8'hA5;    // 给 b 这根线接上恒定值
```

### 为什么需要 wire？—— 用来把模块"接"起来

这是 wire 最重要的用途。在顶层里，你要把子模块之间连起来，**连接处必须声明成 wire**：

```verilog
module top (
    input  wire clk,
    output wire HP_DIN
);
    // 子模块之间的连线：声明成 wire
    wire [23:0] w_sample;      // audio_core 的输出采样
    wire        w_valid;       // 采样有效脉冲

    // 例化子模块，用 wire 把它们的端口连起来
    audio_core u_core (
        .clk     (clk),
        .sample  (w_sample),   // ← 输出接到这根线
        .valid   (w_valid)
    );

    i2s_tx u_i2s (
        .clk     (clk),
        .data    (w_sample),   // ← 同一根线，接到另一个模块的输入
        .valid   (w_valid),
        .din     (HP_DIN)
    );
endmodule
```

**记住这个心智模型**：

```
[模块A] ──输出──> ●────────wire────────● ──输入──> [模块B]
                  一根铜线，把 A 的输出
                  送到 B 的输入
```

在 `top` 里就写成：`.out(w_x)` 和 `.in(w_x)`，两处引用同一根线，就是在做物理连接。

### 顶层例化 90% 的实质工作就是"连 wire"

你将来写 `synth_top.v`，大半篇幅都是这种形状。不是"写逻辑"，是**把各个模块用线接起来**。

### 一个常见错误：两个 assign 驱动同一根 wire

```verilog
wire y;
assign y = a & b;
assign y = c | d;      // ❌ 冲突！y 被两个源驱动
```

综合会报多驱动冲突，或行为不确定。**一根 wire 只能有一个驱动源。**

> 唯一例外是**三态总线**（如 I2C 的 SDA）：多个设备可以轮流驱动，不驱动时输出高阻 `z`。这时要用 `inout` 和 `1'bz`。我们的 OLED I2C 就属于这种情况，等你写到那部分我再展开。


---

## 3. 本项目最常用的四种代码形状

### ① 时钟分频 / 计数器

```verilog
reg [25:0] cnt;
reg        clk_1hz;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        cnt     <= 26'd0;
        clk_1hz <= 1'b0;
    end else if (cnt == 26'd49_999_999) begin   // 100MHz 半周期 0.5s
        cnt     <= 26'd0;
        clk_1hz <= ~clk_1hz;
    end else begin
        cnt <= cnt + 1'b1;
    end
end
```

### ② 单拍脉冲（本项目 `sample_tick` 就是这样产生的）

```verilog
reg [7:0] div_cnt;
wire      tick;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) div_cnt <= 8'd0;
    else        div_cnt <= (div_cnt == 8'd255) ? 8'd0 : div_cnt + 1'b1;
end

assign tick = (div_cnt == 8'd255);   // 每 256 拍，tick 高一个时钟周期
```

### ③ 移位寄存器（I2S 串行输出的核心）

```verilog
reg [23:0] shreg;

always @(posedge bck or negedge rst_n) begin
    if (!rst_n)                     shreg <= 24'd0;
    else if (load)                  shreg <= data_in;      // 并行装入
    else                            shreg <= {shreg[22:0], 1'b0};  // 左移，MSB 先出
end

assign din = shreg[23];    // 每拍把最高位送出去
```

### ④ 状态机

```verilog
localparam S_IDLE = 2'd0,
           S_SEND = 2'd1;

reg [1:0] state;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        state <= S_IDLE;
    end else begin
        case (state)
            S_IDLE: if (start) state <= S_SEND;
            S_SEND: if (done)  state <= S_IDLE;
            default:           state <= S_IDLE;   // ★ 必须有 default
        endcase
    end
end
```

---

## 4. 三种赋值的区别（最容易搞错的一条）

| 写法 | 用在哪 | 特点 |
|---|---|---|
| `assign y = a & b;` | **模块体顶层**，描述连线 | 组合逻辑；不能用 `if` |
| `y = a & b;` | **`always @(*)` 内部** | **阻塞赋值**，立刻生效；用来算组合逻辑 |
| `y <= a & b;` | **`always @(posedge clk)` 内部** | **非阻塞赋值**，在时钟沿统一更新；用来描述寄存器 |

**铁律**

> **同一个 `always` 块里不要混用 `=` 和 `<=`。**
> **时序逻辑（带 `posedge clk`）用 `<=`；组合逻辑（`@(*)`）用 `=`。**

---

## 5. 常量写法（别再写裸的 `0`）

| 写法 | 含义 |
|---|---|
| `1'b0` | 1 位二进制 0 |
| `1'b1` | 1 位二进制 1 |
| `8'd255` | 8 位十进制 255 |
| `16'hABCD` | 16 位十六进制 |
| `12'b1010_1010_1010` | 12 位二进制，**下划线是分隔符，方便数位** |
| `26'd49_999_999` | 推荐写法：位宽 + 进制 + 数字 |

**位宽写不足会被截断**（`8'd256` 实际是 0），**写超了会报错或警告**。计数器位宽一定要算够：

> 需要计到 N，位宽至少要 `ceil(log2(N+1))`。
> 例：计到 50,000,000 → `log2(50000001) ≈ 25.6` → 需要 **26 位**。

---

## 6. 常见编译报错对照表

| 报错关键词 | 真实原因 | 怎么改 |
|---|---|---|
| `syntax error near "..."` | 少分号 / 多逗号 / 括号不配对 | 看报错行**上面一行**的结尾 |
| `is not a variable` / `cannot be assigned` | 给 `output wire` 直接赋值没用 `assign` | 加 `assign`，或改声明为 `reg` 配 `always` |
| `Unknown module type` | 模块名拼错 / 文件没加进工程 | 检查 `module xxx` 与例化名一致 |
| `Failed to find the module` | 顶层模块名与工程设置不符 | 在工程里指定正确的 Top Module |
| `latch inferred` (锁存器推断) | `always @(*)` 里 `if` 少了 `else` 或 `case` 少了 `default` | 补齐所有分支 |
| `width mismatch` | 两边位宽不等 | 显式补零或截断 |

---

## 7. Gowin（云源软件）与其它工具的小差异

| 差异 | 说明 |
|---|---|
| 端口类型可省略 | 不少教程（含 HDLBits）允许 `output zero` 不写 `wire`。**Gowin 能接受，但建议写全**，否则改代码时容易踩坑 |
| 头文件 `include` | `event_defs.vh` 用 `` `include "event_defs.vh" `` 引入；要在工程里设好 include 路径 |
| 综合器的常量优化 | `assign zero = 1'b0;` 会被直接优化成接地，不占资源，这是**正常且正确**的 |
| 顶层端口必须约束管脚 | 不加 `.cst` 会报 `no constraint` 警告 |

---

## 8. 一句话速记

```
module 名字 (端口列表);        ← 圆括号 + 分号
    assign 输出 = 表达式;      ← 组合/常量
    always @(posedge clk)      ← 时序
        ... <= ...;            ← 非阻塞
    always @(*)                ← 组合
        ... = ...;             ← 阻塞
endmodule                      ← 不带分号
```

**写完先自查四件事**：括号配对了吗？每句有分号吗？`endmodule` 后没加东西吗？常量的位宽写全了吗？
