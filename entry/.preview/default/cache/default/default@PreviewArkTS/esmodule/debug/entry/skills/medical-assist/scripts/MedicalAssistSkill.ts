import scriptManager from "@ohos:app.ability.scriptManager";
import type { BusinessError } from "@ohos:base";
import { MedicalAssistService } from "@bundle:com.whatpressure.zhihutongxing/entry/ets/services/MedicalAssistService";
import type { MedicalAssistRequest, MedicalAssistResponse } from "@bundle:com.whatpressure.zhihutongxing/entry/ets/services/MedicalAssistService";
/** 将应用已有的就诊方案能力暴露给系统智能体。 */
export default class MedicalAssistSkill {
    public async planVisit(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
        const hospital: string = argv.length > 0 ? argv[0].trim() : '';
        const department: string = argv.length > 1 ? argv[1].trim() : '';
        const expectedDate: string = argv.length > 2 ? argv[2].trim() : '';
        const purpose: string = argv.length > 3 ? argv[3].trim() : '';
        const isRevisit: boolean = argv.length > 4 && argv[4].trim() === 'true';
        if (purpose.length === 0) {
            await this.fail(info, 'ERR_INVALID_PARAMS', 'purpose is empty', '您这次去医院主要想看病、复查，还是取药呢？');
            return;
        }
        try {
            const request: MedicalAssistRequest = {
                hospital: hospital,
                department: department,
                expectedDate: expectedDate,
                purpose: purpose,
                isRevisit: isRevisit
            };
            const response: MedicalAssistResponse = await MedicalAssistService.planVisit(request);
            if (response.needClarification) {
                await this.fail(info, 'ERR_NEED_CLARIFICATION', 'required slot is empty', response.clarifyQuestion);
                return;
            }
            if (!response.success || response.appointment === null || response.officialChannel === null) {
                await this.fail(info, 'ERR_INTERNAL', 'medical service returned no appointment', '暂时没能查到合适的就诊安排，请稍后再试');
                return;
            }
            const data: Record<string, Object> = {
                'appointment': response.appointment,
                'purpose': purpose,
                'bookingCompleted': false,
                'officialChannelName': response.officialChannel.name,
                'speech': response.speech
            };
            const payload: Record<string, Object> = {
                'type': 'result',
                'status': 'success',
                'data': data
            };
            await this.report(info, { code: 0, result: payload });
        }
        catch (e) {
            const err = e as Error;
            await this.fail(info, 'ERR_INTERNAL', err.message, '暂时没能查到合适的就诊安排，请稍后再试');
        }
    }
    private async fail(info: scriptManager.ArkTSScriptInfo, errCode: string, errMsg: string, suggestion: string): Promise<void> {
        const payload: Record<string, Object> = {
            'type': 'result',
            'status': 'failed',
            'errCode': errCode,
            'errMsg': errMsg,
            'suggestion': suggestion
        };
        await this.report(info, { code: -1, result: payload });
    }
    private async report(info: scriptManager.ArkTSScriptInfo, result: scriptManager.ExecuteResult): Promise<void> {
        try {
            await scriptManager.completeArkTSScriptInApp(info.context, info.requestCode, result);
        }
        catch (e) {
            const err = e as BusinessError;
            console.error(`[MedicalAssistSkill] report failed: ${err.code}, ${err.message}`);
        }
    }
}
