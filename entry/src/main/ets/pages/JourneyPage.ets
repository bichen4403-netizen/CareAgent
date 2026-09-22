/**
 * 智护同行 - 陪诊行程详情
 *
 * 展示中枢 Agent 汇总后的完整方案：就诊安排 / 出行 / 院内路线 / 提醒清单。
 *
 * 挂号确认拆成两步，不再是"点一下就当挂上了"：
 *   1. 用户看完 AI 推荐方案 → 跳转官方渠道（京医通/浙里办等）完成真正的挂号确认
 *   2. 用户从官方渠道回来后，点"我已在官方完成确认" → 才真正注册后续的出行/提醒
 * 这样设计是因为智护同行没有、也不该有绕过医院官方系统直接下单的权限。
 */

import { router } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import {
  Appointment, TravelPlan, IndoorNavPlan, NavStep, ReminderItem, AgentResult, BookingStatus,
  MedicalPreparation, RecordSource
} from '../core/AgentTypes';
import { blackboard } from '../core/EventBus';
import { DeviceSyncService } from '../services/DeviceSyncService';
import { CardDataStore, CardSnapshot } from '../widget/CardDataStore';
import { OfficialChannelRegistry, OfficialChannel, AppLinkService } from '../services/AppLinkService';
import { ContextStore } from '../core/ContextStore';

@Entry
@Component
struct JourneyPage {
  @State appt: Appointment | null = null;
  @State travel: TravelPlan | null = null;
  @State nav: IndoorNavPlan | null = null;
  @State reminders: ReminderItem[] = [];
  @State preparation: MedicalPreparation | null = null;
  @State confirmed: boolean = false;
  @State medicalSource: string = '';
  @State travelSource: string = '';
  @State navigationSource: string = '';

  aboutToAppear(): void {
    this.loadFromBlackboard();
  }

  /** 从共享黑板取出各 Agent 的产出 */
  private loadFromBlackboard(): void {
    const medical: AgentResult | undefined = blackboard.getResultByAgent('MedicalAgent');
    if (medical !== undefined && medical.data.length > 0) {
      this.medicalSource = this.sourceLabel(medical.dataSource as string);
      const d: Record<string, Object> = JSON.parse(medical.data) as Record<string, Object>;
      this.appt = d['appointment'] as Appointment;
      // 兼容旧版本黑板结果：没有准备清单时仍可正常展示就诊安排。
      if (d['preparation'] !== undefined && d['preparation'] !== null) {
        this.preparation = d['preparation'] as MedicalPreparation;
      }
    }

    const travelRes: AgentResult | undefined = blackboard.getResultByAgent('TravelAgent');
    if (travelRes !== undefined && travelRes.data.length > 0) {
      this.travelSource = this.sourceLabel(travelRes.dataSource as string);
      const d: Record<string, Object> = JSON.parse(travelRes.data) as Record<string, Object>;
      this.travel = d['travelPlan'] as TravelPlan;
    }

    const navRes: AgentResult | undefined = blackboard.getResultByAgent('NavigationAgent');
    if (navRes !== undefined && navRes.data.length > 0) {
      this.navigationSource = this.sourceLabel(navRes.dataSource as string);
      const d: Record<string, Object> = JSON.parse(navRes.data) as Record<string, Object>;
      this.nav = d['navPlan'] as IndoorNavPlan;
    }

    const remindRes: AgentResult | undefined = blackboard.getResultByAgent('ReminderAgent');
    if (remindRes !== undefined && remindRes.data.length > 0) {
      const d: Record<string, Object> = JSON.parse(remindRes.data) as Record<string, Object>;
      this.reminders = d['reminders'] as ReminderItem[];
    }
  }

  /**
   * 第一步：跳转官方渠道
   * 只是把用户带过去，不代表挂号已完成，所以这里不设置 confirmed
   */
  private async onGoToOfficialChannel(): Promise<void> {
    if (this.appt === null) {
      return;
    }
    const channel: OfficialChannel = OfficialChannelRegistry.resolve(this.appt.hospitalAddress);
    this.appt.bookingStatus = BookingStatus.AWAITING_OFFICIAL;

    const ctx = getContext(this) as common.UIAbilityContext;
    const opened: boolean = await AppLinkService.openOfficialChannel(ctx, channel);

    if (opened) {
      DeviceSyncService.speak(`已经帮您打开${channel.name}，${channel.hint}`);
    } else {
      DeviceSyncService.speak(`没能自动打开${channel.name}，麻烦您手动打开一下官方渠道确认`);
    }
  }

