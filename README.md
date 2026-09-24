# 楂樹簯 FPGA 瀹炴椂澶氶煶鑹插悎鎴愮數瀛愪箰鍣ㄥ紩鎿?
> 鍏ㄥ浗澶у鐢熷祵鍏ュ紡鑺墖涓庣郴缁熻璁＄珵璧?2026 路 FPGA 鍒涙柊璁捐璧涢亾 路 **楂樹簯鍗婂浣?閫夐浜?*
> 骞冲彴锛?*Sipeed Tang Mega 138K Dock** 路 鑺墖 **GW5AST-LV138PG484AC1/I0**

杩欐槸涓€鍙?*鐢辨紨濂忓姩浣滈┍鍔ㄣ€佺敱 FPGA 纭欢閫昏緫閫愭牱鏈敓鎴愬０闊?*鐨勫疄鏃剁數瀛愪箰鍣ㄣ€?
绯荤粺鐨勬牳蹇冨睘鎬э紙涔熸槸璇勫垎渚濇嵁锛夛細

- 闊抽閫氳矾鐨勬瘡涓€涓牱鏈兘鐢?FPGA 鍦ㄧ‖浠堕€昏緫灞傚疄鏃惰绠楋紝**涓嶆槸棰勫綍 PCM 鎾斁**
- 婕斿鍔ㄤ綔 鈫?浜嬩欢 鈫?澹伴儴 / 鎸崱鍣?鈫?娣烽煶 鈫?I2S 鈫?DAC锛岀鍒扮寤惰繜 **鈮?10 ms**锛堝啿鍒?鈮?5 ms锛?- 鍩虹鐩爣锛?*鈮?4 澶嶉煶**銆?*鈮?2 涓嫭绔嬫紨濂忕淮搴?*銆佺嫭绔?ADSR銆佸疄鏃跺彉璋?- 鍐插鐩爣锛?*鈮?32 鐙珛鎸崱鍣?*銆?*鈮?3 缁磋〃鎯?*銆?*鈮?2 绉嶉煶鑹?*銆佺‖浠堕煶鏁堛€佸彲瑙嗗寲鍙嶉

---

## 涓€銆佸洟闃熸垚鍛樹笌浠诲姟鐨勫敮涓€鍏ュ彛

**姣忎釜浜哄彧璇昏嚜宸遍偅涓€浠戒换鍔′功锛屼笉瑕佽鍒汉鐨勩€?* 浠诲姟涔︽槸浣犲湪鏈粨搴撲腑鐨勬潈闄愯竟鐣岃鏄庝功銆?
| 鎴愬憳 | 浠诲姟涔?| 璐熻矗鐩綍 | 鐙珛宸ョ▼ | 鍒嗘敮 | Git 璐﹀彿 |
|---|---|---|---|---|---|
| **A** 闊抽鍚堟垚涓庨煶璐ㄤ紭鍖?| [`docs/鎴愬憳A_闊抽鍚堟垚涓庨煶璐ㄤ紭鍖栦换鍔′功.md`](docs/鎴愬憳A_闊抽鍚堟垚涓庨煶璐ㄤ紭鍖栦换鍔′功.md) | `rtl/audio_core/`銆乣sim/audio_core_tb/` | `audio_core_sim.gprj` | `dev-audio` | TODO 濉啓 |
| **B** 婕斿杈撳叆涓庡弬鏁扮晫闈?| [`docs/鎴愬憳B_婕斿杈撳叆涓庡弬鏁扮晫闈换鍔′功.md`](docs/鎴愬憳B_婕斿杈撳叆涓庡弬鏁扮晫闈换鍔′功.md) | `rtl/input/`銆乣rtl/ui/`銆乣sim/input_ui_tb/` | `input_ui_sim.gprj` | `dev-input` | TODO 濉啓 |
| **C** 闊抽杈撳嚭涓?FPGA 绯荤粺骞冲彴 | [`docs/鎴愬憳C_闊抽杈撳嚭涓嶧PGA绯荤粺骞冲彴浠诲姟涔?md`](docs/鎴愬憳C_闊抽杈撳嚭涓嶧PGA绯荤粺骞冲彴浠诲姟涔?md) | `rtl/system/`銆乣rtl/common/`銆乣project/`銆乣constraint/`銆乣tb/` | `audio_system_sim.gprj`銆乣synth_top.gprj` | `dev-system` | TODO 濉啓 |

