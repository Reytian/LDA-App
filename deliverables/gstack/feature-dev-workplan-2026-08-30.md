# LDA 边界与路线图 · 全波实施与验证报告

**日期**：2026-08-30
**场景**：全流程交付（计划落地 → 六路并行实现 → 安全审计 + 接缝检查 + 发布 QA → 修复收口）
**参与成员**：主理人（编排 + 合并 + 收口修复）+ 六个实现工程师（worktree 隔离）+ 安全卫士 + 排障手 + 质量门神
**基线**：《LDA 边界与路线图》（2026-08-29 artifact）· 分支 `claude/work-plan-implementation-3fcc10`

---

## 📌 TL;DR

- 整体结论：🟢 通过（QA 初判"条件 Go 88/100"，唯一 High 已修复并有回归测试钉住）
- 路线图 7 个阶段：6 个完成落地，1 个（XPC 拆分）完成设计文档、代码接缝已就位、实施留待有签名 App 在手的专门会话
- 测试：1093 → **1348+ 全绿**（含真机 live GGUF 端到端、密文静置验证、byte-identical 还原）
- 阻塞项：0。两个 Medium 观察项已修，一个 GUI 会话回扫不对称已建 follow-up 任务

---

## 🎯 核心结论卡片

| 项目 | 内容 |
|------|------|
| Go / No-Go | 🟢 Go |
| 严重度分布（审计+QA+接缝合计） | 🔴 0 / 🟠 1（已修）/ 🟡 4（2 已修 2 转 backlog）/ 🟢 若干 LOW 记录在案 |
| 关键行动项 | 3 条（见行动清单） |
| 建议负责人 | 用户（XPC 会话与 GUI 回扫决策）|

---

## 路线图落地对照（§7 执行顺序）

| # | 计划项 | 状态 | 证据 |
|---|--------|------|------|
| 1 | 收掉 detect_entities 明文回传 | ✅ | fb56579；wire-bytes 回归测试 |
| 2 | 合并 gifted-ramanujan + xenodochial-mahavira | ✅ | ee9ccd4/87c27f8；六处冲突语义化解决；1093 绿 |
| 3 | 句柄化 + 暂存 vault | ✅ | 8 工具句柄面；原始文件名/路径零出境；QA 真机 stdio 逐字节验证 |
| 4 | 案号/车牌/微信号/URL 正则 | ✅ | StructuredEntityDetectors；防灾难回溯架构 + 病态输入测试 |
| 5 | Vault 静置加密 + PreToolUse hook | ✅ | AES-GCM LDAVOBJ/LDAVREG；崩溃残留 PID 清扫；hook 13 用例 |
| 6 | XPC 拆分（方案 B 无钥客户端） | 📐 设计完成 | docs/xpc-key-agent-design.md；DocumentVaultEncryption 单文件接缝已留 |
| 7 | 图片输入 · 全文回扫 · 自定义假名 | ✅ | Vision OCR + 盒子涂抹（re-OCR 泄漏测试过）；回扫 + 简称归并；token/pseudonym/asterisk 三风格 |

§5 引擎项全数落地或此前已在基线上（表面漂移修复、评测集）；§6 文案纪律固化为 docs/positioning-claims.md。

---

## 1. 各成员核心结论

### 🛡️ 安全卫士（OWASP+STRIDE 审计）
- 核心判断：句柄边界"well-built and holds"，默认姿态下找不到任何原文/路径/表面文本出境路径；错误路径 describeBoundarySafe 全覆盖；legacy 网关关闭时无旁路。评分 B（0 Critical / 0 High / 2 Medium）。
- 两个 Medium（崩溃后 scratch 明文残留 + attest 失真；`lda vault list` 绕过 hook 的文件名相关性）当日修复：PID 标记 + 死进程清扫（含真实 spawn/exit 进程测试）；hook 拦 `lda vault`/`lda-mcp` 指令 + README 诚实声明。
- 五项实现者存疑决定全部裁定"接受"（CLI 人类可见文件名、Unknown tool 回显、orphan/suspect 回传有界性经取证确认、editedText 入库、固定 outbox）。

### 🔧 排障手（六路合并接缝检查）
- 核心判断：合并健康，零冲突自动合并未埋静默语义破坏；style 参数在全部七类入口无一丢失；回扫 needle 严格限 person/company 有三重保险；Sources 零 house-rule 违规。
- 两个 Medium：GUI 会话缺跨文档回扫（→ follow-up 任务已建，需产品决策）；混合风格反向 restore 静默归零（→ 当日修复：token 分派补 literal 扫描，孤儿语义保持干净）。
- 死代码/重复清单在案：notePlaintextBytesReturned 属刻意 tripwire 保留；containsCJK 双实现已当日合一；TextCompleter 假件工厂合并列入 backlog。

