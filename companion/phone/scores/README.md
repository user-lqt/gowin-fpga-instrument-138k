# 手机短曲谱（2026-10-30）

按默认键位映射编写。当前《夜曲》替换为用户提供 MIDI 开头的20次按键，《欢乐颂》保持16次。

| 文件 | 旋律 | 按键次数 | 建议音色 | 建议BPM |
| --- | --- | --- | --- | --- |
| yequ_guitar_opening.txt | 《夜曲》MIDI开头，高声部单音简化 | 20 | 吉他 | 200 |
| ode_to_joy_bell_short.txt | 《欢乐颂》前段，末尾补主音收束 | 16 | 编钟 | 100 |

先恢复默认键位，选择音色，进入 SONG。通过选择文件加载，或粘贴下面的HTTPS地址并点“读取在线曲谱”，再点“下载并开始指引”。读取在线文件仅填入文本区，不会直接启动演奏。

《夜曲》来源为用户本地 MIDI，从 tick 892（第一个音，约1.16秒）开始，而非副歌。原文件旋律伴奏混在同一轨道，提取规则为高声区 MIDI>=72、48 tick 内近同时音取最高音，取前20组；这是启发式高声部简化，不保证等同人工主旋律分轨。全部音统一降低一个八度，范围E4～G5，保留音程关系；不逐音折叠八度。原MIDI为120 BPM，将原十六分音符映射为指引的一个八分单位，建议200 BPM（网页上限，较原速慢20%）；时值取整并至少1单位，因此快装饰音仍会变慢。可先自由练习，再节奏练习。重复键须松开再按。旧地址 yequ_guitar_chorus.txt 已同步替换为同一份开头内容，文件名仅为兼容旧链接。

吉他曲谱地址：
https://user-lqt.github.io/gowin-fpga-instrument-138k/scores/yequ_guitar_opening.txt

编钟曲谱地址：
https://user-lqt.github.io/gowin-fpga-instrument-138k/scores/ode_to_joy_bell_short.txt

建议使用节奏练习听出节拍；重复音必须松键再按。节奏模式包含四拍预备。文件只存键号和时值，不会自动切换音色，也不会自动播放声音；需跟灯弹奏。自由练习可逐键慢弹，但旋律节奏由演奏者控制。



## 新增短曲谱（2026-11-16）

以下为传统旋律的单音简化片段，采用默认映射 K1=C4、K24=B5；按键次数不包含松键。每行第二个数是八分音符单位，曲谱本身不包含音色和 BPM 设置。

| 曲谱 | 按键次数 | 建议音色 | 建议 BPM | 在线文件 |
| --- | ---: | --- | ---: | --- |
| 送别（旋律片段） | 14 | 吉他 / 钢琴 | 72 | [TXT](https://user-lqt.github.io/gowin-fpga-instrument-138k/scores/songbie_short.txt) |
| 斯卡布罗集市（旋律片段） | 26 | 吉他 | 80 | [TXT](https://user-lqt.github.io/gowin-fpga-instrument-138k/scores/scarborough_fair_short.txt) |
| 奇异恩典（旋律片段） | 15 | 吉他 / 编钟 | 72 | [TXT](https://user-lqt.github.io/gowin-fpga-instrument-138k/scores/amazing_grace_short.txt) |

先恢复默认键位并手动选择音色。在网页设置 BPM，读取 TXT 后点击“下载并开始指引”；开发板需处于曲目指引页。自由练习先认键，熟悉后再用节奏练习。重复音要松开再按。K6 已恢复可用，曲谱按旋律需要选音，不做避键替换。
