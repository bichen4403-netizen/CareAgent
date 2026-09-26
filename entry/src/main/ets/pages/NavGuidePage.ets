/**
 * 智护同行 - 院内引导
 *
 * 导航 Agent 的“到院后”环节：把院内路线拆成一步一步的大字卡片，
 * 每一步自动语音播报（连着耳机就从耳机里听），老人边走边点“下一步”。
 * 引导期间保持屏幕常亮，免得走着走着屏幕黑了找不到按钮。
 * 从“快到医院了”提醒点进来会直接打开本页。
 */

import { common } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { IndoorNavPlan, JourneyRecord, NavStep, DataSourceType } from '../core/AgentTypes';
import { JourneyStore } from '../core/JourneyStore';
import { NavigationAgent } from '../agents/NavigationAgent';
import { DeviceSyncService } from '../services/DeviceSyncService';

@Entry
@Component
struct NavGuidePage {
  @State nav: IndoorNavPlan | null = null;
  @State stepIndex: number = 0;
  @State arrived: boolean = false;
  @State visitInfo: string = '';
  @State isDemoTemplate: boolean = false;

  aboutToAppear(): void {
    const store: JourneyStore = JourneyStore.getInstance();
    const active: JourneyRecord | null = store.getActive();
    const j: JourneyRecord | null = active !== null ? active : store.getDraft();
    if (j !== null && j.nav !== null) {
      this.nav = j.nav;
      this.isDemoTemplate = j.navSource === DataSourceType.DEMO;
      const a = j.appointment;
      const queue: string = a.queueNo.length > 0 ? ` · 排队号 ${a.queueNo}（以医院为准）` : '';
      this.visitInfo = `${a.hospitalName} · ${a.visitTime} 看${a.department}${queue}`;
      this.keepScreenOn(true);
      const intro: string = (this.isDemoTemplate
        ? '以下是演示路线模板，请优先按医院现场导视和导诊台信息确认。'
        : '') + `我来带您去${j.nav.targetRoom}，一共${j.nav.steps.length}步。` +
        NavigationAgent.buildStepSpeech(j.nav, 0);
      DeviceSyncService.speak(intro, true);
    }
  }

  aboutToDisappear(): void {
    this.keepScreenOn(false);
    DeviceSyncService.stopSpeaking();
  }

  private keepScreenOn(on: boolean): void {
    const ctx: Context | undefined = this.getUIContext().getHostContext();
    if (ctx === undefined) {
      return;
    }
    window.getLastWindow(ctx as common.UIAbilityContext).then((win: window.Window) => {
      return win.setWindowKeepScreenOn(on);
    }).catch((err: Error) => {
      console.warn(`[NavGuide] keep screen on failed: ${err.message}`);
    });
  }

  private speakCurrent(): void {
    if (this.nav === null) {
      return;
    }
    DeviceSyncService.speak(NavigationAgent.buildStepSpeech(this.nav, this.stepIndex), true);
  }

  private onNext(): void {
    if (this.nav === null) {
      return;
    }
    if (this.stepIndex >= this.nav.steps.length - 1) {
      this.arrived = true;
      const text: string = this.isDemoTemplate
        ? `演示引导已走完，请按现场导视或询问导诊台，确认是否到达${this.nav.targetRoom}。`
        : `到了，这里就是${this.nav.targetRoom}。在候诊区坐下，留意叫号，快轮到您时我会提醒。`;
      DeviceSyncService.speak(text, true);
      return;
    }
    this.stepIndex += 1;
    this.speakCurrent();
  }

  private onPrev(): void {
    if (this.stepIndex > 0) {
      this.stepIndex -= 1;
      this.speakCurrent();
    }
  }

  private onRestart(): void {
    this.arrived = false;
    this.stepIndex = 0;
    this.speakCurrent();
  }

  private back(): void {
    this.getUIContext().getRouter().back();
  }

  @Builder
  StepCard(nav: IndoorNavPlan, idx: number) {
    Column() {
      Text(`第 ${idx + 1} 步 / 共 ${nav.steps.length} 步`)
        .fontSize(18)
        .fontColor('#2E6F8E')
        .fontWeight(FontWeight.Medium)
      Text(nav.steps[idx].instruction)
        .fontSize(28)
        .fontWeight(FontWeight.Bold)
        .fontColor('#1B2A34')
        .lineHeight(40)
        .margin({ top: 14 })
        .width('100%')
      Text(nav.steps[idx].landmark)
        .fontSize(20)
        .fontColor('#5A6A76')
        .lineHeight(30)
        .margin({ top: 12 })
        .width('100%')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(22)
    .backgroundColor('#FFFFFF')
    .borderRadius(20)
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
        Text('院内引导')
          .fontSize(22)
          .fontWeight(FontWeight.Bold)
          .fontColor('#1B2A34')
        Blank()
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 14, bottom: 10 })

