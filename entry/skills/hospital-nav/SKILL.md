---
name: hospital-nav
description: 院内导航技能。当用户到达医院后需要找科室、找诊室、找药房、找缴费窗口时使用。输出为可直接语音朗读的口语化分步指引，适合边走边听，不需要看屏幕。
---

# 院内导航 Skill

> 上传说明：`scripts/HospitalNavSkill.ets` 是独立运行脚本，不依赖 App 内的
> `src/main/ets` 文件。上传包只需保留本文件和 `scripts/HospitalNavSkill.ets`。
> 院内地图暂无公开接口，返回的是“到院后核对”的引导模板，而不是医院实时地图；返回值中
> `dataSource` 固定为 `TEMPLATE`，每一步都要求用户优先按现场导视或导诊台信息确认。

## 触发场景

当用户明确表达需要院内路线指引时调用，例如：

- 用户到达医院、进入门诊楼后自动激活
- 用户问"诊室在哪""药房怎么走""在几楼""缴费窗口在哪"

不要调用的情况：

- 用户询问的是从家到医院的路线或出发时间（属于 travel-plan 技能）。
- 用户询问疾病诊断、检查结果解读或治疗建议。
- 用户尚未确定要去的医院，无法定位院内路线。

## 为什么需要这个技能

老年用户在医院最容易迷路的不是"怎么到医院"，而是**进门之后**。
门诊楼指示牌信息密集、字小、术语多，本技能把它翻译成一步一步的口语指引。

## 安全边界

- 院内地图数据以医院官方发布为准，不臆造固定电梯、自助机、缴费窗口、药房位置、步行距离或步行时间。
- 若目标位置信息缺失，如实告知并建议就近询问导医台，不猜测。
- 不采集用户在院内的移动轨迹。

## 执行流程

1. 从共享上下文读取目标位置（诊室 / 药房 / 缴费窗口）
2. 生成分步核对指引，每步包含：动作 + 现场可核对的参照物
3. 通过耳机逐步语音播报，用户走到一个节点再播下一步
4. 就诊场景导航到诊室；取药场景导航到缴费窗口再到药房

### 场景 1：查询院内路线（getIndoorRoute）

## 执行参数

exec-cli(command: ohos-arkTSScript --skillName 'hospital-nav' --scriptPath 'scripts/HospitalNavSkill.ets' --functionName 'getIndoorRoute' --args '{
  "arg1": "市第一人民医院",
  "arg2": "门诊楼",
  "arg3": "3楼",
  "arg4": "316诊室",
  "arg5": "clinic"
}')

```json
{
  "args": {
    "type": "object",
    "required": ["arg1"],
    "additionalProperties": false,
    "properties": {
      "arg1": {
        "type": "string",
        "minLength": 1,
        "description": "医院名称，必须已明确，不得为空"
      },
      "arg2": {
        "type": "string",
        "description": "门诊楼/建筑名称；targetType 为 pharmacy 时可传空字符串"
      },
      "arg3": {
        "type": "string",
        "description": "楼层；targetType 为 pharmacy 时可传空字符串"
      },
      "arg4": {
        "type": "string",
        "description": "诊室/房间号；targetType 为 pharmacy 时可传空字符串"
      },
      "arg5": {
        "type": "string",
        "enum": ["clinic", "pharmacy"],
        "description": "目标类型：clinic 表示诊室导航，pharmacy 表示药房导航；未指定时默认为 clinic"
      }
    }
  }
}
```

参数按 `arg1` 至 `arg5` 的顺序传入 `getIndoorRoute`。当 `arg5` 为 `clinic`（含未传时的默认值）时，`arg2`（门诊楼）、`arg3`（楼层）、`arg4`（诊室）三者必须同时提供，否则应先向用户澄清；当 `arg5` 为 `pharmacy` 时，`arg2`~`arg4` 可以为空字符串。

## 执行返回值

### 成功：生成到院后核对模板

