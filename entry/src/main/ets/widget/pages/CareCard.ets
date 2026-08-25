/**
 * 智护同行 - 桌面卡片 UI
 *
 * 设计约束（老年用户 + 卡片尺寸有限）：
 *  1. 只显示"下一步该做什么"，不做信息罗列
 *  2. 字号尽量大，一眼能看清
 *  3. 点击任意位置直接拉起 App，不设小按钮
 */

const storage = new LocalStorage();

@Entry(storage)
@Component
struct CareCard {
  @LocalStorageProp('hasPlan') hasPlan: boolean = false;
  @LocalStorageProp('title') title: string = '还没有陪诊安排';
  @LocalStorageProp('nextAction') nextAction: string = '点一下，说句话就能安排';
  @LocalStorageProp('detail') detail: string = '';
  @LocalStorageProp('hospital') hospital: string = '';
  @LocalStorageProp('stepIndex') stepIndex: number = 0;
  @LocalStorageProp('stepTotal') stepTotal: number = 0;

  /** 点击卡片拉起主应用 */
  private openApp(): void {
    postCardAction(this, {
      action: 'router',
      abilityName: 'EntryAbility',
      params: {
        'from': 'card'
      }
    });
  }

  build() {
    Column() {
      // 顶部品牌行
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
      .margin({ bottom: 8 })

      if (this.hasPlan) {
        // 主信息：下一步动作，最大字号
        Text(this.nextAction)
          .fontSize(22)
          .fontWeight(FontWeight.Bold)
          .fontColor('#1B2A34')
          .width('100%')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })

        Text(this.title)
          .fontSize(15)
          .fontColor('#4A5A66')
          .width('100%')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .margin({ top: 5 })

        if (this.detail.length > 0) {
          Text(this.detail)
            .fontSize(13)
            .fontColor('#E8874A')
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
        // 空态：引导用户开口
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
    .alignItems(HorizontalAlign.Start)
    .backgroundColor('#FFFFFF')
    .borderRadius(20)
    .onClick(() => {
      this.openApp();
    })
  }
}