鍏堣 [`docs/楂樹簯FPGA鐢靛瓙涔愬櫒椤圭洰鎬昏鍒掍功_鏈€缁堢増.md`](docs/楂樹簯FPGA鐢靛瓙涔愬櫒椤圭洰鎬昏鍒掍功_鏈€缁堢増.md)锛堟€绘帶涓庝綔鎴樻墜鍐岋級锛屽啀璇昏嚜宸辩殑浠诲姟涔︼紝鏈€鍚庡彧娴忚鍙﹀涓や汉鐨?鎺ュ彛涓庤竟鐣?绔犺妭銆?
**寮€宸ュ墠蹇呴』鍏堣鐨勪笁浠芥枃浠?*

1. [`docs/PLATFORM_TANG_MEGA_138K.md`](docs/PLATFORM_TANG_MEGA_138K.md) 鈥斺€?鏉垮崱涓庡櫒浠躲€両DE 鐗堟湰銆佺鑴氥€佸畨鍏ㄧ孩绾?2. [`docs/INTERFACE_FREEZE.md`](docs/INTERFACE_FREEZE.md) 鈥斺€?鎺ュ彛鍐荤粨鍗°€侀噰鏍风巼/浣嶅/瀹氱偣銆佸欢杩熼绠?3. [`docs/GIT_WORKFLOW.md`](docs/GIT_WORKFLOW.md) 鈥斺€?鍒嗘敮銆佹彁浜ゃ€佸悎骞躲€佽瘎瀹¤鍒?
**鎴愬憳 C 鍙﹂渶鍏堣**锛歔`docs/C_瀹樻柟渚嬬▼涓庢澘杞介煶棰戦€氳矾鍒嗘瀽.md`](docs/C_瀹樻柟渚嬬▼涓庢澘杞介煶棰戦€氳矾鍒嗘瀽.md) 鈥斺€?宸叉牳瀹炴澘杞?DAC/鍔熸斁閫氳矾涓庡疄鏈?I2S 绠¤剼锛屾槸 C1 鍑哄０鐨勭涓€姝ヤ緷鎹€?
---

## 浜屻€佷粨搴撶粨鏋?
```
gowin-fpga-instrument-138k/
鈹溾攢 README.md                     鏈枃浠?鈹溾攢 rtl/
鈹? 鈹溾攢 common/                    鈽?C 缁存姢锛孉/B/C 鍏辩敤锛堟敼鍔ㄥ繀椤婚€氱煡鍏ㄥ憳锛?鈹? 鈹? 鈹溾攢 event_defs.vh           浜嬩欢/鍙傛暟/闊抽鐨勫敮涓€濂戠害
鈹? 鈹? 鈹溾攢 status_defs.vh          鐘舵€佷笌閿欒鐮?鈹? 鈹? 鈹斺攢 reset_sync.v            澶嶄綅鍚屾鍣?鈹? 鈹溾攢 audio_core/                A 鐙崰锛欴DS銆佹尝琛ㄣ€丗M銆丄DSR銆佸０閮ㄣ€佹贩闊?鈹? 鈹溾攢 input/                     B 鐙崰锛氶敭鐩樸€佺紪鐮佸櫒銆佽Е鎽搞€佸姏搴︺€佹护娉?鈹? 鈹溾攢 ui/                        B 鐙崰锛氬弬鏁扮鐞嗐€侀〉闈㈢姸鎬佷笌鍐呭
鈹? 鈹斺攢 system/                    C 鐙崰锛氭椂閽熴€侀噰鏍疯妭鎷嶃€両2S銆侀煶鏁堛€佺姸鎬?鈹溾攢 sim/
鈹? 鈹溾攢 audio_core_tb/             A锛歵b_audio_core.v + audio_core_sim.gprj
鈹? 鈹溾攢 input_ui_tb/               B锛歵b_input / tb_encoder / tb_sensor / tb_ui
鈹? 鈹斺攢 system_tb/                 C锛歵b_system.v + audio_system_sim.gprj
鈹溾攢 project/                      C 鐙崰锛歴ynth_top.v銆佸悇 *.gprj
鈹溾攢 constraint/                   C 鐙崰锛歵ang_mega138k.cst / .sdc
鈹溾攢 docs/                         浠诲姟涔︺€佽鍒掍功銆佸钩鍙板崱銆佹帴鍙ｅ喕缁撱€侀噰璐竻鍗?鈹溾攢 tools/                        浠跨湡涓庣患鍚堣緟鍔╄剼鏈?鈹溾攢 waveforms/                    淇濆瓨鐨勪豢鐪熸尝褰㈤厤缃笌鎴浘
鈹斺攢 evidence/                     楠屾敹璇佹嵁锛氱患鍚堟姤鍛娿€佹椂搴忋€佸欢杩熴€侀璋?```

