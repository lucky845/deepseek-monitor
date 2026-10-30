class BalanceInfo {
  final String currency;
  final double totalBalance;
  final double grantedBalance;
  final double toppedUpBalance;
  BalanceInfo({
    required this.currency,
    required this.totalBalance,
    required this.grantedBalance,
    required this.toppedUpBalance,
  });
  factory BalanceInfo.fromJson(Map<String, dynamic> j) => BalanceInfo(
        currency: j['currency'] ?? 'CNY',
        totalBalance:
            double.tryParse(j['total_balance']?.toString() ?? '0') ?? 0,
        grantedBalance:
            double.tryParse(j['granted_balance']?.toString() ?? '0') ?? 0,
        toppedUpBalance:
            double.tryParse(j['topped_up_balance']?.toString() ?? '0') ?? 0,
      );
}

/// One platform wallet as it actually arrives: `{currency, balance,
/// token_estimation}`. Note the key is `balance`, not `total_balance` —
/// reading the API-key shape here silently produced zeroes for every
/// platform-token connection.
class _Wallet {
  final String currency;
  final double balance;
  final int tokenEstimation;
  const _Wallet(this.currency, this.balance, this.tokenEstimation);

  static _Wallet? parse(Object? raw) {
    if (raw is! List || raw.isEmpty) return null;
    final w = raw.first;
    if (w is! Map) return null;
    final balance = w['balance'] ?? w['total_balance'];
    return _Wallet(
      w['currency']?.toString() ?? 'CNY',
      double.tryParse(balance?.toString() ?? '0') ?? 0,
      int.tryParse(w['token_estimation']?.toString() ?? '0') ?? 0,
    );
  }
}

class UserSummary {
  final List<BalanceInfo> balances;
  final String totalAvailableTokenEstimation;
  final int currentToken;
  final double totalCosts;
  UserSummary({
    required this.balances,
    required this.totalAvailableTokenEstimation,
    required this.currentToken,
    required this.totalCosts,
  });
  factory UserSummary.fromJson(Map<String, dynamic> j) {
    final biz = j['data']?['biz_data'] ?? {};
    // DeepSeek splits an account into the wallet you paid for and the wallet
    // it gave you. There is no "total" field — the total is their sum, and it
    // is the only place the three numbers we show can come from.
    final paid = _Wallet.parse(biz['normal_wallets']);
    final gift = _Wallet.parse(biz['bonus_wallets']);
    final wallets = <BalanceInfo>[
      if (paid != null || gift != null)
        BalanceInfo(
          currency: paid?.currency ?? gift?.currency ?? 'CNY',
          totalBalance: (paid?.balance ?? 0) + (gift?.balance ?? 0),
          grantedBalance: gift?.balance ?? 0,
          toppedUpBalance: paid?.balance ?? 0,
        ),
    ];
    final costs = (biz['total_costs'] as List? ?? []);
    double totalCost = 0;
    for (final c in costs) {
      totalCost += double.tryParse(c['amount']?.toString() ?? '0') ?? 0;
    }
    return UserSummary(
      balances: wallets,
      totalAvailableTokenEstimation:
          ((paid?.tokenEstimation ?? 0) + (gift?.tokenEstimation ?? 0))
              .toString(),
      currentToken: biz['current_token'] ?? 0,
      totalCosts: totalCost,
    );
  }
}