### ✅ 质量门神（发布级 QA，真机 live GGUF）
- 核心判断：条件 Go 88/100 → 修复后 Go。1348 全绿；真机 MCP 端到端（stage→anonymize→read_redacted→restore→export→attest）：20 个敏感值探针在全会话 stdio 原始字节零命中；attest plaintextBytes=0 且 redactedBytes 逐字节吻合；两种风格还原 byte-identical；vault 对象 cat 出来是密文；F-001 清扫真机复核通过。
- 唯一 High：跳词简称（蓝鲸科技 ⊂ 蓝鲸智能科技有限公司 为子序列非子串）全量泄漏 —— 当日修复为有序字符子序列判定，QA 的两个 fixture 进回归测试。
- Low 观察：年月粒度日期不检出、pseudonym 中文文书混英文占位、法院名过度捕获（无害方向）—— 转 backlog。

### 六个实现工程师（worktree 隔离并行）
- WS-A 句柄化+vault（+42 测试）、WS-B 四类正则（+29）、WS-C 回扫/归并/路由（+66）、WS-D 三风格（+69，AI 改写鲁棒性 0/4→4/4 实证）、WS-E 静置加密（+78）、WS-F 图片输入（+29，re-OCR 泄漏测试）。全部 TDD、全部提交在各自分支后由主理人按序合并，冲突语义化手工解决（含把 D 的 style 移植进 A 重写后的工具面）。

---

## 2. 综合审查发现（去重合并后，全部已处置）

| # | 严重度 | 类别 | 位置 | 问题 | 处置 |
|---|--------|------|------|------|------|
| 1 | 🟠 High | 召回泄漏 | DefinedTermScanner.isDerivedAlias | 跳词简称不归并 → 全量明文出境 | ✅ 修复 480bfcc + 回归测试 |
| 2 | 🟡 Medium | 静置安全 | DocumentVaultEncryption scratch | 崩溃残留明文永存 + attest 失真 | ✅ 修复 740eab9（PID 清扫）|
| 3 | 🟡 Medium | 边界诚实 | lda-vault-guard.sh + CLI | vault list 文件名相关性绕 hook | ✅ 修复 740eab9（指令拦截 + README）|
| 4 | 🟡 Medium | 静默失败 | Restorer token 分派 | 混合风格反向 restore 静默 0 替换 | ✅ 修复 480bfcc（literal 补扫）|
| 5 | 🟡 Medium | 入口不对称 | SessionModel（GUI）| GUI 会话无跨文档回扫 | 📋 follow-up 任务已建（需产品决策）|
| 6 | 🟢 Low ×8 | 各类 | 见两份评审原文 | 年月日期、pseudonym 本地化、containsCJK 漂移（已修）、canonicalToken 语义（已文档化）等 | 2 已修 / 其余 backlog 记录 |

---

## ✅ 行动清单

| # | 行动 | 负责方 | 紧急度 | 备注 |
|---|------|--------|--------|------|
| 1 | XPC 拆分实施会话（按 docs/xpc-key-agent-design.md，需真机签名 App） | 用户 + 后续会话 | P1 | 完成后 attest 升级 "xpc-app-held" |
| 2 | GUI 会话跨文档回扫（follow-up 任务卡已在 UI 出现） | 用户一键启动 | P1 | 回扫命中须进 review 列表 |
| 3 | Backlog：年月日期检出、pseudonym 中文化（案号/车牌专名）、TextCompleter 假件工厂合并、fill/profile 工具句柄化重设计 | 后续 | P2 | 均已在评审原文定位到行级 |

---

## ⚠️ 待完善 / 已知局限

- XPC 拆分未实施前，vault 主密钥仍在进程内静默 Keychain（attest 如实报告 "keychain-silent"）。
- fill / extract_profile / portfolio 工具仍走路径签名，默认隐藏并拒绝（LDA_MCP_LEGACY_PATH_TOOLS=1 显式重开），待句柄化重设计。
- 图片路径 v1 限制照 WS-F 报告：EXIF 方向未应用（fail-safe）、会话内图片走文本中间产物、MCP 流的 redacted PNG 暂不注册为可导出句柄。
- 竞品公开中文精度仍领先；本波方向按计划打"可验证隔离"，不打精度竞赛。

---

## 📚 成员产出索引

- 安全卫士原始产出：会话任务 a0a9dbf0（grade B 审计报告全文）
- 排障手原始产出：会话任务 a116d247（接缝检查报告全文）
- 质量门神原始产出：会话任务 a12c0476（发布 QA 报告全文；QA 工件在会话 scratchpad）
- 六实现工程师报告：各 worktree 分支提交信息 + 会话任务记录
- 设计文档：docs/xpc-key-agent-design.md · docs/positioning-claims.md · macos/LDACore/integration/claude-code/README.md

---

> 本报告由软件工坊 AI 协作生成，关键决策请由工程负责人复核。
