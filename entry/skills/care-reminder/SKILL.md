---
name: care-reminder
description: 关怀提醒技能。负责把陪诊流程中的时间节点转成定时提醒，并按场景选择最合适的设备与方式触达（手表震动/耳机语音/手机卡片）。同时沉淀服务记录，用于下次复诊的主动提前规划。
---

# 关怀提醒 Skill

## 触发场景

当医疗方案与出行方案都已生成、需要把关键时间节点转成可触达提醒时调用，例如：

- 医疗、出行技能全部完成后自动激活，生成整套陪诊提醒
- 用户主动问"到时候会提醒我吗""能不能设个提醒"
- 后台定时巡检，扫描到期复诊并主动发起询问

不要调用的情况：

- 医疗方案（Appointment）或出行方案（TravelPlan）尚未生成完成。
- 用户要求修改或取消已存在的具体某条提醒的时间/设备，而非重新生成整套计划。
- 用户询问的是用药剂量、疗程调整等诊疗建议，而非提醒本身。

## 核心价值

这是"主动服务"最直接的承载者。前两个技能负责把事安排好，
本技能负责**在正确的时间、用正确的设备、把正确的信息送到用户面前**。

## 安全边界

- 本 Skill 只生成提醒计划，不代表提醒已经在系统中正式注册生效。
- 用药提醒只复述医生开具的处方内容，不提供任何用药建议、剂量调整或替代方案。
- 提醒频率要克制，避免打扰疲劳；同一时段的多条提醒合并为一条。
- 用户明确表示不需要某类提醒后，不再重复推送。
- 服务记录仅存端侧，用户可随时查看与删除，不作为模型训练数据上传。

## 设备选择原则

设备不是随便挑的，每种触达方式对应一个真实的使用场景约束：

| 场景 | 设备 | 方式 | 原因 |
|---|---|---|---|
| 前一晚备证件 | 手机 | 卡片 | 信息量大，需要看清楚清单 |
| 出发提醒 | 手表 | 震动 | 手机常在包里，老人看不到；手表贴身 |
| 院内导航 | 耳机 | 语音 | 双手解放，不用边走边看屏幕 |
| 排队叫号 | 手表 | 震动 | 嘈杂环境听不清，震动最可靠 |
| 用药提醒 | 手表 | 震动 | 日常贴身佩戴，不易错过 |

## 提醒时间链

以就诊时间为锚点，向前后展开：

1. **出发前12小时** — 证件准备（医保卡、身份证、上次报告）
2. **出发前20分钟** — 准备出门，含天气与路况说明
3. **出发时刻** — 手表震动"该走了"
4. **预计到院时** — 耳机语音开始院内引导
5. **就诊前10分钟** — 排队叫号提醒
6. **就诊后** — 按处方设置每日用药提醒

### 场景 1：生成关怀提醒计划（createReminderPlan）

## 执行参数

exec-cli(command: ohos-arkTSScript --skillName 'care-reminder' --scriptPath 'scripts/CareReminderSkill.ets' --functionName 'createReminderPlan' --args '{
  "arg1": "{\"hospitalName\":\"市第一人民医院\",\"hospitalAddress\":\"市第一人民医院（人民路128号）\",\"department\":\"心血管内科\",\"doctorName\":\"王建国 主任医师\",\"visitDate\":\"2026-08-27\",\"visitTime\":\"09:00\",\"registrationFee\":15,\"queueNo\":\"A012\",\"buildingName\":\"门诊楼\",\"floor\":\"3楼\",\"roomNo\":\"316诊室\",\"bookingStatus\":\"RECOMMENDED\",\"officialChannelName\":\"国家政务服务平台\"}",
  "arg2": "{\"originAddress\":\"幸福小区3栋2单元\",\"destAddress\":\"市第一人民医院（人民路128号）\",\"departTime\":\"07:52\",\"durationMin\":28,\"distanceKm\":8.6,\"trafficLevel\":\"拥堵\",\"weather\":\"小雨\",\"bufferMin\":25,\"suggestion\":\"今天有雨，建议提前出发，已为您多留出时间\"}"
}')

