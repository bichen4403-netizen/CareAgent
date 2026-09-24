/**
 * 智护同行 - 陪诊安排详情
 *
 * 展示中枢 Agent 汇总后的完整方案（从端侧 JourneyStore 读取，App 被回收后也不会丢）。
 *
 * 挂号确认分两步，AI 不会、也不能绕过医院官方系统：
 *   1. 看完推荐方案 → 打开官方渠道（京医通 / 浙里办等）完成真正的挂号
 *   2. 回到本应用 → 点“我已挂上号，开启提醒”，才注册全流程提醒并更新桌面卡片
 */

import { common } from '@kit.AbilityKit';
import {
  Appointment, JourneyRecord, JourneyStage, NavStep, ReminderItem, BusEvent, BusMessage
} from '../core/AgentTypes';
import { eventBus } from '../core/EventBus';
import { JourneyStore } from '../core/JourneyStore';
import { DateUtil } from '../core/DateUtil';
import { DeviceSyncService, ScheduleResult } from '../services/DeviceSyncService';
import { OfficialChannel, OfficialChannelRegistry, AppLinkService } from '../services/AppLinkService';
import { CardDataStore } from '../widget/CardDataStore';
import { UiLabels } from '../utils/UiLabels';

@Entry
@Component
struct JourneyPage {
  @State journey: JourneyRecord | null = null;
  @State isDraft: boolean = false;
  @State replaceNotice: string = '';
  @State working: boolean = false;
  @State nowTs: number = Date.now();

  private journeyHandler: (msg: BusMessage) => void = (msg: BusMessage) => {
    this.load();
  };
  private askedAfterReturn: boolean = false;

  aboutToAppear(): void {
    eventBus.on(BusEvent.JOURNEY_CHANGED, this.journeyHandler);
    this.load();
  }

  aboutToDisappear(): void {
    eventBus.off(BusEvent.JOURNEY_CHANGED, this.journeyHandler);
  }

  /** 从官方渠道回来时刷新，并追问一次“挂上了吗” */
  onPageShow(): void {
    this.load();
    const j: JourneyRecord | null = this.journey;
    if (j !== null && j.stage === JourneyStage.AWAITING_OFFICIAL && !this.askedAfterReturn) {
      this.askedAfterReturn = true;
      DeviceSyncService.speak('挂上号了吗？挂上了就点下面的“我已挂上号，开启提醒”。', true);
    }
  }

  private load(): void {
    const store: JourneyStore = JourneyStore.getInstance();
    const draft: JourneyRecord | null = store.getDraft();
    const active: JourneyRecord | null = store.getActive();
    this.nowTs = Date.now();
    this.isDraft = draft !== null;
    this.journey = draft !== null ? draft : active;
    if (draft !== null && active !== null) {
      const a: Appointment = active.appointment;
      this.replaceNotice = `您已确认过 ${DateUtil.friendlyDate(a.visitDate, this.nowTs)} ${a.visitTime} ` +
        `${a.hospitalName}${a.department} 的安排，确认新方案后会替换它，原来的提醒也会一起更新。`;
    } else {
      this.replaceNotice = '';
    }
  }

  private hostContext(): common.UIAbilityContext | null {
    const ctx: Context | undefined = this.getUIContext().getHostContext();
    return ctx === undefined ? null : ctx as common.UIAbilityContext;
  }