`tools/`銆乣waveforms/`銆乣evidence/` 涓変釜鐩綍鍏辩敤锛屽懡鍚嶈鍒欒 `docs/GIT_WORKFLOW.md`銆?
---

## 涓夈€佷笁鏉￠搧寰?
1. **鍙敼鑷繁鐨勭洰褰曘€?* 闇€瑕佹敼鍒汉鐨勪笢瑗?鈫?鍏堟彁鎺ュ彛鍙樻洿璇存槑锛屼笉瑕佺洿鎺ユ敼銆?2. **鎺ュ彛浠?`rtl/common/event_defs.vh` 涓哄敮涓€鐪熺浉銆?* 瀛楁/浣嶅/缂栫爜涓嶄竴鑷存椂锛屼互璇ユ枃浠朵负鍑嗐€?3. **涓嶈繘鐗堟湰搴撶殑涓滆タ锛?* Gowin 鐨?`impl/`銆乣*.fs`銆乣*.ipc`銆乣*.log`銆乣.temp/`銆乥itstream銆丳DF 鎵嬪唽銆佷豢鐪熺紦瀛?鈥斺€?瑙?`.gitignore`銆?
---

## 鍥涖€佸父鐢?Git 鍛戒护锛堜笁鍒嗛挓涓婃墜锛?
```bash
# 绗竴娆★細鍏嬮殕
git clone https://github.com/user-lqt/gowin-fpga-instrument-138k.git
cd gowin-fpga-instrument-138k
git config user.name  "浣犵殑鍚嶅瓧"
git config user.email "浣犵殑閭@example.com"

# 鍒囧埌鑷繁鐨勫紑鍙戝垎鏀?git checkout dev-audio      # A 鐢?git checkout dev-input      # B 鐢?git checkout dev-system     # C 鐢?
# 鏃ュ父锛氭敼浠ｇ爜 鈫?鎻愪氦 鈫?鎺ㄩ€?git status
git add rtl/audio_core/phase_acc.v
git commit -m "feat(audio): 瀹炵幇 32 浣嶇浉浣嶇疮鍔犲櫒涓庢尝琛ㄥ鍧€"
git push

# 寮€濮嬫柊宸ヤ綔鍓嶏紝鍏堝悓姝ヤ富骞诧紙閬垮厤闀挎湡鍋忕锛?git fetch origin
git merge origin/main       # 鎴?git rebase origin/main

# 鍔熻兘鍋氬畬 鈫?鍙?Pull Request 鍚堝苟鍒?main
gh pr create --base main --head dev-audio --title "stage1: 鍗曢煶 DDS 閫氳矾" --body "瑙?testbench 缁撴灉"
```

