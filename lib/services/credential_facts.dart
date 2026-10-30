/// What is literally true about credentials on *this* platform.
///
/// The app runs in two very different places: a browser tab, where the page is
/// a guest with no access to any other site's login state, and an installed
/// app, which can host DeepSeek's own sign-in page and read back what DeepSeek
/// issued. Telling both users the same story would mean telling one of them
/// something false, so the settings copy is derived from these facts rather
/// than written twice by hand.
class CredentialFacts {
  const CredentialFacts({
    required this.where,
    required this.whereDetail,
    required this.howToken,
    required this.howTokenDetail,
    required this.inAppLogin,
  });

  /// One line: where the credential is kept.
  final String where;

  /// The consequence the user actually cares about.
  final String whereDetail;

  /// One line: how a platform token arrives.
  final String howToken;

  /// The mechanism, told plainly.
  final String howTokenDetail;

  /// Whether this build can sign in to DeepSeek inside the app.
  final bool inAppLogin;
}

const String kUploadNote = '本应用没有自己的服务器，凭据不会上传到任何第三方。';

/// [inBrowser] is true only for the web build. [canCaptureInApp] is true for
/// Android, iOS, macOS and Windows, where an in-app webview can read the
/// session token DeepSeek issued on its own page.
CredentialFacts credentialFacts({
  required bool inBrowser,
  required bool canCaptureInApp,
}) {
  if (inBrowser) {
    return const CredentialFacts(
      where: '凭据保存在这个浏览器里',
      whereDetail:
          '存在浏览器的 localStorage 中。换设备、换浏览器，或清掉站点数据，都需要重新连接。$kUploadNote',
      howToken: '令牌就是 Authorization 请求头',
      howTokenDetail:
          '在官方页面登录后按 F12 → Network，点一条发往 platform.deepseek.com 的请求，复制 Authorization 请求头里 Bearer 后面那串。平台没有 userToken 字段，令牌就是这个请求头的值——应用发请求时带的也是它。'
          '注意：浏览器会拦下网页直接对 platform.deepseek.com 的跨域请求（缺 CORS 头）。'
          '本地调试可以起一个反代（tool/dev_proxy.py）并用 ?api_base= 指过去；'
          '正式环境请用桌面或手机客户端，或者自己部署一个反代。',
      inAppLogin: false,
    );
  }
  if (canCaptureInApp) {
    return const CredentialFacts(
      where: '凭据保存在这台设备上',
      whereDetail: '存在本机应用数据里。断开连接会立即清除，卸载应用也会一并清掉。$kUploadNote',
      howToken: '可以在应用内直接登录',
      howTokenDetail: '应用会打开 DeepSeek 官方登录页，账号密码只输入在官方页面上，'
          '登录后读回官方发出的令牌，并且先向 DeepSeek 验证通过才保存。',
      inAppLogin: true,
    );
  }
  return const CredentialFacts(
    where: '凭据保存在这台设备上',
    whereDetail: '存在本机应用数据里。断开连接会立即清除，卸载应用也会一并清掉。$kUploadNote',
    howToken: '令牌就是 Authorization 请求头',
    howTokenDetail: '这个平台没有可用的内置浏览器组件，无法在应用内读取登录态。'
        '在浏览器里登录官方页面后按 F12 → Network，点一条发往 platform.deepseek.com 的请求，'
        '复制 Authorization 请求头里 Bearer 后面那串，粘到下面的输入框。',
    inAppLogin: false,
  );
}
