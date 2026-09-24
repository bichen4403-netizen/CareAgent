/**
 * 智护同行 - 桌面卡片提供方
 *
 * 卡片是“主动服务”最轻的触达形态：老人不用打开 App，在桌面就能看到下一步该做什么。
 * 每次刷新（系统每 30 分钟 + 每天 07:00，或主应用主动推送）都按当前时间重新计算下一步。
 */

import { FormExtensionAbility, formBindingData, formProvider, formInfo } from '@kit.FormKit';
import { Want } from '@kit.AbilityKit';
import { CardDataStore, CardSnapshot } from './CardDataStore';

export default class CareCardAbility extends FormExtensionAbility {

  private buildData(): formBindingData.FormBindingData {
    const snapshot: CardSnapshot = CardDataStore.readSnapshotSync(this.context);
    return formBindingData.createFormBindingData(CardDataStore.computeView(snapshot, Date.now()));
  }

  onAddForm(want: Want): formBindingData.FormBindingData {
    let formId: string = '';
    if (want.parameters !== undefined) {
      const v: Object | undefined = want.parameters[formInfo.FormParam.IDENTITY_KEY];
      formId = typeof v === 'string' ? v : '';
    }
    console.info(`[CareCard] onAddForm formId=${formId}`);
    CardDataStore.rememberFormId(this.context, formId);
    return this.buildData();
  }

  onUpdateForm(formId: string): void {
    formProvider.updateForm(formId, this.buildData()).catch((err: Error) => {
      console.error(`[CareCard] updateForm failed: ${err.message}`);
    });
  }

  onRemoveForm(formId: string): void {
    console.info(`[CareCard] onRemoveForm formId=${formId}`);
    CardDataStore.forgetFormId(this.context, formId);
  }

  onFormEvent(formId: string, message: string): void {
    try {
      const obj: Record<string, Object> = JSON.parse(message) as Record<string, Object>;
      if (obj['action'] === 'refresh') {
        this.onUpdateForm(formId);
      }
    } catch (e) {
      console.error(`[CareCard] onFormEvent parse error: ${e}`);
    }
  }

  onAcquireFormState(want: Want): formInfo.FormState {
    return formInfo.FormState.READY;
  }
}
