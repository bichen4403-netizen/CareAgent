---
name: medical-assist
description: 提供就诊事务辅助，包括需求整理、准备清单和官方挂号前待确认信息；不提供诊断、处方、用药建议或号源查询
---

# 医疗辅助 Skill

> 上传说明：`scripts/MedicalAssistSkill.ets` 是独立运行脚本，不依赖 App 内的
> `src/main/ets` 文件。上传包只需保留本文件和 `scripts/MedicalAssistSkill.ets`，
> 这样开放平台审核环境也能直接执行 `planVisit`。

## 触发场景

当用户明确表达就诊事务需求时调用，例如：

- “我要去医院看病”
- “帮我安排复查”
- “我要去第一人民医院拿高血压药”
- “帮我找心血管内科的号”
- “王医生什么时候出诊”

不要调用的情况：

- 用户询问疾病诊断、症状判断或治疗方案。
- 用户要求推荐药物、调整剂量、换药或停药。
- 用户只是咨询一般健康知识，没有就诊事务目标。
- 用户要求绕过官方渠道付款、挂号或修改预约。

## 安全边界

- 本 Skill 只整理就诊准备和待确认信息，不代表已经挂号成功。
- 所有付费、挂号、改约操作必须由用户在医院官方渠道确认。
- 不输出诊断、药物推荐、剂量调整或替代处方。
- 未取得可靠号源时，不得返回可预约方案，不得编造医生、时间、费用、排队号、地址、楼层或诊室；可以返回准备清单和需到官方渠道确认的信息。
- 健康档案只在应用端侧用于本次信息补全，不作为模型训练数据上传。

### 场景 1：生成就诊推荐方案（planVisit）

## 执行参数

exec-cli(command: ohos-arkTSScript --skillName 'medical-assist' --scriptPath 'scripts/MedicalAssistSkill.ets' --functionName 'planVisit' --args '{
  "arg1": "市第一人民医院",
  "arg2": "心血管内科",
  "arg3": "2026-09-01",
  "arg4": "拿高血压药",
  "arg5": "true"
}')

```json
{
  "args": {
    "type": "object",
    "required": ["arg3", "arg4"],
    "additionalProperties": false,
    "properties": {
      "arg1": {
        "type": "string",
        "description": "医院名称；Skill 不保存端侧历史，未明确时由上层 Agent 先询问，不得默认填充"
      },
      "arg2": {
        "type": "string",
        "description": "科室名称；未明确时可根据就诊目的推断，无法推断时先向用户询问"
      },
      "arg3": {
        "type": "string",
        "pattern": "^[0-9]{4}-[0-9]{2}-[0-9]{2}$",
        "description": "明确的就诊日期，格式为 YYYY-MM-DD；未明确时先向用户询问，不得默认填充"
      },
      "arg4": {
        "type": "string",
        "minLength": 1,
        "description": "用户原始就诊目的，例如看病、复查、取药或续方"
      },
      "arg5": {
        "type": "string",
        "enum": ["true", "false"],
        "description": "是否属于复诊或续方；无法判断时传 false"
      }
    }
  }
}
```

参数按 `arg1` 至 `arg5` 的顺序传入 `planVisit`。入口脚本同时兼容审核/调试面板将整个
JSON 作为一个参数传入的情况（可使用 `hospital`、`department`、`expectedDate`、
`purpose`、`isRevisit` 语义化字段，也兼容 `arg1` 至 `arg5`）。不得把诊断结论、
身份证号、医保卡号或完整处方作为参数传入。

## 执行返回值

### 成功：生成准备清单与待确认信息

```json
{
  "type": "result",
  "status": "success",
  "data": {
    "visitPlan": {
      "hospitalName": "市第一人民医院",
      "department": "心血管内科",
      "expectedDate": "2026-09-01",
      "bookingStatus": "NEEDS_OFFICIAL_CONFIRMATION",
      "officialChannelName": "医院官方渠道",
      "missingConfirmation": ["医生", "就诊时间", "诊室", "费用及号源状态"]
    },
    "purpose": "拿高血压药",
    "speech": "已为您整理就诊准备清单。本技能没有接入医院官方号源，请在医院官方渠道完成挂号后，以官方结果为准。",
    "bookingCompleted": false,
    "officialChannelName": "医院官方渠道",
    "dataSource": "USER_PROVIDED_AND_LOCAL_PREPARATION",
    "preparation": {
      "visitItems": ["确认预约医院、科室和时间", "建议提前30分钟到院，预留取号和找路时间"],
      "materials": ["身份证", "医保卡（如使用）", "既往检查报告或病历资料", "预约凭证或手机截图"],
      "notices": ["只按原医嘱用药，不自行加减量或停药", "以医院官方通知和医生要求为准"]
    }
  }
}
```

