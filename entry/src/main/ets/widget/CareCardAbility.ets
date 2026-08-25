/**
 * 智护同行 - 原子化服务卡片提供方
 *
 * 卡片是"主动服务"最轻的触达形态：老人不用打开 App，
 * 在桌面就能看到"下一步该做什么"。
 *
 * 卡片数据来源于端侧存储的当前陪诊安排快照，
 * 由 CardDataStore 在方案确认后写入、在提醒触发后刷新。
 */

import { FormExtensionAbility, formBindingData, formProvider, formInfo } from '@kit.FormKit';
import { Want } from '@kit.AbilityKit';
import { CardDataStore, CardSnapshot } from './CardDataStore';

export default class CareCardAbility extends FormExtensionAbility {

  /** 卡片被添加到桌面时调用 */
  onAddForm(want: Want): formBindingData.FormBindingData {
    const formId: string = want.parameters?.[formInfo.FormParam.IDENTITY_KEY] as string ?? '';
    console.info(`[CareCard] onAddForm formId=${formId}`);

    CardDataStore.rememberFormId(this.context, formId);
    const snapshot: CardSnapshot = CardDataStore.readSync(this.context);
    return formBindingData.createFormBindingData(CardDataStore.toBindingObject(snapshot));
  }

  /** 系统定时刷新（form_config.json 中配置为每小时 + 每天 07:00） */
  onUpdateForm(formId: string): void {
    console.info(`[CareCard] onUpdateForm formId=${formId}`);
    const snapshot: CardSnapshot = CardDataStore.readSync(this.context);
    const data: formBindingData.FormBindingData =
      formBindingData.createFormBindingData(CardDataStore.toBindingObject(snapshot));

    formProvider.updateForm(formId, data).catch((err: Error) => {
      console.error(`[CareCard] updateForm failed: ${err.message}`);
    });
  }

  /** 卡片被移除 */
  onRemoveForm(formId: string): void {
    console.info(`[CareCard] onRemoveForm formId=${formId}`);
    CardDataStore.forgetFormId(this.context, formId);
  }

  /**
   * 卡片上的按钮事件回调
   * 卡片页通过 postCardAction 的 message 类型触发到这里
   */
  onFormEvent(formId: string, message: string): void {
    console.info(`[CareCard] onFormEvent ${formId}: ${message}`);
    try {
      const obj: Record<string, string> = JSON.parse(message) as Record<string, string>;
      const action: string = obj['action'] ?? '';
      if (action === 'refresh') {
        this.onUpdateForm(formId);
      }
    } catch (e) {
      console.error(`[CareCard] onFormEvent parse error: ${e}`);
    }
  }

  onCastToNormalForm(formId: string): void {
    console.info(`[CareCard] onCastToNormalForm ${formId}`);
  }

  onAcquireFormState(want: Want): formInfo.FormState {
    return formInfo.FormState.READY;
  }
}