```json
{
  "type": "result",
  "status": "success",
  "data": {
    "navPlan": {
      "entrance": "门诊楼入口（请以现场导视为准）",
      "targetRoom": "门诊楼3楼316诊室（待现场确认）",
      "estimatedWalkMin": 0,
      "steps": [
        { "order": 1, "instruction": "进入门诊楼后，先向导诊台核对3楼316诊室是否正确", "landmark": "导诊台或服务台" },
        { "order": 2, "instruction": "按现场导视牌前往3楼；行动不便时询问无障碍路线", "landmark": "楼层与科室导视牌" },
        { "order": 3, "instruction": "到3楼后，按门牌和叫号屏确认316诊室，再到候诊区等候", "landmark": "门牌、叫号屏或导诊人员" }
      ]
    },
    "dataSource": "TEMPLATE",
    "verificationStatus": "ONSITE_CONFIRMATION_REQUIRED",
    "speech": "以下是院内引导模板，不是该医院的实时地图。进入医院后，请先按现场导视或向导诊台确认。"
  }
}
```

### 失败：医院信息缺失

```json
{
  "type": "result",
  "status": "failed",
  "errCode": "ERR_INVALID_PARAMS",
  "errMsg": "hospital is empty",
  "suggestion": "请先确认要去的医院"
}
```

### 失败：诊室位置信息不完整

```json
{
  "type": "result",
  "status": "failed",
  "errCode": "ERR_NEED_CLARIFICATION",
  "errMsg": "clinic location is incomplete",
  "suggestion": "还需要确认门诊楼、楼层和诊室"
}
```

### 失败：内部服务异常

```json
{
  "type": "result",
  "status": "failed",
  "errCode": "ERR_INTERNAL",
  "errMsg": "no indoor map data",
  "suggestion": "暂时没有该医院的院内路线，请咨询导医台"
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
      "required": ["navPlan", "dataSource", "verificationStatus", "speech"],
      "properties": {
        "navPlan": {
          "type": "object",
          "additionalProperties": false,
          "required": ["entrance", "targetRoom", "steps", "estimatedWalkMin"],
          "properties": {
            "entrance": { "type": "string", "minLength": 1 },
            "targetRoom": { "type": "string", "minLength": 1 },
            "estimatedWalkMin": { "type": "number", "minimum": 0 },
            "steps": {
              "type": "array",
              "items": {
                "type": "object",
                "additionalProperties": false,
                "required": ["order", "instruction", "landmark"],
                "properties": {
                  "order": { "type": "number", "minimum": 1 },
                  "instruction": { "type": "string", "minLength": 1 },
                  "landmark": { "type": "string", "minLength": 1 }
                }
              }
            }
          }
        },
        "dataSource": { "type": "string", "const": "TEMPLATE" },
        "verificationStatus": { "type": "string", "const": "ONSITE_CONFIRMATION_REQUIRED" },
        "speech": { "type": "string", "minLength": 1 }
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

**每一步必须包含一个可现场核对的参照物**，不能假设某医院的具体布局。

- 错误："向前走50米后左转" —— 老人无法估算50米，也未必适用于该医院
- 正确："先到导诊台确认，再按楼层导视牌前往目标楼层"

其他要求：
- 一次只播一步，不要一口气念完整条路线
- 用"导诊台""导视牌""门牌"这类日常词，不用未经核验的"2号电梯""左手边自助机"等具体位置
- 每步控制在 20 字以内，适合语音朗读

## 异常处理

| 异常 | 返回方式 / 处理方式 |
|---|---|
| 医院未确定 | `ERR_INVALID_PARAMS` |
| clinic 场景下楼层/诊室信息不全 | `ERR_NEED_CLARIFICATION` |
| 无该医院院内地图或内部异常 | 返回导诊台核对模板，明确不是实时路线 |
| 诊室临时变更 | 提示用户在导诊台或官方挂号单上确认新诊室，再重新调用本技能 |
| 院内定位精度不足 | 只提供楼层级核对提示，不提供方向或距离 |
