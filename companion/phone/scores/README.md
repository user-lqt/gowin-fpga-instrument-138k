# 手机短曲谱（2026-10-30）

按默认键位映射编写。当前《夜曲》替换为用户提供 MIDI 开头的20次按键，《欢乐颂》保持16次。

| 文件 | 旋律 | 按键次数 | 建议音色 | 建议BPM |
| --- | --- | --- | --- | --- |
| yequ_guitar_opening.txt | 《夜曲》MIDI开头，高声部单音简化 | 20 | 吉他 | 200 |
| ode_to_joy_bell_short.txt | 《欢乐颂》前段，末尾补主音收束 | 16 | 编钟 | 100 |

先恢复默认键位，选择音色，进入 SONG。通过选择文件加载，或粘贴下面的HTTPS地址并点“读取在线曲谱”，再点“下载并开始指引”。读取在线文件仅填入文本区，不会直接启动演奏。

《夜曲》来源为用户本地 MIDI，从 tick 892（第一个音，约1.16秒）开始，而非副歌。原文件旋律伴奏混在同一轨道，提取规则为高声区 MIDI>=72、48 tick 内近同时音取最高音，取前20组；这是启发式高声部简化，不保证等同人工主旋律分轨。全部音统一降低一个八度，范围E4～G5，保留音程关系；不逐音折叠八度。原MIDI为120 BPM，将原十六分音符映射为指引的一个八分单位，建议200 BPM（网页上限，较原速慢20%）；时值取整并至少1单位，因此快装饰音仍会变慢。可先自由练习，再节奏练习。重复键须松开再按。旧地址 yequ_guitar_chorus.txt 已同步替换为同一份开头内容，文件名仅为兼容旧链接。

吉他曲谱地址：
https://raw.githubusercontent.com/user-lqt/gowin-fpga-instrument-138k/refs/heads/fix/b-integrated-20261016/local_gowin/merged_candidate/tools/phone/scores/yequ_guitar_opening.txt

编钟曲谱地址：
https://raw.githubusercontent.com/user-lqt/gowin-fpga-instrument-138k/refs/heads/fix/b-integrated-20261016/local_gowin/merged_candidate/tools/phone/scores/ode_to_joy_bell_short.txt

建议使用节奏练习听出节拍；重复音必须松键再按。节奏模式包含四拍预备。文件只存键号和时值，不会自动切换音色，也不会自动播放声音；需跟灯弹奏。自由练习可逐键慢弹，但旋律节奏由演奏者控制。

