import FormExtensionAbility from "@ohos:app.form.FormExtensionAbility";
import formBindingData from "@ohos:app.form.formBindingData";
import formProvider from "@ohos:app.form.formProvider";
import formInfo from "@ohos:app.form.formInfo";
import type Want from "@ohos:app.ability.Want";
import { CardDataStore } from "@bundle:com.whatpressure.zhihutongxing/entry/ets/widget/CardDataStore";
import type { CardSnapshot } from "@bundle:com.whatpressure.zhihutongxing/entry/ets/widget/CardDataStore";
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
        const data: formBindingData.FormBindingData = formBindingData.createFormBindingData(CardDataStore.toBindingObject(snapshot));
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
        }
        catch (e) {
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
