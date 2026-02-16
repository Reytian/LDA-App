"""
Prompt templates for the LLM.

Contains two prompts:
- PASS1_PROMPT: Extract entity definitions and aliases from key sections
- PASS2_PROMPT: Identify all sensitive items in each document segment

Note: Prompt content is in Chinese to instruct the LLM for Chinese legal documents.
"""

# ============================================================
# Pass 1 prompt: extract entity definitions from key contract sections
# ============================================================
PASS1_PROMPT = """你是一个法律文档分析助手。以下是一份法律合同的关键片段（包含定义条款、通知条款和签署页）。

请从中提取所有当事方和实体的定义关系，以及所有出现的敏感信息。

需要提取的内容：
1. 实体定义关系：哪些简称/别名指向同一个实体
   例如："甲方" = "上海某某科技有限公司"，"the Target" = "XYZ Technology Limited"
2. 所有敏感信息：人名、公司名、地址、电话、邮箱、金额等

同时请判断该文档的类型（例如：股权转让协议、Employment Agreement、Loan Agreement、NDA、Share Purchase Agreement 等），用简短的英文表述。

请以 JSON 格式返回，不要返回任何其他内容（不要加 ```json 标记）：
{{
  "document_type": "Equity Transfer Agreement",
  "aliases": [
    {{
      "canonical": "上海某某科技有限公司",
      "aliases": ["甲方", "转让方"],
      "type": "company"
    }}
  ],
  "entities": [
    {{"text": "上海某某科技有限公司", "type": "company"}},
    {{"text": "john@example.com", "type": "email"}}
  ]
}}

---
合同关键片段：
{key_sections_text}"""

# ============================================================
# Pass 2 prompt: identify all sensitive items per document segment
# ============================================================
PASS2_PROMPT = """你是一个法律文档脱敏助手。请仔细阅读以下法律文档片段，识别其中所有的敏感信息。

【已知实体定义（来自合同定义条款）】
{entity_aliases_context}

基于以上定义，当文中出现"甲方"、"目标公司"等简称时，也应视为敏感信息。

敏感信息包括但不限于：
- 自然人姓名（中文和英文）
- 公司/机构名称（中文和英文，包括上述定义中的简称/别名）
- 金额（包含货币符号的数字）
- 电话号码、传真号码
- 电子邮箱
- 身份证号、护照号、SSN、EIN
- 银行账号
- 加密货币钱包地址
- 具体地址（街道级别）
- 公司注册号（包括统一社会信用代码、开曼/BVI注册号）
- 具体日期（合同签署日、截止日等，不包括法律生效日等通用日期）

请以 JSON 数组格式返回，不要返回任何其他内容（不要加 ```json 标记）：
[
  {{
    "text": "原文中的敏感信息（保持原文形式）",
    "type": "person/company/amount/phone/email/id/bank/wallet/address/regnum/date",
    "canonical": "如果是已知实体的别名则填正式名称，否则留空字符串"
  }}
]

---
文档片段：
{document_segment}"""
