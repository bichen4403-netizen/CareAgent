---
name: medical-assist
description: 提供就诊事务辅助，包括需求整理、端侧历史信息补全和就诊推荐方案生成；不提供诊断、处方或用药建议
---

# 医疗辅助 Skill

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

- 本 Skill 只生成就诊推荐方案，不代表已经挂号成功。
- 所有付费、挂号、改约操作必须由用户在医院官方渠道确认。
- 不输出诊断、药物推荐、剂量调整或替代处方。
- 未取得可靠号源时必须返回失败，不得编造医生、时间或诊室。
- 健康档案只在应用端侧用于本次信息补全，不作为模型训练数据上传。

### 场景 1：生成就诊推荐方案（planVisit）

## 执行参数

exec-cli(command: ohos-arkTSScript --skillName 'medical-assist' --scriptPath 'scripts/MedicalAssistSkill.ets' --functionName 'planVisit' --args '{
  "arg1": "市第一人民医院",
  "arg2": "心血管内科",
  "arg3": "2026-08-27",
  "arg4": "拿高血压药",
  "arg5": "true"
}')

```json
{
  "args": {
    "type": "object",
    "required": ["arg4"],
    "additionalProperties": false,
    "properties": {
      "arg1": {
        "type": "string",
        "description": "医院名称；未明确时传空字符串，由端侧历史或常去医院补全"
      },
      "arg2": {
        "type": "string",
        "description": "科室名称；未明确时传空字符串，由端侧历史或就诊目的补全"
      },
      "arg3": {
        "type": "string",
        "description": "期望日期，格式为 YYYY-MM-DD；未明确时传空字符串"
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

参数按 `arg1` 至 `arg5` 的顺序传入 `planVisit`。不得把诊断结论、身份证号、医保卡号或完整处方作为参数传入。

## 执行返回值

### 成功：生成推荐方案

```json
{
  "type": "result",
  "status": "success",
  "data": {
    "appointment": {
      "hospitalName": "市第一人民医院",
      "hospitalAddress": "市第一人民医院（人民路128号）",
      "department": "心血管内科",
      "doctorName": "王建国 主任医师",
      "visitDate": "2026-08-27",
      "visitTime": "09:00",
      "registrationFee": 15,
      "queueNo": "A012",
      "buildingName": "门诊楼",
      "floor": "3楼",
      "roomNo": "316诊室",
      "bookingStatus": "RECOMMENDED",
      "officialChannelName": "国家政务服务平台"
    },
    "purpose": "拿高血压药",
    "speech": "为您找到一个就诊推荐方案，但还需要在医院官方渠道确认",
    "bookingCompleted": false,
    "officialChannelName": "国家政务服务平台"
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
      "required": ["appointment", "purpose", "speech", "bookingCompleted", "officialChannelName"],
      "properties": {
        "appointment": {
          "type": "object",
          "additionalProperties": false,
          "required": [
            "hospitalName", "hospitalAddress", "department", "doctorName", "visitDate",
            "visitTime", "registrationFee", "queueNo", "buildingName", "floor", "roomNo",
            "bookingStatus", "officialChannelName"
          ],
          "properties": {
            "hospitalName": { "type": "string", "minLength": 1 },
            "hospitalAddress": { "type": "string", "minLength": 1 },
            "department": { "type": "string", "minLength": 1 },
            "doctorName": { "type": "string", "minLength": 1 },
            "visitDate": { "type": "string", "pattern": "^[0-9]{4}-[0-9]{2}-[0-9]{2}$" },
            "visitTime": { "type": "string", "pattern": "^[0-9]{2}:[0-9]{2}$" },
            "registrationFee": { "type": "number", "minimum": 0 },
            "queueNo": { "type": "string" },
            "buildingName": { "type": "string" },
            "floor": { "type": "string" },
            "roomNo": { "type": "string" },
            "bookingStatus": { "type": "string", "const": "RECOMMENDED" },
            "officialChannelName": { "type": "string", "minLength": 1 }
          }
        },
        "purpose": { "type": "string", "minLength": 1 },
        "speech": { "type": "string", "minLength": 1 },
        "bookingCompleted": { "type": "boolean", "const": false },
        "officialChannelName": { "type": "string", "minLength": 1 }
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
- 明确说明结果是推荐方案，仍需在官方渠道确认。
- 一次说清医院、科室、医生、时间和确认渠道。
- 不使用“诊断成功”“处方已开”“已经挂号”等越权表达。

## 异常处理

| 异常 | 返回方式 |
|---|---|
| 用户没有说明就诊目的 | `ERR_INVALID_PARAMS` |
| 医院或科室无法通过端侧历史补全 | `ERR_NEED_CLARIFICATION` |
| 号源服务或数据源异常 | `ERR_INTERNAL` |
| 医生停诊 | 返回重新推荐的医生与时段，仍标记为 `RECOMMENDED` |
