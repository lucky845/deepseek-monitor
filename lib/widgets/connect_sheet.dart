import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import '../providers/auth_provider.dart';
import '../providers/usage_provider.dart';
import '../services/deepseek_service.dart';
import '../services/credential_facts.dart';
import '../services/token_capture.dart';
import '../theme.dart';
import 'liquid.dart';
import 'privacy_card.dart';

/// Bottom sheet with the two credential paths:
///  1. Platform token — user logs in on the official site, copies the token
///     from devtools/localStorage, pastes it here. We never collect the
///     password, so nothing about the account is handled by this app.
///  2. API key — official endpoint, balance only.
class ConnectSheet extends StatefulWidget {
  const ConnectSheet({super.key});
  @override
  State<ConnectSheet> createState() => _ConnectSheetState();
}

class _ConnectSheetState extends State<ConnectSheet> {
  final _tokenCtrl = TextEditingController();
  final _keyCtrl = TextEditingController();
  bool _busy = false;
  bool _revealToken = false;
  bool _revealKey = false;
  String? _error;
  String? _notice;
  String? _ok;

  /// What is already stored. The field itself stays empty: echoing a stored
  /// credential back into a text box shows the secret in plain sight whenever
  /// the user reveals it, opens the sheet on a shared screen, or takes a
  /// screenshot. The masked tail is enough to recognise which one is in use.
  String? _savedToken;
  String? _savedKey;

  @override
  void initState() {
    super.initState();
    final auth = context.read<AuthProvider>();
    _savedToken = _nonEmpty(auth.token);
    _savedKey = _nonEmpty(auth.apiKey);
  }

  static String? _nonEmpty(String? v) {
    final t = v?.trim();
    return (t == null || t.isEmpty) ? null : t;
  }

  /// `••••9f2c` — recognisable, not reusable.
  static String _maskTail(String value) {
    final t = value.trim();
    return t.length <= 4 ? '••••' : '••••${t.substring(t.length - 4)}';
  }

  @override
  void dispose() {
    _tokenCtrl.dispose();
    _keyCtrl.dispose();
    super.dispose();
  }

  /// Desktop/mobile: log in on DeepSeek's own page inside an in-app webview and
  /// let the app harvest the session token. The result then goes through
  /// exactly the same verify-and-save path as a manually pasted token.
  Future<void> _loginInsideApp() async {
    setState(() {
      _error = null;
      _ok = null;
    });
    final token = await capturePlatformToken(context);
    if (!mounted || token == null) return;
    _tokenCtrl.text = token;
    await _saveToken();
  }

  /// Where the person logs in. Kept here so the button and the copyable
  /// address below it can never disagree.
  static const String _signInUrl = 'https://platform.deepseek.com/sign_in';

  /// Opens the official sign-in page.
  ///
  /// The URL goes out first and the checks come after, on purpose: a platform
  /// round-trip before the launch can cost the click its user gesture, and an
  /// eaten popup then looks exactly like a dead button. If neither attempt
  /// opens anything, the address below is already on screen with a copy
  /// button — nobody gets stuck behind a button that does nothing.
  Future<void> _openOfficialLogin() async {
    final uri = Uri.parse(_signInUrl);
    setState(() {
      _error = null;
      _notice = null;
    });
    var opened = false;
    try {
      opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      opened = false;
    }
    if (!opened) {
      try {
        opened = await launchUrl(uri);
      } catch (_) {
        opened = false;
      }
    }
    if (!opened && mounted) {
      setState(() => _error = '浏览器没有打开新标签页（可能被弹窗拦截）。复制下面的地址，手动打开它就能登录。');
    }
  }

  Future<void> _copySignInUrl() async {
    await Clipboard.setData(const ClipboardData(text: _signInUrl));
    if (mounted) {
      setState(() {
        _error = null;
        _notice = '地址已复制，粘贴到浏览器就能登录。';
      });
    }
  }