  /**
   * 第二步：用户从官方渠道回来后，手动确认"我真的挂上号了"
   * 只有这一步之后才真正注册出行提醒、同步桌面卡片 —— 避免用户还没挂上号，
   * 手表却已经在提醒"该出发了"这种前后矛盾的体验
   */
  private async onConfirmOfficialDone(): Promise<void> {
    if (this.appt === null) {
      return;
    }
    this.appt.bookingStatus = BookingStatus.CONFIRMED;
    this.confirmed = true;
    // 用户明确确认后才沉淀为可信历史，供下一次复诊/取药补全医院和科室。
    try {
      await ContextStore.getInstance().addRecord({
        recordId: `visit_${Date.now()}`,
        hospital: this.appt.hospitalName,
        department: this.appt.department,
        doctorName: this.appt.doctorName,
        visitDate: this.appt.visitDate,
        followUpDays: 0,
        prescription: '',
        source: RecordSource.MANUAL_INPUT,
        confirmed: true
      });
    } catch (e) {
      console.error(`[JourneyPage] save confirmed visit failed: ${e}`);
    }
    DeviceSyncService.scheduleReminders(this.reminders);
    DeviceSyncService.speak('好的，都记下了，到时间我会提醒您');
    this.syncToCard();
  }

  /**
   * 把方案同步到桌面卡片
   * 老人不用打开 App，在桌面就能看到"下一步该做什么"
   */
  private syncToCard(): void {
    if (this.appt === null) {
      return;
    }
    const ctx = getContext(this) as common.UIAbilityContext;
    const departTime: string = this.travel === null ? this.appt.visitTime : this.travel.departTime;
    const detail: string = this.travel === null ? '' : this.travel.suggestion;

    const snapshot: CardSnapshot = {
      hasPlan: true,
      title: `${this.appt.visitDate} ${this.appt.visitTime} ${this.appt.department}`,
      nextAction: `${departTime} 出发`,
      detail: detail,
      hospital: this.appt.hospitalName,
      stepIndex: 1,
      stepTotal: this.reminders.length,
      updatedAt: Date.now()
    };

    CardDataStore.writeSnapshot(ctx, snapshot).catch((e: Error) => {
      console.error(`[JourneyPage] sync card failed: ${e.message}`);
    });
  }

  private bookingStatusLabel(s: BookingStatus): string {
    if (s === BookingStatus.CONFIRMED) {
      return '已在官方渠道确认';
    }
    if (s === BookingStatus.AWAITING_OFFICIAL) {
      return '已跳转官方渠道，等待确认';
    }
    return 'AI推荐方案，待官方确认';
  }

  private deviceLabel(d: string): string {
    if (d === 'watch') {
      return '手表';
    }
    if (d === 'earphone') {
      return '耳机';
    }
    return '手机';
  }

  private sourceLabel(source: string): string {
    if (source === 'OFFICIAL') {
      return '官方数据';
    }
    if (source === 'REALTIME_API') {
      return '实时接口';
    }
    if (source === 'DEMO') {
      return '演示数据，请勿作为真实号源使用';
    }
    if (source === 'FALLBACK') {
      return '接口降级数据';
    }
    return '本地计算';
  }

  private formatTime(ts: number): string {
    const d: Date = new Date(ts);
    const h: string = `${d.getHours()}`.padStart(2, '0');
    const m: string = `${d.getMinutes()}`.padStart(2, '0');
    return `${d.getMonth() + 1}月${d.getDate()}日 ${h}:${m}`;
  }

  @Builder
  SectionCard(title: string, tag: string) {
    Row() {
      Text(title)
        .fontSize(20)
        .fontWeight(FontWeight.Bold)
        .fontColor('#1B2A34')
      Blank()
      Text(tag)
        .fontSize(14)
        .fontColor('#2E6F8E')
        .padding({ left: 10, right: 10, top: 4, bottom: 4 })
        .backgroundColor('#E3EEF4')
        .borderRadius(10)
    }
    .width('100%')
    .margin({ bottom: 12 })
  }

