# UTF-8 切片审计清单（String Slice Audit）

## 事实基座

- 仓颉 `String` 内部为 **UTF-8 编码**：`size` 是字节数，`indexOf`/`lastIndexOf` 返回字节偏移，`String[a..b]` 是字节切片。
- 默认构造校验 UTF-8：切片切在 rune 中间时构造抛 `IllegalArgumentException: Invalid utf8 byte sequence`（已两次真实崩溃）。
- `String.fromUtf8Unchecked` 是唯一绕过校验的入口（仅输入层使用，见 event.cj 风险标注）。
- `String.runes()` 返回惰性 `Iterator<Rune>`（无 size/无 toArray）；`String.toRuneArray()` 返回 `Array<Rune>`（可切片、`String(Array<Rune>)` 可逆）——两者均为**码点语义**，永不切半。
- `TextPosition.column` / `TextArea.cursor` 均为字节偏移，且经 `clampToRuneBoundary` 钳制。

## 判定规则

- 切片安全 ⇔ 边界表达式恒在 rune 边界。判定依据分类：`SAFE-ASCII`（ASCII 标记/分隔符）、`SAFE-CLAMPED`（cursor/column 字节 + clamp）、`SAFE-GRAPHEME`（rune/grapheme 推进）、`SAFE-RUNES`（toRuneArray/runes 码点切片）、`SAFE-STRINGINDEXOF`（匹配起点=字符边界）、`SAFE-DOMAIN`（字节数组）、`SAFE-TEST`、`FIXED`（已修）、`INPUT-UNSAFE`（输入层 unchecked，风险标注）。

## 已修点（4 处）

- `cj_markdown/src/markdown.cj:453,456` — parseListItem 任务标记 `[idx..idx+3]` 字节切片 → `taskMarkerAt` 逐 rune 检查
- `core/src/text_area.cj:1607` — markdown 装饰任务标记 `[markerEnd..markerEnd+3]` 字节切片 → `matchesAsciiNeedleAt` 逐字节比较
- `agent_tui/src/tui.cj:599,605` — revision 采样 `[size-80..]`/`[..40]` 字节切片 → `clampToRuneBoundary` 对齐

## 校验

回归前运行 `python3 tools/utf8_slice_audit.py`（learn_agent_cj 下）：扫描全部切片点并与下方 `已审:` 行号集合对照，新增未审点报错退出码 1。

## 按文件判定

### cj_tui/packages/cj_markdown/src/markdown.cj
- 判定: `FIXED+SAFE-GRAPHEME+SAFE-ASCII` — 453/456 任务标记切片已修（taskMarkerAt 逐 rune）；inline 解析 i 恒在 rune 边界（nextRuneOffset）；块工具均 ASCII 边界
- 已审: 280,355,378,394,449,463,498,570,608,620,630,642,647,664,669,681,686,705,718,719,726,727,729,735,737,750,751,757,758,759,770,847,862,869,886,887,1063,1065,1073,1077,1082,1114,1120,1128,1185,1210,1249

### cj_tui/packages/core/src/app.cj
- 判定: `SAFE-ASCII` — headless 脚本命令前缀切片（[8..] 等固定 ASCII 前缀），无多字节
- 已审: 1089,1091,1093,1098,1279,1285,1287,1289,1294,1299,1304,1306,1551,1593,1598,2088

### cj_tui/packages/core/src/buffer.cj
- 判定: `SAFE-GRAPHEME` — nextGraphemeOffset 边界推进
- 已审: 248

### cj_tui/packages/core/src/canvas.cj
- 判定: `SAFE-RUNES+ASCII` — 176: runes() 逐 rune 累加字节偏移；195: 仅 ASCII 文本分支
- 已审: 176,195

### cj_tui/packages/core/src/command_widgets.cj
- 判定: `SAFE-GRAPHEME` — previousRuneOffset 回退
- 已审: 171

### cj_tui/packages/core/src/component_runtime.cj
- 判定: `SAFE-ASCII` — 组件键 id 为 ASCII 生成格式，indexOf 字节偏移切在分隔符
- 已审: 1508,1512,1513,1522,1528,1532,1533,1537,1538,1560,1561

