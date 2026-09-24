---
name: travel-plan
description: 出行协同技能。当需要规划前往医院的行程、计算出发时间、叫车或安排返程时使用。本技能不自行决定出发时间，而是读取医疗技能确定的就诊时间倒推，并结合实时路况与天气增加缓冲。
---

# 出行协同 Skill

> 上传说明：`scripts/TravelPlanSkill.ets` 是独立运行脚本，不依赖 App 内的
> `src/main/ets` 文件。上传包只需保留本文件和 `scripts/TravelPlanSkill.ets`。
> 脚本顶部的 `GATEWAY_BASE_URL` 配置为自建网关地址时，车程来自高德实时路线；
> 网关设置了 `APP_ACCESS_TOKEN` 时，把同一个值填入脚本的 `GATEWAY_APP_TOKEN`；
> 未配置时返回演示估算，并在 `suggestion` 与播报中明确标注“估算”，不冒充实时路况。

## 触发场景

当就诊时间与目的地已经确定，需要计算出发时间或行程方案时调用，例如：

- 医疗技能确定就诊时间后自动激活
- 用户主动问"几点出发""帮我叫车""看完了怎么回去"

不要调用的情况：

- 就诊时间或医院地址尚未确定（应先完成 medical-assist 流程）。
- 用户询问的是到院后的院内路线（属于 hospital-nav 技能）。
- 用户要求直接下单叫车支付，而未经过方案确认环节。

## 核心原则

**不要自己拍脑袋定出发时间。** 必须先从共享上下文读取医疗技能输出的 `visitTime`，
再倒推。倒推公式：

```
出发时间 = 就诊时间 - 车程 - 天气/路况缓冲 - 15分钟(取号排队)
```

## 安全边界

- 叫车会产生实际费用，**必须经用户确认后才下单**。
- 位置信息仅用于本次行程规划，不做轨迹留存。
- 返程叫车在用户确认就诊结束后触发，不主动扣费。
- 不得虚构路况或天气数据；查询失败时应如实返回异常，不得编造车程时间。

## 执行流程

1. 从共享上下文读取就诊时间、医院地址
2. 读取用户当前位置（无授权则用档案中的住址）
3. 查询实时路况与天气
4. 计算缓冲时间：
   - 晴/多云，路况畅通 → 缓冲 10 分钟
   - 有雨雪，或路况拥堵 → 缓冲 25 分钟
5. 倒推出发时间
6. 就诊结束后，自动触发返程叫车

### 场景 1：生成出行方案（planTrip）

## 执行参数

exec-cli(command: ohos-arkTSScript --skillName 'travel-plan' --scriptPath 'scripts/TravelPlanSkill.ets' --functionName 'planTrip' --args '{
  "arg1": "120.15",
  "arg2": "30.28",
  "arg3": "幸福小区3栋2单元",
  "arg4": "市第一人民医院（人民路128号）",
  "arg5": "09:00",
  "arg6": "小雨"
}')

```json
{
  "args": {
    "type": "object",
    "required": ["arg4", "arg5"],
    "additionalProperties": false,
    "properties": {
      "arg1": {
        "type": "string",
        "description": "起点经度；未知时传空字符串，由端侧定位或用户档案住址补全"
      },
      "arg2": {
        "type": "string",
        "description": "起点纬度；未知时传空字符串，由端侧定位或用户档案住址补全"
      },
      "arg3": {
        "type": "string",
        "description": "起点地址文字描述；未提供时默认为“当前位置”"
      },
      "arg4": {
        "type": "string",
        "minLength": 1,
        "description": "目的地地址，通常为医疗技能返回的医院地址"
      },
      "arg5": {
        "type": "string",
        "minLength": 1,
        "pattern": "^[0-9]{2}:[0-9]{2}$",
        "description": "就诊时间 HH:mm，必须来自医疗技能已确定的方案，不得自行猜测"
      },
      "arg6": {
        "type": "string",
        "description": "当前天气描述；未知时传“未知”"
      }
    }
  }
}
```

参数按 `arg1` 至 `arg6` 的顺序传入 `planTrip`。`arg4`（目的地）和 `arg5`（就诊时间）为必填项，缺一不可；坐标类参数缺失时允许传空字符串，由端侧定位能力兜底。

## 执行返回值

### 成功：生成出行方案

```json
{
  "type": "result",
  "status": "success",
  "data": {
    "travelPlan": {
      "originAddress": "幸福小区3栋2单元",
      "destAddress": "市第一人民医院（人民路128号）",
      "departTime": "07:52",
      "durationMin": 28,
      "distanceKm": 8.6,
      "trafficLevel": "拥堵",
      "weather": "小雨",
      "bufferMin": 25,
      "suggestion": "今天有雨，建议提前出发，已为您多留出时间"
    },
    "speech": "建议您7点52分出发，车程大约28分钟。今天有雨，已经多留出时间，到9点正好赶上看诊"
  }
}
```

### 失败：目的地或就诊时间缺失

```json
{
  "type": "result",
  "status": "failed",
  "errCode": "ERR_INVALID_PARAMS",
  "errMsg": "destination or visitTime is empty",
  "suggestion": "还需要确认医院地址和就诊时间"
}
```

### 失败：内部服务异常

```json
{
  "type": "result",
  "status": "failed",
  "errCode": "ERR_INTERNAL",
  "errMsg": "driving route unavailable",
  "suggestion": "暂时没能生成出行方案，请稍后再试"
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
      "required": ["travelPlan", "speech"],
      "properties": {
        "travelPlan": {
          "type": "object",
          "additionalProperties": false,
          "required": [
            "originAddress", "destAddress", "departTime", "durationMin",
            "distanceKm", "trafficLevel", "weather", "bufferMin", "suggestion"
          ],
          "properties": {
            "originAddress": { "type": "string", "minLength": 1 },
            "destAddress": { "type": "string", "minLength": 1 },
            "departTime": { "type": "string", "pattern": "^[0-9]{2}:[0-9]{2}$" },
            "durationMin": { "type": "number", "minimum": 0 },
            "distanceKm": { "type": "number", "minimum": 0 },
            "trafficLevel": { "type": "string", "enum": ["畅通", "缓行", "拥堵"] },
            "weather": { "type": "string", "minLength": 1 },
            "bufferMin": { "type": "number", "minimum": 0 },
            "suggestion": { "type": "string", "minLength": 1 }
          }
        },
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

- 说清楚"几点出发"和"为什么是这个点"
- 天气或路况有影响时，主动解释原因，让用户明白系统不是随便定的
- 示例："建议您7点52分出发，车程大约28分钟。今天有雨，已经多留出时间，到9点正好赶上看诊"

## 异常处理

| 异常 | 返回方式 / 处理方式 |
|---|---|
| 目的地或就诊时间缺失 | `ERR_INVALID_PARAMS` |
| 路况/地理编码服务异常 | `ERR_INTERNAL` |
| 天气突变为暴雨/大雪 | 触发重规划，提前出发时间，主动告知用户 |
| 严重拥堵导致来不及 | 建议改约或提前更多时间，交回中枢决策 |
| 定位不可用 | 使用用户档案住址，并提示用户确认起点 |