```json
{
  "args": {
    "type": "object",
    "required": ["arg1", "arg2"],
    "additionalProperties": false,
    "properties": {
      "arg1": {
        "type": "string",
        "minLength": 1,
        "description": "medical-assist 技能生成的 Appointment 对象序列化后的 JSON 字符串"
      },
      "arg2": {
        "type": "string",
        "minLength": 1,
        "description": "travel-plan 技能生成的 TravelPlan 对象序列化后的 JSON 字符串"
      }
    }
  }
}
```

参数按 `arg1`、`arg2` 的顺序传入 `createReminderPlan`。两者都必须是已经生成、格式合法的方案对象，不得传入尚未确认的猜测数据。

## 执行返回值

### 成功：生成提醒计划

```json
{
  "type": "result",
  "status": "success",
  "data": {
    "reminders": [
      {
        "id": "R3",
        "title": "该出发了",
        "content": "现在出发，28分钟到市第一人民医院",
        "triggerAt": 1756080000000,
        "targetDevice": "watch",
        "channel": "vibrate",
        "fired": false
      }
    ],
    "registered": false,
    "speech": "已经为您整理好5个提醒，确认方案后才会正式开启"
  }
}
```

### 失败：方案信息缺失

```json
{
  "type": "result",
  "status": "failed",
  "errCode": "ERR_INVALID_PARAMS",
  "errMsg": "appointment or travelPlan is empty",
  "suggestion": "需要先完成就诊和出行安排"
}
```

### 失败：内部服务异常

```json
{
  "type": "result",
  "status": "failed",
  "errCode": "ERR_INTERNAL",
  "errMsg": "reminder plan build failed",
  "suggestion": "提醒计划生成失败，请稍后再试"
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
      "required": ["reminders", "registered", "speech"],
      "properties": {
        "reminders": {
          "type": "array",
          "items": {
            "type": "object",
            "additionalProperties": false,
            "required": ["id", "title", "content", "triggerAt", "targetDevice", "channel", "fired"],
            "properties": {
              "id": { "type": "string", "minLength": 1 },
              "title": { "type": "string", "minLength": 1 },
              "content": { "type": "string", "minLength": 1 },
              "triggerAt": { "type": "number" },
              "targetDevice": { "type": "string", "enum": ["phone", "watch", "earphone"] },
              "channel": { "type": "string", "enum": ["card", "vibrate", "voice"] },
              "fired": { "type": "boolean", "const": false }
            }
          }
        },
        "registered": { "type": "boolean", "const": false },
        "speech": { "type": "string", "minLength": 1 }
      }
    },
    "errCode": {
      "type": "string",
      "enum": ["ERR_INVALID_PARAMS", "ERR_INTERNAL"]
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
        "errCode": { "const": "ERR_INTERNAL" }
      },
      "required": ["errCode", "errMsg", "suggestion"]
    }
  ]
}
```

## 播报要求

- 一次说清共生成了几个提醒，并提醒用户"确认方案后才会正式开启"，不表达为已经生效。
- 用药提醒只照读处方原文，不追加"建议""可以""不妨"等诊疗性措辞。
- 天气或路况导致的额外提醒，主动说明原因，让用户理解为何多了一条。

## 异常处理

| 异常 | 返回方式 / 处理方式 |
|---|---|
| 医疗或出行方案缺失 | `ERR_INVALID_PARAMS` |
| 方案 JSON 解析失败或内部异常 | `ERR_INTERNAL` |
| 手表未连接 | 降级到手机通知，保证提醒不丢失 |
| 提醒时间已过 | 跳过该条，不做补发轰炸 |
| 行程变更 | 同步刷新全部下游提醒时间，重新调用本技能生成新计划 |

## 服务记录沉淀（辅助能力）

就诊完成后写入端侧记录，包含：医院、科室、医生、日期、复诊间隔、处方。
下次用户只说"我要拿药"时，可直接补全全部槽位，无需再问。

后台定时扫描历史记录，命中"距上次就诊已接近医生建议的复诊间隔"时，
提前 3 天主动询问用户是否需要预约，而不是等用户想起来。

文案示例："距离上次在市第一人民医院心血管内科看诊快到复诊时间了，需要我现在帮您约王医生的号吗？"
