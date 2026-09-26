/**
 * 智护同行 - 我的（档案 / 病历 / 演示工具 / 隐私）
 *
 * 隐私承诺的落地：档案和病历只存在这台手机上，可以随时查看、删除，或一键清除全部数据。
 * 模拟器不支持拍照识别时，可以在这里手动录入病历。
 * “演示工具”供答辩现场稳定复现异常回流：模拟就诊日暴雨、模拟医生临时停诊。
 */

import { common } from '@kit.AbilityKit';
import { DemoSettings, RecordSource, ServiceRecord, UserProfile } from '../core/AgentTypes';
import { ContextStore } from '../core/ContextStore';
import { JourneyStore } from '../core/JourneyStore';
import { DateUtil } from '../core/DateUtil';
import { NluRules } from '../core/NluRules';
import { DeviceSyncService } from '../services/DeviceSyncService';
import { BackendConfig } from '../config/BackendConfig';
import { CardDataStore } from '../widget/CardDataStore';
import { UiLabels } from '../utils/UiLabels';

class FollowUpOption {
  label: string = '';
  days: number = 0;

  constructor(label: string, days: number) {
    this.label = label;
    this.days = days;
  }
}

const FOLLOW_UP_OPTIONS: FollowUpOption[] = [
  new FollowUpOption('不用', 0),
  new FollowUpOption('2周', 14),
  new FollowUpOption('1个月', 30),
  new FollowUpOption('3个月', 90)
];

@Entry
@Component
struct ProfilePage {
  // 档案
  @State name: string = '';
  @State ageText: string = '';
  @State homeAddress: string = '';
  @State hospitals: string = '';
  @State contact: string = '';
  // 病历
  @State records: ServiceRecord[] = [];
  @State showForm: boolean = false;
  @State fHospital: string = '';
  @State fDepartment: string = '';
  @State fDoctor: string = '';
  @State fDate: string = '';
  @State fFollowUp: number = 0;
  @State fPrescription: string = '';
  // 演示
  @State simulateStorm: boolean = false;
  @State simulateDoctorOff: boolean = false;

  private scroller: Scroller = new Scroller();

  aboutToAppear(): void {
    this.loadAll();
    const params: Object = this.getUIContext().getRouter().getParams();
    if (params !== undefined && params !== null && typeof params === 'object') {
      const mode: Object | undefined = (params as Record<string, Object>)['mode'];
      if (mode === 'addRecord') {
        this.openForm();
      }
    }
  }

  private loadAll(): void {
    const store: ContextStore = ContextStore.getInstance();
    const p: UserProfile = store.getProfile();
    this.name = p.name;
    this.ageText = p.age > 0 ? `${p.age}` : '';
    this.homeAddress = p.homeAddress;
    this.hospitals = p.preferredHospitals.join('、');
    this.contact = p.emergencyContact;
    this.records = store.getRecords();
    const d: DemoSettings = store.getDemoSettings();
    this.simulateStorm = d.simulateStorm;
    this.simulateDoctorOff = d.simulateDoctorOff;
  }

  private hostContext(): common.UIAbilityContext | null {
    const ctx: Context | undefined = this.getUIContext().getHostContext();
    return ctx === undefined ? null : ctx as common.UIAbilityContext;
  }

