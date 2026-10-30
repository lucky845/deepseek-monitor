import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/auth_provider.dart';
import '../services/credential_facts.dart';
import '../services/token_capture.dart';
import '../theme.dart';
import 'ledger.dart';

/// The trust statement, told in the order a person actually wonders about it:
/// what happens to my password, where does the credential end up, and can I stop
/// it from being written down.
///
/// Two of the four answers differ between a browser tab and an installed app,
/// because the platforms really do differ — a web page cannot read another
/// site's login state, an app can host the sign-in page. Those sentences come
/// from [credentialFacts], so the copy cannot drift away from the code.
class PrivacyCard extends StatelessWidget {
  const PrivacyCard({super.key, this.compact = false});

  final bool compact;

  @override
  Widget build(BuildContext context) {
    final facts = platformCredentialFacts;
    return Panel(
      title: '凭据怎么用',
      hint: compact ? null : (facts.inAppLogin ? null : '只用来查数据'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const _Point(
            icon: Icons.password_outlined,
            title: '账号密码不经过本应用',
            body: '登录始终发生在 DeepSeek 官方页面上，本应用不接触你的账号密码，'
                '只接收官方发出的令牌。',
          ),
          _Point(
            icon: facts.inAppLogin
                ? Icons.phone_iphone_outlined
                : Icons.public_outlined,
            title: facts.where,
            body: facts.whereDetail,
            keyed: ValueKey(facts.where),
          ),
          _Point(
            icon: facts.inAppLogin ? Icons.login_outlined : Icons.content_paste,
            title: facts.howToken,
            body: facts.howTokenDetail,
            keyed: ValueKey(facts.howToken),
          ),
          const _Point(
            icon: Icons.save_outlined,
            title: '保不保存由你决定',
            body: '默认只保存在本机，下次打开自动恢复。打开下面的开关就完全不落盘，'
                '凭据只留在内存里，退出应用即失效。',
          ),
          const SizedBox(height: 4),
          const PersistToggle(),
        ],
      ),
    );
  }
}

/// The one control that changes where credentials live. Lives in the settings
/// view and inside the connect sheet, next to the fields that fill it.
class PersistToggle extends StatelessWidget {
  const PersistToggle({super.key});

  @override
  Widget build(BuildContext context) {
    final persist = context.watch<AuthProvider>().persistCredentials;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 4, 6, 4),
      decoration: BoxDecoration(
        color:
            persist ? Colors.white.withOpacity(0.06) : kWarn.withOpacity(0.10),
        borderRadius: BorderRadius.circular(11),
        border: Border.all(
          color: persist
              ? Colors.white.withOpacity(0.12)
              : kWarn.withOpacity(0.38),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '不保存到本机',
                  style: TextStyle(
                    color: persist ? kText : kWarn,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  persist
                      ? '当前：凭据留在本机，退出后仍然有效。'
                      : '当前：凭据只在内存中，退出应用即失效，本机不留任何记录。',
                  style: labelStyle(color: kMuted, size: 11.5),
                ),
              ],
            ),
          ),
          Switch(
            value: !persist,
            activeColor: kWarn,
            onChanged: (v) => context.read<AuthProvider>().setPersist(!v),
          ),
        ],
      ),
    );
  }
}

class _Point extends StatelessWidget {
  const _Point({
    required this.icon,
    required this.title,
    required this.body,
    this.keyed,
  });

  final IconData icon;
  final String title;
  final String body;
  final Key? keyed;

  @override
  Widget build(BuildContext context) {
    return Padding(
      key: keyed,
      padding: const EdgeInsets.only(bottom: 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 16, color: kAccent.withOpacity(0.9)),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    color: kText,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 3),
                Text(body, style: bodyStyle()),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