  @Builder
  InfoRow(label: string, value: string) {
    Row() {
      Text(label)
        .fontSize(18)
        .fontColor('#7A8A96')
        .width(88)
      Text(value)
        .fontSize(18)
        .fontColor('#22303C')
        .layoutWeight(1)
    }
    .width('100%')
    .padding({ top: 7, bottom: 7 })
    .alignItems(VerticalAlign.Top)
  }

  build() {
    Column() {
      // 标题栏
      Row() {
        Text('返回')
          .fontSize(18)
          .fontColor('#2E6F8E')
          .onClick(() => {
            router.back();
          })
        Blank()
        Text('陪诊安排')
          .fontSize(22)
          .fontWeight(FontWeight.Bold)
        Blank()
        Text('  ')
          .fontSize(18)
      }
      .width('100%')
      .padding({ left: 20, right: 20, top: 14, bottom: 14 })

      Scroll() {
        Column() {
          // 就诊安排
          if (this.appt !== null) {
            Column() {
              this.SectionCard('就诊安排', '医疗 Agent')
              this.InfoRow('医院', this.appt.hospitalName)
              this.InfoRow('科室', this.appt.department)
              this.InfoRow('医生', this.appt.doctorName)
              this.InfoRow('时间', `${this.appt.visitDate} ${this.appt.visitTime}`)
              this.InfoRow('诊室', `${this.appt.buildingName}${this.appt.floor}${this.appt.roomNo}`)
              this.InfoRow('费用', `${this.appt.registrationFee}元`)
              this.InfoRow('状态', this.bookingStatusLabel(this.appt.bookingStatus))
              this.InfoRow('数据来源', this.medicalSource)
            }
            .cardStyle()
          }

          // 医疗 Agent 的材料与注意事项，统一从医疗服务结果读取
          if (this.preparation !== null) {
            Column() {
              this.SectionCard('就诊准备', '医疗 Agent')
              Text('到院前要做什么')
                .fontSize(17)
                .fontWeight(FontWeight.Medium)
                .fontColor('#1B2A34')
                .width('100%')
                .margin({ bottom: 4 })
              ForEach(this.preparation.visitItems, (item: string) => {
                Text(`• ${item}`)
                  .fontSize(17)
                  .fontColor('#22303C')
                  .width('100%')
                  .padding({ top: 4, bottom: 4 })
              }, (item: string) => `visit_${item}`)

              Text('需要带的材料')
                .fontSize(17)
                .fontWeight(FontWeight.Medium)
                .fontColor('#1B2A34')
                .width('100%')
                .margin({ top: 10, bottom: 4 })
              ForEach(this.preparation.materials, (item: string) => {
                Text(`• ${item}`)
                  .fontSize(17)
                  .fontColor('#22303C')
                  .width('100%')
                  .padding({ top: 4, bottom: 4 })
              }, (item: string) => `material_${item}`)

              Text('注意事项')
                .fontSize(17)
                .fontWeight(FontWeight.Medium)
                .fontColor('#1B2A34')
                .width('100%')
                .margin({ top: 10, bottom: 4 })
              ForEach(this.preparation.notices, (item: string) => {
                Text(`• ${item}`)
                  .fontSize(17)
                  .fontColor('#7A5A3A')
                  .width('100%')
                  .padding({ top: 4, bottom: 4 })
              }, (item: string) => `notice_${item}`)
            }
            .cardStyle()
          }

          // 出行方案
          if (this.travel !== null) {
            Column() {
              this.SectionCard('出行方案', '出行 Agent')
              this.InfoRow('出发', `${this.travel.departTime}`)
              this.InfoRow('车程', `约${this.travel.durationMin}分钟 · ${this.travel.distanceKm}公里`)
              this.InfoRow('路况', `${this.travel.trafficLevel} · ${this.travel.weather}`)
              this.InfoRow('说明', this.travel.suggestion)
              this.InfoRow('数据来源', this.travelSource)
            }
            .cardStyle()
          }

          // 院内路线
          if (this.nav !== null) {
            Column() {
              this.SectionCard('院内路线', '导航 Agent')
              this.InfoRow('入口', this.nav.entrance)
              this.InfoRow('目的地', this.nav.targetRoom)
              this.InfoRow('数据来源', this.navigationSource)
              ForEach(this.nav.steps, (s: NavStep) => {
                Row() {
                  Text(`${s.order}`)
                    .fontSize(15)
                    .fontColor('#FFFFFF')
                    .width(26)
                    .height(26)
                    .textAlign(TextAlign.Center)
                    .backgroundColor('#7FA8C9')
                    .borderRadius(13)
                  Text(s.instruction)
                    .fontSize(17)
                    .fontColor('#22303C')
                    .layoutWeight(1)
                    .margin({ left: 12 })
                }
                .width('100%')
                .padding({ top: 8, bottom: 8 })
                .alignItems(VerticalAlign.Top)
              }, (s: NavStep) => `${s.order}`)
            }
            .cardStyle()
          }

          // 提醒清单 —— 体现跨设备分工
          if (this.reminders.length > 0) {
            Column() {
              this.SectionCard('全流程提醒', '提醒 Agent')
              ForEach(this.reminders, (r: ReminderItem) => {
                Row() {
                  Column() {
                    Text(r.title)
                      .fontSize(18)
                      .fontColor('#22303C')
                      .width('100%')
                    Text(r.content)
                      .fontSize(15)
                      .fontColor('#7A8A96')
                      .width('100%')
                      .margin({ top: 3 })
                  }
                  .layoutWeight(1)
                  .alignItems(HorizontalAlign.Start)

                  Column() {
                    Text(this.deviceLabel(r.targetDevice))
                      .fontSize(14)
                      .fontColor('#B5622C')
                      .padding({ left: 8, right: 8, top: 3, bottom: 3 })
                      .backgroundColor('#F7E9DC')
                      .borderRadius(8)
                    Text(this.formatTime(r.triggerAt))
                      .fontSize(13)
                      .fontColor('#9AA8B2')
                      .margin({ top: 4 })
                  }
                  .alignItems(HorizontalAlign.End)
                }
                .width('100%')
                .padding({ top: 10, bottom: 10 })
                .alignItems(VerticalAlign.Top)
              }, (r: ReminderItem) => r.id)
            }
            .cardStyle()
          }

          if (this.appt === null) {
            Text('还没有陪诊安排，回到首页跟我说一句就行')
              .fontSize(19)
              .fontColor('#7A8A96')
              .margin({ top: 60 })
          }
        }
        .width('100%')
        .padding({ left: 16, right: 16, bottom: 20 })
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)

      // 挂号确认分两步：先跳转官方渠道，用户回来后再点"已完成"
      if (this.appt !== null && !this.confirmed) {
        Column() {
          Text(`这是我帮您选好的方案，还需要去${this.appt.officialChannelName}上确认才算真的挂上号`)
            .fontSize(15)
            .fontColor('#7A8A96')
            .width('88%')
            .margin({ bottom: 10 })

          Button(`跳转${this.appt.officialChannelName}确认`)
            .fontSize(20)
            .width('88%')
            .height(58)
            .borderRadius(29)
            .backgroundColor('#2E6F8E')
            .margin({ bottom: 12 })
            .onClick(() => {
              this.onGoToOfficialChannel();
            })

          Button('我已经在官方完成确认了')
            .fontSize(18)
            .width('88%')
            .height(54)
            .borderRadius(27)
            .backgroundColor('#E8874A')
            .margin({ bottom: 24 })
            .onClick(() => {
              this.onConfirmOfficialDone();
            })
        }
        .width('100%')
      }

      if (this.appt !== null && this.confirmed) {
        Button('已确认，提醒已开启')
          .fontSize(21)
          .width('88%')
          .height(62)
          .borderRadius(31)
          .backgroundColor('#8AA5B4')
          .enabled(false)
          .margin({ bottom: 24 })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#EEF3F6')
  }
}

@Extend(Column)
function cardStyle() {
  .width('100%')
  .padding(18)
  .backgroundColor('#FFFFFF')
  .borderRadius(16)
  .margin({ bottom: 14 })
  .alignItems(HorizontalAlign.Start)
}