### 失败：输入目的为空

```json
{
  "type": "result",
  "status": "failed",
  "errCode": "ERR_INVALID_PARAMS",
  "errMsg": "purpose is empty",
  "suggestion": "您这次去医院主要想看病、复查，还是取药呢？"
}
```

### 失败：需要用户补充信息

```json
{
  "type": "result",
  "status": "failed",
  "errCode": "ERR_NEED_CLARIFICATION",
  "errMsg": "required slot is empty",
  "suggestion": "您想去哪家医院？"
}
```

### 失败：内部服务异常

```json
{
  "type": "result",
  "status": "failed",
  "errCode": "ERR_INTERNAL",
  "errMsg": "service unavailable",
  "suggestion": "暂时没能查到合适的就诊安排，请稍后再试"
}
```

### 返回值 JSON Schema

```json
{
  "type": "object",
  "required": ["type", "status"],
  "additionalProperties": false,
  "properties": {
    "type": { "type": "string", "const": "result" },
    "status": { "type": "string", "enum": ["success", "failed"] },
    "data": {
      "type": "object",
      "additionalProperties": false,
      "required": ["visitPlan", "purpose", "speech", "bookingCompleted", "officialChannelName", "dataSource", "preparation"],
      "properties": {
        "visitPlan": {
          "type": "object",
          "additionalProperties": false,
          "required": [
            "hospitalName", "department", "expectedDate", "bookingStatus", "officialChannelName",
            "missingConfirmation"
          ],
          "properties": {
            "hospitalName": { "type": "string", "minLength": 1 },
            "department": { "type": "string", "minLength": 1 },
            "expectedDate": { "type": "string", "pattern": "^[0-9]{4}-[0-9]{2}-[0-9]{2}$" },
            "bookingStatus": { "type": "string", "const": "NEEDS_OFFICIAL_CONFIRMATION" },
            "officialChannelName": { "type": "string", "const": "医院官方渠道" },
            "missingConfirmation": {
              "type": "array",
              "items": { "type": "string", "minLength": 1 },
              "minItems": 1
            }
          }
        },
        "purpose": { "type": "string", "minLength": 1 },
        "speech": { "type": "string", "minLength": 1 },
        "bookingCompleted": { "type": "boolean", "const": false },
        "officialChannelName": { "type": "string", "minLength": 1 },
        "dataSource": { "type": "string", "const": "USER_PROVIDED_AND_LOCAL_PREPARATION" },
        "preparation": {
          "type": "object",
          "additionalProperties": false,
          "required": ["visitItems", "materials", "notices"],
          "properties": {
            "visitItems": { "type": "array", "items": { "type": "string", "minLength": 1 } },
            "materials": { "type": "array", "items": { "type": "string", "minLength": 1 } },
            "notices": { "type": "array", "items": { "type": "string", "minLength": 1 } }
          }
        }
      }
    },
    "errCode": {
      "type": "string",
      "enum": ["ERR_INVALID_PARAMS", "ERR_NEED_CLARIFICATION", "ERR_INTERNAL"]
    },
    "errMsg": { "type": "string", "minLength": 1 },
    "suggestion": { "type": "string", "minLength": 1 }
  },
  "oneOf": [
    {
      "properties": { "status": { "const": "success" } },
      "required": ["data"]
    },
    {
      "properties": {
        "status": { "const": "failed" },
        "errCode": { "const": "ERR_INVALID_PARAMS" }
      },
      "required": ["errCode", "errMsg", "suggestion"]
    },
    {
      "properties": {
        "status": { "const": "failed" },
        "errCode": { "const": "ERR_NEED_CLARIFICATION" }
      },
      "required": ["errCode", "errMsg", "suggestion"]
    },
    {
      "properties": {
        "status": { "const": "failed" },
        "errCode": { "const": "ERR_INTERNAL" }
      },
      "required": ["errCode", "errMsg", "suggestion"]
    }
  ]
}
```

## 播报要求

- 使用“今天、明天、后天”等自然日期表达。
- 明确说明结果是准备清单，不等于已有号源或挂号成功。
- 只说清用户已提供的医院、科室、计划日期和确认渠道；明确提示医生、时间、诊室、费用以官方结果为准。
- 不使用“诊断成功”“处方已开”“已经挂号”等越权表达。

## 异常处理

| 异常 | 返回方式 |
|---|---|
| 用户没有说明就诊目的 | `ERR_INVALID_PARAMS` |
| 医院或科室无法通过端侧历史补全 | `ERR_NEED_CLARIFICATION` |
| 号源服务或数据源异常 | 不尝试编造号源；返回准备清单并提示用户到官方渠道确认 |
| 医生停诊 | 不重新推荐医生；提示用户在官方渠道查看可选医生与时段 |