### cj_tui/packages/core/src/content_widgets.cj
- 判定: `SAFE-CLAMPED` — cursor/selection 为字节偏移且经 clampToRuneBoundary
- 已审: 368,711,723,733

### cj_tui/packages/core/src/data_widgets.cj
- 判定: `SAFE-ASCII` — 路径 '/' 分隔符字节边界
- 已审: 971

### cj_tui/packages/core/src/document.cj
- 判定: `SAFE-STRINGINDEXOF+ASCII` — 693: 字节 sep；722-728: stringIndexOf 匹配起点=字符边界，切片长度=needle 字节数；其余空格/换行切分
- 已审: 693,722,726,728,849,856,872,892

### cj_tui/packages/core/src/dom_style.cj
- 判定: `SAFE-ASCII` — CSS 语法，indexOf 字节偏移 + ASCII 分隔符
- 已审: 334,335,344,345,386,528,532,539,549,553,578

### cj_tui/packages/core/src/event.cj
- 判定: `SAFE-DOMAIN+INPUT-UNSAFE` — 字节数组切片安全；576/696/706 用 String.fromUtf8Unchecked（输入层风险标注：非法字节可注入）
- 已审: 23,512,522,576,678,684,696,706,712

### cj_tui/packages/core/src/lib_test.cj
- 判定: `SAFE-TEST` — 测试工具
- 已审: 82,152,159,172,187,206

### cj_tui/packages/core/src/pty.cj
- 判定: `SAFE-DOMAIN` — 字节数组切片
- 已审: 693

### cj_tui/packages/core/src/style.cj
- 判定: `SAFE-ASCII` — CSS 语法，indexOf 字节偏移
- 已审: 256,259,260,268

### cj_tui/packages/core/src/text.cj
- 判定: `SAFE-GRAPHEME` — 全部 nextGraphemeOffset/nextRuneOffset 边界推进；313 仅 ASCII 分支
- 已审: 45,101,176,181,206,344,351,530,535,578

### cj_tui/packages/core/src/text_area.cj
- 判定: `SAFE-CLAMPED+FIXED` — cursor 字节偏移 + clampToRuneBoundary(224)；行首切片在 \n 边界；1607 任务标记切片已修（matchesAsciiNeedleAt 逐字节比较）
- 已审: 418,459,505,594,599,666,704,730,744,778,810,948,1198,1235,1239,1282,1318,1319,1323,1337,1339,1340,1342,1358,1382,1427,1445,1474,1524,1547,1716

### cj_tui/packages/core/src/text_buffer.cj
- 判定: `SAFE-CLAMPED` — TextPosition.column 字节语义 + clamp(303)；118-127 行切片在 column 边界
- 已审: 118,172,175,229,245,262,308,309,326

### cj_tui/packages/core/src/widgets.cj
- 判定: `SAFE-CLAMPED` — cursor 字节偏移 + clamp
- 已审: 706,715,740,747,754,767

### cj_tui/packages/markdown/src/markdown.cj
- 判定: `SAFE-ASCII` — 行切分在 \n 边界
- 已审: 353,359

### learn_agent_cj/agent_app/src/main.cj
- 判定: `SAFE-ASCII` — 命令前缀切片；1658-1664 数字字符串域（ASCII）；2545/2554 indexOf 字节偏移切在分隔符
- 已审: 304,816,885,1627,1658,1661,1664,1688,2563,2572

### learn_agent_cj/agent_cli/src/commands.cj
- 判定: `SAFE-DOMAIN` — 254: 字节数组 fromUtf8；259: 数组切片
- 已审: 254,259

### learn_agent_cj/agent_tui/src/tui.cj
- 判定: `FIXED-CLAMPED+SAFE-RUNES+SAFE-ASCII` — 599/605 revision 采样已用 clampToRuneBoundary；5340/5412 toRuneArray 码点切片；命令前缀/路径 '/'/固定 ASCII 状态枚举
- 已审: 631,637,1212,1243,1503,1585,5746,5818,6937,7118,7237,7332,7340,7370,7582,7586,7588,7600