  private toast(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message, duration: 2500 });
    } catch (e) {
      console.warn(`[JourneyPage] toast failed: ${e}`);
    }
  }

  private back(): void {
    this.getUIContext().getRouter().back();
  }

  private channelOf(j: JourneyRecord): OfficialChannel {
    return OfficialChannelRegistry.byName(j.appointment.officialChannelName,
      `${j.appointment.hospitalName}${j.appointment.hospitalAddress}`);
  }

  // ==================== 确认流程 ====================

  /** 第一步：打开官方渠道。只是把用户带过去，不代表已经挂上号 */
  private async onGoOfficial(): Promise<void> {
    const j: JourneyRecord | null = this.journey;
    const ctx: common.UIAbilityContext | null = this.hostContext();
    if (j === null || ctx === null) {
      return;
    }
    const channel: OfficialChannel = this.channelOf(j);
    await JourneyStore.getInstance().markAwaitingOfficial();
    this.askedAfterReturn = false;
    const how: string = await AppLinkService.openChannel(ctx, channel);
    if (how === 'none') {
      this.toast(`没能打开，请手动打开“${channel.name}”`);
    } else {
      this.toast(channel.hint);
    }
    this.load();
  }

  /** 第二步：用户确认已在官方渠道挂上号 → 注册提醒、更新卡片 */
  private async onConfirmBooked(): Promise<void> {
    if (this.working || this.journey === null || !this.isDraft) {
      return;
    }
    this.working = true;
    try {
      const ctx: common.UIAbilityContext | null = this.hostContext();
      let notificationOk: boolean = true;
      if (ctx !== null) {
        notificationOk = await DeviceSyncService.ensureNotificationEnabled(ctx);
      }
      const reminders: ReminderItem[] = this.journey.reminders;
      const result: ScheduleResult = await DeviceSyncService.scheduleReminders(reminders);
      const scheduled: number = result.platform + result.local;
      const active: JourneyRecord | null = await JourneyStore.getInstance().promoteDraft(scheduled);
      if (ctx !== null && active !== null) {
        await CardDataStore.writeSnapshot(ctx, CardDataStore.fromJourney(active));
      }
      let msg: string = '';
      if (scheduled > 0) {
        msg = `好的，已经为您开启${scheduled}个提醒，到时间会通知您。`;
        if (!notificationOk) {
          msg += '不过通知还没打开，提醒可能收不到，请在系统设置里允许通知。';
        }
      } else {
        msg = '已确认。就诊时间很近了，来不及提前提醒，请抓紧时间出发。';
      }
      DeviceSyncService.speak(msg, true);
      this.toast(msg);
      this.load();
    } catch (e) {
      console.error(`[JourneyPage] confirm failed: ${e}`);
      this.toast('开启提醒时出了问题，请再试一次');
    } finally {
      this.working = false;
    }
  }

  /** 没挂上 / 不要这个方案：丢弃草稿，回首页重新说 */
  private async onDiscardDraft(): Promise<void> {
    await JourneyStore.getInstance().discardDraft();
    DeviceSyncService.speak('好的，这个方案不要了。想改成哪天、哪家医院，跟我说就行。', true);
    this.back();
  }

  private onCancelActive(): void {
    this.getUIContext().showAlertDialog({
      title: '取消这次安排？',
      message: '取消后，这次的出发、候诊等提醒都会关掉。医院那边的挂号需要您在官方渠道自行取消。',
      primaryButton: {
        value: '先不取消',
        action: () => {
          console.info('[JourneyPage] cancel aborted');
        }
      },
      secondaryButton: {
        value: '确认取消',
        fontColor: '#C8553D',
        action: () => {
          this.doCancelActive();
        }
      }
    });
  }

  private async doCancelActive(): Promise<void> {
    await DeviceSyncService.cancelAllReminders();
    await JourneyStore.getInstance().cancelActive();
    const ctx: common.UIAbilityContext | null = this.hostContext();
    if (ctx !== null) {
      await CardDataStore.writeSnapshot(ctx, CardDataStore.emptySnapshot());
    }
    DeviceSyncService.speak('已取消这次安排，提醒也关掉了。医院的挂号记得在官方渠道取消。', true);
    this.back();
  }

  private openNavGuide(): void {
    this.getUIContext().getRouter().pushUrl({ url: 'pages/NavGuidePage' }).catch((err: Error) => {
      console.error(`[JourneyPage] open nav guide failed: ${err.message}`);
    });
  }

  // ==================== UI ====================

  @Builder
  SectionTitle(title: string, source: string) {
    Row() {
      Text(title)
        .fontSize(20)
        .fontWeight(FontWeight.Bold)
        .fontColor('#1B2A34')
      Blank()
      if (source.length > 0 && UiLabels.source(source).length > 0) {
        Text(UiLabels.source(source))
          .fontSize(13)
          .fontColor(UiLabels.sourceColor(source))
          .padding({ left: 8, right: 8, top: 3, bottom: 3 })
          .backgroundColor('#F4F1EC')
          .borderRadius(8)
      }
    }
    .width('100%')
    .margin({ bottom: 10 })
  }

  @Builder
  InfoRow(label: string, value: string) {
    Row() {
      Text(label)
        .fontSize(17)
        .fontColor('#7A8A96')
        .width(84)
      Text(value)
        .fontSize(18)
        .fontColor('#22303C')
        .layoutWeight(1)
    }
    .width('100%')
    .alignItems(VerticalAlign.Top)
    .padding({ top: 6, bottom: 6 })
  }

  @Builder
  Bullet(text: string) {
    Row() {
      Text('•')
        .fontSize(18)
        .fontColor('#2E6F8E')
        .width(18)
      Text(text)
        .fontSize(17)
        .fontColor('#22303C')
        .layoutWeight(1)
    }
    .width('100%')
    .alignItems(VerticalAlign.Top)
    .padding({ top: 4, bottom: 4 })
  }

  @Builder
  StepRow(step: NavStep) {
    Row() {
      Text(`${step.order}`)
        .fontSize(16)
        .fontColor('#FFFFFF')
        .width(28)
        .height(28)
        .textAlign(TextAlign.Center)
        .backgroundColor('#2E6F8E')
        .borderRadius(14)
      Column() {
        Text(step.instruction)
          .fontSize(18)
          .fontColor('#22303C')
        Text(step.landmark)
          .fontSize(15)
          .fontColor('#7A8A96')
          .margin({ top: 2 })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      .margin({ left: 10 })
    }
    .width('100%')
    .alignItems(VerticalAlign.Top)
    .padding({ top: 8, bottom: 8 })
  }

  @Builder
  ReminderRow(r: ReminderItem) {
    Row() {
      Column() {
        Text(DateUtil.friendlyTime(r.triggerAt, this.nowTs))
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor(r.triggerAt < this.nowTs ? '#B0BAC2' : '#2E6F8E')
        Text(UiLabels.device(r.targetDevice))
          .fontSize(12)
          .fontColor('#8A9AA6')
          .margin({ top: 2 })
      }
      .width(100)
      .alignItems(HorizontalAlign.Start)
      Column() {
        Text(r.title)
          .fontSize(18)
          .fontColor(r.triggerAt < this.nowTs ? '#B0BAC2' : '#22303C')
        Text(r.content)
          .fontSize(15)
          .fontColor(r.triggerAt < this.nowTs ? '#C3CBD1' : '#7A8A96')
          .margin({ top: 2 })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .alignItems(VerticalAlign.Top)
    .padding({ top: 8, bottom: 8 })
  }

  @Builder
  StatusCard(j: JourneyRecord) {
    Column() {
      Text(UiLabels.stage(j.stage))
        .fontSize(15)
        .fontColor(j.stage === JourneyStage.CONFIRMED ? '#3B7A57' : '#A65A2E')
        .padding({ left: 10, right: 10, top: 4, bottom: 4 })
        .backgroundColor(j.stage === JourneyStage.CONFIRMED ? '#E6F2EA' : '#FBEFE3')
        .borderRadius(10)
      Text(this.statusHeadline(j))
        .fontSize(22)
        .fontWeight(FontWeight.Bold)
        .fontColor('#1B2A34')
        .margin({ top: 10 })
        .width('100%')
      Text(this.statusDetail(j))
        .fontSize(17)
        .fontColor('#4A5A66')
        .lineHeight(26)
        .margin({ top: 6 })
        .width('100%')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(18)
    .backgroundColor('#FFFFFF')
    .borderRadius(16)
    .margin({ bottom: 14 })
  }

  private statusHeadline(j: JourneyRecord): string {
    const a: Appointment = j.appointment;
    return `${DateUtil.friendlyDate(a.visitDate, this.nowTs)} ${a.visitTime} · ${a.department}`;
  }

  private statusDetail(j: JourneyRecord): string {
    const channel: string = j.appointment.officialChannelName;
    if (j.stage === JourneyStage.DRAFT) {
      return `这是智能推荐的方案，还没有真正挂号。请先在“${channel}”完成挂号，再回来开启提醒。`;
    }
    if (j.stage === JourneyStage.AWAITING_OFFICIAL) {
      return `在“${channel}”挂上号了吗？挂上了就点下面的按钮开启提醒；没挂上可以重新安排。`;
    }
    const next: ReminderItem | null = this.nextReminder(j);
    if (next !== null) {
      return `下一个提醒：${DateUtil.friendlyTime(next.triggerAt, this.nowTs)} ${next.title}`;
    }
    return '提醒都已完成。看完病回到首页，告诉我医生让您多久后复查。';
  }

  private nextReminder(j: JourneyRecord): ReminderItem | null {
    let found: ReminderItem | null = null;
    for (let i = 0; i < j.reminders.length; i++) {
      const r: ReminderItem = j.reminders[i];
      if (r.triggerAt > this.nowTs && (found === null || r.triggerAt < found.triggerAt)) {
        found = r;
      }
    }
    return found;
  }

  @Builder
  Footer(j: JourneyRecord) {
    Column() {
      if (j.stage === JourneyStage.DRAFT) {
        Button(`去“${j.appointment.officialChannelName}”确认挂号`, { type: ButtonType.Capsule })
          .width('100%')
          .height(58)
          .fontSize(20)
          .backgroundColor('#2E6F8E')
          .onClick(() => {
            this.onGoOfficial();
          })
        Row() {
          Text('已经挂好了？直接开启提醒')
            .fontSize(16)
            .fontColor('#2E6F8E')
            .padding(8)
            .onClick(() => {
              this.onConfirmBooked();
            })
          Blank()
          Text('不要这个方案')
            .fontSize(16)
            .fontColor('#8A9AA6')
            .padding(8)
            .onClick(() => {
              this.onDiscardDraft();
            })
        }
        .width('100%')
        .margin({ top: 6 })
      } else if (j.stage === JourneyStage.AWAITING_OFFICIAL) {
        Button(this.working ? '正在开启提醒…' : '我已挂上号，开启提醒', { type: ButtonType.Capsule })
          .width('100%')
          .height(58)
          .fontSize(20)
          .backgroundColor(this.working ? '#9FB5C1' : '#3B7A57')
          .enabled(!this.working)
          .onClick(() => {
            this.onConfirmBooked();
          })
        Row() {
          Text(`再次打开“${j.appointment.officialChannelName}”`)
            .fontSize(16)
            .fontColor('#2E6F8E')
            .padding(8)
            .onClick(() => {
              this.onGoOfficial();
            })
          Blank()
          Text('没挂上，重新安排')
            .fontSize(16)
            .fontColor('#8A9AA6')
            .padding(8)
            .onClick(() => {
              this.onDiscardDraft();
            })
        }
        .width('100%')
        .margin({ top: 6 })
      } else {
        Row() {
          if (j.nav !== null) {
            Button('开始院内引导', { type: ButtonType.Capsule })
              .layoutWeight(1)
              .height(54)
              .fontSize(19)
              .backgroundColor('#2E6F8E')
              .margin({ right: 10 })
              .onClick(() => {
                this.openNavGuide();
              })
          }
          Button('取消这次安排', { type: ButtonType.Capsule })
            .layoutWeight(1)
            .height(54)
            .fontSize(19)
            .fontColor('#C8553D')
            .backgroundColor('#FBECE8')
            .onClick(() => {
              this.onCancelActive();
            })
        }
        .width('100%')
      }
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 10, bottom: 16 })
    .backgroundColor('#EAF0F3')
  }

  build() {
    Column() {
      Row() {
        Text('‹ 返回')
          .fontSize(18)
          .fontColor('#2E6F8E')
          .padding({ top: 6, bottom: 6, right: 12 })
          .onClick(() => {
            this.back();
          })
        Text('陪诊安排')
          .fontSize(22)
          .fontWeight(FontWeight.Bold)
          .fontColor('#1B2A34')
        Blank()
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 14, bottom: 10 })

      if (this.journey === null) {
        Column() {
          Text('还没有陪诊安排')
            .fontSize(22)
            .fontColor('#4A5A66')
          Text('回到首页，说一句“明天去市第一人民医院复查”就能安排')
            .fontSize(17)
            .fontColor('#8A9AA6')
            .margin({ top: 10 })
            .textAlign(TextAlign.Center)
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
        .padding(24)
      } else {
        Scroll() {
          Column() {
            this.StatusCard(this.journey)

            if (this.replaceNotice.length > 0) {
              Text(this.replaceNotice)
                .fontSize(16)
                .fontColor('#A65A2E')
                .lineHeight(24)
                .width('100%')
                .padding(14)
                .backgroundColor('#FFF6EC')
                .borderRadius(14)
                .margin({ bottom: 14 })
            }

            if (this.journey.travel !== null && this.journey.travel.warning.length > 0) {
              Text(`⚠ ${this.journey.travel.warning}`)
                .fontSize(18)
                .fontColor('#C8553D')
                .lineHeight(26)
                .width('100%')
                .padding(14)
                .backgroundColor('#FBECE8')
                .borderRadius(14)
                .margin({ bottom: 14 })
            }

            // 就诊安排
            Column() {
              this.SectionTitle('就诊安排', this.journey.medicalSource)
              this.InfoRow('医院', this.journey.appointment.hospitalName)
              this.InfoRow('地址', this.journey.appointment.hospitalAddress)
              this.InfoRow('科室', this.journey.appointment.department)
              this.InfoRow('医生', this.journey.appointment.doctorName)
              this.InfoRow('时间',
                `${DateUtil.friendlyDate(this.journey.appointment.visitDate, this.nowTs)} ${this.journey.appointment.visitTime}`)
              this.InfoRow('诊室',
                `${this.journey.appointment.buildingName}${this.journey.appointment.floor}${this.journey.appointment.roomNo}`)
              if (this.journey.appointment.registrationFee > 0) {
                this.InfoRow('挂号费', `约 ${this.journey.appointment.registrationFee} 元（以医院为准）`)
              }
              Text('号源、医生和诊室为演示数据，请以官方渠道最终挂号结果为准。')
                .fontSize(14)
                .fontColor('#A65A2E')
                .margin({ top: 6 })
                .width('100%')
            }
            .width('100%')
            .padding(18)
            .backgroundColor('#FFFFFF')
            .borderRadius(16)
            .margin({ bottom: 14 })

            // 就诊准备
            if (this.journey.preparation.materials.length > 0) {
              Column() {
                this.SectionTitle('出门前准备', '')
                ForEach(this.journey.preparation.materials, (m: string) => {
                  this.Bullet(m)
                }, (m: string) => `m_${m}`)
                ForEach(this.journey.preparation.notices, (n: string) => {
                  Text(n)
                    .fontSize(15)
                    .fontColor('#7A8A96')
                    .lineHeight(22)
                    .width('100%')
                    .margin({ top: 6 })
                }, (n: string) => `n_${n}`)
              }
              .width('100%')
              .padding(18)
              .backgroundColor('#FFFFFF')
              .borderRadius(16)
              .margin({ bottom: 14 })
            }

            // 出行方案
            if (this.journey.travel !== null) {
              Column() {
                this.SectionTitle('出行方案', this.journey.travelSource)
                Text(`建议 ${this.journey.travel.departTime} 出发`)
                  .fontSize(26)
                  .fontWeight(FontWeight.Bold)
                  .fontColor('#2E6F8E')
                  .width('100%')
                  .margin({ bottom: 6 })
                this.InfoRow('路上', `约 ${this.journey.travel.durationMin} 分钟` +
                  (this.journey.travel.distanceKm > 0 ? `（${this.journey.travel.distanceKm} 公里）` : ''))
                this.InfoRow('天气', this.journey.travel.weather)
                this.InfoRow('路况', this.journey.travel.trafficLevel)
                this.InfoRow('多留', `${this.journey.travel.bufferMin} 分钟（取号、排队、找诊室）`)
                this.InfoRow('建议', this.journey.travel.suggestion)
              }
              .width('100%')
              .padding(18)
              .backgroundColor('#FFFFFF')
              .borderRadius(16)
              .margin({ bottom: 14 })
            }

            // 院内路线
            if (this.journey.nav !== null) {
              Column() {
                this.SectionTitle('院内怎么走', this.journey.navSource)
                ForEach(this.journey.nav.steps, (s: NavStep) => {
                  this.StepRow(s)
                }, (s: NavStep) => `s_${s.order}`)
                Button('到医院后，点这里一步一步带我走', { type: ButtonType.Capsule })
                  .width('100%')
                  .height(50)
                  .fontSize(18)
                  .fontColor('#2E6F8E')
                  .backgroundColor('#E3EEF4')
                  .margin({ top: 8 })
                  .onClick(() => {
                    this.openNavGuide();
                  })
              }
              .width('100%')
              .padding(18)
              .backgroundColor('#FFFFFF')
              .borderRadius(16)
              .margin({ bottom: 14 })
            }

            // 提醒
            if (this.journey.reminders.length > 0) {
              Column() {
                this.SectionTitle('全流程提醒', '')
                ForEach(this.journey.reminders, (r: ReminderItem) => {
                  this.ReminderRow(r)
                }, (r: ReminderItem) => `${r.id}_${r.triggerAt}`)
                Text(this.journey.stage === JourneyStage.CONFIRMED
                  ? `已开启 ${this.journey.remindersScheduled} 个提醒。手表会同步手机通知，需在运动健康 App 中开启通知同步。`
                  : '确认挂号后才会开启这些提醒。')
                  .fontSize(14)
                  .fontColor('#7A8A96')
                  .lineHeight(21)
                  .margin({ top: 8 })
                  .width('100%')
              }
              .width('100%')
              .padding(18)
              .backgroundColor('#FFFFFF')
              .borderRadius(16)
              .margin({ bottom: 14 })
            }
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 4, bottom: 12 })
        }
        .layoutWeight(1)
        .scrollBar(BarState.Off)
        .align(Alignment.Top)

        this.Footer(this.journey)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#F2F6F8')
  }
}
