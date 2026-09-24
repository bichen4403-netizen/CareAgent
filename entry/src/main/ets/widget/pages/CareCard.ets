/**
 * 智护同行 - 桌面卡片 UI
 *
 * 设计约束（老年用户 + 卡片尺寸有限）：
 *  1. 最大字号只显示“下一步该做什么”
 *  2. 接下来两步用小字预告，卡片小时自动截断
 *  3. 点击任意位置打开“陪诊安排”
 */

const storage: LocalStorage = new LocalStorage();

@Entry(storage)
@Component
struct CareCard {
  @LocalStorageProp('hasPlan') hasPlan: boolean = false;
  @LocalStorageProp('title') title: string = '还没有陪诊安排';
  @LocalStorageProp('nextAction') nextAction: string = '点一下，说句话就能安排';
  @LocalStorageProp('later') later: string = '';
  @LocalStorageProp('hospital') hospital: string = '';
  @LocalStorageProp('stepIndex') stepIndex: number = 0;
  @LocalStorageProp('stepTotal') stepTotal: number = 0;

  private openApp(): void {
    postCardAction(this, {
      action: 'router',
      abilityName: 'EntryAbility',
      params: {
        'target': this.hasPlan ? 'journey' : 'home'
      }
    });
  }

  build() {
    Column() {
      Row() {
        Text('智护同行')
          .fontSize(13)
          .fontColor('#7A8A96')
        Blank()
        if (this.hasPlan && this.stepTotal > 0) {
          Text(`${this.stepIndex}/${this.stepTotal}`)
            .fontSize(12)
            .fontColor('#2E6F8E')
            .padding({ left: 7, right: 7, top: 2, bottom: 2 })
            .backgroundColor('#E3EEF4')
            .borderRadius(8)
        }
      }
      .width('100%')
      .margin({ bottom: 6 })

      if (this.hasPlan) {
        Text('下一步')
          .fontSize(12)
          .fontColor('#8A9AA6')
          .width('100%')
        Text(this.nextAction)
          .fontSize(21)
          .fontWeight(FontWeight.Bold)
          .fontColor('#1B2A34')
          .width('100%')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .margin({ top: 2 })
        Text(this.title)
          .fontSize(15)
          .fontColor('#4A5A66')
          .width('100%')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .margin({ top: 4 })
        if (this.later.length > 0) {
          Text(this.later)
            .fontSize(13)
            .fontColor('#2E6F8E')
            .width('100%')
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .margin({ top: 6 })
        }
        Blank()
        if (this.hospital.length > 0) {
          Text(this.hospital)
            .fontSize(12)
            .fontColor('#8A9AA6')
            .width('100%')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
      } else {
        Column() {
          Text(this.title)
            .fontSize(18)
            .fontWeight(FontWeight.Medium)
            .fontColor('#4A5A66')
          Text(this.nextAction)
            .fontSize(14)
            .fontColor('#8A9AA6')
            .margin({ top: 6 })
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Start)
      }
    }
    .width('100%')
    .height('100%')
    .padding(16)
    .clip(true)
    .alignItems(HorizontalAlign.Start)
    .backgroundColor('#FFFFFF')
    .borderRadius(20)
    .onClick(() => {
      this.openApp();
    })
  }
}