      if (this.nav === null) {
        Column() {
          Text('还没有院内路线')
            .fontSize(22)
            .fontColor('#4A5A66')
          Text('先在首页安排好看病，确认挂号后就能用院内引导')
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
        Column() {
          Text(`去 ${this.nav.targetRoom}`)
            .fontSize(24)
            .fontWeight(FontWeight.Bold)
            .fontColor('#1B2A34')
            .width('100%')
          if (this.visitInfo.length > 0) {
            Text(this.visitInfo)
              .fontSize(15)
              .fontColor('#7A8A96')
              .width('100%')
              .margin({ top: 4 })
          }
          if (this.isDemoTemplate) {
            Text('演示路线模板：不是医院实时地图，请以现场导视和导诊台信息为准。')
              .fontSize(15)
              .fontColor('#A65A2E')
              .lineHeight(22)
              .width('100%')
              .margin({ top: 8 })
          }
          Row({ space: 8 }) {
            ForEach(this.nav.steps, (s: NavStep, i: number) => {
              Column()
                .width(i === this.stepIndex && !this.arrived ? 26 : 12)
                .height(12)
                .borderRadius(6)
                .backgroundColor(i < this.stepIndex || this.arrived ? '#3B7A57' :
                  (i === this.stepIndex ? '#2E6F8E' : '#C9D5DC'))
            }, (s: NavStep) => `dot_${s.order}`)
          }
          .margin({ top: 14 })
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .padding({ left: 20, right: 20, bottom: 14 })

        Scroll() {
          Column() {
            if (this.arrived) {
              Column() {
                Text('✓')
                  .fontSize(56)
                  .fontColor('#3B7A57')
                Text(this.isDemoTemplate ? '已完成引导' : '到了！')
                  .fontSize(30)
                  .fontWeight(FontWeight.Bold)
                  .fontColor('#1B2A34')
                  .margin({ top: 6 })
                Text(this.isDemoTemplate
                  ? '请按现场导视或询问导诊台，确认实际诊室和候诊位置。'
                  : '在候诊区坐下，留意门口屏幕叫号。快轮到您时手机和手表会提醒。')
                  .fontSize(20)
                  .fontColor('#4A5A66')
                  .lineHeight(30)
                  .textAlign(TextAlign.Center)
                  .margin({ top: 12 })
              }
              .width('100%')
              .padding(26)
              .backgroundColor('#FFFFFF')
              .borderRadius(20)
            } else {
              this.StepCard(this.nav, this.stepIndex)
            }
            Text('找不到路？请找穿工作服的导诊人员帮忙，或者把手机给他们看这一页。')
              .fontSize(15)
              .fontColor('#8A9AA6')
              .lineHeight(22)
              .margin({ top: 14 })
              .width('100%')
          }
          .width('100%')
          .padding({ left: 16, right: 16 })
        }
        .layoutWeight(1)
        .scrollBar(BarState.Off)
        .align(Alignment.Top)

        Column() {
          if (this.arrived) {
            Row() {
              Button('从头再走一遍', { type: ButtonType.Capsule })
                .layoutWeight(1)
                .height(56)
                .fontSize(19)
                .fontColor('#2E6F8E')
                .backgroundColor('#E3EEF4')
                .margin({ right: 10 })
                .onClick(() => {
                  this.onRestart();
                })
              Button('好的，返回', { type: ButtonType.Capsule })
                .layoutWeight(1)
                .height(56)
                .fontSize(19)
                .backgroundColor('#2E6F8E')
                .onClick(() => {
                  this.back();
                })
            }
            .width('100%')
          } else {
            Row() {
              Button('上一步', { type: ButtonType.Capsule })
                .layoutWeight(1)
                .height(52)
                .fontSize(18)
                .fontColor(this.stepIndex > 0 ? '#2E6F8E' : '#B0BAC2')
                .backgroundColor('#E3EEF4')
                .enabled(this.stepIndex > 0)
                .margin({ right: 10 })
                .onClick(() => {
                  this.onPrev();
                })
              Button('再听一遍', { type: ButtonType.Capsule })
                .layoutWeight(1)
                .height(52)
                .fontSize(18)
                .fontColor('#2E6F8E')
                .backgroundColor('#E3EEF4')
                .onClick(() => {
                  this.speakCurrent();
                })
            }
            .width('100%')
            Button(this.stepIndex >= this.nav.steps.length - 1 ? '我到了' : '做完了，下一步', { type: ButtonType.Capsule })
              .width('100%')
              .height(64)
              .fontSize(22)
              .fontWeight(FontWeight.Medium)
              .backgroundColor('#2E6F8E')
              .margin({ top: 10 })
              .onClick(() => {
                this.onNext();
              })
          }
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 10, bottom: 18 })
        .backgroundColor('#EAF0F3')
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#F2F6F8')
  }
}
