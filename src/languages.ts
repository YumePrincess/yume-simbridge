export const serviceLanguages = [
  "en",
  "fr",
  "ja",
  "zh-Hans",
  "zh-Hant",
] as const;
export type ServiceLanguage = (typeof serviceLanguages)[number];
const en = {
  test: "SIM Hub notification test",
  testBody: "The direct Gotify connection is working.",
  pin: "Enter your access code followed by the pound key.",
  retry: "Incorrect code. Try again followed by pound.",
  number:
    "Enter a local number, or press star for plus before an international country code and number. Finish with pound.",
  disabled: "Telephone gateway is not enabled.",
  invalid: "Invalid destination number.",
  offline: "Cellular gateway is offline.",
  denied: "Access denied.",
  expired: "Authorization expired.",
  unknown: "Unknown or hidden number",
  incoming: "SIM incoming call",
  sms: "SIM message",
  from: "Original caller",
  forward: "Forwarding via Twilio {via} to {to}.",
  display: "Your phone will display {via}.",
};
export type Prompt = keyof typeof en;
export const messages: Record<ServiceLanguage, Record<Prompt, string>> = {
  en,
  fr: {
    test: "Test de notification SIM Hub",
    testBody: "La connexion directe à Gotify fonctionne.",
    pin: "Saisissez votre code d’accès, puis appuyez sur dièse.",
    retry: "Code incorrect. Réessayez, puis appuyez sur dièse.",
    number:
      "Saisissez un numéro local. Pour un numéro international, appuyez sur étoile pour le signe plus, puis saisissez l’indicatif et le numéro. Terminez par dièse.",
    disabled: "La passerelle téléphonique n’est pas activée.",
    invalid: "Numéro de destination incorrect.",
    offline: "La passerelle mobile est hors ligne.",
    denied: "Accès refusé.",
    expired: "L’autorisation a expiré.",
    unknown: "Numéro inconnu ou masqué",
    incoming: "Appel SIM entrant",
    sms: "Message SIM",
    from: "Numéro de l’appelant",
    forward: "Transfert via Twilio {via} vers {to}.",
    display: "Votre téléphone affichera {via}.",
  },
  ja: {
    test: "SIM Hub 通知テスト",
    testBody: "Gotify への直接接続が動作しています。",
    pin: "暗証番号を入力し、シャープを押してください。",
    retry: "暗証番号が違います。もう一度入力し、シャープを押してください。",
    number:
      "国内番号を入力してください。国際電話は最初に星印でプラスを入力し、国番号と番号を入力してください。最後にシャープを押してください。",
    disabled: "電話ゲートウェイは有効になっていません。",
    invalid: "電話番号が正しくありません。",
    offline: "携帯電話ゲートウェイはオフラインです。",
    denied: "アクセスが拒否されました。",
    expired: "認証の有効期限が切れました。",
    unknown: "不明または非通知",
    incoming: "SIM 着信",
    sms: "SIM メッセージ",
    from: "元の発信者番号",
    forward: "Twilio {via} 経由で {to} に転送します。",
    display: "着信画面には {via} が表示されます。",
  },
  "zh-Hans": {
    test: "SIM Hub 推送测试",
    testBody: "Gotify 直连推送已正常工作。",
    pin: "请输入电话接入密码，然后按井号键。",
    retry: "密码错误，请重新输入，然后按井号键。",
    number:
      "本地号码请直接输入。国际号码请先按星号键表示加号，再输入国家代码和号码。最后按井号键。",
    disabled: "电话网关尚未启用。",
    invalid: "目标电话号码无效。",
    offline: "蜂窝电话网关当前离线。",
    denied: "验证失败，无法继续。",
    expired: "电话授权已过期。",
    unknown: "未知／隐藏号码",
    incoming: "SIM 来电",
    sms: "SIM 短信",
    from: "原始来电号码",
    forward: "正在通过 Twilio {via} 转接至 {to}。",
    display: "接听页面显示的号码为 {via}。",
  },
  "zh-Hant": {
    test: "SIM Hub 推播測試",
    testBody: "Gotify 直接連線推播已正常運作。",
    pin: "請輸入電話接入密碼，然後按井字鍵。",
    retry: "密碼錯誤，請重新輸入，然後按井字鍵。",
    number:
      "本地號碼請直接輸入。國際號碼請先按星號鍵代表加號，再輸入國家代碼與號碼。最後按井字鍵。",
    disabled: "電話閘道尚未啟用。",
    invalid: "目標電話號碼無效。",
    offline: "行動電話閘道目前離線。",
    denied: "驗證失敗，無法繼續。",
    expired: "電話授權已過期。",
    unknown: "未知／隱藏號碼",
    incoming: "SIM 來電",
    sms: "SIM 簡訊",
    from: "原始來電號碼",
    forward: "正在透過 Twilio {via} 轉接至 {to}。",
    display: "接聽畫面顯示的號碼為 {via}。",
  },
};
export const speech: Record<
  ServiceLanguage,
  { locale: string; voice: string }
> = {
  en: { locale: "en-US", voice: "woman" },
  fr: { locale: "fr-FR", voice: "woman" },
  ja: { locale: "ja-JP", voice: "Polly.Mizuki" },
  "zh-Hans": { locale: "zh-CN", voice: "Polly.Zhiyu" },
  "zh-Hant": { locale: "zh-CN", voice: "Polly.Zhiyu" },
};
export function prompt(
  language: ServiceLanguage,
  key: Prompt,
  values: Record<string, string> = {},
) {
  return messages[language][key].replace(
    /\{(\w+)\}/g,
    (_, k) => values[k] ?? "",
  );
}