  private toast(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message, duration: 2000 });
    } catch (e) {
      console.warn(`[ProfilePage] toast failed: ${e}`);
    }
  }

  private confirm(title: string, message: string, okText: string, onOk: () => void): void {
    this.getUIContext().showAlertDialog({
      title: title,
      message: message,
      primaryButton: {
        value: '取消',
        action: () => {
          console.info('[ProfilePage] dialog cancelled');
        }
      },
      secondaryButton: {
        value: okText,
        fontColor: '#C8553D',
        action: () => {
          onOk();
        }
      }
    });
  }

  // ==================== 档案 ====================

  private async saveProfile(): Promise<void> {
    const store: ContextStore = ContextStore.getInstance();
    const old: UserProfile = store.getProfile();
    const age: number = parseInt(this.ageText);
    const list: string[] = [];
    const parts: string[] = this.hospitals.split(/[、,，\s]+/);
    for (let i = 0; i < parts.length; i++) {
      const h: string = parts[i].trim();
      if (h.length > 0 && list.indexOf(h) < 0) {
        list.push(h);
      }
    }
    const phone: string = this.contact.replace(/[^\d+]/g, '');
    const p: UserProfile = {
      name: this.name.trim(),
      age: isNaN(age) ? 0 : Math.max(0, Math.min(120, age)),
      homeAddress: this.homeAddress.trim(),
      preferredHospitals: list,
      chronicTags: old.chronicTags,
      accessibilityMode: old.accessibilityMode,
      emergencyContact: phone
    };
    await store.saveProfile(p);
    this.contact = phone;
    this.toast('已保存');
  }

  // ==================== 病历 ====================

  private openForm(): void {
    this.fHospital = '';
    this.fDepartment = '';
    this.fDoctor = '';
    this.fDate = DateUtil.todayStr(Date.now());
    this.fFollowUp = 0;
    this.fPrescription = '';
    this.showForm = true;
  }

  private async saveRecord(): Promise<void> {
    const hospital: string = this.fHospital.trim();
    if (hospital.length === 0) {
      this.toast('请填写医院');
      return;
    }
    let date: string = DateUtil.normalizeYmd(this.fDate);
    if (date.length === 0) {
      date = DateUtil.parseChineseDate(this.fDate, Date.now()).date;
    }
    if (date.length === 0) {
      this.toast('日期格式请写成 2026-09-23');
      return;
    }
    let dept: string = this.fDepartment.trim();
    const resolved: string = NluRules.resolveDepartment(dept);
    if (resolved.length > 0) {
      dept = resolved;
    }
    const r: ServiceRecord = {
      recordId: `manual_${Date.now()}`,
      hospital: hospital,
      department: dept,
      doctorName: this.fDoctor.trim(),
      visitDate: date,
      followUpDays: this.fFollowUp,
      prescription: this.fPrescription.trim(),
      source: RecordSource.MANUAL_INPUT,
      confirmed: true
    };
    await ContextStore.getInstance().addRecord(r);
    this.showForm = false;
    this.records = ContextStore.getInstance().getRecords();
    this.toast('病历已保存到手机');
  }

  private deleteRecord(r: ServiceRecord): void {
    this.confirm('删除这条病历？', `${r.visitDate} ${r.hospital}${r.department}`, '删除', () => {
      ContextStore.getInstance().removeRecord(r.recordId).then(() => {
        this.records = ContextStore.getInstance().getRecords();
        this.toast('已删除');
      });
    });
  }

  // ==================== 演示与隐私 ====================

  private async saveDemo(): Promise<void> {
    const d: DemoSettings = { simulateStorm: this.simulateStorm, simulateDoctorOff: this.simulateDoctorOff };
    await ContextStore.getInstance().saveDemoSettings(d);
  }

  private resetDemo(): void {
    this.confirm('恢复演示数据？', '会清空现在的病历和行程，写入演示档案和一条快到复诊时间的记录。', '恢复', () => {
      this.doResetDemo();
    });
  }

  private async doResetDemo(): Promise<void> {
    await DeviceSyncService.cancelAllReminders();
    await JourneyStore.getInstance().clearAll();
    await ContextStore.getInstance().resetDemoData(Date.now());
    await this.writeEmptyCard();
    this.loadAll();
    this.toast('演示数据已恢复');
  }

  private clearAllData(): void {
    this.confirm('清除全部数据？', '档案、病历、行程和提醒都会从这台手机上删除，无法恢复。', '全部清除', () => {
      this.doClearAll();
    });
  }

  private async doClearAll(): Promise<void> {
    await DeviceSyncService.cancelAllReminders();
    await JourneyStore.getInstance().clearAll();
    await ContextStore.getInstance().clearAll();
    await this.writeEmptyCard();
    this.loadAll();
    this.toast('已清除全部数据');
  }

  private async writeEmptyCard(): Promise<void> {
    const ctx: common.UIAbilityContext | null = this.hostContext();
    if (ctx !== null) {
      await CardDataStore.writeSnapshot(ctx, CardDataStore.emptySnapshot());
    }
  }

  // ==================== UI ====================

  @Builder
  Section(title: string) {
    Text(title)
      .fontSize(20)
      .fontWeight(FontWeight.Bold)
      .fontColor('#1B2A34')
      .width('100%')
      .margin({ bottom: 8 })
  }

  @Builder
  FieldLabel(label: string) {
    Text(label)
      .fontSize(16)
      .fontColor('#7A8A96')
      .width('100%')
      .margin({ top: 10, bottom: 4 })
  }

  @Builder
  RecordRow(r: ServiceRecord) {
    Row() {
      Column() {
        Text(`${r.visitDate}  ${r.hospital}`)
          .fontSize(17)
          .fontColor('#22303C')
        Text(`${r.department}${r.doctorName.length > 0 ? ' · ' + r.doctorName : ''} · ${UiLabels.followUp(r.followUpDays)}`)
          .fontSize(15)
          .fontColor('#5A6A76')
          .margin({ top: 2 })
        if (r.prescription.length > 0) {
          Text(`用药：${r.prescription}`)
            .fontSize(14)
            .fontColor('#7A8A96')
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .margin({ top: 2 })
        }
        Text(UiLabels.recordSource(r.source))
          .fontSize(12)
          .fontColor('#2E6F8E')
          .margin({ top: 4 })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      Text('删除')
        .fontSize(16)
        .fontColor('#C8553D')
        .padding(10)
        .onClick(() => {
          this.deleteRecord(r);
        })
    }
    .width('100%')
    .padding({ top: 10, bottom: 10 })
    .border({ width: { bottom: 1 }, color: '#EEF2F4' })
  }

  build() {
    Column() {
      Row() {
        Text('‹ 返回')
          .fontSize(18)
          .fontColor('#2E6F8E')
          .padding({ top: 6, bottom: 6, right: 12 })
          .onClick(() => {
            this.getUIContext().getRouter().back();
          })
        Text('我的')
          .fontSize(22)
          .fontWeight(FontWeight.Bold)
          .fontColor('#1B2A34')
        Blank()
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 14, bottom: 10 })

      Scroll(this.scroller) {
        Column() {
          // 档案
          Column() {
            this.Section('我的档案')
            this.FieldLabel('称呼')
            TextInput({ text: this.name, placeholder: '例如：张秀兰' })
              .fontSize(18)
              .height(48)
              .onChange((v: string) => {
                this.name = v;
              })
            this.FieldLabel('年龄')
            TextInput({ text: this.ageText, placeholder: '例如：72' })
              .fontSize(18)
              .height(48)
              .type(InputType.Number)
              .maxLength(3)
              .onChange((v: string) => {
                this.ageText = v;
              })
            this.FieldLabel('家庭住址（出发地）')
            TextInput({ text: this.homeAddress, placeholder: '例如：幸福小区3栋' })
              .fontSize(18)
              .height(48)
              .onChange((v: string) => {
                this.homeAddress = v;
              })
            this.FieldLabel('常去医院（多个用顿号隔开）')
            TextInput({ text: this.hospitals, placeholder: '例如：市第一人民医院' })
              .fontSize(18)
              .height(48)
              .onChange((v: string) => {
                this.hospitals = v;
              })
            this.FieldLabel('紧急联系人电话')
            TextInput({ text: this.contact, placeholder: '家人手机号，紧急时一键拨打' })
              .fontSize(18)
              .height(48)
              .type(InputType.PhoneNumber)
              .onChange((v: string) => {
                this.contact = v;
              })
            Button('保存档案', { type: ButtonType.Capsule })
              .width('100%')
              .height(50)
              .fontSize(18)
              .backgroundColor('#2E6F8E')
              .margin({ top: 14 })
              .onClick(() => {
                this.saveProfile();
              })
          }
          .width('100%')
          .padding(18)
          .backgroundColor('#FFFFFF')
          .borderRadius(16)
          .margin({ bottom: 14 })

          // 病历
          Column() {
            this.Section('就诊记录')
            if (this.records.length === 0) {
              Text('还没有记录。看完病拍一下处方单，或在下面手动添加。')
                .fontSize(16)
                .fontColor('#8A9AA6')
                .width('100%')
                .margin({ bottom: 8 })
            }
            ForEach(this.records, (r: ServiceRecord) => {
              this.RecordRow(r)
            }, (r: ServiceRecord) => `${r.recordId}_${r.visitDate}_${r.followUpDays}`)

            if (this.showForm) {
              Column() {
                this.FieldLabel('医院')
                TextInput({ text: this.fHospital, placeholder: '例如：市第一人民医院' })
                  .fontSize(18)
                  .height(48)
                  .onChange((v: string) => {
                    this.fHospital = v;
                  })
                this.FieldLabel('科室（也可以写病情，如“高血压”）')
                TextInput({ text: this.fDepartment, placeholder: '例如：心血管内科' })
                  .fontSize(18)
                  .height(48)
                  .onChange((v: string) => {
                    this.fDepartment = v;
                  })
                this.FieldLabel('医生（可不填）')
                TextInput({ text: this.fDoctor, placeholder: '例如：王建国' })
                  .fontSize(18)
                  .height(48)
                  .onChange((v: string) => {
                    this.fDoctor = v;
                  })
                this.FieldLabel('就诊日期')
                TextInput({ text: this.fDate, placeholder: '2026-09-23' })
                  .fontSize(18)
                  .height(48)
                  .onChange((v: string) => {
                    this.fDate = v;
                  })
                this.FieldLabel('医生让多久后复诊')
                Row({ space: 8 }) {
                  ForEach(FOLLOW_UP_OPTIONS, (o: FollowUpOption) => {
                    Text(o.label)
                      .fontSize(17)
                      .fontColor(this.fFollowUp === o.days ? '#FFFFFF' : '#2E6F8E')
                      .backgroundColor(this.fFollowUp === o.days ? '#2E6F8E' : '#E3EEF4')
                      .padding({ left: 14, right: 14, top: 8, bottom: 8 })
                      .borderRadius(16)
                      .onClick(() => {
                        this.fFollowUp = o.days;
                      })
                  }, (o: FollowUpOption) => `fu_${o.days}`)
                }
                .width('100%')
                this.FieldLabel('用药（照处方单抄，可不填）')
                TextArea({ text: this.fPrescription, placeholder: '例如：苯磺酸氨氯地平片 每日1次' })
                  .fontSize(17)
                  .height(80)
                  .onChange((v: string) => {
                    this.fPrescription = v;
                  })
                Row() {
                  Button('取消', { type: ButtonType.Capsule })
                    .layoutWeight(1)
                    .height(48)
                    .fontSize(17)
                    .fontColor('#7A8A96')
                    .backgroundColor('#EEF3F6')
                    .margin({ right: 10 })
                    .onClick(() => {
                      this.showForm = false;
                    })
                  Button('保存记录', { type: ButtonType.Capsule })
                    .layoutWeight(1)
                    .height(48)
                    .fontSize(17)
                    .backgroundColor('#2E6F8E')
                    .onClick(() => {
                      this.saveRecord();
                    })
                }
                .width('100%')
                .margin({ top: 14 })
              }
              .width('100%')
              .padding(14)
              .backgroundColor('#F6F9FA')
              .borderRadius(12)
              .margin({ top: 8 })
            } else {
              Button('手动添加一条', { type: ButtonType.Capsule })
                .width('100%')
                .height(48)
                .fontSize(17)
                .fontColor('#2E6F8E')
                .backgroundColor('#E3EEF4')
                .margin({ top: 10 })
                .onClick(() => {
                  this.openForm();
                })
            }
          }
          .width('100%')
          .padding(18)
          .backgroundColor('#FFFFFF')
          .borderRadius(16)
          .margin({ bottom: 14 })

          // 演示工具
          Column() {
            this.Section('演示工具')
            Row() {
              Column() {
                Text('模拟就诊日暴雨')
                  .fontSize(17)
                  .fontColor('#22303C')
                Text('下次安排时触发“恶劣天气 → 重新规划出行和提醒”')
                  .fontSize(14)
                  .fontColor('#8A9AA6')
                  .margin({ top: 2 })
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)
              Toggle({ type: ToggleType.Switch, isOn: this.simulateStorm })
                .onChange((isOn: boolean) => {
                  this.simulateStorm = isOn;
                  this.saveDemo();
                })
            }
            .width('100%')
            .padding({ top: 6, bottom: 6 })
            Row() {
              Column() {
                Text('模拟医生临时停诊')
                  .fontSize(17)
                  .fontColor('#22303C')
                Text('下次安排时触发“停诊 → 换医生并重排全流程”')
                  .fontSize(14)
                  .fontColor('#8A9AA6')
                  .margin({ top: 2 })
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)
              Toggle({ type: ToggleType.Switch, isOn: this.simulateDoctorOff })
                .onChange((isOn: boolean) => {
                  this.simulateDoctorOff = isOn;
                  this.saveDemo();
                })
            }
            .width('100%')
            .padding({ top: 6, bottom: 6 })
            Button('恢复演示数据', { type: ButtonType.Capsule })
              .width('100%')
              .height(48)
              .fontSize(17)
              .fontColor('#2E6F8E')
              .backgroundColor('#E3EEF4')
              .margin({ top: 10 })
              .onClick(() => {
                this.resetDemo();
              })
            Text(BackendConfig.enabled()
              ? `当前：已连接网关 ${BackendConfig.baseUrl()}（大模型、天气、路线、医院检索）`
              : '当前：离线演示模式（未配置网关，使用离线规则理解与演示数据）')
              .fontSize(14)
              .fontColor('#7A8A96')
              .lineHeight(20)
              .margin({ top: 10 })
              .width('100%')
          }
          .width('100%')
          .padding(18)
          .backgroundColor('#FFFFFF')
          .borderRadius(16)
          .margin({ bottom: 14 })

          // 隐私
          Column() {
            this.Section('隐私与数据')
            Text('档案、病历和行程只保存在这台手机上；发给大模型的内容不含姓名、住址和医生姓名。')
              .fontSize(16)
              .fontColor('#4A5A66')
              .lineHeight(24)
              .width('100%')
            Button('清除全部数据', { type: ButtonType.Capsule })
              .width('100%')
              .height(48)
              .fontSize(17)
              .fontColor('#C8553D')
              .backgroundColor('#FBECE8')
              .margin({ top: 12 })
              .onClick(() => {
                this.clearAllData();
              })
          }
          .width('100%')
          .padding(18)
          .backgroundColor('#FFFFFF')
          .borderRadius(16)
          .margin({ bottom: 20 })
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 4 })
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .align(Alignment.Top)
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#F2F6F8')
  }
}