  /// Always visible next to the button: the address, and a way to take it.
  Widget _signInAddress() {
    return Container(
      margin: const EdgeInsets.only(top: 10),
      padding: const EdgeInsets.fromLTRB(12, 6, 6, 6),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.05),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.white.withOpacity(0.08)),
      ),
      child: Row(
        children: [
          const Expanded(
            child: Text(
              _signInUrl,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: kMuted, fontSize: 12),
            ),
          ),
          TextButton.icon(
            onPressed: _copySignInUrl,
            style: TextButton.styleFrom(foregroundColor: kAccent),
            icon: const Icon(Icons.copy, size: 15),
            label: const Text('复制地址'),
          ),
        ],
      ),
    );
  }

  /// Validate before persisting — an invalid token silently stored would make
  /// the dashboard look broken instead of showing a clear error.
  Future<void> _saveToken() async {
    final typed = _tokenCtrl.text.trim();
    final raw = typed.isEmpty ? (_savedToken ?? '') : typed;
    if (raw.isEmpty) {
      setState(() => _error = '请先粘贴令牌');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _ok = null;
    });
    try {
      await DeepSeekService(token: raw).verifyToken(raw);
      if (!mounted) return;
      final auth = context.read<AuthProvider>();
      final usage = context.read<UsageProvider>();
      auth.setToken(raw);
      await auth.load();
      final now = DateTime.now();
      await usage.fetchRange(raw, DateTime(now.year, now.month, 1),
          DateTime(now.year, now.month + 1, 1));
      if (!mounted) return;
      _tokenCtrl.clear();
      setState(() {
        _busy = false;
        _savedToken = raw;
        _revealToken = false;
        _ok = '令牌有效，已同步真实用量';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = e is DeepSeekException ? e.message : '$e';
      });
    }
  }

  Future<void> _saveApiKey() async {
    final typed = _keyCtrl.text.trim();
    final raw = typed.isEmpty ? (_savedKey ?? '') : typed;
    if (raw.isEmpty) {
      setState(() => _error = '请先填入 API Key');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _ok = null;
    });
    try {
      await DeepSeekService(apiKey: raw).fetchSummary();
      if (!mounted) return;
      context.read<AuthProvider>().setApiKey(raw);
      _keyCtrl.clear();
      setState(() {
        _busy = false;
        _savedKey = raw;
        _revealKey = false;
        _ok = 'API Key 有效，已读取余额';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = e is DeepSeekException ? e.message : '$e';
      });
    }
  }

  Future<void> _pasteFromClipboard(TextEditingController c) async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim();
    if (text == null || text.isEmpty) {
      setState(() => _error = '剪贴板是空的');
      return;
    }
    c.text = text;
    setState(() => _error = null);
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    return Padding(
      padding: EdgeInsets.only(
        left: 24,
        right: 24,
        top: 20,
        bottom: MediaQuery.of(context).viewInsets.bottom + 28,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.18),
                    borderRadius: BorderRadius.circular(2)),
              ),
            ),
            const SizedBox(height: 18),
            Row(
              children: [
                Mascot(size: 54, live: canCaptureTokenInApp, head: true),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('连接 DeepSeek',
                          style: TextStyle(
                              color: kText,
                              fontSize: 19,
                              fontWeight: FontWeight.w700)),
                      const SizedBox(height: 5),
                      // The same fact the settings card leads with, so the two
                      // never tell a different story.
                      Text(platformCredentialFacts.where,
                          style: labelStyle(color: kMuted, size: 11.5)),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            const Text('本应用不碰你的账号密码。你在 DeepSeek 自己的页面上登录，她只把令牌叼回来。',
                style: TextStyle(color: kMuted, fontSize: 12, height: 1.5)),
            const SizedBox(height: 22),

            _sectionHeader('方式一 · 平台令牌（推荐，含模型级用量）', kAccent),
            const SizedBox(height: 10),
            if (canCaptureTokenInApp) ...[
              const Text(
                '在应用内打开 DeepSeek 官方登录页，登录完成后应用会自动读取并验证令牌。'
                '账号密码只输入在官方页面上，大肥鱼看不见。',
                style: TextStyle(color: kMuted, fontSize: 12, height: 1.55),
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: kAccent,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10)),
                  ),
                  onPressed: _busy ? null : _loginInsideApp,
                  icon: const Icon(Icons.login, size: 16),
                  label: const Text('在应用内登录并自动获取令牌'),
                ),
              ),
              const SizedBox(height: 10),
              const Text('自动读取失败时，仍可用下面的手动方式。',
                  style: TextStyle(color: kMuted, fontSize: 12)),
            ] else ...[
              _steps(const [
                '点下面的按钮，在 DeepSeek 官方页面完成登录',
                '登录后按 F12 打开开发者工具 → Network（网络）',
                '点任意一条发往 platform.deepseek.com 的请求，展开 Request Headers，复制 Authorization 里 Bearer 后面那一整串（平台上没有 userToken 这种字段，令牌就是这个请求头的值）',
                '回到这里粘贴并保存',
              ]),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        foregroundColor: kAccent,
                        side: const BorderSide(color: kAccent),
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10)),
                      ),
                      onPressed: _openOfficialLogin,
                      icon: const Icon(Icons.open_in_new, size: 16),
                      label: const Text('打开 DeepSeek 官方登录'),
                    ),
                  ),
                ],
              ),
              _signInAddress(),
            ],
            const SizedBox(height: 12),
            _field(
              _tokenCtrl,
              _savedToken == null ? '粘贴平台令牌' : '粘贴新令牌以替换',
              Icons.key_outlined,
              obscured: !_revealToken,
              onToggleVisibility: () =>
                  setState(() => _revealToken = !_revealToken),
              savedHint: _savedToken == null
                  ? null
                  : '已保存 ${_maskTail(_savedToken!)}，留空则继续使用它',
              onPaste: () => _pasteFromClipboard(_tokenCtrl),
            ),
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: kAccent,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10)),
                ),
                onPressed: _busy ? null : _saveToken,
                child: Text(auth.hasPlatformToken ? '更新令牌' : '验证并保存令牌'),
              ),
            ),
            const SizedBox(height: 26),
            const Divider(color: kSurface2, height: 1),
            const SizedBox(height: 22),
            _sectionHeader('方式二 · API Key（只读余额）', kAccent2),
            const SizedBox(height: 8),
            const Text('在 platform.deepseek.com 的「API Keys」里创建，只用于读取账户余额。',
                style: TextStyle(color: kMuted, fontSize: 12, height: 1.5)),
            const SizedBox(height: 12),
            _field(
              _keyCtrl,
              _savedKey == null ? 'sk-...' : '粘贴新 API Key 以替换',
              Icons.vpn_key_outlined,
              obscured: !_revealKey,
              onToggleVisibility: () =>
                  setState(() => _revealKey = !_revealKey),
              savedHint: _savedKey == null
                  ? null
                  : '已保存 ${_maskTail(_savedKey!)}，留空则继续使用它',
              onPaste: () => _pasteFromClipboard(_keyCtrl),
            ),
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton(
                style: OutlinedButton.styleFrom(
                  foregroundColor: kAccent2,
                  side: const BorderSide(color: kAccent2),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10)),
                ),
                onPressed: _busy ? null : _saveApiKey,
                child: Text(auth.hasApiKey ? '更新 API Key' : '验证并保存 API Key'),
              ),
            ),
            if (_busy) ...[
              const SizedBox(height: 18),
              const Row(
                children: [
                  SizedBox(
                      width: 15,
                      height: 15,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: kAccent)),
                  SizedBox(width: 10),
                  Text('正在向 DeepSeek 验证…',
                      style: TextStyle(color: kMuted, fontSize: 12)),
                ],
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: 18),
              _note(_error!, kDanger, Icons.error_outline),
            ],
            if (_notice != null) ...[
              const SizedBox(height: 18),
              _note(_notice!, kAccent2, Icons.content_copy_outlined),
            ],
            if (_ok != null) ...[
              const SizedBox(height: 18),
              _note(_ok!, kSuccess, Icons.check_circle_outline),
            ],
            if (auth.isLoggedIn) ...[
              const SizedBox(height: 20),
              Center(
                child: TextButton(
                  onPressed: () async {
                    await context.read<AuthProvider>().logout();
                    if (context.mounted) {
                      context.read<UsageProvider>().clear();
                      Navigator.pop(context);
                    }
                  },
                  child: const Text('断开当前连接', style: TextStyle(color: kDanger)),
                ),
              ),
            ],
            const SizedBox(height: 8),
            Row(
              children: [
                const Icon(Icons.lock_outline, size: 12, color: kMuted),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(_storageNote(),
                      style: TextStyle(
                          color: kMuted.withOpacity(0.8), fontSize: 11)),
                ),
              ],
            ),
            // The switch sits with the fields it governs, so the promise above
            // and the storage behaviour below can never drift apart.
            const SizedBox(height: 12),
            const PersistToggle(),
          ],
        ),
      ),
    );
  }

  Widget _sectionHeader(String text, Color color) {
    return Row(
      children: [
        Container(
            width: 3,
            height: 14,
            decoration: BoxDecoration(
                color: color, borderRadius: BorderRadius.circular(2))),
        const SizedBox(width: 8),
        Expanded(
            child: Text(text,
                style: const TextStyle(
                    color: kText, fontSize: 13, fontWeight: FontWeight.w600))),
      ],
    );
  }

  Widget _steps(List<String> steps) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (int i = 0; i < steps.length; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 18,
                  height: 18,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                      color: kSurface2, borderRadius: BorderRadius.circular(5)),
                  child: Text('${i + 1}',
                      style: const TextStyle(
                          color: kMuted,
                          fontSize: 10,
                          fontWeight: FontWeight.w700)),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(steps[i],
                      style: const TextStyle(
                          color: kMuted, fontSize: 12, height: 1.45)),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _field(
    TextEditingController c,
    String hint,
    IconData icon, {
    required bool obscured,
    required VoidCallback onToggleVisibility,
    String? savedHint,
    VoidCallback? onPaste,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: c,
          style: const TextStyle(color: kText, fontSize: 13),
          obscureText: obscured,
          autocorrect: false,
          enableSuggestions: false,
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: const TextStyle(color: kMuted, fontSize: 13),
            prefixIcon: Icon(icon, color: kMuted, size: 18),
            suffixIcon: SizedBox(
              width: onPaste == null ? 48 : 96,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    tooltip: obscured ? '显示' : '隐藏',
                    onPressed: onToggleVisibility,
                    icon: Icon(
                        obscured
                            ? Icons.visibility_off_outlined
                            : Icons.visibility_outlined,
                        color: kMuted,
                        size: 18),
                  ),
                  if (onPaste != null)
                    IconButton(
                      tooltip: '从剪贴板粘贴',
                      onPressed: onPaste,
                      icon: const Icon(Icons.content_paste,
                          color: kMuted, size: 18),
                    ),
                ],
              ),
            ),
            filled: true,
            fillColor: kSurface2,
            contentPadding: const EdgeInsets.symmetric(vertical: 14),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide.none,
            ),
          ),
        ),
        if (savedHint != null) ...[
          const SizedBox(height: 6),
          Row(
            children: [
              const Icon(Icons.check_circle_outline, color: kSuccess, size: 13),
              const SizedBox(width: 6),
              Expanded(
                child: Text(savedHint,
                    style: const TextStyle(
                        color: kMuted, fontSize: 11.5, height: 1.4)),
              ),
            ],
          ),
        ],
      ],
    );
  }

  Widget _note(String text, Color color, IconData icon) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withOpacity(0.12),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withOpacity(0.35)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color, size: 16),
          const SizedBox(width: 8),
          Expanded(
              child: Text(text,
                  style: const TextStyle(
                      color: kText, fontSize: 12, height: 1.45))),
        ],
      ),
    );
  }
}

/// One true sentence about where the credential lands on this platform. On the
/// web it is the browser's storage and the reader should know that; on an
/// installed build it is the app's own data. The promise after it holds
/// everywhere, so it is not duplicated per platform.
String _storageNote() => runsInBrowser
    ? '凭据保存在这个浏览器里（localStorage）。$kUploadNote'
    : '凭据只保存在本机（应用数据）。$kUploadNote';