瀹屾暣瑙勫垯锛堝垎鏀懡鍚嶃€佹彁浜や俊鎭鑼冦€丳R 妫€鏌ュ崟銆佸啿绐佸鐞嗐€侀樁娈垫爣绛撅級瑙?[`docs/GIT_WORKFLOW.md`](docs/GIT_WORKFLOW.md)銆?
---

## 浜斻€侀樁娈典笌 Git 鏍囩

| 闃舵 | 鐩爣 | 閫氳繃鍚庢墦鐨勬爣绛?|
|---|---|---|
| **闃舵 0** | 涓変釜鐙珛宸ョ▼鍙墦寮€銆佷笁涓?testbench 鍙繍琛屻€佹帴鍙ｅ喕缁?| `stage0-freeze` |
| **闃舵 1** | 涓夋潯鐙珛鏈€灏忛摼璺紙鍗曢煶鍚堟垚 / 閿洏杈撳叆 / I2S 鍑哄０锛?| `stage1-minimal` |
| **闃舵 2** | 鍩虹鍙彁浜ょ増鏈細鈮? 澶嶉煶銆? 缁翠氦浜掋€佲墹10 ms | `stage2-baseline` |
| **闃舵 3** | 鍐插鎵╁睍锛?2 鎸崱鍣ㄣ€? 缁磋〃鎯呫€侀煶鑹层€侀煶鏁堛€佲墹5 ms | `stage3-award` |
| **闃舵 4** | 鎴愬搧鍖栦笌姣旇禌鐜板満鍐荤粨 | `stage4-final` |

**`stage2-baseline` 鏄繚搴曠嚎銆?* 鍐插寮€鍙戜竴鏃︾牬鍧忓畠锛岀珛鍗冲洖閫€鍒拌鏍囩鐗堟湰锛屽垹鎺夐闄╂渶楂樼殑鍔熻兘銆?
---

## 鍏€佸綋鍓嶇姸鎬?
- [x] 瀹樻柟璧涢涓庡璁叉潗鏂欏綊妗?- [x] 鍥㈤槦鎬昏鍒掍功涓庝笁浠戒釜浜轰换鍔′功褰掓。
- [x] 纭欢閲囪喘娓呭崟褰掓。
- [x] 骞冲彴涓庡櫒浠朵俊鎭牳瀹烇紙Tang Mega 138K锛?- [x] 浠撳簱楠ㄦ灦 + 鎺ュ彛鏂囦欢鍐荤粨鑽夋
- [ ] **闃舵 0**锛氫笁涓?Gowin 宸ョ▼寤虹珛銆佷笁涓?testbench 璺戦€氥€佹帴鍙ｆ寮忓喕缁?- [ ] **闃舵 1**锛氬崟闊?DAC 鍑哄０
- [ ] **闃舵 2**锛氬熀纭€鍙彁浜ょ増鏈?
闃舵 0 鐨勯獙鏀舵竻鍗曡 [`docs/INTERFACE_FREEZE.md`](docs/INTERFACE_FREEZE.md) 鏈€鍚庝竴鑺傘€?
---

## 涓冦€佸厤璐ｄ笌鍚堣

- 鎵€鏈夎緭鍑洪煶棰戝潎鐢?FPGA 渚濇嵁瀹炴椂婕斿鎸囦护閫愰煶銆侀€愭牱鏈敓鎴愶紱**涓ョ**鎾斁棰勫綍 PCM銆侀缃帹娴佹垨鏁存褰曢煶瑙﹀彂銆?- 澶栨帴 GPIO **鍙厑璁?3.3 V 鐢靛钩**锛涗换浣?5 V 杈撳嚭蹇呴』鍒嗗帇鎴栫數骞宠浆鎹㈠悗鎵嶈兘鎺ュ叆 FPGA銆?- 鍔熸斁涓?BTL 宸垎杈撳嚭锛屾壃澹板櫒璐熺**涓嶅緱鎺ュ湴**锛屽乏鍙冲０閬撹礋绔笉寰椾簰杩炪€?