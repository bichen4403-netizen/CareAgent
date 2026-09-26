/**
 * 智护同行 - 权限按需申请
 *
 * 不在启动时一次性弹多个授权框（老人容易全部点“拒绝”），而是用到哪项才申请哪项，
 * 并在弹框前由页面说明用途：
 *   麦克风 —— 第一次点“说话”时
 *   位置   —— 第一次规划出行路线时
 *   通知   —— 确认挂号、开启提醒时（由 DeviceSyncService 申请）
 * 用户曾经拒绝过时，系统不会再弹授权框，此时拉起“去设置开启”的系统弹窗。
 */

import { abilityAccessCtrl, bundleManager, common, Permissions } from '@kit.AbilityKit';

export class PermissionHelper {

  private static tokenId(): number {
    try {
      const info: bundleManager.BundleInfo = bundleManager.getBundleInfoForSelfSync(
        bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_APPLICATION);
      return info.appInfo.accessTokenId;
    } catch (e) {
      console.error(`[Permission] get token id failed: ${e}`);
      return 0;
    }
  }

  static isGranted(permission: Permissions): boolean {
    const tokenId: number = PermissionHelper.tokenId();
    if (tokenId === 0) {
      return false;
    }
    try {
      const atManager: abilityAccessCtrl.AtManager = abilityAccessCtrl.createAtManager();
      return atManager.checkAccessTokenSync(tokenId, permission) ===
        abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED;
    } catch (e) {
      console.error(`[Permission] check ${permission} failed: ${e}`);
      return false;
    }
  }

  /**
   * 申请权限；primary 获得授权即返回 true。
   * 之前被拒绝过（不再弹框）时，openSettingsIfDenied=true 会拉起系统的“去设置开启”弹窗。
   */
  static async request(ctx: common.UIAbilityContext, permissions: Permissions[], primary: Permissions,
    openSettingsIfDenied: boolean): Promise<boolean> {
    if (PermissionHelper.isGranted(primary)) {
      return true;
    }
    const atManager: abilityAccessCtrl.AtManager = abilityAccessCtrl.createAtManager();
    try {
      await atManager.requestPermissionsFromUser(ctx, permissions);
    } catch (e) {
      console.error(`[Permission] request failed: ${e}`);
    }
    if (PermissionHelper.isGranted(primary)) {
      return true;
    }
    if (!openSettingsIfDenied) {
      return false;
    }
    return await PermissionHelper.openSettingDialog(ctx, [primary]);
  }

  /** 拉起系统的二次授权弹窗（API 12+），用户在弹窗中打开开关即视为授权 */
  static async openSettingDialog(ctx: common.UIAbilityContext, permissions: Permissions[]): Promise<boolean> {
    const atManager: abilityAccessCtrl.AtManager = abilityAccessCtrl.createAtManager();
    try {
      await atManager.requestPermissionOnSetting(ctx, permissions);
    } catch (e) {
      console.warn(`[Permission] setting dialog not shown: ${e}`);
    }
    return PermissionHelper.isGranted(permissions[0]);
  }
}
